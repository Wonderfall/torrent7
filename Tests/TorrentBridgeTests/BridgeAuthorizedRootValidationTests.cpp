#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <array>
#include <cstdint>
#include <initializer_list>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace {

static_assert(TTORRENT_BRIDGE_ABI_VERSION == 38U);
static_assert(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT == 32);

using ErrorBuffer = std::array<char, 512>;

[[nodiscard]] std::vector<std::uint8_t> authorized_path_blob(
    std::vector<std::string> const &paths
)
{
    std::vector<std::uint8_t> blob;
    for (std::string const &path : paths) {
        blob.insert(blob.end(), path.begin(), path.end());
        blob.push_back(0U);
    }
    return blob;
}

[[nodiscard]] std::vector<std::uint8_t> authorized_path_blob(
    std::initializer_list<std::string_view> const paths
)
{
    std::vector<std::uint8_t> blob;
    for (std::string_view const path : paths) {
        blob.insert(blob.end(), path.begin(), path.end());
        blob.push_back(0U);
    }
    return blob;
}

[[nodiscard]] int32_t replace_authorized_roots(
    TTorrentClient &client,
    std::uint8_t const *path_blob,
    int32_t const path_blob_size,
    TTorrentAuthorizedSaveRoot const *roots,
    int32_t const root_count,
    TTorrentAuthorizedRootLifetimeCallback const retain,
    TTorrentAuthorizedRootLifetimeCallback const release,
    ErrorBuffer &error
)
{
    error.fill('\0');
    return TorrentClientReplaceAuthorizedSavePaths(
        &client,
        path_blob,
        path_blob_size,
        roots,
        root_count,
        retain,
        release,
        error.data(),
        static_cast<int32_t>(error.size())
    );
}

[[nodiscard]] int32_t replace_authorized_roots(
    TTorrentClient &client,
    std::vector<std::uint8_t> const &path_blob,
    TTorrentAuthorizedSaveRoot const *roots,
    int32_t const root_count,
    ErrorBuffer &error
)
{
    return replace_authorized_roots(
        client,
        path_blob.empty() ? nullptr : path_blob.data(),
        static_cast<int32_t>(path_blob.size()),
        roots,
        root_count,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    );
}

void check_error(ErrorBuffer const &error, std::string_view const expected)
{
    CHECK(std::string(error.data()) == expected);
}

[[nodiscard]] int descriptors_matching_identity(
    std::uint64_t const device,
    std::uint64_t const inode
)
{
    int matches = 0;
    int const descriptor_limit = ::getdtablesize();
    for (int descriptor = 0; descriptor < descriptor_limit; ++descriptor) {
        struct ::stat metadata {};
        if (::fstat(descriptor, &metadata) == 0
            && static_cast<std::uint64_t>(metadata.st_dev) == device
            && static_cast<std::uint64_t>(metadata.st_ino) == inode) {
            ++matches;
        }
    }
    return matches;
}

void clear_authorized_roots(TTorrentClient &client, ErrorBuffer &error)
{
    REQUIRE(replace_authorized_roots(
        client,
        nullptr,
        0,
        nullptr,
        0,
        nullptr,
        nullptr,
        error
    ) == 0);
}

} // namespace

TEST_CASE("ABI 37 authorized roots enforce pointer count and callback contracts")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const root_path = temporary_directory.path() / "Root";
    REQUIRE(fs::create_directory(root_path));
    bridge_tests::AuthorizedSaveRoot root(root_path);
    TTorrentAuthorizedSaveRoot record = root.record();
    std::vector<std::uint8_t> const blob = authorized_path_blob({root_path.string()});
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};

    CHECK(replace_authorized_roots(
        client,
        nullptr,
        static_cast<int32_t>(blob.size()),
        &record,
        1,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save path list pointer and size do not match.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        0,
        &record,
        1,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save path list pointer and size do not match.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        -1,
        &record,
        1,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save path list has an invalid size.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES + 1,
        &record,
        1,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save path list has an invalid size.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        nullptr,
        1,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save root list pointer and count do not match.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        &record,
        0,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save root list pointer and count do not match.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        &record,
        -1,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save root list has an invalid count.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        &record,
        TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT + 1,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save root list has an invalid count.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        &record,
        1,
        nullptr,
        nullptr,
        error
    ) != 0);
    check_error(error, "The authorized save root lifetime callbacks are invalid.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        &record,
        1,
        bridge_tests::retain_authorized_save_root,
        nullptr,
        error
    ) != 0);
    check_error(error, "The authorized save root lifetime callbacks are invalid.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        &record,
        1,
        nullptr,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save root lifetime callbacks are invalid.");

    CHECK(replace_authorized_roots(
        client,
        nullptr,
        0,
        nullptr,
        0,
        bridge_tests::retain_authorized_save_root,
        nullptr,
        error
    ) != 0);
    check_error(error, "The authorized save root lifetime callbacks are invalid.");

    CHECK(replace_authorized_roots(
        client,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        nullptr,
        0,
        nullptr,
        nullptr,
        error
    ) != 0);
    check_error(error, "The authorized save paths and roots do not correspond.");

    CHECK(replace_authorized_roots(
        client,
        nullptr,
        0,
        &record,
        1,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) != 0);
    check_error(error, "The authorized save paths and roots do not correspond.");

    std::vector<std::uint8_t> const two_paths = authorized_path_blob({
        root_path.string(),
        (temporary_directory.path() / "Other").string(),
    });
    CHECK(replace_authorized_roots(client, two_paths, &record, 1, error) != 0);
    check_error(error, "The authorized save paths and roots do not correspond.");

    REQUIRE(replace_authorized_roots(
        client,
        nullptr,
        0,
        nullptr,
        0,
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        error
    ) == 0);
    CHECK(client.authorized_save_roots.empty());
    CHECK(root.lifetime_probe().retain_count.load() == 0);
    CHECK(root.lifetime_probe().release_count.load() == 0);
}

TEST_CASE("ABI 37 authorized roots reject invalid descriptors contexts and identities")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const root_path = temporary_directory.path() / "Root";
    REQUIRE(fs::create_directory(root_path));
    bridge_tests::AuthorizedSaveRoot root(root_path);
    TTorrentAuthorizedSaveRoot const valid_record = root.record();
    std::vector<std::uint8_t> const blob = authorized_path_blob({root_path.string()});
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};

    TTorrentAuthorizedSaveRoot invalid_descriptor = valid_record;
    invalid_descriptor.directory_descriptor = -1;
    CHECK(replace_authorized_roots(client, blob, &invalid_descriptor, 1, error) != 0);
    check_error(error, "An authorized save root record is invalid.");

    TTorrentAuthorizedSaveRoot missing_context = valid_record;
    missing_context.lifetime_context = nullptr;
    CHECK(replace_authorized_roots(client, blob, &missing_context, 1, error) != 0);
    check_error(error, "An authorized save root record is invalid.");
    CHECK(root.lifetime_probe().retain_count.load() == 0);
    CHECK(root.lifetime_probe().release_count.load() == 0);

    auto check_identity_mismatch = [&](TTorrentAuthorizedSaveRoot record) {
        int const retains_before = root.lifetime_probe().retain_count.load();
        int const releases_before = root.lifetime_probe().release_count.load();
        CHECK(replace_authorized_roots(client, blob, &record, 1, error) != 0);
        check_error(error, "An authorized save root does not match its directory capability.");
        CHECK(root.lifetime_probe().retain_count.load() == retains_before + 1);
        CHECK(root.lifetime_probe().release_count.load() == releases_before + 1);
        CHECK(client.authorized_save_roots.empty());
    };

    TTorrentAuthorizedSaveRoot wrong_device = valid_record;
    ++wrong_device.device;
    check_identity_mismatch(wrong_device);

    TTorrentAuthorizedSaveRoot wrong_inode = valid_record;
    ++wrong_inode.inode;
    check_identity_mismatch(wrong_inode);

    fs::path const file_path = temporary_directory.path() / "regular-file";
    bridge_tests::write_text_file(file_path, "not a directory");
    UniqueFileDescriptor file_descriptor(::open(file_path.c_str(), O_RDONLY | O_CLOEXEC));
    REQUIRE(file_descriptor.is_valid());
    struct ::stat file_metadata {};
    REQUIRE(::fstat(file_descriptor.get(), &file_metadata) == 0);
    bridge_tests::AuthorizedSaveRootLifetimeProbe file_probe;
    TTorrentAuthorizedSaveRoot const file_record{
        .directory_descriptor = file_descriptor.get(),
        .device = static_cast<std::uint64_t>(file_metadata.st_dev),
        .inode = static_cast<std::uint64_t>(file_metadata.st_ino),
        .lifetime_context = &file_probe,
    };
    CHECK(replace_authorized_roots(client, blob, &file_record, 1, error) != 0);
    check_error(error, "An authorized save root does not match its directory capability.");
    CHECK(file_probe.retain_count.load() == 1);
    CHECK(file_probe.release_count.load() == 1);

    fs::path const closed_path = temporary_directory.path() / "Closed";
    REQUIRE(fs::create_directory(closed_path));
    bridge_tests::AuthorizedSaveRoot closed_root(closed_path);
    TTorrentAuthorizedSaveRoot closed_record = closed_root.record();
    closed_root.close_borrowed_descriptor();
    std::vector<std::uint8_t> const closed_blob = authorized_path_blob({closed_path.string()});
    CHECK(replace_authorized_roots(client, closed_blob, &closed_record, 1, error) != 0);
    check_error(error, "An authorized save root does not match its directory capability.");
    CHECK(closed_root.lifetime_probe().retain_count.load() == 1);
    CHECK(closed_root.lifetime_probe().release_count.load() == 1);
}

TEST_CASE("ABI 37 authorized roots reject duplicate normalized paths and identities")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};

    fs::path const first_path = temporary_directory.path() / "First";
    fs::path const second_path = temporary_directory.path() / "Second";
    REQUIRE(fs::create_directory(first_path));
    REQUIRE(fs::create_directory(second_path));
    bridge_tests::AuthorizedSaveRoot first_root(first_path);
    bridge_tests::AuthorizedSaveRoot second_root(second_path);
    std::vector<std::uint8_t> const duplicate_path_blob = authorized_path_blob({
        first_path.string(),
        (first_path / ".." / first_path.filename()).string(),
    });
    std::array<TTorrentAuthorizedSaveRoot, 2> duplicate_path_records{
        first_root.record(),
        second_root.record(),
    };
    CHECK(replace_authorized_roots(
        client,
        duplicate_path_blob,
        duplicate_path_records.data(),
        static_cast<int32_t>(duplicate_path_records.size()),
        error
    ) != 0);
    check_error(error, "The authorized save root list contains a duplicate.");
    CHECK(client.authorized_save_roots.empty());
    CHECK(first_root.lifetime_probe().retain_count.load() == 1);
    CHECK(first_root.lifetime_probe().release_count.load() == 1);
    CHECK(second_root.lifetime_probe().retain_count.load() == 0);
    CHECK(second_root.lifetime_probe().release_count.load() == 0);

    fs::path const identity_path = temporary_directory.path() / "Identity";
    fs::path const other_path = temporary_directory.path() / "Other";
    REQUIRE(fs::create_directory(identity_path));
    REQUIRE(fs::create_directory(other_path));
    bridge_tests::AuthorizedSaveRoot identity_root(identity_path);
    TTorrentAuthorizedSaveRoot const identity_record = identity_root.record();
    std::array<TTorrentAuthorizedSaveRoot, 2> duplicate_identity_records{
        identity_record,
        identity_record,
    };
    std::vector<std::uint8_t> const duplicate_identity_blob = authorized_path_blob({
        identity_path.string(),
        other_path.string(),
    });
    CHECK(replace_authorized_roots(
        client,
        duplicate_identity_blob,
        duplicate_identity_records.data(),
        static_cast<int32_t>(duplicate_identity_records.size()),
        error
    ) != 0);
    check_error(error, "The authorized save root list contains a duplicate.");
    CHECK(client.authorized_save_roots.empty());
    CHECK(identity_root.lifetime_probe().retain_count.load() == 1);
    CHECK(identity_root.lifetime_probe().release_count.load() == 1);
}

TEST_CASE("ABI 37 authorized roots require path and record ordering to agree")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const first_path = temporary_directory.path() / "First";
    fs::path const second_path = temporary_directory.path() / "Second";
    REQUIRE(fs::create_directory(first_path));
    REQUIRE(fs::create_directory(second_path));
    bridge_tests::AuthorizedSaveRoot first_root(first_path);
    bridge_tests::AuthorizedSaveRoot second_root(second_path);
    std::array<TTorrentAuthorizedSaveRoot, 2> const reversed_records{
        second_root.record(),
        first_root.record(),
    };
    std::vector<std::uint8_t> const blob = authorized_path_blob({
        first_path.string(),
        second_path.string(),
    });
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};

    CHECK(replace_authorized_roots(
        client,
        blob,
        reversed_records.data(),
        static_cast<int32_t>(reversed_records.size()),
        error
    ) != 0);
    check_error(error, "An authorized save root does not match its directory capability.");
    CHECK(client.authorized_save_roots.empty());
    CHECK(first_root.lifetime_probe().retain_count.load() == 0);
    CHECK(first_root.lifetime_probe().release_count.load() == 0);
    CHECK(second_root.lifetime_probe().retain_count.load() == 1);
    CHECK(second_root.lifetime_probe().release_count.load() == 1);
}

TEST_CASE("ABI 37 second-record failures clean up and preserve replacement atomicity")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const existing_path = temporary_directory.path() / "Existing";
    fs::path const first_path = temporary_directory.path() / "First";
    fs::path const second_path = temporary_directory.path() / "Second";
    REQUIRE(fs::create_directory(existing_path));
    REQUIRE(fs::create_directory(first_path));
    REQUIRE(fs::create_directory(second_path));
    bridge_tests::AuthorizedSaveRoot existing_root(existing_path);
    bridge_tests::AuthorizedSaveRoot first_root(first_path);
    bridge_tests::AuthorizedSaveRoot second_root(second_path);
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};

    TTorrentAuthorizedSaveRoot existing_record = existing_root.record();
    std::vector<std::uint8_t> const existing_blob = authorized_path_blob({existing_path.string()});
    REQUIRE(replace_authorized_roots(client, existing_blob, &existing_record, 1, error) == 0);
    auto *const retained_existing_root = client.authorized_save_roots.at(existing_path.string()).get();

    TTorrentAuthorizedSaveRoot second_record = second_root.record();
    ++second_record.inode;
    std::array<TTorrentAuthorizedSaveRoot, 2> const candidate_records{
        first_root.record(),
        second_record,
    };
    std::vector<std::uint8_t> const candidate_blob = authorized_path_blob({
        first_path.string(),
        second_path.string(),
    });
    int const first_descriptors_before = descriptors_matching_identity(
        candidate_records.front().device,
        candidate_records.front().inode
    );
    int const second_descriptors_before = descriptors_matching_identity(
        second_root.record().device,
        second_root.record().inode
    );

    CHECK(replace_authorized_roots(
        client,
        candidate_blob,
        candidate_records.data(),
        static_cast<int32_t>(candidate_records.size()),
        error
    ) != 0);
    check_error(error, "An authorized save root does not match its directory capability.");
    REQUIRE(client.authorized_save_roots.size() == 1U);
    CHECK(client.authorized_save_roots.at(existing_path.string()).get() == retained_existing_root);
    CHECK(existing_root.lifetime_probe().retain_count.load() == 1);
    CHECK(existing_root.lifetime_probe().release_count.load() == 0);
    CHECK(first_root.lifetime_probe().retain_count.load() == 1);
    CHECK(first_root.lifetime_probe().release_count.load() == 1);
    CHECK(second_root.lifetime_probe().retain_count.load() == 1);
    CHECK(second_root.lifetime_probe().release_count.load() == 1);
    CHECK(descriptors_matching_identity(
        candidate_records.front().device,
        candidate_records.front().inode
    ) == first_descriptors_before);
    CHECK(descriptors_matching_identity(
        second_root.record().device,
        second_root.record().inode
    ) == second_descriptors_before);

    ErrorBuffer create_error{};
    TTorrentClient *const failed_client = TorrentClientCreateWithError(
        (temporary_directory.path() / "FailedState").c_str(),
        0,
        candidate_blob.data(),
        static_cast<int32_t>(candidate_blob.size()),
        candidate_records.data(),
        static_cast<int32_t>(candidate_records.size()),
        bridge_tests::retain_authorized_save_root,
        bridge_tests::release_authorized_save_root,
        create_error.data(),
        static_cast<int32_t>(create_error.size())
    );
    CHECK(failed_client == nullptr);
    check_error(create_error, "An authorized save root does not match its directory capability.");
    CHECK(first_root.lifetime_probe().retain_count.load() == 2);
    CHECK(first_root.lifetime_probe().release_count.load() == 2);
    CHECK(second_root.lifetime_probe().retain_count.load() == 2);
    CHECK(second_root.lifetime_probe().release_count.load() == 2);

    clear_authorized_roots(client, error);
    CHECK(existing_root.lifetime_probe().retain_count.load()
          == existing_root.lifetime_probe().release_count.load());
}

TEST_CASE("ABI 37 same-root reuse balances callbacks without accumulating descriptors")
{
    constexpr int replacement_count = 64;
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const root_path = temporary_directory.path() / "Root";
    REQUIRE(fs::create_directory(root_path));
    bridge_tests::AuthorizedSaveRoot root(root_path);
    TTorrentAuthorizedSaveRoot record = root.record();
    std::vector<std::uint8_t> const blob = authorized_path_blob({root_path.string()});
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};

    REQUIRE(replace_authorized_roots(client, blob, &record, 1, error) == 0);
    std::shared_ptr<lt::aux::storage_root> retained_authority =
        client.authorized_save_roots.at(root_path.string());
    auto *const retained_root = retained_authority.get();
    int const stable_descriptor_count = descriptors_matching_identity(record.device, record.inode);
    REQUIRE(stable_descriptor_count >= 2);

    for (int replacement = 0; replacement < replacement_count; ++replacement) {
        REQUIRE(replace_authorized_roots(client, blob, &record, 1, error) == 0);
        CHECK(client.authorized_save_roots.at(root_path.string()).get() == retained_root);
        CHECK(descriptors_matching_identity(record.device, record.inode)
              == stable_descriptor_count);
    }
    CHECK(root.lifetime_probe().retain_count.load() == replacement_count + 1);
    CHECK(root.lifetime_probe().release_count.load() == replacement_count);

    clear_authorized_roots(client, error);
    CHECK(client.authorized_save_roots.empty());
    CHECK(root.lifetime_probe().release_count.load() == replacement_count);
    CHECK(descriptors_matching_identity(record.device, record.inode)
          == stable_descriptor_count);

    REQUIRE(replace_authorized_roots(client, blob, &record, 1, error) == 0);
    CHECK(client.authorized_save_roots.at(root_path.string()).get() == retained_root);
    CHECK(client.authorized_save_root_lifetimes.size() == 1U);
    CHECK(root.lifetime_probe().retain_count.load() == replacement_count + 2);
    CHECK(root.lifetime_probe().release_count.load() == replacement_count + 1);
    CHECK(descriptors_matching_identity(record.device, record.inode)
          == stable_descriptor_count);

    clear_authorized_roots(client, error);
    retained_authority.reset();
    CHECK(root.lifetime_probe().retain_count.load() == replacement_count + 2);
    CHECK(root.lifetime_probe().release_count.load() == replacement_count + 2);
    CHECK(descriptors_matching_identity(record.device, record.inode)
          == stable_descriptor_count - 1);
}

TEST_CASE("ABI 37 root reuse never crosses lifetime contexts")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const root_path = temporary_directory.path() / "Root";
    REQUIRE(fs::create_directory(root_path));
    bridge_tests::AuthorizedSaveRoot first_capability(root_path);
    bridge_tests::AuthorizedSaveRoot second_capability(root_path);
    TTorrentAuthorizedSaveRoot first_record = first_capability.record();
    TTorrentAuthorizedSaveRoot second_record = second_capability.record();
    std::vector<std::uint8_t> const blob = authorized_path_blob({root_path.string()});
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};

    REQUIRE(replace_authorized_roots(client, blob, &first_record, 1, error) == 0);
    std::shared_ptr<lt::aux::storage_root> first_active_root =
        client.authorized_save_roots.at(root_path.string());
    REQUIRE(replace_authorized_roots(client, blob, &second_record, 1, error) == 0);

    std::shared_ptr<lt::aux::storage_root> second_root =
        client.authorized_save_roots.at(root_path.string());
    CHECK(second_root.get() != first_active_root.get());
    CHECK(second_root->lifetime_context() != first_active_root->lifetime_context());
    CHECK(client.authorized_save_root_lifetimes.size() == 2U);
    CHECK(first_capability.lifetime_probe().retain_count.load() == 1);
    CHECK(first_capability.lifetime_probe().release_count.load() == 0);
    CHECK(second_capability.lifetime_probe().retain_count.load() == 1);
    CHECK(second_capability.lifetime_probe().release_count.load() == 0);

    clear_authorized_roots(client, error);
    first_active_root.reset();
    second_root.reset();
    CHECK(first_capability.lifetime_probe().release_count.load() == 1);
    CHECK(second_capability.lifetime_probe().release_count.load() == 1);
}

TEST_CASE("ABI 37 live root budget includes authorities retained after allowlist replacement")
{
    constexpr int root_limit = TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT;
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};
    std::vector<std::unique_ptr<bridge_tests::AuthorizedSaveRoot>> roots;
    std::vector<std::shared_ptr<lt::aux::storage_root>> simulated_active_storage_roots;
    roots.reserve(static_cast<std::size_t>(root_limit + 1));
    simulated_active_storage_roots.reserve(static_cast<std::size_t>(root_limit));

    for (int index = 0; index <= root_limit; ++index) {
        fs::path const path = temporary_directory.path() / ("Generation-" + std::to_string(index));
        REQUIRE(fs::create_directory(path));
        roots.push_back(std::make_unique<bridge_tests::AuthorizedSaveRoot>(path));
    }

    for (int index = 0; index < root_limit; ++index) {
        std::vector<std::uint8_t> const blob = authorized_path_blob({roots.at(
            static_cast<std::size_t>(index)
        )->path().string()});
        TTorrentAuthorizedSaveRoot record = roots.at(static_cast<std::size_t>(index))->record();
        REQUIRE(replace_authorized_roots(client, blob, &record, 1, error) == 0);
        simulated_active_storage_roots.push_back(client.authorized_save_roots.begin()->second);
    }
    REQUIRE(client.authorized_save_root_lifetimes.size() == static_cast<std::size_t>(root_limit));

    bridge_tests::AuthorizedSaveRoot &extra_root = *roots.back();
    std::vector<std::uint8_t> const extra_blob = authorized_path_blob({extra_root.path().string()});
    TTorrentAuthorizedSaveRoot extra_record = extra_root.record();
    CHECK(replace_authorized_roots(client, extra_blob, &extra_record, 1, error)
          == TTORRENT_ERROR_AUTHORIZED_SAVE_ROOT_CAPACITY);
    check_error(error, "Too many authorized save roots remain in use.");
    CHECK(client.authorized_save_roots.begin()->first
          == roots.at(static_cast<std::size_t>(root_limit - 1))->path().string());
    CHECK(extra_root.lifetime_probe().retain_count.load() == 0);
    CHECK(extra_root.lifetime_probe().release_count.load() == 0);

    simulated_active_storage_roots.front().reset();
    REQUIRE(replace_authorized_roots(client, extra_blob, &extra_record, 1, error) == 0);
    CHECK(client.authorized_save_roots.contains(extra_root.path().string()));
    CHECK(client.authorized_save_root_lifetimes.size() == static_cast<std::size_t>(root_limit));

    clear_authorized_roots(client, error);
    simulated_active_storage_roots.clear();
    for (auto const &root : roots) {
        CHECK(root->lifetime_probe().retain_count.load()
              == root->lifetime_probe().release_count.load());
    }
}

TEST_CASE("ABI 37 authorized root limit accepts 32 and rejects 33 atomically")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    ErrorBuffer error{};
    std::vector<std::unique_ptr<bridge_tests::AuthorizedSaveRoot>> roots;
    std::vector<TTorrentAuthorizedSaveRoot> records;
    std::vector<std::string> paths;
    roots.reserve(static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT));
    records.reserve(static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT));
    paths.reserve(static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT));

    for (int32_t index = 0; index < TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT; ++index) {
        fs::path const path = temporary_directory.path() / ("Root-" + std::to_string(index));
        REQUIRE(fs::create_directory(path));
        auto root = std::make_unique<bridge_tests::AuthorizedSaveRoot>(path);
        paths.push_back(path.string());
        records.push_back(root->record());
        roots.push_back(std::move(root));
    }
    std::vector<std::uint8_t> const maximum_blob = authorized_path_blob(paths);
    REQUIRE(replace_authorized_roots(
        client,
        maximum_blob,
        records.data(),
        static_cast<int32_t>(records.size()),
        error
    ) == 0);
    REQUIRE(client.authorized_save_roots.size()
            == static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT));
    for (auto const &root : roots) {
        CHECK(root->lifetime_probe().retain_count.load() == 1);
        CHECK(root->lifetime_probe().release_count.load() == 0);
    }

    std::vector<TTorrentAuthorizedSaveRoot> over_limit_records(
        static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT + 1),
        records.front()
    );
    CHECK(replace_authorized_roots(
        client,
        maximum_blob,
        over_limit_records.data(),
        static_cast<int32_t>(over_limit_records.size()),
        error
    ) != 0);
    check_error(error, "The authorized save root list has an invalid count.");
    CHECK(client.authorized_save_roots.size()
          == static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT));

    std::vector<std::string> over_limit_paths = paths;
    over_limit_paths.push_back((temporary_directory.path() / "Root-32").string());
    std::vector<std::uint8_t> const over_limit_blob = authorized_path_blob(over_limit_paths);
    CHECK(replace_authorized_roots(
        client,
        over_limit_blob,
        nullptr,
        0,
        error
    ) != 0);
    check_error(error, "The authorized save path list contains too many paths.");
    CHECK(client.authorized_save_roots.size()
          == static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT));
    for (auto const &root : roots) {
        CHECK(root->lifetime_probe().retain_count.load() == 1);
        CHECK(root->lifetime_probe().release_count.load() == 0);
    }

    fs::path const replacement_path = temporary_directory.path() / "Replacement";
    REQUIRE(fs::create_directory(replacement_path));
    bridge_tests::AuthorizedSaveRoot replacement_root(replacement_path);
    TTorrentAuthorizedSaveRoot replacement_record = replacement_root.record();
    std::vector<std::uint8_t> const replacement_blob = authorized_path_blob({
        replacement_path.string(),
    });
    REQUIRE(replace_authorized_roots(
        client,
        replacement_blob,
        &replacement_record,
        1,
        error
    ) == 0);
    CHECK(client.authorized_save_roots.size() == 1U);
    CHECK(client.authorized_save_roots.contains(replacement_path.string()));
    for (auto const &root : roots) {
        CHECK(root->lifetime_probe().retain_count.load() == 1);
        CHECK(root->lifetime_probe().release_count.load() == 1);
    }

    clear_authorized_roots(client, error);
    CHECK(replacement_root.lifetime_probe().retain_count.load() == 1);
    CHECK(replacement_root.lifetime_probe().release_count.load() == 1);
}
