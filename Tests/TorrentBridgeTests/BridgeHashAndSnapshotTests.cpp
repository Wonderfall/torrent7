#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <libtorrent/create_torrent.hpp>

#include <array>
#include <memory>
#include <span>
#include <string>
#include <vector>

TEST_CASE("hex and bridge ID helpers use lowercase canonical forms")
{
    std::string bytes;
    bytes.push_back(static_cast<char>(0x00U));
    bytes.push_back(static_cast<char>(0x0fU));
    bytes.push_back(static_cast<char>(0x10U));
    bytes.push_back(static_cast<char>(0xffU));

    CHECK(hex_string(bytes) == "000f10ff");
    CHECK(is_hex_character('0'));
    CHECK(is_hex_character('a'));
    CHECK(is_hex_character('f'));
    CHECK_FALSE(is_hex_character('A'));
    CHECK_FALSE(is_hex_character('g'));

    CHECK(is_canonical_torrent_id(bridge_tests::canonical_id('a')));
    CHECK_FALSE(is_canonical_torrent_id("t:" + std::string(32U, 'A')));
    CHECK_FALSE(is_canonical_torrent_id("v1:" + std::string(40U, '1')));

    CHECK(is_resume_data_id(bridge_tests::canonical_id('b')));
    CHECK(is_resume_data_id(bridge_tests::v1_id('1')));
    CHECK(is_resume_data_id(bridge_tests::v2_id('2')));
    CHECK_FALSE(is_resume_data_id("v2:" + std::string(63U, '2')));
}

TEST_CASE("make_canonical_torrent_id returns syntactically valid durable IDs")
{
    CHECK(is_canonical_torrent_id(make_canonical_torrent_id()));
}

TEST_CASE("hash keys include available protocols in stable order")
{
    lt::info_hash_t const hashes = bridge_tests::info_hashes_from_seed(1U, 33U);

    std::vector<std::string> const keys = hash_keys(hashes);
    REQUIRE(keys.size() == 2U);
    CHECK(keys.at(0) == "v1:" + bridge_tests::hex_for_sequential_bytes(20U, 1U));
    CHECK(keys.at(1) == "v2:" + bridge_tests::hex_for_sequential_bytes(32U, 33U));

    std::vector<std::string> const requested = hash_keys_with_requested(hashes, bridge_tests::canonical_id('c'));
    REQUIRE(requested.size() == 3U);
    CHECK(requested.at(2) == bridge_tests::canonical_id('c'));
}

TEST_CASE("copy_primary_hash_key writes the v1 hash when present")
{
    lt::info_hash_t const hashes = bridge_tests::info_hashes_from_seed(1U, 33U);
    std::array<char, 68> output{};

    copy_primary_hash_key(std::span{output}, hashes);

    CHECK(bridge_tests::string_from_c_buffer(std::span{output}) == "v1:" + bridge_tests::hex_for_sequential_bytes(20U, 1U));
}

TEST_CASE("hash matching and snapshot identity prefer canonical IDs when available")
{
    lt::info_hash_t const hashes = bridge_tests::info_hashes_from_seed(1U, 33U);
    std::string const v1 = "v1:" + bridge_tests::hex_for_sequential_bytes(20U, 1U);
    std::string const canonical = bridge_tests::canonical_id('d');
    TorrentIdentity identity;
    identity.canonical_id = canonical;

    CHECK(hash_matches(hashes, v1));
    CHECK_FALSE(hash_matches(hashes, canonical));
    CHECK(primary_hash_key(hashes) == v1);
    CHECK(identity_snapshot_id(&identity, hashes) == canonical);
    CHECK(identity_snapshot_id(nullptr, hashes) == v1);
}

TEST_CASE("encoded resume data carries only valid canonical bridge IDs")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    TorrentIdentity identity;
    identity.canonical_id = bridge_tests::canonical_id('e');

    std::vector<char> const encoded = encoded_resume_data(params, &identity);
    CHECK(canonical_id_from_resume_data(encoded) == identity.canonical_id);

    identity.canonical_id = "not-a-canonical-id";
    std::vector<char> const encoded_without_identity = encoded_resume_data(params, &identity);
    CHECK(canonical_id_from_resume_data(encoded_without_identity).empty());

    CHECK(canonical_id_from_resume_data(bridge_tests::byte_vector("not bencoded")).empty());
}

TEST_CASE("bridge booleans and torrent states are stable ABI values")
{
    CHECK(bridge_bool(true) == 1U);
    CHECK(bridge_bool(false) == 0U);
    CHECK(bridge_bool(static_cast<std::uint8_t>(99U)));
    CHECK_FALSE(bridge_bool(static_cast<std::uint8_t>(0U)));

    CHECK(bridge_torrent_state(lt::torrent_status::checking_files) == TTORRENT_BRIDGE_STATE_CHECKING_FILES);
    CHECK(bridge_torrent_state(lt::torrent_status::downloading_metadata) == TTORRENT_BRIDGE_STATE_DOWNLOADING_METADATA);
    CHECK(bridge_torrent_state(lt::torrent_status::downloading) == TTORRENT_BRIDGE_STATE_DOWNLOADING);
    CHECK(bridge_torrent_state(lt::torrent_status::finished) == TTORRENT_BRIDGE_STATE_FINISHED);
    CHECK(bridge_torrent_state(lt::torrent_status::seeding) == TTORRENT_BRIDGE_STATE_SEEDING);
    CHECK(bridge_torrent_state(lt::torrent_status::checking_resume_data) == TTORRENT_BRIDGE_STATE_CHECKING_RESUME_DATA);
}

TEST_CASE("tracker host normalization extracts bounded lowercase hosts")
{
    CHECK(normalized_tracker_host("https://Tracker.Example.Org:443/announce").value_or("") == "tracker.example.org");
    CHECK(normalized_tracker_host("udp://torrent.FEDORAPROJECT.org:6969/announce").value_or("") == "torrent.fedoraproject.org");
    CHECK(normalized_tracker_host("http://tracker.example.org./announce").value_or("") == "tracker.example.org");
    CHECK_FALSE(normalized_tracker_host("not a tracker url").has_value());
    CHECK_FALSE(normalized_tracker_host("https:///announce").has_value());
}

TEST_CASE("download progress handles terminal, empty, and clamped states")
{
    lt::torrent_status status;
    status.total_wanted = 100;
    status.total_wanted_done = 25;
    CHECK(download_progress(status) == doctest::Approx(0.25));

    status.total_wanted_done = 250;
    CHECK(download_progress(status) == doctest::Approx(1.0));

    status.total_wanted = 0;
    status.total_wanted_done = 0;
    CHECK(download_progress(status) == doctest::Approx(0.0));

    status.is_finished = true;
    CHECK(download_progress(status) == doctest::Approx(1.0));
}

TEST_CASE("snapshot_from_status copies sanitized ABI fields")
{
    lt::torrent_status status;
    status.info_hashes = bridge_tests::info_hashes_from_seed(1U, 33U);
    status.name = "Example";
    status.save_path = "/tmp/downloads";
    status.total_wanted = 200;
    status.total_wanted_done = 50;
    status.total_upload = 1;
    status.total_download = 2;
    status.total_payload_upload = 3;
    status.total_payload_download = 4;
    status.all_time_upload = 5;
    status.all_time_download = 6;
    status.download_rate = 7;
    status.upload_rate = 8;
    status.download_payload_rate = 9;
    status.upload_payload_rate = 10;
    status.num_peers = 11;
    status.list_peers = 12;
    status.num_seeds = 13;
    status.state = lt::torrent_status::downloading;
    status.queue_position = lt::queue_position_t(14);
    status.flags |= lt::torrent_flags::paused;
    status.flags |= lt::torrent_flags::auto_managed;
    status.has_metadata = true;

    TTorrentSnapshot const snapshot = snapshot_from_status(status);
    std::string const expected_id = "v1:" + bridge_tests::hex_for_sequential_bytes(20U, 1U);

    CHECK(std::string(snapshot.id) == expected_id);
    CHECK(std::string(snapshot.info_hash) == expected_id);
    CHECK(std::string(snapshot.name) == "Example");
    CHECK(std::string(snapshot.save_path) == "/tmp/downloads");
    CHECK(snapshot.progress == doctest::Approx(0.25));
    CHECK(snapshot.total_done == 50);
    CHECK(snapshot.total_wanted == 200);
    CHECK(snapshot.total_upload == 1);
    CHECK(snapshot.total_download == 2);
    CHECK(snapshot.total_payload_upload == 3);
    CHECK(snapshot.total_payload_download == 4);
    CHECK(snapshot.all_time_upload == 5);
    CHECK(snapshot.all_time_download == 6);
    CHECK(snapshot.download_rate == 7);
    CHECK(snapshot.upload_rate == 8);
    CHECK(snapshot.download_payload_rate == 9);
    CHECK(snapshot.upload_payload_rate == 10);
    CHECK(snapshot.peers == 11);
    CHECK(snapshot.known_peers == 12);
    CHECK(snapshot.seeds == 13);
    CHECK(snapshot.state == TTORRENT_BRIDGE_STATE_DOWNLOADING);
    CHECK(snapshot.queue_position == 14);
    CHECK(snapshot.queue_priority == TTORRENT_QUEUE_PRIORITY_NORMAL);
    CHECK(bridge_bool(snapshot.paused));
    CHECK(bridge_bool(snapshot.auto_managed));
    CHECK(bridge_bool(snapshot.has_metadata));
}

TEST_CASE("snapshot_from_status maps torrent metadata facts when available")
{
    lt::file_storage storage;
    storage.add_file("metadata.bin", 1024);

    lt::create_torrent creator(storage, 16 * 1024, lt::create_torrent::v1_only);
    creator.set_priv(true);
    creator.set_comment("Created for tests");
    creator.set_creation_date(12'345);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(17U));

    std::vector<char> const buffer = creator.generate_buf();
    lt::error_code error;
    auto info = std::make_shared<lt::torrent_info>(
        lt::span<char const>(buffer.data(), static_cast<int>(buffer.size())),
        error,
        lt::from_span
    );
    REQUIRE_FALSE(error);

    lt::torrent_status status;
    status.info_hashes = info->info_hashes();
    status.torrent_file = info;
    status.total = 512;
    status.total_wanted = 256;
    status.completed_time = 67'890;
    status.has_metadata = true;

    TTorrentSnapshot const snapshot = snapshot_from_status(status);

    CHECK(std::string(snapshot.comment) == "Created for tests");
    CHECK(snapshot.total_size == 1024);
    CHECK(snapshot.created_time == 12'345);
    CHECK(snapshot.completed_time == 67'890);
    CHECK(bridge_bool(snapshot.private_torrent));
}
