#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <libtorrent/create_torrent.hpp>

#include <array>
#include <cstdint>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

[[nodiscard]] lt::add_torrent_params make_source_torrent_params()
{
    std::vector<lt::create_file_entry> files;
    files.emplace_back("source-test.bin", 4);

    lt::create_torrent creator(
        std::move(files),
        16 * 1024,
        lt::create_torrent::v1_only | lt::create_torrent::symlinks
    );
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(12U));
    creator.add_tracker("http://tracker.example/announce", 0);
    creator.add_tracker("https://secure-tracker.example/announce", 1);
    creator.add_url_seed("http://seed.example/file");
    creator.add_url_seed("https://secure-seed.example/file");

    std::vector<char> const buffer = creator.generate_buf();
    return bridge_tests::load_torrent_params(buffer, "source test torrent info");
}

[[nodiscard]] std::shared_ptr<lt::torrent_info const> make_file_priority_torrent_info()
{
    std::vector<lt::create_file_entry> files;
    files.emplace_back("files/high.bin", 4);
    files.emplace_back("files/skip.bin", 4);
    files.emplace_back("files/low.bin", 4);

    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(14U));

    std::vector<char> const buffer = creator.generate_buf();
    return bridge_tests::load_torrent_params(buffer, "file priority test torrent info").ti;
}

[[nodiscard]] std::vector<char> make_http_tracker_torrent_buffer()
{
    std::vector<lt::create_file_entry> files;
    files.emplace_back("http-tracker-test.bin", 4);

    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(13U));
    creator.add_tracker("http://tracker.example/announce", 0);
    return creator.generate_buf();
}

[[nodiscard]] std::string source_inspection_magnet(std::string_view query = {})
{
    std::string magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567";
    magnet.append(query);
    return magnet;
}

[[nodiscard]] TTorrentSourceSecurityInspection inspect_magnet_sources(std::string const &magnet)
{
    TTorrentSourceSecurityInspection inspection{};
    REQUIRE(TorrentBridgeInspectMagnetSources(magnet.c_str(), &inspection) == 0);
    return inspection;
}

void check_inspection_matches_native_parse(std::string const &magnet)
{
    TTorrentSourceSecurityInspection const inspection = inspect_magnet_sources(magnet);

    lt::error_code parse_error;
    lt::add_torrent_params params = lt::parse_magnet_uri(magnet, parse_error);
    REQUIRE_FALSE(parse_error);
    sanitize_magnet_endpoint_hints(params);
    REQUIRE(validate_torrent_sources(params).has_value());
    TorrentSourceCounts const counts = torrent_source_counts(params);

    CHECK(inspection.tracker_count == counts.tracker_count);
    CHECK(inspection.https_tracker_count == counts.https_tracker_count);
    CHECK(inspection.web_seed_count == counts.web_seed_count);
    CHECK(inspection.https_web_seed_count == counts.https_web_seed_count);
}

void append_bencoded_string(std::vector<char> &buffer, std::string_view value)
{
    std::string const size = std::to_string(value.size());
    buffer.insert(buffer.end(), size.begin(), size.end());
    buffer.push_back(':');
    buffer.insert(buffer.end(), value.begin(), value.end());
}

void append_bencoded_string(std::string &buffer, std::string_view value)
{
    buffer += std::to_string(value.size());
    buffer.push_back(':');
    buffer.append(value);
}

[[nodiscard]] std::vector<char> make_duplicate_file_torrent_buffer()
{
    std::vector<char> buffer;
    auto append = [&buffer](std::string_view value) {
        buffer.insert(buffer.end(), value.begin(), value.end());
    };

    append("d4:infod5:filesl");
    for (int index = 0; index < 2; ++index) {
        append("d6:lengthi4e4:pathl8:same.binee");
    }
    append("e4:name9:duplicate12:piece lengthi16384e6:pieces");
    append_bencoded_string(buffer, std::string(20U, '\0'));
    append("ee");
    return buffer;
}

[[nodiscard]] std::shared_ptr<lt::torrent_info const> make_raw_v1_torrent_info(std::string_view files_payload)
{
    std::vector<char> buffer;
    auto append = [&buffer](std::string_view value) {
        buffer.insert(buffer.end(), value.begin(), value.end());
    };

    append("d4:infod5:filesl");
    append(files_payload);
    append("e4:name");
    append_bencoded_string(buffer, "source");
    append("12:piece lengthi16384e6:pieces");
    append_bencoded_string(buffer, std::string(20U, '\0'));
    append("ee");

    return bridge_tests::load_torrent_params(buffer, "raw validation test torrent info").ti;
}

[[nodiscard]] std::vector<std::uint8_t> authorized_path_blob(
    std::initializer_list<std::string_view> paths
)
{
    std::vector<std::uint8_t> blob;
    for (std::string_view const path : paths) {
        blob.insert(blob.end(), path.begin(), path.end());
        blob.push_back(0U);
    }
    return blob;
}

} // namespace

TEST_CASE("save paths must be present and absolute")
{
    BridgeResult const missing = validate_save_path("");
    REQUIRE_FALSE(missing);
    CHECK(missing.error().code == 1);
    CHECK(missing.error().message == "Missing save path.");

    BridgeResult const relative = validate_save_path("Downloads");
    REQUIRE_FALSE(relative);
    CHECK(relative.error().code == 1);
    CHECK(relative.error().message == "The save path must be absolute.");

    CHECK(validate_save_path("/Users/dev/Downloads").has_value());
}

TEST_CASE("authorized save path blobs are strict bounded UTF-8 records")
{
    std::vector<std::uint8_t> const valid = authorized_path_blob({
        "/Downloads/B/../A",
        "/Downloads/A",
        "/Downloads/日本語",
    });
    AuthorizedSavePathResult parsed = parse_authorized_save_paths_blob(valid);
    REQUIRE(parsed.has_value());
    CHECK(*parsed == AuthorizedSavePathSet{
        "/Downloads/A",
        "/Downloads/日本語",
    });
    CHECK(parse_authorized_save_paths_blob({}).has_value());

    std::vector<std::uint8_t> missing_terminator{'/', 'a'};
    CHECK_FALSE(parse_authorized_save_paths_blob(missing_terminator).has_value());
    CHECK_FALSE(parse_authorized_save_paths_blob(authorized_path_blob({"relative"})).has_value());
    CHECK_FALSE(parse_authorized_save_paths_blob(authorized_path_blob({"/valid", ""})).has_value());

    std::vector<std::uint8_t> invalid_utf8{'/', 0xffU, 0U};
    CHECK_FALSE(parse_authorized_save_paths_blob(invalid_utf8).has_value());

    std::string const oversized_path(
        static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES),
        'x'
    );
    CHECK_FALSE(parse_authorized_save_paths_blob(
        authorized_path_blob({"/" + oversized_path})
    ).has_value());

    std::vector<std::uint8_t> too_many_paths;
    for (int32_t index = 0; index <= TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT; ++index) {
        too_many_paths.insert(too_many_paths.end(), {'/', 'x', 0U});
    }
    CHECK_FALSE(parse_authorized_save_paths_blob(too_many_paths).has_value());
}

TEST_CASE("client creation validates authorized path blob pointer and size before reading")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    std::string const state_path = (temporary_directory.path() / "State").string();
    std::array<char, 512> error{};
    std::uint8_t byte = 0U;

    CHECK(TorrentClientCreateWithError(
        state_path.c_str(),
        1,
        nullptr,
        1,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == nullptr);
    CHECK(std::string(error.data()) == "The authorized save path list pointer and size do not match.");

    CHECK(TorrentClientCreateWithError(
        state_path.c_str(),
        1,
        &byte,
        0,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == nullptr);
    CHECK(std::string(error.data()) == "The authorized save path list pointer and size do not match.");

    CHECK(TorrentClientCreateWithError(
        state_path.c_str(),
        1,
        &byte,
        TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES + 1,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == nullptr);
    CHECK(std::string(error.data()) == "The authorized save path list has an invalid size.");
}

TEST_CASE("runtime authorized path replacement is bounded and atomic")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    std::array<char, 512> error{};

    std::vector<std::uint8_t> valid = authorized_path_blob({"/Downloads/B/../A"});
    REQUIRE(TorrentClientReplaceAuthorizedSavePaths(
        &client,
        valid.data(),
        static_cast<int32_t>(valid.size()),
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    CHECK(client.authorized_save_paths == AuthorizedSavePathSet{"/Downloads/A"});

    std::vector<std::uint8_t> missing_terminator{'/', 'D'};
    CHECK(TorrentClientReplaceAuthorizedSavePaths(
        &client,
        missing_terminator.data(),
        static_cast<int32_t>(missing_terminator.size()),
        error.data(),
        static_cast<int32_t>(error.size())
    ) != 0);
    CHECK(std::string(error.data()) == "The authorized save path list is not NUL terminated.");
    CHECK(client.authorized_save_paths == AuthorizedSavePathSet{"/Downloads/A"});

    std::uint8_t byte = 0U;
    CHECK(TorrentClientReplaceAuthorizedSavePaths(
        &client,
        &byte,
        TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES + 1,
        error.data(),
        static_cast<int32_t>(error.size())
    ) != 0);
    CHECK(std::string(error.data()) == "The authorized save path list has an invalid size.");
    CHECK(client.authorized_save_paths == AuthorizedSavePathSet{"/Downloads/A"});

    REQUIRE(TorrentClientReplaceAuthorizedSavePaths(
        &client,
        nullptr,
        0,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    CHECK(client.authorized_save_paths.empty());
}

TEST_CASE("torrent metadata rejects symbolic links and paths that cannot fit the bridge ABI")
{
    BridgeResult const symlink = validate_torrent_info(*make_raw_v1_torrent_info(
        "d4:attr1:l6:lengthi0e4:pathl4:linke12:symlink pathl8:file.txtee"
        "d6:lengthi4e4:pathl8:file.txtee"
    ));
    REQUIRE_FALSE(symlink);
    CHECK(symlink.error().code == 2);
    CHECK(symlink.error().message == "The torrent contains symbolic links, which are not supported.");

    std::string long_path_payload = "d6:lengthi4e4:pathl";
    for (char component = 'a'; component < 'f'; ++component) {
        append_bencoded_string(long_path_payload, std::string(240U, component));
    }
    long_path_payload += "ee";
    BridgeResult const long_path = validate_torrent_info(*make_raw_v1_torrent_info(long_path_payload));
    REQUIRE_FALSE(long_path);
    CHECK(long_path.error().code == 2);
    CHECK(long_path.error().message == "The torrent contains a file path that is too long.");
}

TEST_CASE("torrent metadata rejects unsafe renamed file layouts")
{
    std::shared_ptr<lt::torrent_info const> const info = make_file_priority_torrent_info();
    REQUIRE(info != nullptr);

    using RenameMap = std::map<lt::file_index_t, std::string>;
    auto expect_rejected = [&info](RenameMap const &renames) {
        BridgeResult const result = validate_torrent_info(*info, renames);
        CHECK_FALSE(result.has_value());
        if (!result) {
            CHECK(result.error().code == 2);
        }
    };

    CHECK(validate_torrent_info(
        *info,
        RenameMap{{lt::file_index_t(0), "renamed-high.bin"}}
    ).has_value());

    expect_rejected(RenameMap{{lt::file_index_t(0), ""}});
    expect_rejected(RenameMap{{lt::file_index_t(-1), "negative-index.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(info->layout().num_files()), "past-end.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "/tmp/escaped.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "../escaped.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "files/./renamed.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "files//renamed.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "files/control\nname.bin"}});

    std::string nul_path = "files/nul";
    nul_path.push_back('\0');
    nul_path += "name.bin";
    expect_rejected(RenameMap{{lt::file_index_t(0), std::move(nul_path)}});

    std::string delete_path = "files/delete";
    delete_path.push_back(static_cast<char>(0x7f));
    delete_path += "name.bin";
    expect_rejected(RenameMap{{lt::file_index_t(0), std::move(delete_path)}});

    std::string overlong_path = "files/";
    overlong_path.append(sizeof(TTorrentFileSnapshot::path), 'x');
    expect_rejected(RenameMap{{lt::file_index_t(0), std::move(overlong_path)}});
}

TEST_CASE("peer source snapshots count overlapping libtorrent source flags")
{
    std::vector<lt::peer_info> peers(5);
    peers.at(0).source = lt::peer_info::tracker;
    peers.at(1).source = lt::peer_info::dht | lt::peer_info::pex;
    peers.at(2).source = lt::peer_info::resume_data | lt::peer_info::incoming;
    peers.at(3).source = lt::peer_info::lsd;
    peers.at(3).connection_type = lt::peer_info::web_seed;

    TTorrentPeerSourceSnapshot const snapshot = peer_source_snapshot(peers);

    CHECK(snapshot.connected == 5);
    CHECK(snapshot.tracker == 1);
    CHECK(snapshot.dht == 1);
    CHECK(snapshot.peer_exchange == 1);
    CHECK(snapshot.local_service_discovery == 1);
    CHECK(snapshot.resume_data == 1);
    CHECK(snapshot.incoming == 1);
    CHECK(snapshot.web_seed == 1);
    CHECK(snapshot.other == 1);
}

TEST_CASE("network binding trims input and classifies valid binding forms")
{
    NetworkBinding const any = network_binding("   ");
    CHECK(any.kind == NetworkBindingKind::any);
    CHECK(any.value.empty());

    NetworkBinding const name = network_binding(" en0 ");
    CHECK(name.kind == NetworkBindingKind::name);
    CHECK(name.value == "en0");

    NetworkBinding const ipv4 = network_binding("192.0.2.10");
    CHECK(ipv4.kind == NetworkBindingKind::ipv4);
    CHECK(ipv4.value == "192.0.2.10");

    NetworkBinding const ipv6 = network_binding("2001:db8::1");
    CHECK(ipv6.kind == NetworkBindingKind::ipv6);
    CHECK(ipv6.value == "2001:db8::1");
}

TEST_CASE("network binding rejects ambiguous or unsafe input")
{
    CHECK_THROWS_AS(static_cast<void>(network_binding("en0,utun0")), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(network_binding("en0 utun0")), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(network_binding("[2001:db8::1]")), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(network_binding("2001:db8:::1")), std::invalid_argument);
}

TEST_CASE("listen and outgoing interfaces honor blocked networking")
{
    CHECK(listen_interfaces(6881, "", true).empty());
    CHECK(outgoing_interfaces("en0", true).empty());
}

TEST_CASE("listen interfaces format all binding variants")
{
    CHECK(listen_interfaces(6881, "", false) == "0.0.0.0:6881,[::]:6881");
    CHECK(listen_interfaces(6881, "en0", false) == "en0:6881");
    CHECK(listen_interfaces(6881, "192.0.2.10", false) == "192.0.2.10:6881");
    CHECK(listen_interfaces(6881, "2001:db8::1", false) == "[2001:db8::1]:6881");
    CHECK(listen_interfaces(0, "", false) == "0.0.0.0:0,[::]:0");

    CHECK_THROWS_AS(static_cast<void>(listen_interfaces(-1, "", false)), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(listen_interfaces(1023, "", false)), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(listen_interfaces(65536, "", false)), std::invalid_argument);
}

TEST_CASE("outgoing interfaces pass through explicit bindings only")
{
    CHECK(outgoing_interfaces("", false).empty());
    CHECK(outgoing_interfaces("en0", false) == "en0");
    CHECK(outgoing_interfaces("192.0.2.10", false) == "192.0.2.10");
    CHECK(outgoing_interfaces("2001:db8::1", false) == "2001:db8::1");
}

TEST_CASE("encryption policy maps only the supported ABI values")
{
    CHECK(is_valid_encryption_policy(0));
    CHECK(is_valid_encryption_policy(1));
    CHECK(is_valid_encryption_policy(2));
    CHECK_FALSE(is_valid_encryption_policy(-1));
    CHECK_FALSE(is_valid_encryption_policy(3));

    CHECK(encryption_policy(0) == static_cast<int>(lt::settings_pack::pe_enabled));
    CHECK(encryption_policy(1) == static_cast<int>(lt::settings_pack::pe_forced));
    CHECK(encryption_policy(2) == static_cast<int>(lt::settings_pack::pe_disabled));
    CHECK(encryption_policy(99) == static_cast<int>(lt::settings_pack::pe_enabled));
}

TEST_CASE("add params map peer exchange preference to torrent flags")
{
    lt::add_torrent_params enabled = bridge_tests::add_params_with_hashes();
    prepare_add_params(enabled, "/tmp", false, true);
    CHECK_FALSE(static_cast<bool>(enabled.flags & lt::torrent_flags::disable_pex));

    lt::add_torrent_params already_disabled = bridge_tests::add_params_with_hashes();
    already_disabled.flags |= lt::torrent_flags::disable_pex;
    prepare_add_params(already_disabled, "/tmp", false, true);
    CHECK(static_cast<bool>(already_disabled.flags & lt::torrent_flags::disable_pex));

    lt::add_torrent_params disabled = bridge_tests::add_params_with_hashes();
    prepare_add_params(disabled, "/tmp", false, false);
    CHECK(static_cast<bool>(disabled.flags & lt::torrent_flags::disable_pex));
}

TEST_CASE("add params apply file priority classes")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.ti = make_file_priority_torrent_info();

    std::array<TTorrentFilePriorityEntry, 3> const priorities{{
        TTorrentFilePriorityEntry{.index = 0, .priority = TTORRENT_FILE_PRIORITY_HIGH},
        TTorrentFilePriorityEntry{.index = 1, .priority = TTORRENT_FILE_PRIORITY_SKIP},
        TTorrentFilePriorityEntry{.index = 2, .priority = TTORRENT_FILE_PRIORITY_LOW}
    }};

    BridgeResult const applied = apply_file_priorities(params, std::span{priorities});
    REQUIRE(applied);
    REQUIRE(params.file_priorities.size() == priorities.size());
    CHECK(params.file_priorities.at(0) == lt::top_priority);
    CHECK(params.file_priorities.at(1) == lt::dont_download);
    CHECK(params.file_priorities.at(2) == lt::low_priority);
}

TEST_CASE("add params reject invalid file priorities")
{
    lt::add_torrent_params all_skipped = bridge_tests::add_params_with_hashes();
    all_skipped.ti = make_file_priority_torrent_info();
    std::array<TTorrentFilePriorityEntry, 3> const skipped_priorities{{
        TTorrentFilePriorityEntry{.index = 0, .priority = TTORRENT_FILE_PRIORITY_SKIP},
        TTorrentFilePriorityEntry{.index = 1, .priority = TTORRENT_FILE_PRIORITY_SKIP},
        TTorrentFilePriorityEntry{.index = 2, .priority = TTORRENT_FILE_PRIORITY_SKIP}
    }};
    BridgeResult const skipped = apply_file_priorities(all_skipped, std::span{skipped_priorities});
    REQUIRE_FALSE(skipped);
    CHECK(skipped.error().message == "Choose at least one file.");

    lt::add_torrent_params duplicate = bridge_tests::add_params_with_hashes();
    duplicate.ti = make_file_priority_torrent_info();
    std::array<TTorrentFilePriorityEntry, 2> const duplicate_priorities{{
        TTorrentFilePriorityEntry{.index = 0, .priority = TTORRENT_FILE_PRIORITY_NORMAL},
        TTorrentFilePriorityEntry{.index = 0, .priority = TTORRENT_FILE_PRIORITY_HIGH}
    }};
    BridgeResult const duplicate_result = apply_file_priorities(duplicate, std::span{duplicate_priorities});
    REQUIRE_FALSE(duplicate_result);
    CHECK(duplicate_result.error().message == "The file priorities are invalid.");
}

TEST_CASE("HTTPS source URL classification is strict and case-insensitive")
{
    CHECK(is_https_url("https://tracker.example/announce"));
    CHECK(is_https_url("HTTPS://tracker.example/announce"));
    CHECK_FALSE(is_https_url("http://tracker.example/announce"));
    CHECK_FALSE(is_https_url("udp://tracker.example/announce"));
    CHECK_FALSE(is_https_url("tracker.example/announce"));
}

TEST_CASE("source counts include trackers and web seeds")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce"
    };
    params.url_seeds.push_back("http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    TorrentSourceCounts const counts = torrent_source_counts(params);

    CHECK(counts.tracker_count == 2);
    CHECK(counts.https_tracker_count == 1);
    CHECK(counts.web_seed_count == 2);
    CHECK(counts.https_web_seed_count == 1);
}

TEST_CASE("magnet source inspection matches native parsing for case and numbered parameters")
{
    std::string const magnet = source_inspection_magnet(
        "&TR.1=HTTP%3A%2F%2Ftracker.example%2Fannounce"
        "&tr.=HTTPS%3A%2F%2Fsecure.example%2Fannounce"
        "&tr.label=https%3A%2F%2Fignored.example%2Fannounce"
        "&WS.2=HTTPS%3A%2F%2Fseed.example%2Ffile"
        "&ws.label=http%3A%2F%2Fignored-seed.example%2Ffile"
    );

    check_inspection_matches_native_parse(magnet);
    TTorrentSourceSecurityInspection const inspection = inspect_magnet_sources(magnet);
    CHECK(inspection.tracker_count == 2);
    CHECK(inspection.https_tracker_count == 1);
    CHECK(inspection.web_seed_count == 1);
    CHECK(inspection.https_web_seed_count == 1);
}

TEST_CASE("magnet source inspection matches native authority validation and decode-once behavior")
{
    std::string const malformed_authorities = source_inspection_magnet(
        "&tr=https%3A%2F%2F"
        "&tr=https%3A%2F%2Funder_score.example%2Fannounce"
        "&tr=https%3A%2F%2Fu%3Ap%40evil%40host.example%2Fannounce"
        "&tr=https%3A%2F%2Fsecure.example%2Fannounce%0A"
    );
    check_inspection_matches_native_parse(malformed_authorities);
    CHECK(inspect_magnet_sources(malformed_authorities).tracker_count == 0);

    std::string const decoded_once = source_inspection_magnet(
        "&tr=https%3A%2F%2Ftracker.example%2Fann+ounce"
        "&tr=https%3A%2F%2F%2565xample.com%2Fannounce"
        "&t%72=https%3A%2F%2Fignored.example%2Fannounce"
    );
    check_inspection_matches_native_parse(decoded_once);
    CHECK(inspect_magnet_sources(decoded_once).tracker_count == 0);
}

TEST_CASE("magnet source inspection enforces source count caps")
{
    std::string maximum = source_inspection_magnet();
    for (int32_t index = 0; index < TTORRENT_MAX_TRACKER_COUNT; ++index) {
        maximum += "&tr=http://t/a";
    }
    for (int32_t index = 0; index < TTORRENT_MAX_WEB_SEED_COUNT; ++index) {
        maximum += "&ws=http://s/f";
    }
    REQUIRE(maximum.size() <= kMaxMagnetURIBytes);

    TTorrentSourceSecurityInspection const maximum_inspection = inspect_magnet_sources(maximum);
    CHECK(maximum_inspection.tracker_count == TTORRENT_MAX_TRACKER_COUNT);
    CHECK(maximum_inspection.web_seed_count == TTORRENT_MAX_WEB_SEED_COUNT);

    std::string too_many_trackers = source_inspection_magnet();
    for (int32_t index = 0; index <= TTORRENT_MAX_TRACKER_COUNT; ++index) {
        too_many_trackers += "&tr=http://t/a";
    }
    REQUIRE(too_many_trackers.size() <= kMaxMagnetURIBytes);
    TTorrentSourceSecurityInspection tracker_output{
        .tracker_count = 1,
        .https_tracker_count = 1,
        .web_seed_count = 1,
        .https_web_seed_count = 1
    };
    CHECK(TorrentBridgeInspectMagnetSources(too_many_trackers.c_str(), &tracker_output) == 2);
    CHECK(tracker_output.tracker_count == 0);
    CHECK(tracker_output.https_tracker_count == 0);
    CHECK(tracker_output.web_seed_count == 0);
    CHECK(tracker_output.https_web_seed_count == 0);

    std::string too_many_web_seeds = source_inspection_magnet();
    for (int32_t index = 0; index <= TTORRENT_MAX_WEB_SEED_COUNT; ++index) {
        too_many_web_seeds += "&ws=http://s/f";
    }
    REQUIRE(too_many_web_seeds.size() <= kMaxMagnetURIBytes);
    TTorrentSourceSecurityInspection web_seed_output{};
    CHECK(TorrentBridgeInspectMagnetSources(too_many_web_seeds.c_str(), &web_seed_output) == 2);
}

TEST_CASE("magnet source inspection fails closed for invalid or oversized input")
{
    TTorrentSourceSecurityInspection output{
        .tracker_count = 1,
        .https_tracker_count = 1,
        .web_seed_count = 1,
        .https_web_seed_count = 1
    };
    CHECK(TorrentBridgeInspectMagnetSources("not-a-magnet", &output) == 2);
    CHECK(output.tracker_count == 0);
    CHECK(output.https_tracker_count == 0);
    CHECK(output.web_seed_count == 0);
    CHECK(output.https_web_seed_count == 0);

    std::string oversized = source_inspection_magnet();
    oversized.append(kMaxMagnetURIBytes, 'x');
    CHECK(TorrentBridgeInspectMagnetSources(oversized.c_str(), &output) == 2);
    CHECK(output.tracker_count == 0);

    CHECK(TorrentBridgeInspectMagnetSources(nullptr, &output) == 1);
    CHECK(output.tracker_count == 0);
    CHECK(TorrentBridgeInspectMagnetSources(source_inspection_magnet().c_str(), nullptr) == 1);
}

TEST_CASE("source validation rejects source lists above bridge limits")
{
    lt::add_torrent_params trackers = bridge_tests::add_params_with_hashes();
    trackers.trackers.resize(static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT) + 1U, "http://tracker.example/announce");

    BridgeResult const too_many_trackers = validate_torrent_sources(trackers);
    REQUIRE_FALSE(too_many_trackers);
    CHECK(too_many_trackers.error().code == 2);
    CHECK(too_many_trackers.error().message == "The torrent contains too many trackers. The maximum is 2000.");

    lt::add_torrent_params web_seeds = bridge_tests::add_params_with_hashes();
    web_seeds.url_seeds.resize(static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT) + 1U, "http://seed.example/file");

    BridgeResult const too_many_web_seeds = validate_torrent_sources(web_seeds);
    REQUIRE_FALSE(too_many_web_seeds);
    CHECK(too_many_web_seeds.error().code == 2);
    CHECK(too_many_web_seeds.error().message == "The torrent contains too many web seeds. The maximum is 2000.");
}

TEST_CASE("source validation applies after HTTPS source filtering")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers.resize(static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT) + 1U, "http://tracker.example/announce");
    params.trackers.push_back("https://secure-tracker.example/announce");
    params.url_seeds.resize(static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT) + 1U, "http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    REQUIRE(filter_non_https_sources(params, true, true));

    CHECK(validate_torrent_sources(params).has_value());
    CHECK(params.trackers == std::vector<std::string>{"https://secure-tracker.example/announce"});
    CHECK(params.url_seeds == std::vector<std::string>{"https://secure-seed.example/file"});
}

TEST_CASE("source restoration preserves bridge source count caps")
{
    TorrentIdentity identity;
    identity.source_trackers.emplace_back("http://extra-tracker.example/announce");
    identity.source_web_seeds.emplace_back("http://extra-seed.example/file");

    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers.reserve(static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT));
    for (int32_t index = 0; index < TTORRENT_MAX_TRACKER_COUNT; ++index) {
        params.trackers.push_back("http://tracker" + std::to_string(index) + ".example/announce");
    }
    params.url_seeds.reserve(static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT));
    for (int32_t index = 0; index < TTORRENT_MAX_WEB_SEED_COUNT; ++index) {
        params.url_seeds.push_back("http://seed" + std::to_string(index) + ".example/file");
    }

    restore_source_policy_sources(params, &identity);

    CHECK(params.trackers.size() == static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT));
    CHECK(params.url_seeds.size() == static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT));
    CHECK(validate_torrent_sources(params).has_value());
}

TEST_CASE("torrent file data preview counts sources drained into add params")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    std::vector<char> const torrent_data = make_http_tracker_torrent_buffer();

    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentFilePreview preview{};
    int32_t required_count = 0;
    char error[512]{};
    REQUIRE(TorrentClientPreviewTorrentFileData(
        &client,
        torrent_data.data(),
        static_cast<int32_t>(torrent_data.size()),
        &preview,
        nullptr,
        0,
        &required_count,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(required_count == 1);
    CHECK(preview.tracker_count == 1);
    CHECK(preview.https_tracker_count == 0);
    CHECK(preview.web_seed_count == 0);
    CHECK(preview.https_web_seed_count == 0);
}

TEST_CASE("torrent file data preview applies duplicate filename renames from add params")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    std::vector<char> const torrent_data = make_duplicate_file_torrent_buffer();
    lt::add_torrent_params const params =
        bridge_tests::load_torrent_params(torrent_data, "duplicate filename torrent info");
    REQUIRE(params.ti != nullptr);
    REQUIRE(params.ti->layout().num_files() == 2);
    CHECK(params.ti->layout().file_path(lt::file_index_t(0)) == "duplicate/same.bin");
    CHECK(params.ti->layout().file_path(lt::file_index_t(1)) == "duplicate/same.bin");

    auto const renamed = params.renamed_files.find(lt::file_index_t(1));
    REQUIRE(renamed != params.renamed_files.end());
    REQUIRE(renamed->second == "duplicate/same.1.bin");

    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentFilePreview preview{};
    std::array<TTorrentFileSnapshot, 2> files{};
    int32_t required_count = 0;
    char error[512]{};
    REQUIRE(TorrentClientPreviewTorrentFileData(
        &client,
        torrent_data.data(),
        static_cast<int32_t>(torrent_data.size()),
        &preview,
        files.data(),
        static_cast<int32_t>(files.size()),
        &required_count,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(required_count == 2);
    CHECK(preview.file_count == 2);
    CHECK(std::string(files.at(0).path) == "duplicate/same.bin");
    CHECK(std::string(files.at(1).path) == renamed->second);
}

TEST_CASE("filtering non-HTTPS sources keeps tracker tiers aligned")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce",
        "udp://tracker.example/announce",
        "HTTPS://second-secure-tracker.example/announce"
    };
    params.tracker_tiers = {0, 1, 2, 3};
    params.url_seeds.push_back("http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    CHECK(filter_non_https_sources(params));

    std::vector<std::string> const expected_trackers{
        "https://secure-tracker.example/announce",
        "HTTPS://second-secure-tracker.example/announce"
    };
    std::vector<int> const expected_tiers{1, 3};
    std::vector<std::string> const expected_url_seeds{
        "https://secure-seed.example/file"
    };

    CHECK(params.trackers == expected_trackers);
    CHECK(params.tracker_tiers == expected_tiers);
    CHECK(std::vector<std::string>(params.url_seeds.begin(), params.url_seeds.end()) == expected_url_seeds);
}

TEST_CASE("filtering non-HTTPS sources can target trackers only")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce"
    };
    params.tracker_tiers = {0, 1};
    params.url_seeds.push_back("http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    CHECK(filter_non_https_sources(params, true, false));

    std::vector<std::string> const expected_trackers{"https://secure-tracker.example/announce"};
    std::vector<std::string> const expected_url_seeds{
        "http://seed.example/file",
        "https://secure-seed.example/file"
    };
    CHECK(params.trackers == expected_trackers);
    CHECK(std::vector<std::string>(params.url_seeds.begin(), params.url_seeds.end()) == expected_url_seeds);
}

TEST_CASE("filtering non-HTTPS sources can target web seeds only")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce"
    };
    params.tracker_tiers = {0, 1};
    params.url_seeds.push_back("http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    CHECK(filter_non_https_sources(params, false, true));

    std::vector<std::string> const expected_trackers{
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce"
    };
    std::vector<std::string> const expected_url_seeds{"https://secure-seed.example/file"};
    CHECK(params.trackers == expected_trackers);
    CHECK(std::vector<std::string>(params.url_seeds.begin(), params.url_seeds.end()) == expected_url_seeds);
}

TEST_CASE("filtering non-HTTPS sources filters loaded torrent sources")
{
    lt::add_torrent_params params = make_source_torrent_params();

    CHECK(filter_non_https_sources(params));

    TorrentSourceCounts const counts = torrent_source_counts(params);
    CHECK(counts.tracker_count == 1);
    CHECK(counts.https_tracker_count == 1);
    CHECK(counts.web_seed_count == 1);
    CHECK(counts.https_web_seed_count == 1);
}

TEST_CASE("restricted DHT policy strips trackerless resume peer cache")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.peers.emplace_back(lt::make_address_v4("203.0.113.10"), 6881);
    TorrentIdentity identity;

    CHECK(should_strip_resume_peer_cache(params, &identity, true));
    strip_resume_peer_cache(params);

    std::vector<char> const encoded = encoded_resume_data(params, &identity, false, true);
    lt::error_code error;
    lt::add_torrent_params const decoded = lt::read_resume_data(
        lt::span<char const>(encoded.data(), static_cast<int>(encoded.size())),
        error
    );

    REQUIRE_FALSE(error);
    CHECK(decoded.peers.empty());
    CHECK(app_disabled_dht_from_resume_data(encoded));
}

TEST_CASE("restricted DHT policy keeps resume peer cache when trackers remain")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers.push_back("https://secure-tracker.example/announce");
    params.tracker_tiers.push_back(0);
    params.peers.emplace_back(lt::make_address_v4("203.0.113.10"), 6881);
    TorrentIdentity identity;

    CHECK_FALSE(should_strip_resume_peer_cache(params, &identity, true));

    std::vector<char> const encoded = encoded_resume_data(params, &identity, false, true);
    lt::error_code error;
    lt::add_torrent_params const decoded = lt::read_resume_data(
        lt::span<char const>(encoded.data(), static_cast<int>(encoded.size())),
        error
    );

    REQUIRE_FALSE(error);
    REQUIRE(decoded.peers.size() == 1U);
    CHECK(decoded.peers.front().port() == 6881);
}

TEST_CASE("resume encoding uses captured source policy snapshot")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    TorrentIdentity identity;
    identity.canonical_id = "t:0123456789abcdef0123456789abcdef";
    identity.allows_non_https_trackers = true;
    identity.requires_https_web_seeds = true;
    identity.dht_disabled_by_user = true;
    identity.lsd_disabled_by_user = true;
    identity.source_trackers.emplace_back("http://tracker.example/announce");

    ResumePolicySnapshot const snapshot = resume_policy_snapshot(&identity, false, true, true, false);

    identity.allows_non_https_trackers = false;
    identity.requires_https_web_seeds = false;
    identity.dht_disabled_by_user = false;
    identity.lsd_disabled_by_user = false;
    identity.source_trackers.clear();

    std::vector<char> const encoded = encoded_resume_data(params, snapshot);

    CHECK(canonical_id_from_resume_data(encoded) == "t:0123456789abcdef0123456789abcdef");
    CHECK(allow_non_https_trackers_from_resume_data(encoded));
    CHECK(require_https_web_seeds_from_resume_data(encoded));
    CHECK(disable_dht_from_resume_data(encoded));
    CHECK(app_disabled_dht_from_resume_data(encoded));
    CHECK(disable_lsd_from_resume_data(encoded));
    CHECK(app_disabled_lsd_from_resume_data(encoded));
}

TEST_CASE("resume encoding records explicit pre-metadata DHT consent only for a pending validation")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    TorrentIdentity identity;
    identity.canonical_id = "t:0123456789abcdef0123456789abcdef";
    identity.allow_pre_metadata_dht = true;

    std::vector<char> const pending = encoded_resume_data(params, &identity, true);
    std::vector<char> const validated = encoded_resume_data(params, &identity, false);

    CHECK(metadata_validation_pending_from_resume_data(pending));
    CHECK(allow_pre_metadata_dht_from_resume_data(pending));
    CHECK_FALSE(metadata_validation_pending_from_resume_data(validated));
    CHECK_FALSE(allow_pre_metadata_dht_from_resume_data(validated));
}

TEST_CASE("restored source policy trackers are persisted in resume params with metadata")
{
    lt::add_torrent_params params = make_source_torrent_params();
    params.trackers.clear();
    params.tracker_tiers.clear();

    TorrentIdentity identity;
    lt::announce_entry tracker;
    tracker.url = "http://tracker.example/announce";
    tracker.tier = 0;
    identity.source_trackers.push_back(tracker);

    restore_source_policy_sources(params, &identity);

    REQUIRE(params.trackers.size() == 1U);
    CHECK(params.trackers.front() == "http://tracker.example/announce");
    REQUIRE(params.tracker_tiers.size() == 1U);
    CHECK(params.tracker_tiers.front() == 0);
}

TEST_CASE("network client identity is generic and coarse")
{
    lt::settings_pack const settings = make_settings();

    CHECK(settings.get_str(lt::settings_pack::user_agent) == std::string(kNetworkClientIdentity));
    CHECK(settings.get_str(lt::settings_pack::handshake_client_version) == std::string(kNetworkClientIdentity));
    CHECK(settings.get_str(lt::settings_pack::user_agent).find("torrent-app") == std::string::npos);
    CHECK(settings.get_str(lt::settings_pack::handshake_client_version).find("torrent-app") == std::string::npos);
    CHECK(settings.get_bool(lt::settings_pack::no_connect_privileged_ports));
}

TEST_CASE("untrusted magnet endpoint hints are discarded")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.dht_nodes.emplace_back("127.0.0.1", 6881);
    params.peers.emplace_back(lt::make_address_v4("127.0.0.1"), 6881);
    params.peers.emplace_back(lt::make_address_v4("8.8.8.8"), 80);
    params.peers.emplace_back(lt::make_address_v4("8.8.8.8"), 6881);
    params.peers.emplace_back(lt::make_address("2001:4860:4860::8888"), 6881);

    sanitize_magnet_endpoint_hints(params);

    CHECK(params.dht_nodes.empty());
    CHECK(params.peers.empty());
}
