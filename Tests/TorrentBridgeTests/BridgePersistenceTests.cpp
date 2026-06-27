#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <array>
#include <filesystem>
#include <span>
#include <string>
#include <system_error>
#include <vector>

namespace {

[[nodiscard]] bool has_owner_read_write_only(fs::path const &path)
{
    fs::perms const permissions = fs::status(path).permissions();
    return (permissions & fs::perms::owner_read) != fs::perms::none
        && (permissions & fs::perms::owner_write) != fs::perms::none
        && (permissions & fs::perms::owner_exec) == fs::perms::none
        && (permissions & fs::perms::group_all) == fs::perms::none
        && (permissions & fs::perms::others_all) == fs::perms::none;
}

[[nodiscard]] bool directory_contains_temporary_file(fs::path const &directory)
{
    for (auto const &entry : fs::directory_iterator(directory)) {
        if (entry.path().filename().string().contains(kTempExtension)) {
            return true;
        }
    }
    return false;
}

} // namespace

TEST_CASE("read_file reads regular files and classifies bad inputs")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const file_path = temporary_directory.path() / "data.bin";
    bridge_tests::write_text_file(file_path, "abc");

    FileReadResult const read = read_file(file_path, 3U);
    REQUIRE(read.has_value());
    CHECK(std::string(read->begin(), read->end()) == "abc");

    FileReadResult const too_large = read_file(file_path, 2U);
    REQUIRE_FALSE(too_large);
    CHECK(too_large.error() == FileReadFailure::too_large);

    fs::path const empty_path = temporary_directory.path() / "empty.bin";
    bridge_tests::write_text_file(empty_path, "");
    FileReadResult const empty = read_file(empty_path, 8U);
    REQUIRE_FALSE(empty);
    CHECK(empty.error() == FileReadFailure::empty);

    FileReadResult const missing = read_file(temporary_directory.path() / "missing.bin", 8U);
    REQUIRE_FALSE(missing);
    CHECK(missing.error() == FileReadFailure::unreadable);
}

TEST_CASE("read_file refuses to follow symbolic links")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const target_path = temporary_directory.path() / "target.bin";
    fs::path const link_path = temporary_directory.path() / "link.bin";
    bridge_tests::write_text_file(target_path, "abc");

    std::error_code link_error;
    fs::create_symlink(target_path, link_path, link_error);
    REQUIRE_FALSE(link_error);

    FileReadResult const read = read_file(link_path, 8U);
    REQUIRE_FALSE(read);
    CHECK(read.error() == FileReadFailure::unreadable);
}

TEST_CASE("write_owner_only_file_checked commits data with owner-only permissions")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const file_path = temporary_directory.path() / "resume.fastresume";

    ResumeSaveResult const written = write_owner_only_file_checked(file_path, "payload");
    REQUIRE(written.has_value());

    CHECK(bridge_tests::read_text_file(file_path) == "payload");
    CHECK(has_owner_read_write_only(file_path));
    CHECK_FALSE(directory_contains_temporary_file(temporary_directory.path()));
}

TEST_CASE("resume path helpers only accept final resume files")
{
    std::string const id = bridge_tests::v1_id('1');

    std::optional<std::string> const parsed = resume_id_from_resume_path(fs::path(id + std::string(kResumeExtension)));
    REQUIRE(parsed.has_value());
    CHECK(*parsed == id);

    CHECK_FALSE(resume_id_from_resume_path(fs::path(id + std::string(kResumeExtension) + std::string(kTempExtension))).has_value());
    CHECK_FALSE(resume_id_from_resume_path(fs::path(".fastresume")).has_value());
    CHECK_FALSE(resume_id_from_resume_path(fs::path("resume.txt")).has_value());
}

TEST_CASE("resume identifiers are normalized and validated")
{
    std::string const canonical = bridge_tests::canonical_id('a');
    std::string const v1 = bridge_tests::v1_id('1');
    std::string const v2 = bridge_tests::v2_id('2');

    ResumeIDListResult const normalized = normalized_resume_ids({"", canonical, v1, canonical, v2});
    REQUIRE(normalized.has_value());
    CHECK(*normalized == std::vector<std::string>{canonical, v1, v2});

    ResumeIDListResult const invalid = normalized_resume_ids({"v1:" + std::string(40U, 'A')});
    REQUIRE_FALSE(invalid);
    CHECK(invalid.error() == "Resume data identifier is invalid.");
}

TEST_CASE("removal tombstone filenames have the expected strict shape")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const tombstone_path = removal_tombstone_path(temporary_directory.path());

    CHECK(is_removal_tombstone_path(tombstone_path));
    CHECK(is_removal_tombstone_path(fs::path("removal-" + std::string(32U, 'a') + ".fastresume.remove")));
    CHECK_FALSE(is_removal_tombstone_path(fs::path("removal-" + std::string(32U, 'A') + ".fastresume.remove")));
    CHECK_FALSE(is_removal_tombstone_path(fs::path("removal-" + std::string(30U, 'a') + ".fastresume.remove")));
    CHECK_FALSE(is_removal_tombstone_path(fs::path("resume.fastresume.remove")));
}

TEST_CASE("tombstone payloads round-trip all metadata")
{
    std::vector<std::string> const ids{
        bridge_tests::canonical_id('b'),
        bridge_tests::v1_id('3'),
        bridge_tests::v2_id('4')
    };
    std::string const payload = tombstone_payload(
        ids,
        RemovalTombstoneState::awaiting_payload_delete,
        true,
        false
    );

    TombstonePayloadResult const parsed = tombstone_payload_from_bytes(bridge_tests::byte_vector(payload));
    REQUIRE(parsed.has_value());
    CHECK(parsed->ids == ids);
    CHECK(parsed->state == RemovalTombstoneState::awaiting_payload_delete);
    CHECK(parsed->delete_files);
    CHECK_FALSE(parsed->delete_partfile);
}

TEST_CASE("tombstone payload parsing rejects malformed data")
{
    std::string const id = bridge_tests::canonical_id('c');

    TombstonePayloadResult const wrong_version = tombstone_payload_from_bytes(bridge_tests::byte_vector("version=1\nid=" + id + "\n"));
    REQUIRE_FALSE(wrong_version);
    CHECK(wrong_version.error() == "Removal tombstone version is invalid.");

    TombstonePayloadResult const missing_metadata = tombstone_payload_from_bytes(bridge_tests::byte_vector("version=2\nid=" + id + "\n"));
    REQUIRE_FALSE(missing_metadata);
    CHECK(missing_metadata.error() == "Removal tombstone metadata is incomplete.");

    TombstonePayloadResult const invalid_id = tombstone_payload_from_bytes(bridge_tests::byte_vector(
        "version=2\nstate=resume_cleanup\ndelete_files=0\ndelete_partfile=0\nid=not-a-resume-id\n"
    ));
    REQUIRE_FALSE(invalid_id);
    CHECK(invalid_id.error() == "Removal tombstone contains an invalid identifier.");

    TombstonePayloadResult const empty_field = tombstone_payload_from_bytes(bridge_tests::byte_vector(
        "version=2\nstate=resume_cleanup\n\ndelete_files=0\ndelete_partfile=0\nid=" + id + "\n"
    ));
    REQUIRE_FALSE(empty_field);
    CHECK(empty_field.error() == "Removal tombstone contains an empty field.");
}

TEST_CASE("joined_error_messages preserves the first failures and truncates long batches")
{
    CHECK(joined_error_messages({}).empty());
    CHECK(joined_error_messages({"one"}) == "one");

    std::vector<std::string> errors;
    for (int index = 0; index < 10; ++index) {
        errors.push_back("error " + std::to_string(index));
    }

    CHECK(joined_error_messages(errors) == "Multiple resume operations failed: error 0; error 1; error 2; error 3; error 4; error 5; error 6; error 7; 2 more.");
}
