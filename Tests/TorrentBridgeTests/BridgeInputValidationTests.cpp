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
}
