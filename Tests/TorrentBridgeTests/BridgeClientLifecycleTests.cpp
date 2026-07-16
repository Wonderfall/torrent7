#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <libtorrent/aux_/stack_allocator.hpp>
#include <libtorrent/create_torrent.hpp>

#include <atomic>
#include <bitset>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

namespace {

struct BlockingWakeContext {
    std::mutex lock;
    std::condition_variable changed;
    bool entered = false;
    bool released = false;
};

void blocking_wake_callback(void *context)
{
    auto *wake_context = static_cast<BlockingWakeContext *>(context);
    std::unique_lock guard(wake_context->lock);
    wake_context->entered = true;
    wake_context->changed.notify_all();
    wake_context->changed.wait(guard, [wake_context] {
        return wake_context->released;
    });
}

void counting_wake_callback(void *context)
{
    auto *count = static_cast<std::atomic_uint64_t *>(context);
    count->fetch_add(1U, std::memory_order_relaxed);
}

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
        .allow_pre_metadata_dht = bridge_bool(false),
    };
}

[[nodiscard]] std::shared_ptr<lt::torrent_info const> make_torrent_info(bool is_private)
{
    std::vector<lt::create_file_entry> files;
    files.emplace_back(is_private ? "private.bin" : "public.bin", 4);

    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_priv(is_private);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(9U));

    std::vector<char> const buffer = creator.generate_buf();
    return bridge_tests::load_torrent_params(buffer, "torrent info").ti;
}

[[nodiscard]] std::shared_ptr<lt::torrent_info const> make_piece_map_torrent_info()
{
    constexpr int piece_size = 16 * 1024;
    constexpr int piece_count = 5;

    std::vector<lt::create_file_entry> files;
    files.emplace_back("piece-map.bin", static_cast<std::int64_t>(piece_size * piece_count));

    lt::create_torrent creator(std::move(files), piece_size, lt::create_torrent::v1_only);
    for (int piece = 0; piece < piece_count; ++piece) {
        creator.set_hash(lt::piece_index_t(piece), bridge_tests::sha1_hash_from_seed(static_cast<unsigned char>(20 + piece)));
    }

    std::vector<char> const buffer = creator.generate_buf();
    return bridge_tests::load_torrent_params(buffer, "piece map torrent info").ti;
}

[[nodiscard]] lt::add_torrent_params make_source_torrent_params()
{
    std::vector<lt::create_file_entry> files;
    files.emplace_back("source-policy.bin", 4);

    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(10U));
    creator.add_tracker("http://tracker.example/announce", 0);
    creator.add_tracker("https://secure-tracker.example/announce", 1);
    creator.add_url_seed("http://seed.example/file");
    creator.add_url_seed("https://secure-seed.example/file");

    std::vector<char> const buffer = creator.generate_buf();
    return bridge_tests::load_torrent_params(buffer, "source policy torrent info");
}

[[nodiscard]] std::shared_ptr<lt::torrent_info const> make_queue_torrent_info(unsigned char seed)
{
    std::vector<lt::create_file_entry> files;
    files.emplace_back("queue-" + std::to_string(seed) + ".bin", 4);

    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(seed));

    std::vector<char> const buffer = creator.generate_buf();
    return bridge_tests::load_torrent_params(buffer, "queue torrent info").ti;
}

[[nodiscard]] fs::path write_valid_resume_entry(
    fs::path const &state_directory,
    std::string const &save_path,
    unsigned char const seed,
    char const canonical_id_seed
)
{
    fs::path const resume_directory = state_directory / "ResumeData";
    static_cast<void>(fs::create_directories(resume_directory));
    REQUIRE(fs::exists(resume_directory));
    std::shared_ptr<lt::torrent_info const> const info = make_queue_torrent_info(seed);
    REQUIRE(info != nullptr);

    lt::add_torrent_params params;
    params.ti = info;
    params.info_hashes = info->info_hashes();
    params.save_path = save_path;
    TorrentIdentity identity;
    identity.canonical_id = bridge_tests::canonical_id(canonical_id_seed);
    std::vector<char> const encoded = encoded_resume_data(params, &identity);

    fs::path const resume_path = resume_directory
        / (primary_hash_key(info->info_hashes()) + std::string(kResumeExtension));
    ResumeSaveResult const written = write_owner_only_file_checked(
        resume_path,
        std::string_view(encoded.data(), encoded.size())
    );
    REQUIRE(written.has_value());
    return resume_path;
}

[[nodiscard]] int32_t cached_url_seed_count(TTorrentClient &client, std::string const &id)
{
    std::uint64_t revision = 0;
    int32_t required_count = 0;
    std::uint8_t resident = bridge_bool(false);
    REQUIRE(client.copy_web_seeds(id, {}, &revision, &required_count, &resident) == 0);
    REQUIRE(bridge_bool(resident));

    std::vector<TTorrentWebSeedSnapshot> web_seeds(static_cast<std::size_t>(required_count));
    REQUIRE(client.copy_web_seeds(id, web_seeds, &revision, &required_count, &resident) == required_count);

    return required_count;
}

[[nodiscard]] int32_t set_source_policy_field(
    TTorrentClient &client,
    TorrentIdentity const &identity,
    int32_t field,
    bool enabled,
    std::span<char> error
)
{
    return TorrentClientSetSourcePolicyField(
        &client,
        identity.canonical_id.c_str(),
        field,
        bridge_bool(enabled),
        error.data(),
        static_cast<int32_t>(error.size())
    );
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
    lt::add_torrent_params params,
    fs::path const &save_path,
    TorrentIdentity *&identity
)
{
    if (!params.ti) {
        throw std::runtime_error("Could not add metadata torrent without torrent info.");
    }
    params.info_hashes = params.ti->info_hashes();
    prepare_add_params(params, save_path.string(), false, true);

    identity = client.attach_identity(params);
    remember_source_policy_sources(*identity, params);
    lt::error_code add_error;
    lt::torrent_handle handle = client.session.add_torrent(std::move(params), add_error);
    if (add_error) {
        throw std::runtime_error("Could not add metadata torrent: " + add_error.message());
    }
    client.mark_active(handle, identity);
    return handle;
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
    return add_metadata_torrent(client, std::move(params), save_path, identity);
}

[[nodiscard]] bool eventually_take_removal_result(
    TTorrentClient &client,
    std::uint64_t request_token,
    TTorrentRemovalResult &result,
    std::span<char> error
)
{
    return eventually([&] {
        client.pump_alerts();
        return TorrentClientTakeRemovalResult(
            &client,
            request_token,
            &result,
            error.data(),
            static_cast<int32_t>(error.size())
        ) == 0 && result.state != TTORRENT_REMOVAL_PENDING;
    });
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

TEST_CASE("resume restoration is fail-closed and preserves unauthorized entries with one aggregate error")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const unauthorized_directory = temporary_directory.path() / "Unauthorized";
    REQUIRE(fs::create_directories(unauthorized_directory));
    fs::path const first_resume = write_valid_resume_entry(
        state_directory,
        unauthorized_directory.string(),
        41U,
        '1'
    );
    fs::path const second_resume = write_valid_resume_entry(
        state_directory,
        unauthorized_directory.string(),
        42U,
        '2'
    );

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    CHECK(client.session.get_torrents().empty());
    CHECK(file_exists(first_resume));
    CHECK(file_exists(second_resume));
    std::array<char, 512> error{};
    REQUIRE(client.take_alert_error(std::span{error}));
    CHECK(std::string(error.data())
          == "Skipped restoring 2 saved torrents because download folder access is not authorized. Resume data was preserved.");
    CHECK_FALSE(client.take_alert_error(std::span{error}));
    DirtyMask changes = 0U;
    static_cast<void>(client.take_changes(&changes));
    CHECK((changes & TTORRENT_DIRTY_ERRORS) != 0U);
}

TEST_CASE("authorized resume restoration uses the exact lexically normalized capability path")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const authorized_directory = temporary_directory.path() / "Authorized";
    fs::path const outside_directory = temporary_directory.path() / "Outside";
    REQUIRE(fs::create_directories(authorized_directory));
    REQUIRE(fs::create_directories(outside_directory));
    fs::path const resume_path = write_valid_resume_entry(
        state_directory,
        (authorized_directory / ".").string(),
        43U,
        '3'
    );
    fs::path const denied_resume_path = write_valid_resume_entry(
        state_directory,
        (authorized_directory / ".." / "Outside").string(),
        44U,
        '4'
    );

    std::string const blob_path = (authorized_directory / "child" / "..").string();
    std::vector<std::uint8_t> blob(blob_path.begin(), blob_path.end());
    blob.push_back(0U);
    std::array<char, 512> error{};
    TTorrentClient *client = TorrentClientCreateWithError(
        state_directory.c_str(),
        1,
        blob.data(),
        static_cast<int32_t>(blob.size()),
        error.data(),
        static_cast<int32_t>(error.size())
    );
    REQUIRE(client != nullptr);
    client->set_session_shutdown_asynchronous(false);
    client->stop_alert_worker();

    CHECK(error.front() == '\0');
    CHECK(client->session.get_torrents().size() == 1U);
    CHECK(file_exists(resume_path));
    CHECK(file_exists(denied_resume_path));
    std::array<char, 512> alert_error{};
    REQUIRE(client->take_alert_error(std::span{alert_error}));
    CHECK(std::string(alert_error.data())
          == "Skipped restoring 1 saved torrent because download folder access is not authorized. Resume data was preserved.");
    CHECK_FALSE(client->take_alert_error(std::span{alert_error}));

    TorrentClientDestroyBlocking(client);
}

TEST_CASE("clearing a wake callback waits for every in-flight invocation")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    BlockingWakeContext context;
    client.set_wake_callback(blocking_wake_callback, &context);
    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(client.lock);
        wake = client.publish_changes_locked(TTORRENT_DIRTY_ERRORS);
    }

    std::jthread invocation([&client, wake] {
        client.invoke_wake_callback(wake);
    });
    {
        std::unique_lock guard(context.lock);
        context.changed.wait(guard, [&context] {
            return context.entered;
        });
    }

    std::atomic_bool cleared = false;
    std::jthread clearing([&client, &cleared] {
        client.clear_wake_callback();
        cleared.store(true);
    });
    REQUIRE(eventually([&client] {
        std::scoped_lock guard(client.lock);
        return client.wake_callback == nullptr;
    }));
    CHECK_FALSE(cleared.load());

    {
        std::scoped_lock guard(context.lock);
        context.released = true;
    }
    context.changed.notify_all();
    invocation.join();
    clearing.join();
    CHECK(cleared.load());
}

TEST_CASE("alert worker failure backoff grows exponentially and stays bounded")
{
    CHECK(alert_worker_failure_backoff(0) == kAlertWorkerInitialFailureBackoff);
    CHECK(alert_worker_failure_backoff(1) == kAlertWorkerInitialFailureBackoff);
    CHECK(alert_worker_failure_backoff(2) == std::chrono::milliseconds(200));
    CHECK(alert_worker_failure_backoff(3) == std::chrono::milliseconds(400));
    CHECK(alert_worker_failure_backoff(6) == std::chrono::milliseconds(3200));
    CHECK(alert_worker_failure_backoff(7) == kAlertWorkerMaximumFailureBackoff);
    CHECK(alert_worker_failure_backoff(std::numeric_limits<std::uint64_t>::max())
          == kAlertWorkerMaximumFailureBackoff);
}

TEST_CASE("alert worker failure backoff stops promptly")
{
    std::atomic_bool entered = false;
    std::atomic_bool completed_delay = true;
    std::jthread waiter([&](std::stop_token const &stop_token) {
        entered.store(true, std::memory_order_release);
        completed_delay.store(
            wait_for_alert_worker_backoff(stop_token, kAlertWorkerMaximumFailureBackoff),
            std::memory_order_release
        );
    });
    REQUIRE(eventually([&entered] {
        return entered.load(std::memory_order_acquire);
    }));

    auto const started = std::chrono::steady_clock::now();
    waiter.request_stop();
    waiter.join();
    auto const elapsed = std::chrono::steady_clock::now() - started;

    CHECK_FALSE(completed_delay.load(std::memory_order_acquire));
    CHECK(elapsed < std::chrono::milliseconds(500));
}

TEST_CASE("alert worker health publishes bounded failures and recovery")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    DirtyMask discarded = 0;
    static_cast<void>(client.take_changes(&discarded));
    std::atomic_uint64_t wake_count = 0;
    client.set_wake_callback(counting_wake_callback, &wake_count);

    std::string const long_error(1024U, 'x');
    CHECK(client.record_alert_worker_failure(long_error) == 1U);

    TTorrentBridgeHealth health{};
    REQUIRE(TorrentClientCopyHealth(&client, &health) == 1);
    CHECK(health.total_alert_worker_failures == 1U);
    CHECK(health.consecutive_alert_worker_failures == 1U);
    CHECK(bridge_bool(health.alert_worker_degraded));
    CHECK(std::string(health.last_alert_worker_error).size()
          == sizeof(health.last_alert_worker_error) - 1U);

    DirtyMask changes = 0;
    static_cast<void>(client.take_changes(&changes));
    CHECK((changes & TTORRENT_DIRTY_HEALTH) != 0U);
    CHECK((changes & TTORRENT_DIRTY_ERRORS) != 0U);

    std::array<char, 1024> alert_error{};
    REQUIRE(client.take_alert_error(std::span{alert_error}));
    std::string const queued_error(alert_error.data());
    CHECK(queued_error.starts_with("Libtorrent alert worker failed and will retry: "));
    CHECK(queued_error.size() <= sizeof(health.last_alert_worker_error) - 1U);

    CHECK(client.record_alert_worker_failure("second failure") == 2U);
    static_cast<void>(client.take_changes(&changes));
    client.record_alert_worker_recovery();
    static_cast<void>(client.take_changes(&changes));
    CHECK(changes == TTORRENT_DIRTY_HEALTH);
    REQUIRE(TorrentClientCopyHealth(&client, &health) == 1);
    CHECK(health.total_alert_worker_failures == 2U);
    CHECK(health.consecutive_alert_worker_failures == 0U);
    CHECK_FALSE(bridge_bool(health.alert_worker_degraded));
    CHECK(std::string(health.last_alert_worker_error) == "second failure");
    CHECK(wake_count.load(std::memory_order_relaxed) == 3U);

    client.clear_wake_callback();
}

TEST_CASE("alert worker failure accounting and error queue saturate")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    {
        std::scoped_lock guard(client.lock);
        client.bridge_health.total_alert_worker_failures = std::numeric_limits<std::uint64_t>::max();
        client.bridge_health.consecutive_alert_worker_failures = std::numeric_limits<std::uint64_t>::max();
    }
    CHECK(client.record_alert_worker_failure("saturated") == std::numeric_limits<std::uint64_t>::max());

    for (std::size_t index = 0; index < kMaxPendingAlertErrors * 2U; ++index) {
        static_cast<void>(client.record_alert_worker_failure("bounded queue"));
    }

    std::scoped_lock guard(client.lock);
    CHECK(client.bridge_health.total_alert_worker_failures == std::numeric_limits<std::uint64_t>::max());
    CHECK(client.bridge_health.consecutive_alert_worker_failures == std::numeric_limits<std::uint64_t>::max());
    CHECK(client.pending_alert_errors.size() == kMaxPendingAlertErrors);
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

TEST_CASE("TTorrentClient startup preserves unreadable resume entries but removes definitively invalid ones")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const resume_directory = state_directory / "ResumeData";
    REQUIRE(fs::create_directories(resume_directory));

    fs::path const target = temporary_directory.path() / "resume-target";
    bridge_tests::write_text_file(target, "not resume data");
    fs::path const unreadable_resume =
        resume_directory / (bridge_tests::v1_id('7') + std::string(kResumeExtension));
    fs::path const empty_resume =
        resume_directory / (bridge_tests::v1_id('8') + std::string(kResumeExtension));
    std::error_code symlink_error;
    fs::create_symlink(target, unreadable_resume, symlink_error);
    REQUIRE_FALSE(symlink_error);
    bridge_tests::write_text_file(empty_resume, "");

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);

    CHECK(fs::is_symlink(fs::symlink_status(unreadable_resume)));
    CHECK_FALSE(file_exists(empty_resume));
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

TEST_CASE("retired torrent identities release active state behind stable userdata tokens")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    TorrentIdentity *identity = client.make_identity(bridge_tests::canonical_id('9'));
    REQUIRE(identity != nullptr);
    REQUIRE(identity->token != nullptr);
    TorrentIdentityToken *const token = identity->token;
    lt::client_data_t const userdata(token);
    identity->source_trackers.emplace_back("https://tracker.example/announce");
    identity->source_web_seeds.emplace_back("https://seed.example/file");
    identity->intended_file_priorities.resize(1'000U, lt::default_priority);
    CHECK(identity_from_client_data(userdata) == identity);

    {
        std::scoped_lock io_guard(client.resume_io_lock);
        client.retire_identity_if_unreferenced_locked(identity);
    }

    CHECK(client.torrent_identities.empty());
    CHECK(client.retiring_torrent_identities.size() == 1U);
    CHECK(identity_from_client_data(userdata) == nullptr);
    {
        [[maybe_unused]] IdentityReclamationBlock reclamation_block(client);
        client.reclaim_retired_identities();
        CHECK(client.retiring_torrent_identities.size() == 1U);
    }
    CHECK(client.retiring_torrent_identities.empty());
    CHECK(client.identity_tokens.size() == 1U);
    CHECK(token->active_identity.load(std::memory_order_acquire) == nullptr);
}

TEST_CASE("torrent identity creation enforces the snapshot admission limit")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    client.torrent_identities.reserve(static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT));
    for (int32_t index = 0; index < TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT; ++index) {
        client.torrent_identities.push_back(std::make_unique<TorrentIdentity>());
    }

    BridgeResult const admission = client.ensure_torrent_admission_available(7);
    REQUIRE_FALSE(admission);
    CHECK(admission.error().code == 7);
    CHECK(admission.error().message == "The torrent limit has been reached.");
    CHECK_THROWS_AS(static_cast<void>(client.make_identity()), std::length_error);

    fs::path const preserved_resume =
        client.resume_directory / (bridge_tests::v1_id('a') + std::string(kResumeExtension));
    bridge_tests::write_text_file(preserved_resume, "preserve at capacity");
    client.load_resume_data();
    CHECK(file_exists(preserved_resume));
    std::array<char, 512> error{};
    REQUIRE(client.take_alert_error(std::span{error}));
    CHECK(bridge_tests::string_from_c_buffer(std::span{error})
          == "Resume restore stopped: The torrent limit has been reached. Remaining resume data was preserved.");
    DirtyMask changes = 0;
    static_cast<void>(client.take_changes(&changes));
    CHECK((changes & TTORRENT_DIRTY_ERRORS) != 0U);
    client.torrent_identities.clear();
}

TEST_CASE("session lifetime identity token budget bounds add and remove churn")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::string const reusable_id = bridge_tests::canonical_id('b');
    for (std::size_t index = 0; index < kMaxTorrentIdentityTokenCount; ++index) {
        TorrentIdentity *identity = client.make_identity(reusable_id);
        {
            std::scoped_lock io_guard(client.resume_io_lock);
            client.retire_identity_if_unreferenced_locked(identity);
        }
        client.reclaim_retired_identities();
    }

    CHECK(client.torrent_identities.empty());
    CHECK(client.retiring_torrent_identities.empty());
    CHECK(client.identity_tokens.size() == kMaxTorrentIdentityTokenCount);
    BridgeResult const admission = client.ensure_torrent_admission_available(8);
    REQUIRE_FALSE(admission);
    CHECK(admission.error().code == 8);
    CHECK(admission.error().message
          == "The torrent identity safety limit for this app session has been reached. Restart the app before adding more torrents.");
    CHECK_THROWS_AS(static_cast<void>(client.make_identity(reusable_id)), std::length_error);

    fs::path const preserved_resume =
        client.resume_directory / (bridge_tests::v1_id('b') + std::string(kResumeExtension));
    bridge_tests::write_text_file(preserved_resume, "preserve after churn");
    client.load_resume_data();
    CHECK(file_exists(preserved_resume));
    std::array<char, 512> error{};
    REQUIRE(client.take_alert_error(std::span{error}));
    CHECK(bridge_tests::string_from_c_buffer(std::span{error})
          == "Resume restore stopped: The torrent identity safety limit for this app session has been reached. Restart the app before adding more torrents. Remaining resume data was preserved.");
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

TEST_CASE("resume metadata refreshes identity and cached snapshot")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::string const id = bridge_tests::v1_id('4');
    TorrentIdentity *identity = client.make_identity(id);
    REQUIRE(identity != nullptr);
    std::string const cache_id = identity->canonical_id;

    TTorrentSnapshot snapshot{};
    copy_string(std::span{snapshot.id}, cache_id);
    client.snapshot_indices.emplace(cache_id, 0U);
    client.snapshot_cache.push_back(snapshot);

    lt::add_torrent_params params;
    params.comment = "Metadata from resume data";
    params.creation_date = 12'345;

    CHECK(client.cache_resume_metadata(identity, params) == TTORRENT_DIRTY_TORRENTS);
    CHECK(identity->comment == "Metadata from resume data");
    CHECK(identity->creation_date == 12'345);
    REQUIRE(client.snapshot_cache.size() == 1U);
    CHECK(std::string(client.snapshot_cache.front().comment) == "Metadata from resume data");
    CHECK(client.snapshot_cache.front().created_time == 12'345);
    CHECK(client.cache_resume_metadata(identity, params) == 0U);
}

TEST_CASE("resume persistence rejects unsafe serialized file renames")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    std::shared_ptr<lt::torrent_info const> const info = make_torrent_info(false);
    REQUIRE(info != nullptr);

    std::array<std::string, 2> const unsafe_paths{
        "/tmp/outside-download.bin",
        "../outside-download.bin",
    };
    for (std::size_t index = 0; index < unsafe_paths.size(); ++index) {
        fs::path const state_directory = temporary_directory.path() / ("UnsafeResume-" + std::to_string(index));
        fs::path const resume_directory = state_directory / "ResumeData";
        REQUIRE(fs::create_directories(resume_directory));

        lt::add_torrent_params params;
        params.ti = info;
        params.info_hashes = info->info_hashes();
        params.save_path = temporary_directory.path().string();
        params.renamed_files.emplace(lt::file_index_t(0), unsafe_paths.at(index));

        TorrentIdentity identity;
        identity.canonical_id = bridge_tests::canonical_id(static_cast<char>('a' + index));
        std::vector<char> const encoded = encoded_resume_data(params, &identity);

        lt::error_code read_error;
        lt::add_torrent_params const decoded = lt::read_resume_data(
            lt::span<char const>(encoded),
            read_error
        );
        REQUIRE_FALSE(read_error);
        REQUIRE(decoded.renamed_files.contains(lt::file_index_t(0)));
        CHECK(decoded.renamed_files.at(lt::file_index_t(0)) == unsafe_paths.at(index));

        std::string const resume_id = primary_hash_key(info->info_hashes());
        fs::path const resume_path = resume_directory / (resume_id + std::string(kResumeExtension));
        ResumeSaveResult const written = write_owner_only_file_checked(
            resume_path,
            std::string_view(encoded.data(), encoded.size())
        );
        REQUIRE(written.has_value());

        TTorrentClient client(
            state_directory.string(),
            true,
            AuthorizedSavePathSet{temporary_directory.path().lexically_normal().string()}
        );
        client.set_session_shutdown_asynchronous(false);

        CHECK(client.session.get_torrents().empty());
        CHECK_FALSE(file_exists(resume_path));

        ResumeSaveResult const rejected = client.write_resume_data_checked(
            params,
            nullptr,
            ResumePolicySnapshot{},
            0,
            {}
        );
        REQUIRE_FALSE(rejected);
        CHECK(rejected.error() == "The torrent contains a file path outside its download folder.");
    }
}

TEST_CASE("resume metadata flows through add, async save alerts, and reload")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::string const expected_comment = "Metadata lifecycle comment";
    constexpr std::time_t expected_creation_date = 23'456;

    std::vector<lt::create_file_entry> files;
    files.emplace_back("metadata-lifecycle.bin", 4);
    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_comment(expected_comment.c_str());
    creator.set_creation_date(expected_creation_date);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(31U));
    std::vector<char> const torrent_data = creator.generate_buf();

    std::string canonical_id;
    {
        TTorrentClient client(state_directory.string());
        client.set_session_shutdown_asynchronous(false);

        TTorrentAddOptions add_options = default_add_options();
        char added_id[TTORRENT_ID_CAPACITY]{};
        char error[512]{};
        REQUIRE(TorrentClientAddTorrentFileData(
            &client,
            torrent_data.data(),
            static_cast<int32_t>(torrent_data.size()),
            temporary_directory.path().c_str(),
            &add_options,
            added_id,
            static_cast<int32_t>(sizeof(added_id)),
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);

        canonical_id = added_id;
        std::optional<lt::torrent_handle> const handle = client.find(canonical_id);
        REQUIRE(handle.has_value());
        TorrentIdentity *identity = identity_from_handle(*handle);
        REQUIRE(identity != nullptr);
        CHECK(identity->comment == expected_comment);
        CHECK(identity->creation_date == expected_creation_date);

        {
            std::scoped_lock guard(client.lock);
            auto const cached = client.snapshot_indices.find(canonical_id);
            REQUIRE(cached != client.snapshot_indices.end());
            TTorrentSnapshot &snapshot = client.snapshot_cache.at(cached->second);
            CHECK(std::string(snapshot.comment) == expected_comment);
            CHECK(snapshot.created_time == expected_creation_date);

            identity->comment.clear();
            identity->creation_date = 0;
            copy_string(std::span{snapshot.comment}, "");
            snapshot.created_time = 0;
        }

        client.request_save(*handle, kPolicyResumeSaveFlags);
        REQUIRE(eventually([&] {
            client.pump_alerts();
            std::scoped_lock guard(client.lock);
            auto const cached = client.snapshot_indices.find(canonical_id);
            if (cached == client.snapshot_indices.end()) {
                return false;
            }
            TTorrentSnapshot const &snapshot = client.snapshot_cache.at(cached->second);
            return identity->comment == expected_comment
                && identity->creation_date == expected_creation_date
                && std::string(snapshot.comment) == expected_comment
                && snapshot.created_time == expected_creation_date;
        }));
    }

    TTorrentClient reloaded(
        state_directory.string(),
        true,
        AuthorizedSavePathSet{temporary_directory.path().lexically_normal().string()}
    );
    reloaded.set_session_shutdown_asynchronous(false);
    std::scoped_lock guard(reloaded.lock);
    auto const cached = reloaded.snapshot_indices.find(canonical_id);
    REQUIRE(cached != reloaded.snapshot_indices.end());
    TTorrentSnapshot const &snapshot = reloaded.snapshot_cache.at(cached->second);
    CHECK(std::string(snapshot.comment) == expected_comment);
    CHECK(snapshot.created_time == expected_creation_date);
}

TEST_CASE("active file cache applies filenames renamed before add")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::shared_ptr<lt::torrent_info const> const info = make_torrent_info(false);
    CHECK(info->layout().file_path(lt::file_index_t(0)) == "public.bin");
    lt::add_torrent_params params;
    params.ti = info;
    params.renamed_files.emplace(lt::file_index_t(0), "renamed-public.bin");

    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(
        client,
        std::move(params),
        temporary_directory.path(),
        identity
    );
    REQUIRE(identity != nullptr);
    REQUIRE(handle.is_valid());
    REQUIRE(eventually([&] {
        try {
            return handle.get_renamed_files().file_path(
                info->layout(),
                lt::file_index_t(0)
            ) == "renamed-public.bin";
        } catch (...) {
            return false;
        }
    }));

    DirtyMask changes = 0;
    {
        std::scoped_lock guard(client.lock);
        REQUIRE(client.request_files(identity->canonical_id, changes).has_value());
    }

    std::uint64_t revision = 0;
    int32_t required_count = 0;
    std::uint8_t resident = bridge_bool(false);
    REQUIRE(client.copy_files(identity->canonical_id, {}, &revision, &required_count, &resident) == 0);
    REQUIRE(bridge_bool(resident));
    REQUIRE(required_count == 1);

    std::array<TTorrentFileSnapshot, 1> files{};
    REQUIRE(client.copy_files(identity->canonical_id, files, &revision, &required_count, &resident) == 1);
    CHECK(std::string(files.front().path) == "renamed-public.bin");
}

TEST_CASE("detail cache distinguishes resident empty data from a silent eviction")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::string const id = "empty-web-seeds";
    std::uint64_t first_revision = 0;
    {
        std::scoped_lock guard(client.lock);
        DirtyMask const changes = client.cache_web_seeds(id, {});
        REQUIRE((changes & TTORRENT_DIRTY_WEB_SEEDS) != 0U);
        static_cast<void>(client.publish_changes_locked(changes));
        first_revision = client.web_seed_revision;
    }

    std::uint64_t revision = 0;
    int32_t required_count = -1;
    std::uint8_t resident = bridge_bool(false);
    CHECK(client.copy_web_seeds(id, {}, &revision, &required_count, &resident) == 0);
    CHECK(bridge_bool(resident));
    CHECK(required_count == 0);
    CHECK(revision == first_revision);

    {
        std::scoped_lock guard(client.lock);
        client.evict_detail_cache_entry_locked(DetailCacheKind::web_seeds, id);
        CHECK(client.web_seed_revision == first_revision);
    }

    resident = bridge_bool(true);
    CHECK(client.copy_web_seeds(id, {}, &revision, &required_count, &resident) == 0);
    CHECK_FALSE(bridge_bool(resident));
    CHECK(required_count == 0);
    CHECK(revision == first_revision);

    {
        std::scoped_lock guard(client.lock);
        DirtyMask const changes = client.cache_web_seeds(id, {});
        REQUIRE((changes & TTORRENT_DIRTY_WEB_SEEDS) != 0U);
        static_cast<void>(client.publish_changes_locked(changes));
    }
    resident = bridge_bool(false);
    CHECK(client.copy_web_seeds(id, {}, &revision, &required_count, &resident) == 0);
    CHECK(bridge_bool(resident));
    CHECK(revision > first_revision);
}

TEST_CASE("detail cache enforces one deterministic payload LRU across cache kinds")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto insert_maximum_file_entry = [&](std::string const &id) {
        std::vector<TTorrentFileSnapshot> files(static_cast<std::size_t>(TTORRENT_MAX_FILE_COUNT));
        std::size_t const payload_bytes = files.capacity() * sizeof(TTorrentFileSnapshot);
        std::scoped_lock guard(client.lock);
        auto [cached, created] = client.file_cache.try_emplace(id);
        REQUIRE(created);
        REQUIRE(client.admit_detail_cache_entry_locked(DetailCacheKind::files, id, 0, payload_bytes));
        cached->second.files = std::move(files);
    };

    insert_maximum_file_entry("a");
    insert_maximum_file_entry("b");
    insert_maximum_file_entry("c");
    {
        std::scoped_lock guard(client.lock);
        REQUIRE(client.file_cache.size() == 3U);
        REQUIRE(client.detail_cache_payload_bytes <= kDetailCachePayloadBudgetBytes);
    }

    std::uint64_t revision = 0;
    int32_t required_count = 0;
    std::uint8_t resident = bridge_bool(false);
    CHECK(client.copy_files("a", {}, &revision, &required_count, &resident) == 0);
    REQUIRE(bridge_bool(resident));

    {
        std::vector<std::uint8_t> pieces(static_cast<std::size_t>(TTORRENT_MAX_PIECE_MAP_COUNT));
        std::size_t const payload_bytes = pieces.capacity() + sizeof(TTorrentPieceMapSnapshot);
        std::scoped_lock guard(client.lock);
        auto [cached, created] = client.piece_map_cache.try_emplace("piece-map");
        REQUIRE(created);
        REQUIRE(client.admit_detail_cache_entry_locked(
            DetailCacheKind::piece_map,
            "piece-map",
            0,
            payload_bytes
        ));
        cached->second.pieces = std::move(pieces);
    }

    insert_maximum_file_entry("d");
    {
        std::scoped_lock guard(client.lock);
        CHECK(client.file_cache.contains("a"));
        CHECK_FALSE(client.file_cache.contains("b"));
        CHECK(client.file_cache.contains("c"));
        CHECK(client.file_cache.contains("d"));
        CHECK(client.piece_map_cache.contains("piece-map"));
        CHECK(client.detail_cache_payload_bytes <= kDetailCachePayloadBudgetBytes);
        CHECK(client.detail_cache_entry_count_locked() == 4U);
    }
}

TEST_CASE("detail cache enforces its entry-count metadata bound")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::scoped_lock guard(client.lock);
    for (std::size_t index = 0; index <= kDetailCacheMaxEntryCount; ++index) {
        std::string const id = "peer-" + std::to_string(index);
        auto [cached, created] = client.peer_source_cache.try_emplace(id);
        REQUIRE(created);
        REQUIRE(client.admit_detail_cache_entry_locked(
            DetailCacheKind::peer_sources,
            id,
            0,
            sizeof(TTorrentPeerSourceSnapshot)
        ));
        static_cast<void>(cached);
    }

    CHECK(client.detail_cache_entry_count_locked() == kDetailCacheMaxEntryCount);
    CHECK_FALSE(client.peer_source_cache.contains("peer-0"));
    CHECK(client.peer_source_cache.contains("peer-256"));
    CHECK(client.detail_cache_payload_bytes
          == kDetailCacheMaxEntryCount * sizeof(TTorrentPeerSourceSnapshot));
}

TEST_CASE("tracker host materialization caps rows and backfills its deterministic prefix")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    CHECK(client.tracker_host_cache.capacity() == 0U);

    constexpr std::size_t torrent_count = 11U;
    std::vector<lt::torrent_handle> handles;
    std::vector<TorrentIdentity *> identities;
    handles.reserve(torrent_count);
    identities.reserve(torrent_count);

    for (std::size_t torrent = 0; torrent < torrent_count; ++torrent) {
        std::shared_ptr<lt::torrent_info const> const info = make_queue_torrent_info(
            static_cast<unsigned char>(60U + torrent)
        );
        TorrentIdentity *identity = nullptr;
        lt::torrent_handle handle = add_metadata_torrent(
            client,
            *info,
            temporary_directory.path(),
            identity
        );
        REQUIRE(identity != nullptr);

        std::vector<lt::announce_entry> trackers;
        trackers.reserve(static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT));
        for (int32_t tracker = 0; tracker < TTORRENT_MAX_TRACKER_COUNT; ++tracker) {
            trackers.emplace_back(
                "https://tracker-" + std::to_string(torrent) + "-" + std::to_string(tracker)
                + ".example/announce"
            );
        }
        handle.replace_trackers(trackers);
        {
            std::scoped_lock guard(client.lock);
            static_cast<void>(client.cache_snapshot(handle));
        }
        handles.push_back(handle);
        identities.push_back(identity);
    }

    {
        std::scoped_lock guard(client.lock);
        REQUIRE(client.tracker_host_cache.size()
                == static_cast<std::size_t>(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT));
        CHECK(client.tracker_host_cache.capacity()
              <= static_cast<std::size_t>(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT));
        CHECK(std::ranges::none_of(client.tracker_host_cache, [&](TTorrentTrackerHostSnapshot const &row) {
            return std::string_view(row.torrent_id) == identities.back()->canonical_id;
        }));
    }

    handles.front().replace_trackers({});
    DirtyMask host_changes = 0;
    {
        std::scoped_lock guard(client.lock);
        host_changes = client.cache_tracker_hosts(identities.front()->canonical_id, {});
        REQUIRE(client.tracker_host_cache.size()
                == static_cast<std::size_t>(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT));
        CHECK(client.tracker_host_cache.capacity()
              <= static_cast<std::size_t>(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT));
        CHECK(std::ranges::any_of(client.tracker_host_cache, [&](TTorrentTrackerHostSnapshot const &row) {
            return std::string_view(row.torrent_id) == identities.back()->canonical_id;
        }));
    }
    CHECK((host_changes & TTORRENT_DIRTY_TRACKER_HOSTS) != 0U);

    std::uint64_t revision = 0;
    int32_t required_count = 0;
    CHECK(client.copy_tracker_hosts({}, &revision, &required_count) == 0);
    CHECK(required_count == TTORRENT_MAX_TRACKER_HOST_ROW_COUNT);
}

TEST_CASE("unchanged tracker details do not rebuild the aggregate host cache")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::shared_ptr<lt::torrent_info const> const first_info = make_queue_torrent_info(90U);
    std::shared_ptr<lt::torrent_info const> const second_info = make_queue_torrent_info(91U);
    TorrentIdentity *first_identity = nullptr;
    TorrentIdentity *second_identity = nullptr;
    lt::torrent_handle first_handle = add_metadata_torrent(
        client,
        *first_info,
        temporary_directory.path(),
        first_identity
    );
    lt::torrent_handle second_handle = add_metadata_torrent(
        client,
        *second_info,
        temporary_directory.path(),
        second_identity
    );
    REQUIRE(first_identity != nullptr);
    REQUIRE(second_identity != nullptr);

    std::vector<lt::announce_entry> const first_trackers{
        lt::announce_entry{"https://first.example/announce"},
    };
    std::vector<lt::announce_entry> const original_second_trackers{
        lt::announce_entry{"https://second-old.example/announce"},
    };
    first_handle.replace_trackers(first_trackers);
    second_handle.replace_trackers(original_second_trackers);
    {
        std::scoped_lock guard(client.lock);
        static_cast<void>(client.cache_snapshot(first_handle));
        static_cast<void>(client.cache_snapshot(second_handle));
        static_cast<void>(client.cache_trackers(first_handle, first_trackers));
        REQUIRE(std::ranges::any_of(client.tracker_host_cache, [](TTorrentTrackerHostSnapshot const &row) {
            return std::string_view(row.host) == "second-old.example";
        }));
    }

    {
        std::scoped_lock guard(client.lock);
        {
            std::scoped_lock io_guard(client.resume_io_lock);
            client.handle_by_id.insert_or_assign(second_identity->canonical_id, lt::torrent_handle{});
        }
        CHECK(client.cache_trackers(first_handle, first_trackers) == 0U);
        CHECK(std::ranges::any_of(client.tracker_host_cache, [](TTorrentTrackerHostSnapshot const &row) {
            return std::string_view(row.host) == "second-old.example";
        }));
        {
            std::scoped_lock io_guard(client.resume_io_lock);
            client.handle_by_id.insert_or_assign(second_identity->canonical_id, second_handle);
        }
    }
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

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE,
        true,
        error
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

    TTorrentClient reloaded(
        state_directory.string(),
        true,
        AuthorizedSavePathSet{temporary_directory.path().lexically_normal().string()}
    );
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

    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_DHT, true, error) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE,
        true,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_LSD, true, error) == 0);

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

    char error[512]{};
    CHECK(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_DHT, false, error) == 2);

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
    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_DHT, true, error) == 0);

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
    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_DHT, true, error) == 0);

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

    lt::add_torrent_params source_params = make_source_torrent_params();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, std::move(source_params), temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    REQUIRE(handle.trackers().size() == 2U);
    REQUIRE(handle.url_seeds().size() == 2U);

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

    settings.require_https_trackers = bridge_bool(false);
    settings.require_https_web_seeds = bridge_bool(false);
    REQUIRE(TorrentClientApplySettings(
        &client,
        &settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(handle.trackers().size() == 2U);
    CHECK(cached_url_seed_count(client, identity->canonical_id) == 2);
}

TEST_CASE("per-torrent HTTPS source exception preserves loaded torrent sources")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::add_torrent_params source_params = make_source_torrent_params();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, std::move(source_params), temporary_directory.path(), identity);
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
}

TEST_CASE("source policy toggles DHT PEX LSD and HTTPS sources for a loaded torrent")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::add_torrent_params source_params = make_source_torrent_params();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, std::move(source_params), temporary_directory.path(), identity);
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

    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_DHT, false, error) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE,
        false,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_LSD, false, error) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_TRACKERS,
        true,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_WEB_SEEDS,
        true,
        error
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
    CHECK(identity->dht_disabled_by_user);
    CHECK(identity->peer_exchange_disabled_by_user);
    CHECK(identity->lsd_disabled_by_user);
    CHECK(identity->requires_https_trackers);
    CHECK(identity->requires_https_web_seeds);
    CHECK_FALSE(identity->allows_non_https_trackers);
    CHECK_FALSE(identity->allows_non_https_web_seeds);

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_TRACKERS,
        false,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_WEB_SEEDS,
        false,
        error
    ) == 0);
    REQUIRE(handle.trackers().size() == 2U);
    CHECK(cached_url_seed_count(client, identity->canonical_id) == 2);
    CHECK_FALSE(identity->requires_https_trackers);
    CHECK_FALSE(identity->requires_https_web_seeds);
}

TEST_CASE("unrelated source policy mutations preserve global HTTPS enforcement")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::add_torrent_params source_params = make_source_torrent_params();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(
        client,
        std::move(source_params),
        temporary_directory.path(),
        identity
    );
    REQUIRE(identity != nullptr);

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
    REQUIRE(handle.trackers().size() == 1U);
    REQUIRE(handle.url_seeds().size() == 1U);
    REQUIRE_FALSE(identity->requires_https_trackers);
    REQUIRE_FALSE(identity->requires_https_web_seeds);
    REQUIRE_FALSE(identity->allows_non_https_trackers);
    REQUIRE_FALSE(identity->allows_non_https_web_seeds);

    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_DHT, false, error) == 0);

    CHECK(handle.trackers().size() == 1U);
    CHECK(handle.trackers().front().url == "https://secure-tracker.example/announce");
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.url_seeds().contains("https://secure-seed.example/file"));
    CHECK_FALSE(identity->requires_https_trackers);
    CHECK_FALSE(identity->requires_https_web_seeds);
    CHECK_FALSE(identity->allows_non_https_trackers);
    CHECK_FALSE(identity->allows_non_https_web_seeds);
}

TEST_CASE("source policy rejects metadata-only fields after metadata is available")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    REQUIRE(info != nullptr);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    REQUIRE(handle.is_valid());

    REQUIRE_FALSE(client.metadata_validation_pending.contains(identity));
    char error[512]{};
    CHECK(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT,
        true,
        error
    ) != 0);
    CHECK(std::string(error) == "This source policy field is unavailable for the current metadata state.");
    CHECK_FALSE(identity->allow_pre_metadata_dht);
    CHECK_FALSE(identity->dht_enabled_by_user);
    CHECK_FALSE(identity->dht_disabled_by_user);
}

TEST_CASE("source policy reports explicit user policy over transient libtorrent flags")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::add_torrent_params source_params = make_source_torrent_params();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, std::move(source_params), temporary_directory.path(), identity);
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
    std::uint8_t resident = bridge_bool(false);
    REQUIRE(client.copy_piece_map(
        identity->canonical_id,
        &snapshot,
        {},
        &revision,
        &required_count,
        &resident
    ) == 0);
    REQUIRE(bridge_bool(resident));

    CHECK(snapshot.total_pieces == info->num_pieces());
    CHECK(snapshot.completed_pieces == 0);
    CHECK(snapshot.available_pieces == info->num_pieces());
    CHECK(required_count == info->num_pieces());

    std::vector<std::uint8_t> pieces(static_cast<std::size_t>(required_count));
    REQUIRE(client.copy_piece_map(
                identity->canonical_id,
                &snapshot,
                std::span{pieces},
                &revision,
                &required_count,
                &resident
            )
            == info->num_pieces());
    for (std::uint8_t const piece : pieces) {
        CHECK_FALSE(bridge_bool(piece));
    }
}

TEST_CASE("hash-only torrent info is rejected as invalid metadata")
{
    lt::torrent_info const info{
        lt::info_hash_t{bridge_tests::sha1_hash_from_seed(26U)}
    };
    REQUIRE_FALSE(info.is_valid());

    BridgeResult const result = validate_torrent_info(info);
    REQUIRE_FALSE(result);
    CHECK(result.error().code == 2);
    CHECK(result.error().message == "The torrent file is invalid.");
}

TEST_CASE("metadata-less magnets replace retained file and piece details with authoritative empties")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::string const magnet = "magnet:?xt=urn:btih:0123456A89abcdef32056417897768acf0261b73";
    std::string const save_path = temporary_directory.path().string();
    TTorrentAddOptions add_options = default_add_options(false);
    add_options.starts_paused = bridge_bool(true);
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
    REQUIRE(is_canonical_torrent_id(added_id));

    std::optional<lt::torrent_handle> const handle = client.find(added_id);
    REQUIRE(handle.has_value());
    lt::torrent_status const status = handle->status(lt::torrent_handle::query_torrent_file);
    REQUIRE_FALSE(status.has_metadata);
    std::shared_ptr<lt::torrent_info const> const torrent_file = status.torrent_file.lock();
    REQUIRE(torrent_file != nullptr);
    REQUIRE_FALSE(torrent_file->is_valid());

    {
        std::vector<TTorrentFileSnapshot> retained_files(4U);
        std::size_t const retained_bytes = retained_files.capacity() * sizeof(TTorrentFileSnapshot);
        std::scoped_lock guard(client.lock);
        auto [cached, created] = client.file_cache.try_emplace(added_id);
        REQUIRE(created);
        REQUIRE(client.admit_detail_cache_entry_locked(
            DetailCacheKind::files,
            added_id,
            0,
            retained_bytes
        ));
        cached->second.files = std::move(retained_files);
        REQUIRE(client.detail_cache_payload_bytes == retained_bytes);
    }

    REQUIRE(TorrentClientRequestFiles(
        &client,
        added_id,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(error[0] == '\0');
    {
        std::scoped_lock guard(client.lock);
        auto const cached = client.file_cache.find(added_id);
        REQUIRE(cached != client.file_cache.end());
        CHECK(cached->second.files.capacity() == 0U);
        CHECK(client.detail_cache_payload_bytes == 0U);
    }

    std::uint64_t revision = 0;
    int32_t required_count = -1;
    std::uint8_t resident = bridge_bool(false);
    CHECK(TorrentClientCopyFileBatch(
        &client,
        added_id,
        nullptr,
        0,
        &revision,
        &required_count,
        &resident
    ) == 0);
    CHECK(bridge_bool(resident));
    CHECK(required_count == 0);

    lt::torrent_status synthetic_status = status;
    synthetic_status.pieces.resize(3);
    DirtyMask synthetic_changes = 0;
    {
        std::scoped_lock guard(client.lock);
        synthetic_changes |= client.cache_piece_map(synthetic_status);
    }
    CHECK((synthetic_changes & TTORRENT_DIRTY_PIECES) != 0U);

    TTorrentPieceMapSnapshot synthetic_snapshot{};
    revision = 0;
    required_count = -1;
    CHECK(TorrentClientCopyPieceMap(
        &client,
        added_id,
        &synthetic_snapshot,
        nullptr,
        0,
        &revision,
        &required_count,
        &resident
    ) == 0);
    CHECK(synthetic_snapshot.total_pieces == 3);
    CHECK(synthetic_snapshot.completed_pieces == 0);
    CHECK(synthetic_snapshot.available_pieces == 3);
    CHECK(bridge_bool(synthetic_snapshot.map_available));
    CHECK_FALSE(bridge_bool(synthetic_snapshot.map_truncated));
    CHECK(required_count == 3);

    REQUIRE(TorrentClientRequestPieceMap(
        &client,
        added_id,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(error[0] == '\0');

    TTorrentPieceMapSnapshot snapshot{};
    revision = 0;
    required_count = -1;
    CHECK(TorrentClientCopyPieceMap(
        &client,
        added_id,
        &snapshot,
        nullptr,
        0,
        &revision,
        &required_count,
        &resident
    ) == 0);
    CHECK(snapshot.total_pieces == 0);
    CHECK(snapshot.completed_pieces == 0);
    CHECK(snapshot.available_pieces == 0);
    CHECK_FALSE(bridge_bool(snapshot.map_available));
    CHECK_FALSE(bridge_bool(snapshot.map_truncated));
    CHECK(required_count == 0);
}

TEST_CASE("source policy cannot override DHT PEX or LSD source locks")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::add_torrent_params source_params = make_source_torrent_params();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, std::move(source_params), temporary_directory.path(), identity);
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

    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_DHT, true, error) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE,
        true,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_LSD, true, error) == 0);

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

    lt::add_torrent_params params = make_source_torrent_params();
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

    char error[512]{};
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_TRACKERS,
        false,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_WEB_SEEDS,
        false,
        error
    ) == 0);

    REQUIRE(handle.trackers().size() == 2U);
    CHECK(cached_url_seed_count(client, identity->canonical_id) == 2);
}

TEST_CASE("source policy restore does not reinsert blocked HTTPS-only sources")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::add_torrent_params params = make_source_torrent_params();
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

    static_cast<void>(client.restore_metadata_source_policy(handle, identity));

    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.trackers().front().url == "https://secure-tracker.example/announce");
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.url_seeds().contains("https://secure-seed.example/file"));
    CHECK(identity->source_trackers.size() == 2U);
    CHECK(identity->source_web_seeds.size() == 2U);
}

TEST_CASE("magnet torrents gate payload files and untrusted discovery until metadata is validated")
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
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::block_non_global_peers));
    CHECK(client.metadata_validation_pending.contains(identity));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(identity));
}

TEST_CASE("trackerless magnet can explicitly allow DHT before metadata validation")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::string const hash(40U, '6');
    std::string const magnet = "magnet:?xt=urn:btih:" + hash;
    std::string const save_path = temporary_directory.path().string();
    TTorrentAddOptions add_options = default_add_options();
    add_options.allow_pre_metadata_dht = bridge_bool(true);
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

        lt::torrent_handle handle = client.handle_by_id.at(bridge_tests::v1_id('6'));
        TorrentIdentity *identity = identity_from_handle(handle);
        REQUIRE(identity != nullptr);
        CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
        CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
        CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
        CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::block_non_global_peers));
        CHECK(identity->allow_pre_metadata_dht);
        CHECK(client.metadata_validation_pending.contains(identity));
        TTorrentSourcePolicy const policy = client.source_policy(handle, identity);
        CHECK(bridge_bool(policy.metadata_validation_pending));
        CHECK(bridge_bool(policy.allow_pre_metadata_dht));
    }

    TTorrentClient reloaded(
        state_directory.string(),
        true,
        AuthorizedSavePathSet{temporary_directory.path().lexically_normal().string()}
    );
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = reloaded.handle_by_id.at(bridge_tests::v1_id('6'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::block_non_global_peers));
    CHECK(identity->allow_pre_metadata_dht);
    CHECK(reloaded.metadata_validation_pending.contains(identity));
}

TEST_CASE("pending magnet DHT revocation is durable before the setter returns")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::string const hash(40U, '7');
    std::string const magnet = "magnet:?xt=urn:btih:" + hash;
    std::string const save_path = temporary_directory.path().string();
    TTorrentAddOptions add_options = default_add_options();
    add_options.allow_pre_metadata_dht = bridge_bool(true);
    char added_id[TTORRENT_ID_CAPACITY]{};
    char error[512]{};

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

    lt::torrent_handle handle = client.handle_by_id.at(bridge_tests::v1_id('7'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    REQUIRE(identity->allow_pre_metadata_dht);
    client.stop_alert_worker();

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT,
        false,
        error
    ) == 0);
    CHECK_FALSE(identity->allow_pre_metadata_dht);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));

    std::string const resume_id = bridge_tests::v1_id('7');
    fs::path const resume_path = client.resume_directory / (resume_id + std::string(kResumeExtension));
    FileReadResult const persisted = read_file(resume_path, kMaxResumeFileBytes);
    REQUIRE(persisted.has_value());
    CHECK(metadata_validation_pending_from_resume_data(*persisted));
    CHECK_FALSE(allow_pre_metadata_dht_from_resume_data(*persisted));

    fs::path const restart_state = temporary_directory.path() / "RestartState";
    fs::path const restart_resume_directory = restart_state / "ResumeData";
    REQUIRE(fs::create_directories(restart_resume_directory));
    REQUIRE(fs::copy_file(
        resume_path,
        restart_resume_directory / resume_path.filename(),
        fs::copy_options::none
    ));

    TTorrentClient restarted(
        restart_state.string(),
        true,
        AuthorizedSavePathSet{temporary_directory.path().lexically_normal().string()}
    );
    restarted.set_session_shutdown_asynchronous(false);
    lt::torrent_handle restarted_handle = restarted.handle_by_id.at(resume_id);
    TorrentIdentity *restarted_identity = identity_from_handle(restarted_handle);
    REQUIRE(restarted_identity != nullptr);
    CHECK(restarted.metadata_validation_pending.contains(restarted_identity));
    CHECK_FALSE(restarted_identity->allow_pre_metadata_dht);
    CHECK(static_cast<bool>(restarted_handle.flags() & lt::torrent_flags::disable_dht));
}

TEST_CASE("payload deletion waits for libtorrent and removes an exact torrent file")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    fs::path const payload = temporary_directory.path() / "public.bin";
    bridge_tests::write_text_file(payload, "data");
    std::shared_ptr<lt::torrent_info const> const info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    static_cast<void>(add_metadata_torrent(client, *info, temporary_directory.path(), identity));
    REQUIRE(identity != nullptr);

    std::uint64_t request_token = 0;
    std::array<char, 512> error{};
    REQUIRE(TorrentClientRemove(
        &client,
        identity->canonical_id.c_str(),
        bridge_bool(true),
        bridge_bool(false),
        &request_token,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    REQUIRE(request_token != 0);

    TTorrentRemovalResult result{};
    REQUIRE(TorrentClientTakeRemovalResult(
        &client,
        request_token,
        &result,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    CHECK(result.state == TTORRENT_REMOVAL_PENDING);

    REQUIRE(eventually_take_removal_result(client, request_token, result, error));
    CHECK(result.state == TTORRENT_REMOVAL_SUCCEEDED);
    CHECK_FALSE(file_exists(payload));
}

TEST_CASE("payload deletion does not recursively remove a colliding directory")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    fs::path const colliding_directory = temporary_directory.path() / "public.bin";
    fs::path const unrelated_file = colliding_directory / "unrelated.txt";
    REQUIRE(fs::create_directory(colliding_directory));
    bridge_tests::write_text_file(unrelated_file, "unrelated data");
    std::shared_ptr<lt::torrent_info const> const info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    static_cast<void>(add_metadata_torrent(client, *info, temporary_directory.path(), identity));
    REQUIRE(identity != nullptr);

    std::uint64_t request_token = 0;
    std::array<char, 512> error{};
    REQUIRE(TorrentClientRemove(
        &client,
        identity->canonical_id.c_str(),
        bridge_bool(true),
        bridge_bool(false),
        &request_token,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);

    TTorrentRemovalResult result{};
    REQUIRE(eventually_take_removal_result(client, request_token, result, error));
    CHECK(result.state == TTORRENT_REMOVAL_FAILED);
    CHECK(bridge_tests::string_from_c_buffer(std::span{result.error}).contains("Some files may remain on disk"));
    CHECK(fs::is_directory(colliding_directory));
    CHECK(file_exists(unrelated_file));
}

TEST_CASE("a second payload deletion is rejected while the first is pending")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::shared_ptr<lt::torrent_info const> const first_info = make_queue_torrent_info(41U);
    std::shared_ptr<lt::torrent_info const> const second_info = make_queue_torrent_info(42U);
    TorrentIdentity *first_identity = nullptr;
    TorrentIdentity *second_identity = nullptr;
    static_cast<void>(add_metadata_torrent(client, *first_info, temporary_directory.path(), first_identity));
    static_cast<void>(add_metadata_torrent(client, *second_info, temporary_directory.path(), second_identity));
    REQUIRE(first_identity != nullptr);
    REQUIRE(second_identity != nullptr);

    std::uint64_t first_token = 0;
    std::array<char, 512> error{};
    REQUIRE(TorrentClientRemove(
        &client,
        first_identity->canonical_id.c_str(),
        bridge_bool(true),
        bridge_bool(false),
        &first_token,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);

    std::uint64_t second_token = 1;
    CHECK(TorrentClientRemove(
        &client,
        second_identity->canonical_id.c_str(),
        bridge_bool(true),
        bridge_bool(false),
        &second_token,
        error.data(),
        static_cast<int32_t>(error.size())
    ) != 0);
    CHECK(second_token == 0);
    CHECK(bridge_tests::string_from_c_buffer(std::span{error}).contains("already pending"));
    CHECK(client.find(second_identity->canonical_id).has_value());

    TTorrentRemovalResult result{};
    CHECK(eventually_take_removal_result(client, first_token, result, error));
}

TEST_CASE("a completed payload deletion remains tracked until its result is collected")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::shared_ptr<lt::torrent_info const> const first_info = make_queue_torrent_info(43U);
    std::shared_ptr<lt::torrent_info const> const second_info = make_queue_torrent_info(44U);
    std::uint64_t const first_token = client.begin_delete_request(first_info->info_hashes());
    client.complete_delete_request(first_info->info_hashes(), TTORRENT_REMOVAL_SUCCEEDED);

    std::bitset<lt::abi_alert_count> dropped_alerts;
    dropped_alerts.set(lt::torrent_deleted_alert::alert_type);
    lt::aux::stack_allocator allocator;
    lt::alerts_dropped_alert const dropped_alert(allocator, dropped_alerts);
    CHECK(client.fail_dropped_delete_request(dropped_alert) == 0U);

    CHECK_THROWS(client.begin_delete_request(second_info->info_hashes()));

    TTorrentRemovalResult result{};
    std::array<char, 512> error{};
    CHECK(TorrentClientTakeRemovalResult(
        &client,
        first_token + 1U,
        &result,
        error.data(),
        static_cast<int32_t>(error.size())
    ) != 0);
    CHECK_THROWS(client.begin_delete_request(second_info->info_hashes()));

    REQUIRE(TorrentClientTakeRemovalResult(
        &client,
        first_token,
        &result,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    CHECK(result.state == TTORRENT_REMOVAL_SUCCEEDED);

    std::uint64_t const second_token = client.begin_delete_request(second_info->info_hashes());
    CHECK(second_token != 0);
    client.abandon_removal_request(second_token);
    std::uint64_t const third_token = client.begin_delete_request(first_info->info_hashes());
    CHECK(third_token != 0);
    client.abandon_removal_request(third_token);
    CHECK_FALSE(client.removal_request.has_value());
}

TEST_CASE("a dropped terminal deletion alert fails the request and completes cleanup")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::shared_ptr<lt::torrent_info const> const info = make_torrent_info(false);
    std::string const resume_id = primary_hash_key(info->info_hashes());
    std::uint64_t const request_token = client.begin_delete_request(info->info_hashes());
    client.remember_pending_delete(info->info_hashes(), {resume_id});

    std::bitset<lt::abi_alert_count> dropped_alerts;
    dropped_alerts.set(lt::torrent_deleted_alert::alert_type);
    lt::aux::stack_allocator allocator;
    lt::alerts_dropped_alert const alert(allocator, dropped_alerts);
    CHECK((client.fail_dropped_delete_request(alert) & TTORRENT_DIRTY_ERRORS) != 0U);
    CHECK(client.awaiting_delete_resume_ids_by_id.empty());

    TTorrentRemovalResult result{};
    std::array<char, 512> error{};
    REQUIRE(TorrentClientTakeRemovalResult(
        &client,
        request_token,
        &result,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    CHECK(result.state == TTORRENT_REMOVAL_FAILED);
    CHECK(bridge_tests::string_from_c_buffer(std::span{result.error}).contains("terminal libtorrent alert was dropped"));
}

TEST_CASE("metadata-less magnet removal treats a zero-error failed alert conservatively")
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

    std::uint64_t request_token = 0;
    REQUIRE(TorrentClientRemove(
        &client,
        id.c_str(),
        bridge_bool(true),
        bridge_bool(true),
        &request_token,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(request_token != 0);

    TTorrentRemovalResult removal_result{};
    CHECK(eventually([&] {
        client.pump_alerts();
        return TorrentClientTakeRemovalResult(
            &client,
            request_token,
            &removal_result,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0 && removal_result.state != TTORRENT_REMOVAL_PENDING;
    }));

    CHECK(removal_result.state == TTORRENT_REMOVAL_FAILED);
    CHECK(bridge_tests::string_from_c_buffer(std::span{removal_result.error}).contains("Some files may remain on disk"));
    CHECK(client.take_alert_error(std::span{error}));
}

TEST_CASE("metadata validation gate survives resume reload")
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

    TTorrentClient reloaded(
        state_directory.string(),
        true,
        AuthorizedSavePathSet{temporary_directory.path().lexically_normal().string()}
    );
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = reloaded.handle_by_id.at(bridge_tests::v1_id('3'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK(reloaded.metadata_validation_pending.contains(identity));
    CHECK_FALSE(reloaded.peer_exchange_disabled_by_app.contains(identity));
}

TEST_CASE("pending resume discovery guards do not become source locks")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const resume_directory = state_directory / "ResumeData";
    REQUIRE(fs::create_directories(resume_directory));

    std::string const hash(40U, '5');
    lt::error_code parse_error;
    lt::add_torrent_params params = lt::parse_magnet_uri(
        "magnet:?xt=urn:btih:" + hash,
        parse_error
    );
    REQUIRE_FALSE(parse_error);
    params.save_path = temporary_directory.path().string();
    params.flags |= lt::torrent_flags::disable_dht;
    params.flags |= lt::torrent_flags::disable_pex;
    params.flags |= lt::torrent_flags::disable_lsd;

    TorrentIdentity persisted_identity;
    persisted_identity.canonical_id = bridge_tests::canonical_id('5');
    std::vector<char> const encoded = encoded_resume_data(params, &persisted_identity, true);
    std::string const resume_id = primary_hash_key(params.info_hashes);
    REQUIRE_FALSE(resume_id.empty());
    ResumeSaveResult const written = write_owner_only_file_checked(
        resume_directory / (resume_id + std::string(kResumeExtension)),
        std::string_view(encoded.data(), encoded.size())
    );
    REQUIRE(written.has_value());

    TTorrentClient reloaded(
        state_directory.string(),
        true,
        AuthorizedSavePathSet{temporary_directory.path().lexically_normal().string()}
    );
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = reloaded.handle_by_id.at(resume_id);
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);

    CHECK(reloaded.metadata_validation_pending.contains(identity));
    CHECK_FALSE(identity->dht_locked_by_source);
    CHECK_FALSE(identity->peer_exchange_locked_by_source);
    CHECK_FALSE(identity->lsd_locked_by_source);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
}

TEST_CASE("app-default DHT changes do not bypass pending metadata consent after reload")
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

    TTorrentClient reloaded(
        state_directory.string(),
        true,
        AuthorizedSavePathSet{temporary_directory.path().lexically_normal().string()}
    );
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
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(reloaded.dht_disabled_by_app.contains(identity));
    CHECK_FALSE(identity->allow_pre_metadata_dht);
}

TEST_CASE("metadata resolution owns peer exchange pending policy")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    auto public_info = make_torrent_info(false);
    TorrentIdentity *public_identity = nullptr;
    lt::torrent_handle public_handle = add_metadata_torrent(client, *public_info, temporary_directory.path(), public_identity);
    REQUIRE(public_identity != nullptr);

    DirtyMask changes = 0;
    public_identity->intended_default_dont_download = false;
    public_identity->intended_file_priorities = {lt::low_priority};
    public_handle.prioritize_files({lt::dont_download});
    public_handle.set_flags(lt::torrent_flags::default_dont_download);
    public_handle.set_flags(lt::torrent_flags::disable_dht);
    public_handle.set_flags(lt::torrent_flags::disable_pex);
    public_handle.set_flags(lt::torrent_flags::disable_lsd);
    public_handle.set_flags(lt::torrent_flags::block_non_global_peers);
    client.metadata_validation_pending.insert(public_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(public_handle, changes));
    REQUIRE(eventually([&public_handle] {
        std::vector<lt::download_priority_t> const priorities = public_handle.get_file_priorities();
        return priorities.size() == 1U && priorities.front() == lt::low_priority;
    }));
    CHECK_FALSE(static_cast<bool>(public_handle.flags() & lt::torrent_flags::default_dont_download));
    CHECK_FALSE(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(static_cast<bool>(public_handle.flags() & lt::torrent_flags::block_non_global_peers));
    CHECK_FALSE(client.metadata_validation_pending.contains(public_identity));

    public_identity->dht_locked_by_source = true;
    public_identity->peer_exchange_locked_by_source = true;
    public_identity->lsd_locked_by_source = true;
    public_handle.set_flags(lt::torrent_flags::disable_dht);
    public_handle.set_flags(lt::torrent_flags::disable_pex);
    public_handle.set_flags(lt::torrent_flags::disable_lsd);
    client.metadata_validation_pending.insert(public_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(public_handle, changes));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(client.metadata_validation_pending.contains(public_identity));

    public_identity->dht_locked_by_source = false;
    public_identity->peer_exchange_locked_by_source = false;
    public_identity->lsd_locked_by_source = false;
    public_handle.set_flags(lt::torrent_flags::disable_pex);
    client.metadata_validation_pending.insert(public_identity);
    client.peer_exchange_disabled_by_app.insert(public_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(public_handle, changes));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(client.metadata_validation_pending.contains(public_identity));
    CHECK(client.peer_exchange_disabled_by_app.contains(public_identity));

    auto private_info = make_torrent_info(true);
    TorrentIdentity *private_identity = nullptr;
    lt::torrent_handle private_handle = add_metadata_torrent(client, *private_info, temporary_directory.path(), private_identity);
    REQUIRE(private_identity != nullptr);

    client.metadata_validation_pending.insert(private_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(private_handle, changes));
    CHECK(static_cast<bool>(private_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(client.metadata_validation_pending.contains(private_identity));
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
    client.metadata_validation_pending.insert(private_identity);
    REQUIRE(client.validate_or_remove_loaded_metadata(private_handle, changes));
    CHECK_FALSE(client.peer_exchange_disabled_by_app.contains(private_identity));
    CHECK_FALSE(client.metadata_validation_pending.contains(private_identity));
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
