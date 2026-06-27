#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <libtorrent/create_torrent.hpp>

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <vector>

namespace {

[[nodiscard]] bool has_owner_directory_permissions(fs::path const &path)
{
    fs::perms const permissions = fs::status(path).permissions();
    return (permissions & fs::perms::owner_read) != fs::perms::none
        && (permissions & fs::perms::owner_write) != fs::perms::none
        && (permissions & fs::perms::owner_exec) != fs::perms::none
        && (permissions & fs::perms::group_all) == fs::perms::none
        && (permissions & fs::perms::others_all) == fs::perms::none;
}

[[nodiscard]] bool file_exists(fs::path const &path)
{
    std::error_code ignored;
    return fs::exists(path, ignored);
}

template <typename Predicate>
[[nodiscard]] bool eventually(Predicate &&predicate)
{
    for (int attempt = 0; attempt < 40; ++attempt) {
        if (predicate()) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    return predicate();
}

[[nodiscard]] TTorrentAddOptions default_add_options(bool enable_peer_exchange = true)
{
    return TTorrentAddOptions{
        .starts_paused = bridge_bool(false),
        .queue_priority = static_cast<uint8_t>(TTORRENT_QUEUE_PRIORITY_NORMAL),
        .enable_peer_exchange = bridge_bool(enable_peer_exchange),
        .allow_non_https_trackers = bridge_bool(false),
        .allow_non_https_web_seeds = bridge_bool(false),
    };
}

[[nodiscard]] std::shared_ptr<lt::torrent_info> make_torrent_info(bool is_private)
{
    lt::file_storage storage;
    storage.add_file(is_private ? "private.bin" : "public.bin", 4);

    lt::create_torrent creator(storage, 16 * 1024, lt::create_torrent::v1_only);
    creator.set_priv(is_private);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(9U));

    std::vector<char> const buffer = creator.generate_buf();
    lt::error_code error;
    auto info = std::make_shared<lt::torrent_info>(
        lt::span<char const>(buffer.data(), static_cast<int>(buffer.size())),
        error,
        lt::from_span
    );
    if (error) {
        throw std::runtime_error("Could not create torrent info: " + error.message());
    }
    return info;
}

[[nodiscard]] std::shared_ptr<lt::torrent_info> make_piece_map_torrent_info()
{
    constexpr int piece_size = 16 * 1024;
    constexpr int piece_count = 5;

    lt::file_storage storage;
    storage.add_file("piece-map.bin", static_cast<std::int64_t>(piece_size * piece_count));

    lt::create_torrent creator(storage, piece_size, lt::create_torrent::v1_only);
    for (int piece = 0; piece < piece_count; ++piece) {
        creator.set_hash(lt::piece_index_t(piece), bridge_tests::sha1_hash_from_seed(static_cast<unsigned char>(20 + piece)));
    }

    std::vector<char> const buffer = creator.generate_buf();
    lt::error_code error;
    auto info = std::make_shared<lt::torrent_info>(
        lt::span<char const>(buffer.data(), static_cast<int>(buffer.size())),
        error,
        lt::from_span
    );
    if (error) {
        throw std::runtime_error("Could not create piece map torrent info: " + error.message());
    }
    return info;
}

[[nodiscard]] std::shared_ptr<lt::torrent_info> make_source_torrent_info()
{
    lt::file_storage storage;
    storage.add_file("source-policy.bin", 4);

    lt::create_torrent creator(storage, 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(10U));
    creator.add_tracker("http://tracker.example/announce", 0);
    creator.add_tracker("https://secure-tracker.example/announce", 1);
    creator.add_url_seed("http://seed.example/file");
    creator.add_url_seed("https://secure-seed.example/file");
    creator.add_http_seed("http://http-seed.example/file");
    creator.add_http_seed("https://secure-http-seed.example/file");

    std::vector<char> const buffer = creator.generate_buf();
    lt::error_code error;
    auto info = std::make_shared<lt::torrent_info>(
        lt::span<char const>(buffer.data(), static_cast<int>(buffer.size())),
        error,
        lt::from_span
    );
    if (error) {
        throw std::runtime_error("Could not create source policy torrent info: " + error.message());
    }
    return info;
}

[[nodiscard]] std::shared_ptr<lt::torrent_info> make_queue_torrent_info(unsigned char seed)
{
    lt::file_storage storage;
    storage.add_file("queue-" + std::to_string(seed) + ".bin", 4);

    lt::create_torrent creator(storage, 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(seed));

    std::vector<char> const buffer = creator.generate_buf();
    lt::error_code error;
    auto info = std::make_shared<lt::torrent_info>(
        lt::span<char const>(buffer.data(), static_cast<int>(buffer.size())),
        error,
        lt::from_span
    );
    if (error) {
        throw std::runtime_error("Could not create queue torrent info: " + error.message());
    }
    return info;
}

struct WebSeedCounts {
    int32_t url = 0;
    int32_t http = 0;
};

struct SelfClearingWakeContext {
    TTorrentClient *client = nullptr;
    bool called = false;
};

void self_clearing_wake_callback(void *context)
{
    auto *wake_context = static_cast<SelfClearingWakeContext *>(context);
    wake_context->called = true;
    TorrentClientClearWakeCallback(wake_context->client);
}

[[nodiscard]] WebSeedCounts cached_web_seed_counts(TTorrentClient &client, std::string const &id)
{
    std::uint64_t revision = 0;
    int32_t required_count = 0;
    REQUIRE(client.copy_web_seeds(id, {}, &revision, &required_count) == 0);

    std::vector<TTorrentWebSeedSnapshot> web_seeds(static_cast<std::size_t>(required_count));
    REQUIRE(client.copy_web_seeds(id, web_seeds, &revision, &required_count) == required_count);

    WebSeedCounts counts;
    for (TTorrentWebSeedSnapshot const &web_seed : web_seeds) {
        if (web_seed.kind == static_cast<int32_t>(WebSeedKind::http)) {
            ++counts.http;
        } else {
            ++counts.url;
        }
    }
    return counts;
}

[[nodiscard]] int32_t persisted_queue_rank(TTorrentClient const &client, lt::torrent_info const &info)
{
    std::string const id = primary_hash_key(info.info_hashes());
    FileReadResult const buffer = read_file(client.resume_directory / (id + std::string(kResumeExtension)),
                                            kMaxResumeFileBytes);
    if (!buffer) {
        return kUnsetQueueRank;
    }
    return queue_rank_from_resume_data(*buffer);
}

[[nodiscard]] lt::torrent_handle add_metadata_torrent(
    TTorrentClient &client,
    lt::torrent_info const &info,
    fs::path const &save_path,
    TorrentIdentity *&identity
)
{
    lt::add_torrent_params params;
    params.ti = std::make_shared<lt::torrent_info>(info);
    params.info_hashes = info.info_hashes();
    prepare_add_params(params, save_path.string(), false, true);

    identity = client.attach_identity(params);
    remember_source_policy_sources(*identity, info);
    lt::error_code add_error;
    lt::torrent_handle handle = client.session.add_torrent(std::move(params), add_error);
    if (add_error) {
        throw std::runtime_error("Could not add metadata torrent: " + add_error.message());
    }
    client.mark_active(handle, identity);
    return handle;
}

} // namespace

TEST_CASE("TTorrentClient creates owner-only state directories and holds an exclusive lock")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const resume_directory = state_directory / "ResumeData";

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);

    CHECK(file_exists(state_directory));
    CHECK(file_exists(resume_directory));
    CHECK(has_owner_directory_permissions(state_directory));
    CHECK(has_owner_directory_permissions(resume_directory));

    CHECK_THROWS_AS(static_cast<void>(TTorrentClient(state_directory.string())), std::system_error);
}

TEST_CASE("wake callback can clear itself without waiting on itself")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    SelfClearingWakeContext context{.client = &client};
    TorrentClientSetWakeCallback(&client, self_clearing_wake_callback, &context);

    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(client.lock);
        wake = client.publish_changes_locked(TTORRENT_DIRTY_ERRORS);
    }
    client.invoke_wake_callback(wake);

    CHECK(context.called);
    {
        std::scoped_lock guard(client.lock);
        CHECK(client.wake_callbacks_in_flight == 0);
    }
}

TEST_CASE("TTorrentClient startup completes durable tombstoned resume cleanup")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const resume_directory = state_directory / "ResumeData";
    REQUIRE(fs::create_directories(resume_directory));

    std::string const id = bridge_tests::v1_id('5');
    fs::path const resume_path = resume_directory / (id + std::string(kResumeExtension));
    fs::path const simple_temp_path = resume_directory / (id + std::string(kResumeExtension) + std::string(kTempExtension));
    fs::path const unique_temp_path = resume_directory / (id + std::string(kResumeExtension) + std::string(kTempExtension) + ".123.456.0");
    fs::path const tombstone_path = removal_tombstone_path(resume_directory);

    bridge_tests::write_text_file(resume_path, "resume");
    bridge_tests::write_text_file(simple_temp_path, "temp");
    bridge_tests::write_text_file(unique_temp_path, "temp");
    ResumeSaveResult const tombstone = write_owner_only_file_checked(
        tombstone_path,
        tombstone_payload({id}, RemovalTombstoneState::resume_cleanup, false, false)
    );
    REQUIRE(tombstone.has_value());

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);

    CHECK_FALSE(file_exists(resume_path));
    CHECK_FALSE(file_exists(simple_temp_path));
    CHECK_FALSE(file_exists(unique_temp_path));
    CHECK_FALSE(file_exists(tombstone_path));
}

TEST_CASE("TTorrentClient startup reports abandoned payload deletion tombstones")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const resume_directory = state_directory / "ResumeData";
    REQUIRE(fs::create_directories(resume_directory));

    std::string const id = bridge_tests::v1_id('6');
    fs::path const tombstone_path = removal_tombstone_path(resume_directory);
    ResumeSaveResult const tombstone = write_owner_only_file_checked(
        tombstone_path,
        tombstone_payload({id}, RemovalTombstoneState::awaiting_payload_delete, true, true)
    );
    REQUIRE(tombstone.has_value());

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);

    std::array<char, 512> error{};
    CHECK(client.take_alert_error(std::span{error}));
    CHECK(bridge_tests::string_from_c_buffer(std::span{error}) == "A previous data deletion did not finish before shutdown. Some downloaded files may remain on disk.");
    CHECK_FALSE(file_exists(tombstone_path));
}

TEST_CASE("pending resume cleanup groups are normalized and deduplicated")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::string const first = bridge_tests::v1_id('7');
    std::string const second = bridge_tests::v2_id('8');

    client.remember_pending_resume_cleanup({first, second, first});

    std::vector<std::vector<std::string>> const groups = client.pending_resume_cleanup_id_groups();
    REQUIRE(groups.size() == 1U);
    CHECK(groups.front() == std::vector<std::string>{first, second});
}

TEST_CASE("coalesced async resume saves preserve policy save flags")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    TorrentIdentity *identity = client.make_identity();

    std::optional<std::uint64_t> const generation =
        client.begin_async_resume_save(identity, kRoutineResumeSaveFlags);
    REQUIRE(generation.has_value());
    CHECK_FALSE(client.begin_async_resume_save(identity, kPolicyResumeSaveFlags).has_value());

    std::optional<lt::resume_data_flags_t> const repeat_flags =
        client.complete_async_resume_save(identity, *generation);
    REQUIRE(repeat_flags.has_value());
    CHECK(static_cast<bool>(*repeat_flags & lt::torrent_handle::save_info_dict));
    CHECK_FALSE(static_cast<bool>(*repeat_flags & lt::torrent_handle::only_if_modified));
}

TEST_CASE("settings apply toggles peer exchange for loaded torrents")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    char error[512]{};

    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(true);
    settings.use_pex_by_default = bridge_bool(false);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));

    settings.use_pex_by_default = bridge_bool(true);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));

    handle.set_flags(lt::torrent_flags::disable_pex);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
}

TEST_CASE("disabled peer exchange plugin gates per-torrent PEX policy")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string(), false);
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    char error[512]{};

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(true);
    settings.use_pex_by_default = bridge_bool(true);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    TTorrentSourcePolicy policy{};
    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK_FALSE(bridge_bool(policy.peer_exchange_locked));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));

    policy.enable_peer_exchange = bridge_bool(true);
    REQUIRE(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(client.peer_exchange_disabled_by_app.contains(identity));

    client.peer_exchange_plugin_enabled = true;
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(identity));
}

TEST_CASE("per-torrent options copy and set bandwidth limits")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    char error[512]{};

    TTorrentOptions options{};
    REQUIRE(TorrentClientCopyTorrentOptions(
        &client,
        identity->canonical_id.c_str(),
        &options,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(options.download_rate_limit == -1);
    CHECK(options.upload_rate_limit == -1);
    CHECK(options.max_uploads == -1);
    CHECK(options.max_connections == -1);
    CHECK(options.queue_priority == TTORRENT_QUEUE_PRIORITY_NORMAL);

    options.download_rate_limit = 512 * 1024;
    options.upload_rate_limit = 128 * 1024;
    options.max_uploads = 6;
    options.max_connections = 80;
    options.queue_priority = TTORRENT_QUEUE_PRIORITY_HIGH;
    REQUIRE(TorrentClientSetTorrentOptions(
        &client,
        identity->canonical_id.c_str(),
        &options,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(handle.download_limit() == 512 * 1024);
    CHECK(handle.upload_limit() == 128 * 1024);
    CHECK(handle.max_uploads() == 6);
    CHECK(handle.max_connections() == 80);
    CHECK(identity->queue_priority == TTORRENT_QUEUE_PRIORITY_HIGH);

    TTorrentOptions copied{};
    REQUIRE(TorrentClientCopyTorrentOptions(
        &client,
        identity->canonical_id.c_str(),
        &copied,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(copied.download_rate_limit == 512 * 1024);
    CHECK(copied.upload_rate_limit == 128 * 1024);
    CHECK(copied.max_uploads == 6);
    CHECK(copied.max_connections == 80);
    CHECK(copied.queue_priority == TTORRENT_QUEUE_PRIORITY_HIGH);
}

TEST_CASE("queue moves normalize and persist app-owned queue ranks")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    auto first_info = make_queue_torrent_info(21U);
    auto second_info = make_queue_torrent_info(22U);
    auto third_info = make_queue_torrent_info(23U);

    {
        TTorrentClient client(state_directory.string());
        client.set_session_shutdown_asynchronous(false);

        TorrentIdentity *first_identity = nullptr;
        TorrentIdentity *second_identity = nullptr;
        TorrentIdentity *third_identity = nullptr;
        static_cast<void>(add_metadata_torrent(client, *first_info, temporary_directory.path(), first_identity));
        static_cast<void>(add_metadata_torrent(client, *second_info, temporary_directory.path(), second_identity));
        static_cast<void>(add_metadata_torrent(client, *third_info, temporary_directory.path(), third_identity));
        REQUIRE(first_identity != nullptr);
        REQUIRE(second_identity != nullptr);
        REQUIRE(third_identity != nullptr);
        char error[512]{};

        first_identity->queue_rank = 0;
        second_identity->queue_rank = 1;
        third_identity->queue_rank = 2;
        static_cast<void>(client.apply_queue_priority_order_locked());
        BridgeResult const saved = client.save_all_checked();
        REQUIRE(static_cast<bool>(saved));

        REQUIRE(TorrentClientMoveTorrentInQueue(
            &client,
            third_identity->canonical_id.c_str(),
            TTORRENT_QUEUE_MOVE_TOP,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);

        CHECK(third_identity->queue_rank == 0);
        CHECK(first_identity->queue_rank == 1);
        CHECK(second_identity->queue_rank == 2);

        REQUIRE(eventually([&] {
            client.pump_alerts();
            return persisted_queue_rank(client, *third_info) == 0
                && persisted_queue_rank(client, *first_info) == 1
                && persisted_queue_rank(client, *second_info) == 2;
        }));
    }

    TTorrentClient reloaded(state_directory.string());
    reloaded.set_session_shutdown_asynchronous(false);
    TorrentIdentity *reloaded_third =
        identity_from_handle(reloaded.handle_by_id.at(primary_hash_key(third_info->info_hashes())));
    TorrentIdentity *reloaded_first =
        identity_from_handle(reloaded.handle_by_id.at(primary_hash_key(first_info->info_hashes())));
    TorrentIdentity *reloaded_second =
        identity_from_handle(reloaded.handle_by_id.at(primary_hash_key(second_info->info_hashes())));
    REQUIRE(reloaded_third != nullptr);
    REQUIRE(reloaded_first != nullptr);
    REQUIRE(reloaded_second != nullptr);
    CHECK(reloaded_third->queue_rank == 0);
    CHECK(reloaded_first->queue_rank == 1);
    CHECK(reloaded_second->queue_rank == 2);
}

TEST_CASE("per-torrent source policy can override DHT PEX and LSD defaults")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    char error[512]{};

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(true);
    settings.enable_dht = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(false);
    settings.enable_lsd = bridge_bool(true);
    settings.use_lsd_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(false);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK(client.dht_disabled_by_app.contains(identity));
    CHECK(client.peer_exchange_disabled_by_app.contains(identity));
    CHECK(client.lsd_disabled_by_app.contains(identity));

    TTorrentSourcePolicy policy{};
    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_dht));
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK_FALSE(bridge_bool(policy.enable_lsd));
    CHECK_FALSE(bridge_bool(policy.dht_locked));
    CHECK_FALSE(bridge_bool(policy.peer_exchange_locked));
    CHECK_FALSE(bridge_bool(policy.lsd_locked));

    policy.enable_dht = bridge_bool(true);
    policy.enable_peer_exchange = bridge_bool(true);
    policy.enable_lsd = bridge_bool(true);
    REQUIRE(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK(identity->dht_enabled_by_user);
    CHECK(identity->peer_exchange_enabled_by_user);
    CHECK(identity->lsd_enabled_by_user);
    CHECK_FALSE(identity->dht_disabled_by_user);
    CHECK_FALSE(identity->peer_exchange_disabled_by_user);
    CHECK_FALSE(identity->lsd_disabled_by_user);
    CHECK_FALSE(client.dht_disabled_by_app.contains(identity));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(identity));
    CHECK_FALSE(client.lsd_disabled_by_app.contains(identity));

    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
}

TEST_CASE("per-torrent source policy fails closed when persistence is faulted")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    REQUIRE_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));

    BridgeResult const fault = client.fault_persistence(2, "Synthetic persistence fault.");
    REQUIRE_FALSE(fault);

    TTorrentSourcePolicy policy{};
    policy.enable_dht = bridge_bool(false);
    policy.enable_peer_exchange = bridge_bool(true);
    policy.enable_lsd = bridge_bool(true);
    char error[512]{};
    CHECK(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 2);

    CHECK(bridge_tests::string_from_c_buffer(error) == "Synthetic persistence fault.");
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(identity->dht_disabled_by_user);
}

TEST_CASE("blocked settings fail closed before persistent source policy changes")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(true);
    settings.enable_lsd = bridge_bool(true);
    settings.use_lsd_by_default = bridge_bool(true);
    settings.use_pex_by_default = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE_FALSE(client.requested_network_blocked);

    BridgeResult const fault = client.fault_persistence(2, "Synthetic persistence fault.");
    REQUIRE_FALSE(fault);

    settings.network_blocked = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(false);
    settings.use_lsd_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(false);
    CHECK(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 2);

    CHECK(bridge_tests::string_from_c_buffer(error) == "Synthetic persistence fault.");
    CHECK(client.requested_network_blocked);
    CHECK(client.dht_enabled_by_default);
    CHECK(client.lsd_enabled_by_default);
    CHECK(client.peer_exchange_enabled_by_default);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(client.dht_disabled_by_app.contains(identity));
    CHECK_FALSE(client.lsd_disabled_by_app.contains(identity));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(identity));
}

TEST_CASE("settings validation rejects invalid ports before source policy mutation")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.incoming_port = 1;
    settings.enable_dht = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(false);
    settings.enable_lsd = bridge_bool(true);
    settings.use_lsd_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    CHECK(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 2);

    CHECK(bridge_tests::string_from_c_buffer(error) == "Incoming port must be 0 or between 1024 and 65535.");
    CHECK(client.dht_enabled_by_default);
    CHECK(client.lsd_enabled_by_default);
    CHECK(client.peer_exchange_enabled_by_default);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(client.dht_disabled_by_app.contains(identity));
    CHECK_FALSE(client.lsd_disabled_by_app.contains(identity));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(identity));
}

TEST_CASE("global LSD and PEX default changes request resume persistence")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    std::uint64_t const generation_before_settings = identity->resume_save.next_generation;

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(true);
    settings.enable_lsd = bridge_bool(true);
    settings.use_lsd_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(client.lsd_disabled_by_app.contains(identity));
    CHECK(client.peer_exchange_disabled_by_app.contains(identity));
    CHECK(identity->resume_save.next_generation > generation_before_settings);
}

TEST_CASE("per-torrent DHT policy does not override disabled DHT node")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(false);
    settings.use_dht_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    handle.set_flags(
        lt::torrent_flags::paused | lt::torrent_flags::auto_managed,
        lt::torrent_flags::paused | lt::torrent_flags::auto_managed
    );
    REQUIRE(static_cast<bool>(handle.flags() & lt::torrent_flags::paused));
    REQUIRE(static_cast<bool>(handle.flags() & lt::torrent_flags::auto_managed));

    TTorrentSourcePolicy policy{};
    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    policy.enable_dht = bridge_bool(true);
    policy.enable_peer_exchange = bridge_bool(false);
    REQUIRE(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    lt::torrent_flags_t const flags = handle.flags();
    CHECK(static_cast<bool>(flags & lt::torrent_flags::paused));
    CHECK(static_cast<bool>(flags & lt::torrent_flags::auto_managed));
    CHECK_FALSE(static_cast<bool>(flags & lt::torrent_flags::disable_dht));
    CHECK_FALSE(client.session.is_dht_running());
}

TEST_CASE("per-torrent DHT enable does not resume paused torrents")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(eventually([&] {
        return client.session.is_dht_running();
    }));
    REQUIRE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));

    handle.set_flags(lt::torrent_flags::paused, lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
    REQUIRE(static_cast<bool>(handle.flags() & lt::torrent_flags::paused));
    REQUIRE_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::auto_managed));

    TTorrentSourcePolicy policy{};
    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    policy.enable_dht = bridge_bool(true);
    REQUIRE(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    lt::torrent_flags_t const flags = handle.flags();
    CHECK(static_cast<bool>(flags & lt::torrent_flags::paused));
    CHECK_FALSE(static_cast<bool>(flags & lt::torrent_flags::auto_managed));
    CHECK_FALSE(static_cast<bool>(flags & lt::torrent_flags::disable_dht));
}

TEST_CASE("enabling the DHT node preserves default DHT-off torrent policy")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(false);
    settings.use_dht_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    REQUIRE(client.dht_disabled_by_app.contains(identity));
    CHECK_FALSE(client.session.is_dht_running());

    settings.enable_dht = bridge_bool(true);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(eventually([&] {
        return client.session.is_dht_running();
    }));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(client.dht_disabled_by_app.contains(identity));
    CHECK(eventually([&] {
        return !handle.status().announcing_to_dht;
    }));
}

TEST_CASE("ordinary settings apply does not resume an already unblocked session")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(false);
    settings.use_dht_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};

    REQUIRE(client.session.is_paused());
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(client.session.is_paused());

    client.session.pause();
    REQUIRE(client.session.is_paused());
    settings.enable_dht = bridge_bool(true);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(client.session.is_paused());
}

TEST_CASE("privacy-sensitive tracker settings are explicit")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::settings_pack initial = client.session.get_settings();
    CHECK(initial.get_bool(lt::settings_pack::anonymous_mode));
    CHECK(initial.get_bool(lt::settings_pack::dht_privacy_lookups));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::announce_to_all_trackers));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::announce_to_all_tiers));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::prefer_udp_trackers));
    CHECK(initial.get_bool(lt::settings_pack::validate_https_trackers));
    CHECK(initial.get_bool(lt::settings_pack::ssrf_mitigation));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::always_send_user_agent));

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(true);
    settings.anonymous_mode = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};

    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(eventually([&] {
        lt::settings_pack const current = client.session.get_settings();
        return !current.get_bool(lt::settings_pack::anonymous_mode)
            && current.get_bool(lt::settings_pack::dht_privacy_lookups)
            && !current.get_bool(lt::settings_pack::announce_to_all_trackers)
            && !current.get_bool(lt::settings_pack::announce_to_all_tiers)
            && !current.get_bool(lt::settings_pack::prefer_udp_trackers)
            && current.get_bool(lt::settings_pack::validate_https_trackers)
            && current.get_bool(lt::settings_pack::ssrf_mitigation)
            && !current.get_bool(lt::settings_pack::always_send_user_agent);
    }));
}

TEST_CASE("DHT privacy lookups follow effective DHT availability")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(false);
    settings.use_pex_by_default = bridge_bool(true);
    settings.anonymous_mode = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};

    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(eventually([&] {
        return client.session.get_settings().get_bool(lt::settings_pack::dht_privacy_lookups);
    }));

    settings.enable_dht = bridge_bool(false);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(eventually([&] {
        return !client.session.get_settings().get_bool(lt::settings_pack::dht_privacy_lookups);
    }));

    settings.enable_dht = bridge_bool(true);
    settings.network_blocked = bridge_bool(true);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(eventually([&] {
        return !client.session.get_settings().get_bool(lt::settings_pack::dht_privacy_lookups);
    }));
}

TEST_CASE("settings apply enforces HTTPS-only source policy on loaded torrents")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_source_torrent_info();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    REQUIRE(handle.trackers().size() == 2U);
    REQUIRE(handle.url_seeds().size() == 2U);
    REQUIRE(handle.http_seeds().size() == 2U);

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(true);
    settings.use_pex_by_default = bridge_bool(true);
    settings.require_https_trackers = bridge_bool(true);
    settings.require_https_web_seeds = bridge_bool(false);
    char error[512]{};
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    std::vector<lt::announce_entry> const trackers = handle.trackers();
    REQUIRE(trackers.size() == 1U);
    CHECK(trackers.front().url == "https://secure-tracker.example/announce");
    CHECK(handle.url_seeds().size() == 2U);
    CHECK(handle.http_seeds().size() == 2U);

    settings.require_https_web_seeds = bridge_bool(true);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.url_seeds().contains("https://secure-seed.example/file"));
    CHECK(handle.http_seeds().size() == 1U);
    CHECK(handle.http_seeds().contains("https://secure-http-seed.example/file"));

    settings.require_https_trackers = bridge_bool(false);
    settings.require_https_web_seeds = bridge_bool(false);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(handle.trackers().size() == 2U);
    WebSeedCounts const restored_web_seeds = cached_web_seed_counts(client, identity->canonical_id);
    CHECK(restored_web_seeds.url == 2);
    CHECK(restored_web_seeds.http == 2);
}

TEST_CASE("per-torrent HTTPS source exception preserves loaded torrent sources")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_source_torrent_info();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    identity->allows_non_https_trackers = true;
    identity->allows_non_https_web_seeds = true;

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(true);
    settings.use_pex_by_default = bridge_bool(true);
    settings.require_https_trackers = bridge_bool(true);
    settings.require_https_web_seeds = bridge_bool(true);
    char error[512]{};
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(handle.trackers().size() == 2U);
    CHECK(handle.url_seeds().size() == 2U);
    CHECK(handle.http_seeds().size() == 2U);
}

TEST_CASE("source policy toggles DHT PEX LSD and HTTPS sources for a loaded torrent")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_source_torrent_info();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    char error[512]{};
    TTorrentSourcePolicy policy{};
    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(bridge_bool(policy.enable_dht));
    CHECK(bridge_bool(policy.enable_peer_exchange));
    CHECK(bridge_bool(policy.enable_lsd));
    CHECK_FALSE(bridge_bool(policy.require_https_trackers));
    CHECK_FALSE(bridge_bool(policy.require_https_web_seeds));
    CHECK_FALSE(bridge_bool(policy.dht_locked));
    CHECK_FALSE(bridge_bool(policy.peer_exchange_locked));
    CHECK_FALSE(bridge_bool(policy.lsd_locked));

    TTorrentSourcePolicy updated{};
    updated.enable_dht = bridge_bool(false);
    updated.enable_peer_exchange = bridge_bool(false);
    updated.enable_lsd = bridge_bool(false);
    updated.require_https_trackers = bridge_bool(true);
    updated.require_https_web_seeds = bridge_bool(true);
    REQUIRE(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &updated,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_dht));
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK_FALSE(bridge_bool(policy.enable_lsd));
    CHECK(bridge_bool(policy.require_https_trackers));
    CHECK(bridge_bool(policy.require_https_web_seeds));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.trackers().front().url == "https://secure-tracker.example/announce");
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.http_seeds().size() == 1U);
    CHECK(identity->dht_disabled_by_user);
    CHECK(identity->peer_exchange_disabled_by_user);
    CHECK(identity->lsd_disabled_by_user);
    CHECK(identity->requires_https_trackers);
    CHECK(identity->requires_https_web_seeds);
    CHECK_FALSE(identity->allows_non_https_trackers);
    CHECK_FALSE(identity->allows_non_https_web_seeds);

    updated.require_https_trackers = bridge_bool(false);
    updated.require_https_web_seeds = bridge_bool(false);
    REQUIRE(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &updated,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(handle.trackers().size() == 2U);
    WebSeedCounts const restored_web_seeds = cached_web_seed_counts(client, identity->canonical_id);
    CHECK(restored_web_seeds.url == 2);
    CHECK(restored_web_seeds.http == 2);
    CHECK_FALSE(identity->requires_https_trackers);
    CHECK_FALSE(identity->requires_https_web_seeds);
}

TEST_CASE("source policy reports explicit user policy over transient libtorrent flags")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_source_torrent_info();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    identity->dht_enabled_by_user = true;
    identity->peer_exchange_enabled_by_user = true;
    identity->lsd_enabled_by_user = true;
    handle.set_flags(lt::torrent_flags::disable_dht);
    handle.set_flags(lt::torrent_flags::disable_pex);
    handle.set_flags(lt::torrent_flags::disable_lsd);

    char error[512]{};
    TTorrentSourcePolicy policy{};
    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(bridge_bool(policy.enable_dht));
    CHECK(bridge_bool(policy.enable_peer_exchange));
    CHECK(bridge_bool(policy.enable_lsd));

    identity->dht_enabled_by_user = false;
    identity->peer_exchange_enabled_by_user = false;
    identity->lsd_enabled_by_user = false;
    identity->dht_disabled_by_user = true;
    identity->peer_exchange_disabled_by_user = true;
    identity->lsd_disabled_by_user = true;
    handle.unset_flags(lt::torrent_flags::disable_dht);
    handle.unset_flags(lt::torrent_flags::disable_pex);
    handle.unset_flags(lt::torrent_flags::disable_lsd);

    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_dht));
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK_FALSE(bridge_bool(policy.enable_lsd));
}

TEST_CASE("piece map reports metadata piece count before any piece is downloaded")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_piece_map_torrent_info();
    REQUIRE(info->num_pieces() == 5);

    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    REQUIRE(handle.is_valid());

    DirtyMask changes = 0;
    {
        std::scoped_lock guard(client.lock);
        REQUIRE(client.request_piece_map(identity->canonical_id, changes).has_value());
    }

    TTorrentPieceMapSnapshot snapshot{};
    std::uint64_t revision = 0;
    int32_t required_count = 0;
    REQUIRE(client.copy_piece_map(identity->canonical_id, &snapshot, {}, &revision, &required_count) == 0);

    CHECK(snapshot.total_pieces == info->num_pieces());
    CHECK(snapshot.completed_pieces == 0);
    CHECK(snapshot.available_pieces == info->num_pieces());
    CHECK(required_count == info->num_pieces());

    std::vector<std::uint8_t> pieces(static_cast<std::size_t>(required_count));
    REQUIRE(client.copy_piece_map(identity->canonical_id, &snapshot, std::span{pieces}, &revision, &required_count)
            == info->num_pieces());
    for (std::uint8_t const piece : pieces) {
        CHECK_FALSE(bridge_bool(piece));
    }
}

TEST_CASE("source policy cannot override DHT PEX or LSD source locks")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_source_torrent_info();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    identity->dht_locked_by_source = true;
    identity->peer_exchange_locked_by_source = true;
    identity->lsd_locked_by_source = true;
    handle.set_flags(lt::torrent_flags::disable_dht);
    handle.set_flags(lt::torrent_flags::disable_pex);
    handle.set_flags(lt::torrent_flags::disable_lsd);

    char error[512]{};
    TTorrentSourcePolicy policy{};
    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_dht));
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK_FALSE(bridge_bool(policy.enable_lsd));
    CHECK(bridge_bool(policy.dht_locked));
    CHECK(bridge_bool(policy.peer_exchange_locked));
    CHECK(bridge_bool(policy.lsd_locked));

    TTorrentSourcePolicy requested{};
    requested.enable_dht = bridge_bool(true);
    requested.enable_peer_exchange = bridge_bool(true);
    requested.enable_lsd = bridge_bool(true);
    requested.require_https_trackers = bridge_bool(false);
    requested.require_https_web_seeds = bridge_bool(false);
    REQUIRE(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &requested,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    REQUIRE(TorrentClientCopySourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_dht));
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK_FALSE(bridge_bool(policy.enable_lsd));
    CHECK(bridge_bool(policy.dht_locked));
    CHECK(bridge_bool(policy.peer_exchange_locked));
    CHECK(bridge_bool(policy.lsd_locked));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(identity->dht_enabled_by_user);
    CHECK_FALSE(identity->dht_disabled_by_user);
    CHECK_FALSE(identity->peer_exchange_enabled_by_user);
    CHECK_FALSE(identity->peer_exchange_disabled_by_user);
    CHECK_FALSE(identity->lsd_enabled_by_user);
    CHECK_FALSE(identity->lsd_disabled_by_user);
}

TEST_CASE("source policy restores sources preserved before HTTPS-only filtering")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_source_torrent_info();
    lt::add_torrent_params params;
    params.ti = info;
    params.info_hashes = info->info_hashes();
    lt::add_torrent_params const source_params = params;
    REQUIRE(filter_non_https_sources(params));
    prepare_add_params(params, temporary_directory.path().string(), false, true);

    TorrentIdentity *identity = client.attach_identity(params);
    REQUIRE(identity != nullptr);
    remember_source_policy_sources(*identity, source_params);

    lt::error_code add_error;
    lt::torrent_handle handle = client.session.add_torrent(std::move(params), add_error);
    REQUIRE_FALSE(add_error);
    client.mark_active(handle, identity);

    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.http_seeds().size() == 1U);

    char error[512]{};
    TTorrentSourcePolicy requested{};
    requested.enable_dht = bridge_bool(true);
    requested.enable_peer_exchange = bridge_bool(true);
    requested.require_https_trackers = bridge_bool(false);
    requested.require_https_web_seeds = bridge_bool(false);
    REQUIRE(TorrentClientSetSourcePolicy(
        &client,
        identity->canonical_id.c_str(),
        &requested,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    REQUIRE(handle.trackers().size() == 2U);
    WebSeedCounts const restored_web_seeds = cached_web_seed_counts(client, identity->canonical_id);
    CHECK(restored_web_seeds.url == 2);
    CHECK(restored_web_seeds.http == 2);
}

TEST_CASE("source policy restore does not reinsert blocked HTTPS-only sources")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_source_torrent_info();
    lt::add_torrent_params params;
    params.ti = info;
    params.info_hashes = info->info_hashes();
    lt::add_torrent_params const source_params = params;
    REQUIRE(filter_non_https_sources(params, true, true));
    prepare_add_params(params, temporary_directory.path().string(), false, true);

    TorrentIdentity *identity = client.attach_identity(params);
    REQUIRE(identity != nullptr);
    remember_source_policy_sources(*identity, source_params);

    lt::error_code add_error;
    lt::torrent_handle handle = client.session.add_torrent(std::move(params), add_error);
    REQUIRE_FALSE(add_error);
    client.mark_active(handle, identity);

    client.require_https_trackers = true;
    client.require_https_web_seeds = true;

    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.http_seeds().size() == 1U);

    static_cast<void>(client.restore_metadata_source_policy(handle, identity));

    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.trackers().front().url == "https://secure-tracker.example/announce");
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.url_seeds().contains("https://secure-seed.example/file"));
    CHECK(handle.http_seeds().size() == 1U);
    CHECK(handle.http_seeds().contains("https://secure-http-seed.example/file"));
    CHECK(identity->source_trackers.size() == 2U);
    CHECK(identity->source_web_seeds.size() == 4U);
}

TEST_CASE("magnet torrents disable peer exchange until metadata arrives")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::string const hash(40U, '2');
    std::string const magnet = "magnet:?xt=urn:btih:" + hash;
    std::string const save_path = temporary_directory.path().string();
    TTorrentAddOptions add_options = default_add_options();
    char added_id[TTORRENT_ID_CAPACITY]{};
    char error[512]{};

    REQUIRE(TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        save_path.c_str(),
        &add_options,
        added_id,
        static_cast<int32_t>(sizeof(added_id)),
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(is_canonical_torrent_id(added_id));

    lt::torrent_handle handle = client.handle_by_id.at(bridge_tests::v1_id('2'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(client.peer_exchange_disabled_until_metadata.contains(identity));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(identity));
}

TEST_CASE("metadata-less magnet removal treats zero-error delete alert as success")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::string const hash(40U, '9');
    std::string const id = bridge_tests::v1_id('9');
    std::string const magnet = "magnet:?xt=urn:btih:" + hash;
    std::string const save_path = temporary_directory.path().string();
    TTorrentAddOptions add_options = default_add_options();
    char added_id[TTORRENT_ID_CAPACITY]{};
    char error[512]{};

    REQUIRE(TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        save_path.c_str(),
        &add_options,
        added_id,
        static_cast<int32_t>(sizeof(added_id)),
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    REQUIRE(TorrentClientRemove(
        &client,
        id.c_str(),
        bridge_bool(true),
        bridge_bool(true),
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(eventually([&] {
        client.pump_alerts();
        std::scoped_lock guard(client.lock);
        return client.awaiting_delete_resume_ids_by_id.empty();
    }));

    CHECK_FALSE(client.take_alert_error(std::span{error}));
}

TEST_CASE("metadata-pending peer exchange policy survives resume reload")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::string const hash(40U, '3');
    std::string const magnet = "magnet:?xt=urn:btih:" + hash;
    std::string const save_path = temporary_directory.path().string();
    TTorrentAddOptions add_options = default_add_options();
    char added_id[TTORRENT_ID_CAPACITY]{};
    char error[512]{};

    {
        TTorrentClient client(state_directory.string());
        client.set_session_shutdown_asynchronous(false);
        REQUIRE(TorrentClientAddMagnet(
            &client,
            magnet.c_str(),
            save_path.c_str(),
            &add_options,
            added_id,
            static_cast<int32_t>(sizeof(added_id)),
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);
    }

    TTorrentClient reloaded(state_directory.string());
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = reloaded.handle_by_id.at(bridge_tests::v1_id('3'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(reloaded.peer_exchange_disabled_until_metadata.contains(identity));
    CHECK_FALSE(reloaded.peer_exchange_disabled_by_app.contains(identity));
}

TEST_CASE("app-default DHT disabled policy survives resume reload")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::string const hash(40U, '4');
    std::string const magnet = "magnet:?xt=urn:btih:" + hash;
    std::string const save_path = temporary_directory.path().string();
    TTorrentAddOptions add_options = default_add_options();
    char added_id[TTORRENT_ID_CAPACITY]{};
    char error[512]{};

    {
        TTorrentClient client(state_directory.string());
        client.set_session_shutdown_asynchronous(false);

        TTorrentSessionSettings settings{};
        settings.required_network_interface = "";
        settings.network_blocked = bridge_bool(false);
        settings.enable_dht = bridge_bool(false);
        settings.use_dht_by_default = bridge_bool(false);
        settings.use_pex_by_default = bridge_bool(true);
        settings.active_downloads = 3;
        settings.active_seeds = 5;
        settings.active_limit = 500;
        REQUIRE(TorrentClientApplySettings(
            &client,
            &settings,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);

        REQUIRE(TorrentClientAddMagnet(
            &client,
            magnet.c_str(),
            save_path.c_str(),
            &add_options,
            added_id,
            static_cast<int32_t>(sizeof(added_id)),
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);

        lt::torrent_handle handle = client.handle_by_id.at(bridge_tests::v1_id('4'));
        TorrentIdentity *identity = identity_from_handle(handle);
        REQUIRE(identity != nullptr);
        CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
        CHECK(client.dht_disabled_by_app.contains(identity));
    }

    TTorrentClient reloaded(state_directory.string());
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = reloaded.handle_by_id.at(bridge_tests::v1_id('4'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(reloaded.dht_disabled_by_app.contains(identity));

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.use_dht_by_default = bridge_bool(true);
    settings.use_pex_by_default = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    REQUIRE(TorrentClientApplySettings(
        &reloaded,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(reloaded.dht_disabled_by_app.contains(identity));
}

TEST_CASE("metadata resolution owns peer exchange pending policy")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto public_info = make_torrent_info(false);
    TorrentIdentity *public_identity = nullptr;
    lt::torrent_handle public_handle = add_metadata_torrent(client, *public_info, temporary_directory.path(), public_identity);
    REQUIRE(public_identity != nullptr);

    DirtyMask changes = 0;
    public_handle.set_flags(lt::torrent_flags::disable_pex);
    client.peer_exchange_disabled_until_metadata.insert(public_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(public_handle, changes));
    CHECK_FALSE(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(client.peer_exchange_disabled_until_metadata.contains(public_identity));

    public_handle.set_flags(lt::torrent_flags::disable_pex);
    client.peer_exchange_disabled_until_metadata.insert(public_identity);
    client.peer_exchange_disabled_by_app.insert(public_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(public_handle, changes));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(client.peer_exchange_disabled_until_metadata.contains(public_identity));
    CHECK(client.peer_exchange_disabled_by_app.contains(public_identity));

    auto private_info = make_torrent_info(true);
    TorrentIdentity *private_identity = nullptr;
    lt::torrent_handle private_handle = add_metadata_torrent(client, *private_info, temporary_directory.path(), private_identity);
    REQUIRE(private_identity != nullptr);

    client.peer_exchange_disabled_until_metadata.insert(private_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(private_handle, changes));
    CHECK(static_cast<bool>(private_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(client.peer_exchange_disabled_until_metadata.contains(private_identity));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(private_identity));

    TTorrentSessionSettings settings{};
    settings.required_network_interface = "";
    settings.network_blocked = bridge_bool(true);
    settings.use_pex_by_default = bridge_bool(true);
    char error[512]{};
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(static_cast<bool>(private_handle.flags() & lt::torrent_flags::disable_pex));

    client.peer_exchange_disabled_by_app.insert(private_identity);
    client.peer_exchange_disabled_until_metadata.insert(private_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(private_handle, changes));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(private_identity));
    CHECK_FALSE(client.peer_exchange_disabled_until_metadata.contains(private_identity));
}

TEST_CASE("resume cleanups for a write merge pending and explicit IDs by generation")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::string const first = bridge_tests::v1_id('1');
    std::string const second = bridge_tests::v1_id('2');
    std::string const third = bridge_tests::v1_id('3');
    TorrentIdentity *identity = client.make_identity(bridge_tests::canonical_id('f'));

    client.remember_pending_cleanups(identity, {
        PendingResumeCleanup{.after_generation = 99U, .resume_ids = {first, second}}
    });
    std::vector<PendingResumeCleanup> const cleanups = client.cleanups_for_write(
        identity,
        42U,
        {PendingResumeCleanup{.after_generation = 100U, .resume_ids = {second, third}}}
    );

    REQUIRE(cleanups.size() == 1U);
    CHECK(cleanups.front().after_generation == 42U);
    CHECK(cleanups.front().resume_ids == std::vector<std::string>{first, second, third});
}
