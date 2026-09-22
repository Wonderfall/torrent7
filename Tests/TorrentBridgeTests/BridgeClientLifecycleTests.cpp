#include "BridgeTestSupport.hpp"

#include <boost/asio/post.hpp>
#include <doctest.h>

#include <libtorrent/aux_/session_impl.hpp>
#include <libtorrent/aux_/stack_allocator.hpp>
#include <libtorrent/create_torrent.hpp>

#include <atomic>
#include <bitset>
#include <chrono>
#include <cstdint>
#include <ctime>
#include <filesystem>
#include <future>
#include <initializer_list>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

namespace {

inline constexpr int32_t TTORRENT_SOURCE_POLICY_ENABLE_DHT = 0;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE = 1;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_ENABLE_LSD = 2;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY = 3;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY = 4;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT = 5;

// Production resume restoration uses the Swift callback-backed importer. This
// test-only oracle keeps lifecycle tests native while making callback routing
// observable; it is never linked into a shipped target.
class TestOnlyResumeInfoParser final : public lt::aux::swarm_metadata_parser {
public:
    [[nodiscard]] std::size_t invocation_count() const noexcept
    {
        return invocation_count_;
    }

    std::shared_ptr<lt::torrent_info> parse(
        lt::span<char const> const info,
        lt::error_code &error
    ) noexcept override
    {
        ++invocation_count_;
        lt::bdecode_node const root = lt::bdecode(info, error);
        if (error || root.type() != lt::bdecode_node::dict_t) {
            return nullptr;
        }
        lt::load_torrent_limits limits{};
        auto parsed = std::make_shared<lt::torrent_info>(
            root,
            error,
            limits,
            lt::from_info_section
        );
        return error ? nullptr : parsed;
    }

private:
    std::size_t invocation_count_ = 0U;
};

[[nodiscard]] std::string next_test_canonical_id()
{
    static std::atomic_uint64_t next_value{1U};
    std::uint64_t value = next_value.fetch_add(1U, std::memory_order_relaxed);
    std::string id = "t:" + std::string(32U, '0');
    for (std::size_t index = 0; index < 16U; ++index) {
        id[id.size() - 1U - index] = hex_digit(static_cast<unsigned char>(value));
        value >>= 4U;
    }
    return id;
}

struct TTorrentSourcePolicy {
    std::uint8_t enable_dht = 0;
    std::uint8_t enable_peer_exchange = 0;
    std::uint8_t enable_lsd = 0;
    std::uint8_t https_tracker_policy = TTORRENT_HTTPS_POLICY_INHERIT;
    std::uint8_t https_web_seed_policy = TTORRENT_HTTPS_POLICY_INHERIT;
    std::uint8_t effective_https_tracker_policy = TTORRENT_HTTPS_POLICY_ORIGINAL;
    std::uint8_t effective_https_web_seed_policy = TTORRENT_HTTPS_POLICY_ORIGINAL;
    std::uint8_t dht_locked = 0;
    std::uint8_t peer_exchange_locked = 0;
    std::uint8_t lsd_locked = 0;
    std::uint8_t metadata_validation_pending = 0;
    std::uint8_t allow_pre_metadata_dht = 0;
};

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

class SessionExecutorGate {
public:
    explicit SessionExecutorGate(TTorrentClient &client)
        : state_(std::make_shared<State>())
    {
        auto const session = client.session.native_handle();
        REQUIRE(session != nullptr);
        boost::asio::post(session->get_context(), [state = state_] {
            std::unique_lock guard(state->lock);
            state->entered = true;
            state->changed.notify_all();
            state->changed.wait(guard, [state] {
                return state->released;
            });
        });

        std::unique_lock guard(state_->lock);
        bool const entered = state_->changed.wait_for(
            guard,
            std::chrono::seconds(2),
            [this] {
                return state_->entered;
            }
        );
        if (!entered) {
            state_->released = true;
            guard.unlock();
            state_->changed.notify_all();
        }
        REQUIRE(entered);
    }

    SessionExecutorGate(SessionExecutorGate const &) = delete;
    SessionExecutorGate &operator=(SessionExecutorGate const &) = delete;
    SessionExecutorGate(SessionExecutorGate &&) = delete;
    SessionExecutorGate &operator=(SessionExecutorGate &&) = delete;

    ~SessionExecutorGate()
    {
        release();
    }

    void release()
    {
        {
            std::scoped_lock guard(state_->lock);
            state_->released = true;
        }
        state_->changed.notify_all();
    }

private:
    struct State {
        std::mutex lock;
        std::condition_variable changed;
        bool entered = false;
        bool released = false;
    };

    std::shared_ptr<State> state_;
};

struct DetachedCleanupProbeState {
    std::promise<void> entered_promise;
    std::shared_future<void> entered = entered_promise.get_future().share();
    std::promise<void> release_promise;
    std::shared_future<void> release = release_promise.get_future().share();
    std::promise<void> finished_promise;
    std::future<void> finished = finished_promise.get_future();
};

class BlockingTerminalCleanup final {
public:
    explicit BlockingTerminalCleanup(std::shared_ptr<DetachedCleanupProbeState> state)
        : state_(std::move(state))
    {
    }

    BlockingTerminalCleanup(BlockingTerminalCleanup const &) = delete;
    BlockingTerminalCleanup &operator=(BlockingTerminalCleanup const &) = delete;
    BlockingTerminalCleanup(BlockingTerminalCleanup &&) noexcept = default;
    BlockingTerminalCleanup &operator=(BlockingTerminalCleanup &&) = delete;

    ~BlockingTerminalCleanup()
    {
        if (!state_) {
            return;
        }
        state_->entered_promise.set_value();
        state_->release.wait();
        state_->finished_promise.set_value();
    }

private:
    std::shared_ptr<DetachedCleanupProbeState> state_;
};

[[nodiscard]] TTorrentSessionSettings unblocked_session_settings()
{
    TTorrentSessionSettings settings{};
    settings.network_blocked = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    settings.dht_discovery_policy = TTORRENT_DHT_DISCOVERY_ALONGSIDE_TRACKERS;
    settings.dht_privacy_lookups = bridge_bool(true);
    return settings;
}

int32_t apply_settings(
    TTorrentClient *client,
    TTorrentSessionSettings settings,
    char *error,
    int32_t error_capacity,
    std::string_view network_interface = {}
)
{
    char const *const network_interface_data = network_interface.empty()
        ? nullptr
        : network_interface.data();
    return TorrentClientApplySettings(
        client,
        settings,
        network_interface_data,
        static_cast<int32_t>(network_interface.size()),
        error,
        error_capacity
    );
}

[[nodiscard]] std::uint64_t native_token(TTorrentClient &client, std::string_view const id)
{
    std::scoped_lock io_guard(client.resume_io_lock);
    auto const identity = std::ranges::find_if(
        client.torrent_identities,
        [id](auto const &candidate) {
            return candidate != nullptr && candidate->canonical_id == id;
        }
    );
    REQUIRE(identity != client.torrent_identities.end());
    REQUIRE((*identity)->token != nullptr);
    REQUIRE((*identity)->token->value != 0U);
    REQUIRE(client.handle_by_native_token.contains((*identity)->token->value));
    return (*identity)->token->value;
}

int32_t TorrentClientAddMagnet(
    TTorrentClient *client,
    char const *magnet,
    TTorrentAddOptions options,
    char *added_id,
    int32_t added_id_capacity,
    int32_t *add_outcome,
    char *error,
    int32_t error_capacity
)
{
    bridge_tests::ParsedMagnetFixture const parsed = bridge_tests::parsed_magnet_fixture(magnet);
    std::uint64_t token = 0;
    return ::TorrentClientAddParsedMagnet(
        client,
        parsed.header,
        parsed.blob.data(),
        static_cast<int32_t>(parsed.blob.size()),
        parsed.trackers.data(),
        static_cast<int32_t>(parsed.trackers.size()),
        parsed.web_seeds.data(),
        static_cast<int32_t>(parsed.web_seeds.size()),
        parsed.file_selections.data(),
        static_cast<int32_t>(parsed.file_selections.size()),
        options,
        added_id,
        added_id_capacity,
        &token,
        add_outcome,
        error,
        error_capacity
    );
}

int32_t add_test_torrent(
    TTorrentClient *client,
    lt::add_torrent_params params,
    TTorrentStorageActivation activation,
    TTorrentAddOptions options,
    char *added_id,
    int32_t added_id_capacity,
    int32_t *add_outcome,
    char *error,
    int32_t error_capacity
)
{
    std::uint64_t token = 0;
    return add_torrent_params_for_testing(
        client,
        std::move(params),
        activation,
        options,
        added_id,
        added_id_capacity,
        &token,
        add_outcome,
        error,
        error_capacity
    );
}

int32_t TorrentClientRemove(
    TTorrentClient *client,
    char const *id,
    std::uint8_t *removal_committed,
    char *error,
    int32_t error_capacity
)
{
    return ::TorrentClientRemove(
        client,
        native_token(*client, id),
        removal_committed,
        error,
        error_capacity
    );
}

int32_t TorrentClientSetFilePriority(
    TTorrentClient *client,
    char const *id,
    int32_t file_index,
    int32_t priority,
    char *error,
    int32_t error_capacity
)
{
    return ::TorrentClientSetFilePriority(
        client,
        native_token(*client, id),
        file_index,
        priority,
        error,
        error_capacity
    );
}

int32_t TorrentClientSetTorrentOptions(
    TTorrentClient *client,
    char const *id,
    TTorrentOptions options,
    char *error,
    int32_t error_capacity
)
{
    return ::TorrentClientSetTorrentOptions(
        client,
        native_token(*client, id),
        options,
        error,
        error_capacity
    );
}

int32_t TorrentClientCopyFileBatch(
    TTorrentClient *client,
    char const *id,
    TTorrentFileSnapshot *files,
    int32_t capacity,
    int32_t *required_count,
    std::uint8_t *available
)
{
    return ::TorrentClientCopyFileBatch(
        client,
        native_token(*client, id),
        files,
        capacity,
        required_count,
        available
    );
}

int32_t TorrentClientCopyPieceMap(
    TTorrentClient *client,
    char const *id,
    TTorrentPieceMapSnapshot *snapshot,
    std::uint8_t *pieces,
    int32_t capacity,
    int32_t *required_count,
    std::uint8_t *available
)
{
    return ::TorrentClientCopyPieceMap(
        client,
        native_token(*client, id),
        snapshot,
        pieces,
        capacity,
        required_count,
        available
    );
}

int32_t TorrentClientCopyTorrentMetadata(
    TTorrentClient *client,
    char const *id,
    std::uint8_t *metadata,
    int32_t capacity,
    int32_t *required_count,
    std::uint8_t *available
)
{
    return ::TorrentClientCopyTorrentMetadata(
        client,
        native_token(*client, id),
        metadata,
        capacity,
        required_count,
        available
    );
}

int32_t copy_source_policy(
    TTorrentClient *client,
    char const *torrent_id,
    TTorrentSourcePolicy *policy,
    char *error,
    int32_t error_capacity
)
{
    static_cast<void>(error);
    static_cast<void>(error_capacity);
    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    static_cast<void>(TorrentClientCopySourcePolicyStateBatch(
        client,
        nullptr,
        0,
        &required_count,
        &available
    ));
    if (!bridge_bool(available)) {
        return 1;
    }
    std::vector<TTorrentSourcePolicyState> states(static_cast<std::size_t>(required_count));
    int32_t const copied = TorrentClientCopySourcePolicyStateBatch(
        client,
        states.data(),
        required_count,
        &required_count,
        &available
    );
    if (!bridge_bool(available) || copied != required_count) {
        return 1;
    }
    std::uint64_t const token = native_token(*client, torrent_id);
    auto const state = std::ranges::find_if(states, [token](TTorrentSourcePolicyState const &candidate) {
        return candidate.native_token == token;
    });
    if (state == states.end()) {
        return 2;
    }

    lt::torrent_handle handle;
    bool peer_exchange_plugin_enabled = false;
    constexpr HTTPSPolicy global_tracker_policy = HTTPSPolicy::prefer;
    constexpr HTTPSPolicy global_web_seed_policy = HTTPSPolicy::require;
    BRIDGE_WITH_CLIENT_LOCK(
        *client,
        (handle = *client->find(token),
            peer_exchange_plugin_enabled = client->peer_exchange_plugin_enabled)
    );
    lt::torrent_flags_t const flags = handle.flags();
    bool const dht_enabled = state->dht_policy == TTORRENT_BOOLEAN_POLICY_ENABLED
        || (state->dht_policy == TTORRENT_BOOLEAN_POLICY_INHERIT
            && !static_cast<bool>(flags & lt::torrent_flags::disable_dht));
    policy->enable_dht = bridge_bool(!bridge_bool(state->dht_locked) && dht_enabled);
    bool const peer_exchange_enabled = state->peer_exchange_policy == TTORRENT_BOOLEAN_POLICY_ENABLED
        || (state->peer_exchange_policy == TTORRENT_BOOLEAN_POLICY_INHERIT
            && !static_cast<bool>(flags & lt::torrent_flags::disable_pex));
    policy->enable_peer_exchange = bridge_bool(
        peer_exchange_plugin_enabled
        && !bridge_bool(state->peer_exchange_locked)
        && !bridge_bool(state->metadata_validation_pending)
        && peer_exchange_enabled
    );
    bool const lsd_enabled = state->lsd_policy == TTORRENT_BOOLEAN_POLICY_ENABLED
        || (state->lsd_policy == TTORRENT_BOOLEAN_POLICY_INHERIT
            && !static_cast<bool>(flags & lt::torrent_flags::disable_lsd));
    policy->enable_lsd = bridge_bool(
        !bridge_bool(state->lsd_locked)
        && !bridge_bool(state->metadata_validation_pending)
        && lsd_enabled
    );
    policy->https_tracker_policy = state->https_tracker_policy;
    policy->https_web_seed_policy = state->https_web_seed_policy;
    policy->effective_https_tracker_policy = state->https_tracker_policy == TTORRENT_HTTPS_POLICY_INHERIT
        ? static_cast<std::uint8_t>(global_tracker_policy)
        : state->https_tracker_policy;
    policy->effective_https_web_seed_policy = state->https_web_seed_policy == TTORRENT_HTTPS_POLICY_INHERIT
        ? static_cast<std::uint8_t>(global_web_seed_policy)
        : state->https_web_seed_policy;
    policy->dht_locked = state->dht_locked;
    policy->peer_exchange_locked = state->peer_exchange_locked;
    policy->lsd_locked = state->lsd_locked;
    policy->metadata_validation_pending = state->metadata_validation_pending;
    policy->allow_pre_metadata_dht = state->allow_pre_metadata_dht;
    return 0;
}

int32_t copy_torrent_options(
    TTorrentClient *client,
    char const *torrent_id,
    TTorrentOptions *options,
    char *error,
    int32_t error_capacity
)
{
    TTorrentOptionsResult const result = TorrentClientCopyTorrentOptions(
        client,
        native_token(*client, torrent_id),
        error,
        error_capacity
    );
    *options = result.options;
    return result.status;
}

int32_t copy_health(TTorrentClient *client, TTorrentBridgeHealth *health)
{
    TTorrentBridgeHealthResult const result = TorrentClientCopyHealth(client);
    *health = result.health;
    return result.status;
}

[[nodiscard]] std::vector<TTorrentSnapshot> copied_snapshots(TTorrentClient &client)
{
    int32_t required_count = 0;
    REQUIRE(client.copy_snapshots({}, &required_count) == 0);
    REQUIRE(required_count >= 0);
    std::vector<TTorrentSnapshot> snapshots(static_cast<std::size_t>(required_count));
    REQUIRE(client.copy_snapshots(snapshots, &required_count) == required_count);
    return snapshots;
}

[[nodiscard]] std::vector<TTorrentEvent> drained_events(TTorrentClient &client)
{
    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    REQUIRE(client.drain_events({}, &required_count, &available) == 0);
    REQUIRE(bridge_bool(available));
    REQUIRE(required_count >= 0);
    std::vector<TTorrentEvent> events(static_cast<std::size_t>(required_count));
    REQUIRE(client.drain_events(events, &required_count, &available) == required_count);
    REQUIRE(bridge_bool(available));
    return events;
}

[[nodiscard]] std::vector<std::uint8_t> drained_event_kinds(TTorrentClient &client)
{
    std::vector<TTorrentEvent> const events = drained_events(client);
    std::vector<std::uint8_t> kinds;
    kinds.reserve(events.size());
    for (TTorrentEvent const &event : events) {
        kinds.push_back(event.kind);
    }
    return kinds;
}

[[nodiscard]] std::vector<TTorrentPresentationMetadata> drained_presentation_metadata(
    TTorrentClient &client
)
{
    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    REQUIRE(client.drain_presentation_metadata({}, &required_count, &available) == 0);
    REQUIRE(bridge_bool(available));
    REQUIRE(required_count >= 0);
    std::vector<TTorrentPresentationMetadata> metadata(static_cast<std::size_t>(required_count));
    REQUIRE(client.drain_presentation_metadata(metadata, &required_count, &available) == required_count);
    REQUIRE(bridge_bool(available));
    return metadata;
}

[[nodiscard]] bool contains_event(
    std::span<std::uint8_t const> kinds,
    std::uint8_t const expected
) noexcept
{
    return std::ranges::find(kinds, expected) != kinds.end();
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

[[nodiscard]] TorrentIdentity *mapped_active_identity(TTorrentClient const &client, std::string const &id)
{
    std::scoped_lock io_guard(client.resume_io_lock);
    return client.active_identity_by_id.at(id);
}

[[nodiscard]] bool has_mapped_active_identity(TTorrentClient const &client, std::string const &id)
{
    std::scoped_lock io_guard(client.resume_io_lock);
    return client.active_identity_by_id.contains(id);
}

[[nodiscard]] lt::torrent_handle mapped_torrent_handle(TTorrentClient const &client, std::string const &id)
{
    std::scoped_lock io_guard(client.resume_io_lock);
    TorrentIdentity const *identity = client.active_identity_by_id.at(id);
    return client.handle_by_native_token.at(identity->token->value);
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
    TTorrentAddOptions options{
        .starts_paused = bridge_bool(false),
        .queue_priority = static_cast<uint8_t>(TTORRENT_QUEUE_PRIORITY_NORMAL),
        .enable_dht = bridge_bool(true),
        .enable_peer_exchange = bridge_bool(enable_peer_exchange),
        .enable_lsd = bridge_bool(true),
        .https_tracker_policy = TTORRENT_HTTPS_POLICY_INHERIT,
        .https_web_seed_policy = TTORRENT_HTTPS_POLICY_INHERIT,
        .effective_https_tracker_policy = TTORRENT_HTTPS_POLICY_PREFER,
        .effective_https_web_seed_policy = TTORRENT_HTTPS_POLICY_REQUIRE,
        .allow_pre_metadata_dht = bridge_bool(false),
    };
    std::string const canonical_id = next_test_canonical_id();
    std::ranges::copy(canonical_id, options.canonical_id);
    return options;
}

[[nodiscard]] TTorrentAddOptions add_options_with_id(std::string_view const canonical_id)
{
    REQUIRE(canonical_id.size() < TTORRENT_ID_CAPACITY);
    TTorrentAddOptions options = default_add_options();
    std::ranges::fill(options.canonical_id, '\0');
    std::ranges::copy(canonical_id, options.canonical_id);
    return options;
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

[[nodiscard]] std::string indexed_v1_hash(std::size_t value)
{
    constexpr std::string_view digits = "0123456789abcdef";
    std::string hash(40U, '0');
    for (std::size_t position = hash.size(); value != 0U && position != 0U; value >>= 4U) {
        --position;
        hash[position] = digits[value & 0x0fU];
    }
    return hash;
}

void write_valid_magnet_resume_entry(
    fs::path const &resume_directory,
    std::string const &save_path,
    std::size_t index
)
{
    std::string const hash = indexed_v1_hash(index);
    lt::error_code parse_error;
    lt::add_torrent_params params = lt::parse_magnet_uri(
        "magnet:?xt=urn:btih:" + hash,
        parse_error
    );
    REQUIRE_FALSE(parse_error);
    params.save_path = save_path;

    TorrentIdentity identity;
    identity.canonical_id = std::string(kCanonicalIDPrefix) + hash.substr(8U);
    std::vector<char> const encoded = encoded_resume_data(params, &identity, true);
    ResumeSaveResult const written = write_owner_only_file_checked(
        resume_directory / ("v1:" + hash + std::string(kResumeExtension)),
        std::string_view(encoded.data(), encoded.size())
    );
    REQUIRE(written.has_value());
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

[[nodiscard]] std::size_t removal_tombstone_count(fs::path const &directory)
{
    return static_cast<std::size_t>(std::ranges::count_if(
        fs::directory_iterator(directory),
        [](fs::directory_entry const &entry) {
            return is_removal_tombstone_path(entry.path());
        }
    ));
}

void check_nonregular_removal_tombstone_is_rejected(bool const use_symlink)
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const resume_directory = state_directory / "ResumeData";
    REQUIRE(fs::create_directories(resume_directory));

    fs::path const marker = resume_directory / make_removal_tombstone_filename();
    fs::path const target = temporary_directory.path() / "tombstone-target";
    if (use_symlink) {
        bridge_tests::write_text_file(target, "sentinel");
        std::error_code link_error;
        fs::create_symlink(target, marker, link_error);
        REQUIRE_FALSE(link_error);
    } else {
        REQUIRE(fs::create_directory(marker));
    }

    std::string startup_error;
    try {
        static_cast<void>(TTorrentClient(state_directory.string()));
    } catch (std::runtime_error const &error) {
        startup_error = error.what();
    }
    CHECK(startup_error == "Removal tombstone is not a regular file.");

    if (use_symlink) {
        CHECK(fs::is_symlink(fs::symlink_status(marker)));
        FileReadResult const target_bytes = read_file(target, 64U);
        REQUIRE(target_bytes.has_value());
        CHECK(std::string_view(target_bytes->data(), target_bytes->size()) == "sentinel");
    } else {
        CHECK(fs::is_directory(marker));
    }
}

void check_replaced_resume_root_remains_confined(bool const replace_with_symlink)
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const download_directory = temporary_directory.path() / "Downloads";
    REQUIRE(fs::create_directory(download_directory));

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    fs::path const resume_directory = state_directory / "ResumeData";
    fs::path const retained_resume_directory = temporary_directory.path() / "RetainedResumeData";
    fs::path const redirected_resume_directory = replace_with_symlink
        ? temporary_directory.path() / "RedirectedResumeData"
        : resume_directory;

    std::error_code rename_error;
    fs::rename(resume_directory, retained_resume_directory, rename_error);
    REQUIRE_FALSE(rename_error);
    if (replace_with_symlink) {
        REQUIRE(fs::create_directory(redirected_resume_directory));
        std::error_code link_error;
        fs::create_directory_symlink(redirected_resume_directory, resume_directory, link_error);
        REQUIRE_FALSE(link_error);
    } else {
        REQUIRE(fs::create_directory(resume_directory));
    }

    std::string const hash(40U, replace_with_symlink ? '6' : '7');
    std::string const id = "v1:" + hash;
    std::string const resume_filename = id + std::string(kResumeExtension);
    fs::path const redirected_resume = redirected_resume_directory / resume_filename;
    bridge_tests::write_text_file(redirected_resume, "redirected");

    std::string const magnet = "magnet:?xt=urn:btih:" + hash;
    TTorrentAddOptions add_options = default_add_options();
    std::array<char, TTORRENT_ID_CAPACITY> added_id{};
    std::array<char, 512> error{};
    int32_t add_outcome = TTORRENT_ADD_REJECTED;
    REQUIRE(TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        add_options,
        added_id.data(),
        static_cast<int32_t>(added_id.size()),
        &add_outcome,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);

    CHECK(file_exists(retained_resume_directory / resume_filename));
    CHECK(bridge_tests::read_text_file(redirected_resume) == "redirected");

    BridgeResult const persisted = client.persist_removal_tombstones({id});
    REQUIRE(persisted.has_value());
    CHECK(removal_tombstone_count(retained_resume_directory) == 1U);
    CHECK(removal_tombstone_count(redirected_resume_directory) == 0U);

    ResumeSaveResult const removed = client.remove_resume_files_for_ids_checked({id});
    REQUIRE(removed.has_value());
    CHECK_FALSE(file_exists(retained_resume_directory / resume_filename));
    CHECK(bridge_tests::read_text_file(redirected_resume) == "redirected");

    ResumeSaveResult const cleared = client.clear_removal_tombstones({id});
    REQUIRE(cleared.has_value());
    CHECK(removal_tombstone_count(retained_resume_directory) == 0U);
    CHECK(removal_tombstone_count(redirected_resume_directory) == 0U);
}

[[nodiscard]] int32_t cached_url_seed_count(TTorrentClient &client, std::string const &id)
{
    std::uint64_t const token = native_token(client, id);
    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    REQUIRE(client.copy_web_seeds(token, {}, &required_count, &available) == 0);
    REQUIRE(bridge_bool(available));

    std::vector<TTorrentWebSeedSnapshot> web_seeds(static_cast<std::size_t>(required_count));
    REQUIRE(client.copy_web_seeds(token, web_seeds, &required_count, &available) == required_count);

    return required_count;
}

[[nodiscard]] int32_t set_source_policy_field(
    TTorrentClient &client,
    TorrentIdentity const &identity,
    int32_t field,
    int32_t value,
    std::span<char> error,
    HTTPSPolicy const global_tracker_policy = HTTPSPolicy::prefer,
    HTTPSPolicy const global_web_seed_policy = HTTPSPolicy::require
)
{
    bool const metadata_pending = BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.metadata_validation_pending.contains(&identity)
    );
    if ((metadata_pending && field != TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT
            && field <= TTORRENT_SOURCE_POLICY_ENABLE_LSD)
        || (!metadata_pending && field == TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT)) {
        copy_error(error, "This source policy field is unavailable for the current metadata state.");
        return 2;
    }

    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    static_cast<void>(TorrentClientCopySourcePolicyStateBatch(
        &client,
        nullptr,
        0,
        &required_count,
        &available
    ));
    if (!bridge_bool(available)) {
        return 1;
    }
    std::vector<TTorrentSourcePolicyState> states(static_cast<std::size_t>(required_count));
    if (TorrentClientCopySourcePolicyStateBatch(
            &client,
            states.data(),
            required_count,
            &required_count,
            &available
        ) != required_count || !bridge_bool(available)) {
        return 1;
    }

    std::vector<TTorrentSourcePolicyApplication> applications;
    applications.reserve(states.size());
    for (TTorrentSourcePolicyState const &state : states) {
        lt::torrent_handle handle;
        bool peer_exchange_plugin_enabled = false;
        BRIDGE_WITH_CLIENT_LOCK(
            client,
            (handle = *client.find(state.native_token),
                peer_exchange_plugin_enabled = client.peer_exchange_plugin_enabled)
        );
        lt::torrent_flags_t const flags = handle.flags();
        TTorrentSourcePolicyApplication application{};
        application.native_token = state.native_token;
        application.dht_policy = state.dht_policy;
        application.peer_exchange_policy = state.peer_exchange_policy;
        application.lsd_policy = state.lsd_policy;
        application.https_tracker_policy = state.https_tracker_policy;
        application.https_web_seed_policy = state.https_web_seed_policy;
        application.effective_https_tracker_policy = state.https_tracker_policy == TTORRENT_HTTPS_POLICY_INHERIT
            ? static_cast<std::uint8_t>(global_tracker_policy)
            : state.https_tracker_policy;
        application.effective_https_web_seed_policy = state.https_web_seed_policy == TTORRENT_HTTPS_POLICY_INHERIT
            ? static_cast<std::uint8_t>(global_web_seed_policy)
            : state.https_web_seed_policy;
        application.enable_dht = bridge_bool(
            !bridge_bool(state.dht_locked)
            && !static_cast<bool>(flags & lt::torrent_flags::disable_dht)
        );
        application.enable_peer_exchange = bridge_bool(
            peer_exchange_plugin_enabled
            && !bridge_bool(state.peer_exchange_locked)
            && !bridge_bool(state.metadata_validation_pending)
            && !static_cast<bool>(flags & lt::torrent_flags::disable_pex)
        );
        application.enable_lsd = bridge_bool(
            !bridge_bool(state.lsd_locked)
            && !bridge_bool(state.metadata_validation_pending)
            && !static_cast<bool>(flags & lt::torrent_flags::disable_lsd)
        );
        application.allow_pre_metadata_dht = state.allow_pre_metadata_dht;

        if (identity.token != nullptr && identity.token->value == state.native_token) {
            bool const enabled = value != 0;
            switch (field) {
            case TTORRENT_SOURCE_POLICY_ENABLE_DHT:
                application.dht_policy = bridge_bool(state.dht_locked)
                    ? TTORRENT_BOOLEAN_POLICY_INHERIT
                    : (enabled ? TTORRENT_BOOLEAN_POLICY_ENABLED : TTORRENT_BOOLEAN_POLICY_DISABLED);
                application.enable_dht = bridge_bool(!bridge_bool(state.dht_locked) && enabled);
                break;
            case TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE:
                application.peer_exchange_policy = bridge_bool(state.peer_exchange_locked)
                    ? TTORRENT_BOOLEAN_POLICY_INHERIT
                    : (enabled ? TTORRENT_BOOLEAN_POLICY_ENABLED : TTORRENT_BOOLEAN_POLICY_DISABLED);
                application.enable_peer_exchange = bridge_bool(
                    !bridge_bool(state.peer_exchange_locked)
                    && peer_exchange_plugin_enabled
                    && enabled
                );
                break;
            case TTORRENT_SOURCE_POLICY_ENABLE_LSD:
                application.lsd_policy = bridge_bool(state.lsd_locked)
                    ? TTORRENT_BOOLEAN_POLICY_INHERIT
                    : (enabled ? TTORRENT_BOOLEAN_POLICY_ENABLED : TTORRENT_BOOLEAN_POLICY_DISABLED);
                application.enable_lsd = bridge_bool(!bridge_bool(state.lsd_locked) && enabled);
                break;
            case TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY:
                application.https_tracker_policy = static_cast<std::uint8_t>(value);
                application.effective_https_tracker_policy = value == TTORRENT_HTTPS_POLICY_INHERIT
                    ? static_cast<std::uint8_t>(global_tracker_policy)
                    : static_cast<std::uint8_t>(value);
                break;
            case TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY:
                application.https_web_seed_policy = static_cast<std::uint8_t>(value);
                application.effective_https_web_seed_policy = value == TTORRENT_HTTPS_POLICY_INHERIT
                    ? static_cast<std::uint8_t>(global_web_seed_policy)
                    : static_cast<std::uint8_t>(value);
                break;
            case TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT:
                application.allow_pre_metadata_dht = bridge_bool(
                    !bridge_bool(state.dht_locked) && enabled
                );
                application.enable_dht = application.allow_pre_metadata_dht;
                break;
            default:
                return 1;
            }
        }
        applications.push_back(application);
    }

    int32_t const result = TorrentClientApplySourcePolicyState(
        &client,
        applications.data(),
        static_cast<int32_t>(applications.size()),
        error.data(),
        static_cast<int32_t>(error.size())
    );
    if (result != 0) {
        return result;
    }
    BridgeResult const saved = client.save_resume_data_checked(
        identity.token->value,
        ResumeSaveMode::policy
    );
    return saved ? 0 : 2;
}

[[nodiscard]] lt::torrent_handle add_metadata_torrent(
    TTorrentClient &client,
    lt::add_torrent_params params,
    fs::path const &save_path,
    TorrentIdentity *&identity,
    std::optional<TTorrentStorageActivation> const activation = std::nullopt
)
{
    if (!params.ti) {
        throw std::runtime_error("Could not add metadata torrent without torrent info.");
    }
    params.info_hashes = params.ti->info_hashes();
    if (activation) {
        prepare_add_params(params, client.part_file_path(*activation), false, true);
        params.file_provider = client.make_payload_provider(*activation);
    } else {
        prepare_add_params(params, save_path.string(), false, true);
    }

    identity = client.attach_identity(params, next_test_canonical_id());
    identity->storage_activation = activation;
    REQUIRE(remember_source_policy_sources(*identity, params));
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
    TorrentIdentity *&identity,
    std::optional<TTorrentStorageActivation> const activation = std::nullopt
)
{
    lt::add_torrent_params params;
    params.ti = std::make_shared<lt::torrent_info>(info);
    return add_metadata_torrent(client, std::move(params), save_path, identity, activation);
}

[[nodiscard]] lt::torrent_handle add_metadata_torrent_with_trackers(
    TTorrentClient &client,
    lt::torrent_info const &info,
    fs::path const &save_path,
    TorrentIdentity *&identity,
    std::span<lt::announce_entry const> trackers
)
{
    lt::add_torrent_params params;
    params.ti = std::make_shared<lt::torrent_info>(info);
    params.trackers.reserve(trackers.size());
    for (lt::announce_entry const &tracker : trackers) {
        params.trackers.push_back(tracker.url);
    }
    return add_metadata_torrent(client, std::move(params), save_path, identity);
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

TEST_CASE("detached terminal cleanup returns before destroying its owned state")
{
    auto state = std::make_shared<DetachedCleanupProbeState>();
    std::promise<void> handoff_returned_promise;
    std::future<void> handoff_returned = handoff_returned_promise.get_future();
    std::jthread launcher([state, &handoff_returned_promise] {
        detach_terminal_cleanup(BlockingTerminalCleanup(state));
        handoff_returned_promise.set_value();
    });

    CHECK(
        handoff_returned.wait_for(std::chrono::seconds(2))
        == std::future_status::ready
    );
    CHECK(state->entered.wait_for(std::chrono::seconds(2)) == std::future_status::ready);
    CHECK(state->finished.wait_for(std::chrono::milliseconds(100)) == std::future_status::timeout);

    state->release_promise.set_value();
    CHECK(state->finished.wait_for(std::chrono::seconds(2)) == std::future_status::ready);
}

TEST_CASE("resume persistence retains its directory authority after root symlink replacement")
{
    check_replaced_resume_root_remains_confined(true);
}

TEST_CASE("resume persistence retains its directory authority after root directory replacement")
{
    check_replaced_resume_root_remains_confined(false);
}

TEST_CASE("resume restoration preserves entries missing storage claim authority with one aggregate error")
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
          == "Skipped restoring 2 saved torrents because brokered storage authority was missing or invalid. Resume data was preserved.");
    CHECK_FALSE(client.take_alert_error(std::span{error}));
    std::vector<std::uint8_t> const events = drained_event_kinds(client);
    CHECK(contains_event(events, TTORRENT_EVENT_ERRORS_AVAILABLE));
}

TEST_CASE("resume HTTPS policy corruption requires explicit recovery and preserves the saved records")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::array<fs::path, 3> const paths{
        write_valid_resume_entry(state_directory, temporary_directory.path().string(), 41U, 'b'),
        write_valid_resume_entry(state_directory, temporary_directory.path().string(), 42U, 'c'),
        write_valid_resume_entry(state_directory, temporary_directory.path().string(), 43U, 'd')
    };
    std::array<std::vector<char>, 3> corrupted;
    for (std::size_t index = 0U; index < paths.size(); ++index) {
        FileReadResult const original = read_file(paths[index], kMaxResumeFileBytes);
        REQUIRE(original);
        lt::error_code error;
        lt::bdecode_node const decoded = lt::bdecode(lt::span<char const>(*original), error);
        REQUIRE_FALSE(error);
        lt::entry record(decoded);
        record.dict().insert_or_assign(std::string(kHTTPSTrackerPolicyResumeKey), lt::entry(3));
        record.dict().insert_or_assign(std::string(kHTTPSWebSeedPolicyResumeKey), lt::entry(3));
        if (index == 0U) {
            record.dict().insert_or_assign(std::string(kHTTPSTrackerPolicyResumeKey), lt::entry(std::int64_t{4'294'967'297}));
        } else if (index == 1U) {
            record.dict().insert_or_assign(std::string(kHTTPSWebSeedPolicyResumeKey), lt::entry("3"));
        } else {
            record.dict().insert_or_assign(
                std::string(kHTTPSTrackerPolicyResumeKey),
                lt::entry(std::numeric_limits<std::int64_t>::min())
            );
        }
        lt::bencode(std::back_inserter(corrupted[index]), record);
        REQUIRE(write_owner_only_file_checked(paths[index], std::string_view(corrupted[index].data(), corrupted[index].size())));
    }
    write_valid_magnet_resume_entry(state_directory / "ResumeData", temporary_directory.path().string(), 12345U);
    auto parser = std::make_shared<TestOnlyResumeInfoParser>();
    for (int restart = 0; restart < 2; ++restart) {
        CAPTURE(restart);
        {
            TTorrentClient client(state_directory.string(), false, nullptr, parser);
            client.set_session_shutdown_asynchronous(false);
            client.stop_alert_worker();
            CHECK(client.session.get_torrents().size() == 1U);
            CHECK(client.session.is_paused());
            CHECK(parser->invocation_count() == 0U);
            std::array<char, 512> error{};
            REQUIRE(client.take_alert_error(error));
            CHECK(std::string(error.data())
                == "Skipped restoring 3 saved torrents because the saved HTTPS policy was invalid. Resume data was preserved."
                   " Explicit recovery is required; re-add the affected torrents with reviewed HTTPS policies.");
            CHECK_FALSE(client.take_alert_error(error));
            CHECK(contains_event(drained_event_kinds(client), TTORRENT_EVENT_ERRORS_AVAILABLE));
        }
        for (std::size_t index = 0U; index < paths.size(); ++index) {
            FileReadResult const preserved = read_file(paths[index], kMaxResumeFileBytes);
            REQUIRE(preserved);
            CHECK(*preserved == corrupted[index]);
        }
    }

    std::string const recovered_id = paths.front().stem().string();
    {
        TTorrentClient client(state_directory.string(), false, nullptr, parser);
        client.set_session_shutdown_asynchronous(false);
        client.stop_alert_worker();
        TTorrentAddOptions options = default_add_options();
        options.starts_paused = bridge_bool(true);
        options.https_tracker_policy = TTORRENT_HTTPS_POLICY_REQUIRE;
        options.https_web_seed_policy = TTORRENT_HTTPS_POLICY_REQUIRE;
        options.effective_https_tracker_policy = TTORRENT_HTTPS_POLICY_REQUIRE;
        options.effective_https_web_seed_policy = TTORRENT_HTTPS_POLICY_REQUIRE;
        std::array<char, TTORRENT_ID_CAPACITY> added_id{};
        std::array<char, 512> error{};
        int32_t outcome = TTORRENT_ADD_REJECTED;
        std::string const magnet = "magnet:?xt=urn:btih:" + recovered_id.substr(3U);
        REQUIRE(TorrentClientAddMagnet(
            &client, magnet.c_str(), options,
            added_id.data(), static_cast<int32_t>(added_id.size()), &outcome,
            error.data(), static_cast<int32_t>(error.size())
        ) == 0);
        REQUIRE(outcome == TTORRENT_ADD_COMMITTED);
        FileReadResult const recovered = read_file(paths.front(), kMaxResumeFileBytes);
        REQUIRE(recovered);
        auto const policy = https_source_policy_from_resume_data(*recovered);
        REQUIRE(policy);
        CHECK(policy->trackers == HTTPSPolicy::require);
        CHECK(policy->web_seeds == HTTPSPolicy::require);
    }
    TTorrentClient recovered(state_directory.string(), false, nullptr, parser);
    recovered.set_session_shutdown_asynchronous(false);
    recovered.stop_alert_worker();
    CHECK(recovered.session.get_torrents().size() == 2U);
    lt::torrent_handle const handle = mapped_torrent_handle(recovered, recovered_id);
    TorrentIdentity const *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK(identity->https_tracker_policy == HTTPSPolicy::require);
    CHECK(identity->https_web_seed_policy == HTTPSPolicy::require);
    for (std::size_t index = 1U; index < paths.size(); ++index) {
        FileReadResult const still_invalid = read_file(paths[index], kMaxResumeFileBytes);
        REQUIRE(still_invalid);
        CHECK(*still_invalid == corrupted[index]);
    }
    std::array<char, 512> error{};
    REQUIRE(recovered.take_alert_error(error));
    CHECK(std::string(error.data()).starts_with("Skipped restoring 2 saved torrents because the saved HTTPS policy was invalid."));
}

TEST_CASE("resume restoration preserves pre-broker metadata-less entries without activating them")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const resume_directory = state_directory / "ResumeData";
    REQUIRE(fs::create_directories(resume_directory));

    std::string const hash(40U, '6');
    lt::error_code parse_error;
    lt::add_torrent_params params = lt::parse_magnet_uri(
        "magnet:?xt=urn:btih:" + hash,
        parse_error
    );
    REQUIRE_FALSE(parse_error);
    params.save_path = temporary_directory.path().string();

    TorrentIdentity identity;
    identity.canonical_id = bridge_tests::canonical_id('6');
    std::vector<char> const encoded = encoded_resume_data(params, &identity, false);
    fs::path const resume_path = resume_directory
        / ("v1:" + hash + std::string(kResumeExtension));
    REQUIRE(write_owner_only_file_checked(
        resume_path,
        std::string_view(encoded.data(), encoded.size())
    ).has_value());

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    CHECK(client.session.get_torrents().empty());
    CHECK(file_exists(resume_path));
    std::array<char, 512> error{};
    REQUIRE(client.take_alert_error(std::span{error}));
    CHECK(std::string(error.data())
          == "Skipped restoring 1 saved torrent because brokered storage authority was missing or invalid. Resume data was preserved.");
}

TEST_CASE("add failures report an unknown outcome when durable rollback cannot be proven")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const download_directory = temporary_directory.path() / "Downloads";
    REQUIRE(fs::create_directories(download_directory));

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    constexpr mode_t kOwnerReadExecute = S_IRUSR | S_IXUSR;
    constexpr mode_t kOwnerReadWriteExecute = S_IRUSR | S_IWUSR | S_IXUSR;
    REQUIRE(::fchmod(client.resume_directory_descriptor.get(), kOwnerReadExecute) == 0);

    TTorrentAddOptions add_options = default_add_options();
    std::string const magnet = "magnet:?xt=urn:btih:" + std::string(40U, '8');
    std::array<char, TTORRENT_ID_CAPACITY> added_id{};
    std::array<char, 512> error{};
    int32_t add_outcome = TTORRENT_ADD_REJECTED;
    int32_t const result = TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        add_options,
        added_id.data(),
        static_cast<int32_t>(added_id.size()),
        &add_outcome,
        error.data(),
        static_cast<int32_t>(error.size())
    );

    REQUIRE(::fchmod(client.resume_directory_descriptor.get(), kOwnerReadWriteExecute) == 0);
    CHECK(result != 0);
    CHECK(add_outcome == TTORRENT_ADD_OUTCOME_UNKNOWN);
    CHECK(added_id.front() == '\0');
    CHECK(std::string_view(error.data()).starts_with("Torrent was added, but resume data could not be saved:"));
    CHECK(client.session.get_torrents().size() == 1U);
}

TEST_CASE("pre-accept exceptions release unpublished torrent identity admission state")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::size_t const initial_identity_count = BRIDGE_WITH_RESUME_IO_LOCK(
        client,
        client.torrent_identities.size()
    );
    std::size_t const initial_token_count = BRIDGE_WITH_RESUME_IO_LOCK(client, client.identity_tokens.size());
    lt::add_torrent_params params;

    try {
        std::scoped_lock guard(client.lock);
        TorrentIdentity *identity = client.attach_identity(params, next_test_canonical_id());
        UnpublishedIdentityGuard identity_guard(client, identity);
        CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.torrent_identities.size())
              == initial_identity_count + 1U);
        CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.identity_tokens.size()) == initial_token_count + 1U);
        throw std::runtime_error("forced pre-accept failure");
    } catch (std::runtime_error const &error) {
        CHECK(std::string_view(error.what()) == "forced pre-accept failure");
    }

    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.torrent_identities.size()) == initial_identity_count);
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.identity_tokens.size()) == initial_token_count);
}

TEST_CASE("post-accept add failures remain unknown after a durable removal request")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const download_directory = temporary_directory.path() / "Downloads";
    REQUIRE(fs::create_directories(download_directory));

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::string const hash_id = bridge_tests::v1_id('9');
    std::string const obsolete_id = bridge_tests::canonical_id('a');
    REQUIRE(client.persist_removal_tombstones({hash_id, obsolete_id}).has_value());
    // A directory at an obsolete resume filename makes cleanup fail only after
    // libtorrent has accepted the add and its new resume data has been saved.
    REQUIRE(fs::create_directory(
        state_directory / "ResumeData" / (obsolete_id + std::string(kResumeExtension))
    ));

    TTorrentAddOptions add_options = default_add_options();
    std::string const magnet = "magnet:?xt=urn:btih:" + std::string(40U, '9');
    std::array<char, TTORRENT_ID_CAPACITY> added_id{};
    std::array<char, 512> error{};
    int32_t add_outcome = TTORRENT_ADD_REJECTED;
    int32_t const result = TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        add_options,
        added_id.data(),
        static_cast<int32_t>(added_id.size()),
        &add_outcome,
        error.data(),
        static_cast<int32_t>(error.size())
    );

    CHECK(result != 0);
    CHECK(add_outcome == TTORRENT_ADD_OUTCOME_UNKNOWN);
    CHECK(added_id.front() == '\0');
    CHECK(std::string_view(error.data()).starts_with(
        "Obsolete resume data could not be removed:"
    ));
    // The rollback request succeeded, but removal itself is asynchronous and
    // therefore cannot turn a post-accept failure into a terminal rejection.
    CHECK(removal_tombstone_count(state_directory / "ResumeData") == 1U);
}

TEST_CASE("new adds require a bounded canonical identity chosen by Swift")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentAddOptions options = default_add_options();
    std::ranges::fill(options.canonical_id, 'a');
    std::string const magnet = "magnet:?xt=urn:btih:" + std::string(40U, '8');
    std::array<char, TTORRENT_ID_CAPACITY> added_id{};
    std::array<char, 512> error{};
    int32_t add_outcome = TTORRENT_ADD_OUTCOME_UNKNOWN;

    CHECK(TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        options,
        added_id.data(),
        static_cast<int32_t>(added_id.size()),
        &add_outcome,
        error.data(),
        static_cast<int32_t>(error.size())
    ) != 0);
    CHECK(add_outcome == TTORRENT_ADD_REJECTED);
    CHECK(std::string_view(error.data()) == "Invalid Swift torrent identifier.");
}

TEST_CASE("startup rejects nonregular entries in the removal tombstone namespace")
{
    SUBCASE("symlink")
    {
        check_nonregular_removal_tombstone_is_rejected(true);
    }
    SUBCASE("directory")
    {
        check_nonregular_removal_tombstone_is_rejected(false);
    }
}

TEST_CASE("stateless tombstone scanning enforces materialization budgets")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::array<std::vector<std::string>, 2> const ids{{
        {bridge_tests::v1_id('1'), bridge_tests::canonical_id('2')},
        {bridge_tests::v2_id('3'), bridge_tests::canonical_id('4')},
    }};
    for (std::vector<std::string> const &entry_ids : ids) {
        ResumeSaveResult const written = write_owner_only_file_at_checked(
            client.resume_directory_descriptor.get(),
            make_removal_tombstone_filename(),
            tombstone_payload(entry_ids)
        );
        REQUIRE(written.has_value());
    }

    std::scoped_lock io_guard(client.resume_io_lock);
    TombstoneEntriesResult const too_many_entries = client.scan_removal_tombstone_entries_locked(
        RemovalTombstoneIndexLimits{.entry_count = 1U, .id_membership_count = 4U}
    );
    REQUIRE_FALSE(too_many_entries.has_value());
    CHECK(too_many_entries.error() == "Removal tombstone index contains too many entries.");

    TombstoneEntriesResult const too_many_memberships = client.scan_removal_tombstone_entries_locked(
        RemovalTombstoneIndexLimits{.entry_count = 2U, .id_membership_count = 3U}
    );
    REQUIRE_FALSE(too_many_memberships.has_value());
    CHECK(too_many_memberships.error()
        == "Removal tombstone index contains too many identifier references.");

    TombstoneEntriesResult const accepted = client.scan_removal_tombstone_entries_locked(
        RemovalTombstoneIndexLimits{.entry_count = 2U, .id_membership_count = 4U}
    );
    REQUIRE(accepted.has_value());
    CHECK(accepted->size() == 2U);
}

TEST_CASE("removal tombstone overlap lookups use validated stateless scans")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const resume_directory = temporary_directory.path() / "State" / "ResumeData";
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    REQUIRE(BRIDGE_WITH_RESUME_IO_LOCK(client, client.removal_tombstone_directory_scan_count) == 1U);
    std::string const first = bridge_tests::v1_id('1');
    std::string const second = bridge_tests::canonical_id('2');
    std::string const unrelated = bridge_tests::v2_id('3');
    REQUIRE(client.persist_removal_tombstones({first, second}).has_value());

    for (int index = 0; index < 64; ++index) {
        bridge_tests::write_text_file(
            resume_directory / ("unrelated-" + std::to_string(index)),
            "unrelated"
        );
    }

    for (int attempt = 0; attempt < 128; ++attempt) {
        ResumeIDListResult const matched = client.tombstone_ids_overlapping({first});
        REQUIRE(matched.has_value());
        CHECK(*matched == std::vector<std::string>{first, second});
        ResumeIDListResult const missed = client.tombstone_ids_overlapping({unrelated});
        REQUIRE(missed.has_value());
        CHECK(missed->empty());
    }
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.removal_tombstone_directory_scan_count) > 1U);

    REQUIRE(client.clear_removal_tombstones({first, second}).has_value());
    ResumeIDListResult const cleared = client.tombstone_ids_overlapping({first});
    REQUIRE(cleared.has_value());
    CHECK(cleared->empty());
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.removal_tombstone_directory_scan_count) > 1U);
}

TEST_CASE("removal tombstone scans reflect only durable filesystem outcomes")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const resume_directory = temporary_directory.path() / "State" / "ResumeData";
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::string const id = bridge_tests::v1_id('4');
    constexpr mode_t kOwnerReadExecute = S_IRUSR | S_IXUSR;
    constexpr mode_t kOwnerReadWriteExecute = S_IRUSR | S_IWUSR | S_IXUSR;
    REQUIRE(::fchmod(client.resume_directory_descriptor.get(), kOwnerReadExecute) == 0);
    BridgeResult const failed_commit = client.persist_removal_tombstones({id});
    REQUIRE(::fchmod(client.resume_directory_descriptor.get(), kOwnerReadWriteExecute) == 0);
    REQUIRE_FALSE(failed_commit.has_value());
    ResumeIDListResult const absent_after_failed_commit = client.tombstone_ids_overlapping({id});
    REQUIRE(absent_after_failed_commit.has_value());
    REQUIRE(absent_after_failed_commit->empty());

    REQUIRE(client.persist_removal_tombstones({id}).has_value());
    TombstoneEntriesResult const entries = BRIDGE_WITH_RESUME_IO_LOCK(
        client,
        client.removal_tombstone_entries_locked()
    );
    REQUIRE(entries.has_value());
    REQUIRE(entries->size() == 1U);
    std::string const filename = entries->front().filename;
    fs::path const marker = resume_directory / filename;
    REQUIRE(fs::remove(marker));
    REQUIRE(fs::create_directory(marker));

    ResumeSaveResult const failed_clear = client.clear_removal_tombstones({id});
    REQUIRE_FALSE(failed_clear.has_value());
    ResumeIDListResult const invalid_on_disk = client.tombstone_ids_overlapping({id});
    REQUIRE_FALSE(invalid_on_disk.has_value());

    REQUIRE(fs::remove(marker));
    REQUIRE(client.clear_removal_tombstones({id}).has_value());
    ResumeIDListResult const absent_after_clear = client.tombstone_ids_overlapping({id});
    REQUIRE(absent_after_clear.has_value());
    CHECK(absent_after_clear->empty());
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
        wake = client.publish_changes_locked(kChangeErrors);
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

TEST_CASE("draining events with an undersized buffer does not consume them")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    static_cast<void>(drained_event_kinds(client));
    {
        std::scoped_lock guard(client.lock);
        static_cast<void>(client.publish_changes_locked(kChangeTorrents | kChangeTrackers));
    }

    std::vector<TTorrentEvent> undersized(1U);
    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    CHECK(client.drain_events(undersized, &required_count, &available) == 0);
    CHECK(required_count == 2);
    CHECK(bridge_bool(available));

    std::vector<std::uint8_t> const events = drained_event_kinds(client);
    REQUIRE(events.size() == 2U);
    CHECK(events[0] == TTORRENT_EVENT_TORRENTS_CHANGED);
    CHECK(events[1] == TTORRENT_EVENT_TRACKERS_CHANGED);
}

TEST_CASE("event pressure collapses to a bounded resync marker")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    static_cast<void>(drained_event_kinds(client));
    {
        std::scoped_lock guard(client.lock);
        for (int32_t index = 0; index <= TTORRENT_MAX_EVENT_COUNT; ++index) {
            static_cast<void>(client.publish_changes_locked(kChangeTorrents));
        }
    }

    std::vector<std::uint8_t> const events = drained_event_kinds(client);
    REQUIRE(events.size() == 1U);
    CHECK(events.front() == TTORRENT_EVENT_RESYNC_REQUIRED);
}

TEST_CASE("critical fault handoff retains a bounded slot under event pressure")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    static_cast<void>(drained_events(client));
    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(client.lock);
        client.pending_events.assign(
            static_cast<std::size_t>(TTORRENT_MAX_EVENT_COUNT),
            TTorrentEvent{
                .native_token = 0U,
                .kind = TTORRENT_EVENT_TORRENTS_CHANGED,
                .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                .critical_faults = 0U,
            }
        );
        DirtyMask const changes = client.record_critical_fault_locked(
            TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY
        );
        wake = client.publish_changes_locked(changes);
    }
    client.invoke_wake_callback(wake);

    std::vector<TTorrentEvent> const events = drained_events(client);
    CHECK(events.size() <= static_cast<std::size_t>(TTORRENT_MAX_EVENT_COUNT));
    CHECK(std::ranges::any_of(events, [](TTorrentEvent const &event) {
        return event.kind == TTORRENT_EVENT_CRITICAL_FAULT
            && event.critical_faults == TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY;
    }));
    CHECK(std::ranges::any_of(events, [](TTorrentEvent const &event) {
        return event.kind == TTORRENT_EVENT_RESYNC_REQUIRED;
    }));
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

    static_cast<void>(drained_event_kinds(client));
    std::atomic_uint64_t wake_count = 0;
    client.set_wake_callback(counting_wake_callback, &wake_count);

    std::string const long_error(1024U, 'x');
    CHECK(client.record_alert_worker_failure(long_error) == 1U);

    TTorrentBridgeHealth health{};
    REQUIRE(copy_health(&client, &health) == 1);
    CHECK(health.total_alert_worker_failures == 1U);
    CHECK(health.consecutive_alert_worker_failures == 1U);
    CHECK(bridge_bool(health.alert_worker_degraded));
    CHECK(std::string(health.last_alert_worker_error).size()
          == sizeof(health.last_alert_worker_error) - 1U);

    std::vector<std::uint8_t> events = drained_event_kinds(client);
    CHECK(contains_event(events, TTORRENT_EVENT_HEALTH_CHANGED));
    CHECK(contains_event(events, TTORRENT_EVENT_ERRORS_AVAILABLE));

    std::array<char, 1024> alert_error{};
    REQUIRE(client.take_alert_error(std::span{alert_error}));
    std::string const queued_error(alert_error.data());
    CHECK(queued_error.starts_with("Libtorrent alert worker failed and will retry: "));
    CHECK(queued_error.size() <= sizeof(health.last_alert_worker_error) - 1U);

    CHECK(client.record_alert_worker_failure("second failure") == 2U);
    static_cast<void>(drained_event_kinds(client));
    client.record_alert_worker_recovery();
    events = drained_event_kinds(client);
    REQUIRE(events.size() == 1U);
    CHECK(events.front() == TTORRENT_EVENT_HEALTH_CHANGED);
    REQUIRE(copy_health(&client, &health) == 1);
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
    fs::path const tombstone_path = resume_directory / make_removal_tombstone_filename();

    bridge_tests::write_text_file(resume_path, "resume");
    bridge_tests::write_text_file(simple_temp_path, "temp");
    bridge_tests::write_text_file(unique_temp_path, "temp");
    ResumeSaveResult const tombstone = write_owner_only_file_checked(
        tombstone_path,
        tombstone_payload({id})
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
        std::scoped_lock guard(client.lock);
        std::scoped_lock io_guard(client.resume_io_lock);
        client.retire_identity_if_unreferenced_locked(identity);
    }

    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.torrent_identities.empty()));
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.retiring_torrent_identities.size()) == 1U);
    CHECK(identity_from_client_data(userdata) == nullptr);
    {
        [[maybe_unused]] IdentityReclamationBlock reclamation_block(client);
        client.reclaim_retired_identities();
        CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.retiring_torrent_identities.size()) == 1U);
    }
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.retiring_torrent_identities.empty()));
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.identity_tokens.size()) == 1U);
    CHECK(token->active_identity.load(std::memory_order_acquire) == nullptr);
}

TEST_CASE("torrent identity creation enforces the snapshot admission limit")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    BRIDGE_WITH_RESUME_IO_LOCK(
        client,
        client.torrent_identities.reserve(static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT))
    );
    for (int32_t index = 0; index < TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT; ++index) {
        BRIDGE_WITH_RESUME_IO_LOCK(
            client,
            client.torrent_identities.push_back(std::make_unique<TorrentIdentity>())
        );
    }

    BridgeResult const admission = BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.ensure_torrent_admission_available(7)
    );
    REQUIRE_FALSE(admission);
    CHECK(admission.error().code == 7);
    CHECK(admission.error().message == "The torrent limit has been reached.");
    CHECK_THROWS_AS(
        static_cast<void>(client.make_identity(next_test_canonical_id())),
        std::length_error
    );

    fs::path const preserved_resume =
        state_directory / "ResumeData" / (bridge_tests::v1_id('a') + std::string(kResumeExtension));
    bridge_tests::write_text_file(preserved_resume, "preserve at capacity");
    client.load_resume_data();
    CHECK(file_exists(preserved_resume));
    std::array<char, 512> error{};
    REQUIRE(client.take_alert_error(std::span{error}));
    CHECK(bridge_tests::string_from_c_buffer(std::span{error})
          == "Resume restore stopped: The torrent limit has been reached. Remaining resume data was preserved.");
    std::vector<std::uint8_t> const events = drained_event_kinds(client);
    CHECK(contains_event(events, TTORRENT_EVENT_ERRORS_AVAILABLE));
    BRIDGE_WITH_RESUME_IO_LOCK(client, client.torrent_identities.clear());
}

TEST_CASE("resume restore drains synchronous add alerts before the queue can overflow")
{
    constexpr int kTestAlertQueueSize = 256;
    constexpr std::size_t kRestoreCount = kSynchronousAddAlertDrainInterval + 1U;

    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::string const save_path = temporary_directory.path().lexically_normal().string();
    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();
    client.pump_alerts();

    lt::settings_pack queue_settings;
    queue_settings.set_int(lt::settings_pack::alert_queue_size, kTestAlertQueueSize);
    client.session.apply_settings(queue_settings);
    REQUIRE(client.session.get_settings().get_int(lt::settings_pack::alert_queue_size)
            == kTestAlertQueueSize);

    for (std::size_t index = 1U; index <= kRestoreCount; ++index) {
        write_valid_magnet_resume_entry(state_directory / "ResumeData", save_path, index);
    }
    client.load_resume_data();

    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.torrent_identities.size()) == kRestoreCount);
    std::array<char, 512> alert_error{};
    CHECK_FALSE(client.take_alert_error(std::span{alert_error}));
}

TEST_CASE("live magnet bursts opportunistically drain synchronous add alerts")
{
    constexpr int kTestAlertQueueSize = 512;
    constexpr std::size_t kAddCount = (2U * kSynchronousAddAlertDrainInterval) + 1U;

    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::string const save_path = temporary_directory.path().lexically_normal().string();
    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();
    client.pump_alerts();

    lt::settings_pack queue_settings;
    queue_settings.set_int(lt::settings_pack::alert_queue_size, kTestAlertQueueSize);
    client.session.apply_settings(queue_settings);
    REQUIRE(client.session.get_settings().get_int(lt::settings_pack::alert_queue_size)
            == kTestAlertQueueSize);

    std::array<char, TTORRENT_ID_CAPACITY> added_id{};
    std::array<char, 512> error{};
    for (std::size_t index = 1U; index <= kAddCount; ++index) {
        TTorrentAddOptions add_options = default_add_options();
        add_options.starts_paused = bridge_bool(true);
        std::string const magnet = "magnet:?xt=urn:btih:" + indexed_v1_hash(index);
        int32_t add_outcome = TTORRENT_ADD_REJECTED;
        REQUIRE(TorrentClientAddMagnet(
            &client,
            magnet.c_str(),
            add_options,
            added_id.data(),
            static_cast<int32_t>(added_id.size()),
            &add_outcome,
            error.data(),
            static_cast<int32_t>(error.size())
        ) == 0);
        REQUIRE(add_outcome == TTORRENT_ADD_COMMITTED);
    }
    client.pump_alerts();

    CHECK(copied_snapshots(client).size() == kAddCount);
    CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.synchronous_adds_since_alert_drain) == 0U);
    CHECK_FALSE(client.take_alert_error(std::span{error}));
}

TEST_CASE("critical identity faults synchronously contain and emit typed handoff state")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    TTorrentSessionSettings settings = unblocked_session_settings();
    std::array<char, 512> error{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    REQUIRE_FALSE(client.session.is_paused());
    static_cast<void>(drained_events(client));

    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(client.lock);
        DirtyMask const changes = client.record_critical_fault_locked(
            TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY
        );
        wake = client.publish_changes_locked(changes);
    }
    client.invoke_wake_callback(wake);

    lt::settings_pack const contained = client.session.get_settings();
    CHECK(contained.get_str(lt::settings_pack::listen_interfaces).empty());
    CHECK(contained.get_str(lt::settings_pack::outgoing_interfaces).empty());
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_outgoing_tcp));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_incoming_tcp));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_outgoing_utp));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_incoming_utp));
    CHECK(client.session.is_paused());
    CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.requested_network_blocked));

    std::vector<TTorrentEvent> const events = drained_events(client);
    auto const fault = std::ranges::find_if(events, [](TTorrentEvent const &event) {
        return event.kind == TTORRENT_EVENT_CRITICAL_FAULT;
    });
    REQUIRE(fault != events.end());
    CHECK(fault->native_token == 0U);
    CHECK(fault->resume_save_mode == TTORRENT_RESUME_SAVE_ROUTINE);
    CHECK(fault->critical_faults == TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY);

    // Native owns detection, containment, and the transient typed handoff only.
    // Swift owns the durable admission/restart lifecycle decision after drain.
    BridgeResult const admission = BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.ensure_torrent_admission_available(6)
    );
    CHECK(admission.has_value());
}

TEST_CASE("canonical torrent identity reservations reject duplicates and release exact IDs")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::string const requested_id = bridge_tests::canonical_id('c');
    TorrentIdentity *first = client.make_identity(requested_id);
    REQUIRE(first != nullptr);
    CHECK(first->canonical_id == requested_id);
    CHECK_THROWS_WITH_AS(
        static_cast<void>(client.make_identity(requested_id)),
        "The requested torrent identifier is already in use.",
        std::runtime_error
    );
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.canonical_ids_in_use.size()) == 1U);
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.canonical_ids_in_use.contains(first->canonical_id)));

    {
        std::scoped_lock guard(client.lock);
        std::scoped_lock io_guard(client.resume_io_lock);
        client.retire_identity_if_unreferenced_locked(first);
    }
    CHECK_FALSE(BRIDGE_WITH_RESUME_IO_LOCK(client, client.canonical_ids_in_use.contains(requested_id)));

    TorrentIdentity *replacement = client.make_identity(requested_id);
    REQUIRE(replacement != nullptr);
    CHECK(replacement->canonical_id == requested_id);
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.canonical_ids_in_use.contains(requested_id)));
}

TEST_CASE("conflict removals retain admission authority until their exact removed alert")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::shared_ptr<lt::torrent_info const> const duplicate_info = make_queue_torrent_info(101U);
    std::shared_ptr<lt::torrent_info const> const survivor_info = make_queue_torrent_info(102U);
    TorrentIdentity *duplicate_identity = nullptr;
    TorrentIdentity *survivor_identity = nullptr;
    lt::torrent_handle duplicate = add_metadata_torrent(
        client,
        *duplicate_info,
        temporary_directory.path(),
        duplicate_identity
    );
    lt::torrent_handle survivor = add_metadata_torrent(
        client,
        *survivor_info,
        temporary_directory.path(),
        survivor_identity
    );
    REQUIRE(duplicate_identity != nullptr);
    REQUIRE(survivor_identity != nullptr);
    REQUIRE(duplicate_identity->token != nullptr);

    lt::info_hash_t const duplicate_hashes = duplicate.info_hashes();
    std::vector<std::string> const duplicate_ids = hash_keys(duplicate_hashes);
    REQUIRE_FALSE(duplicate_ids.empty());
    client.mark_active(duplicate_hashes, survivor, survivor_identity);
    for (std::string const &id : duplicate_ids) {
        REQUIRE(mapped_active_identity(client, id) == survivor_identity);
        REQUIRE(identity_from_handle(mapped_torrent_handle(client, id)) == survivor_identity);
    }

    {
        std::scoped_lock io_guard(client.resume_io_lock);
        client.torrent_identities.reserve(
            static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT)
        );
        while (client.torrent_identities.size()
               < static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT)) {
            client.torrent_identities.push_back(std::make_unique<TorrentIdentity>());
        }
    }
    REQUIRE_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.ensure_torrent_admission_available(9).has_value()
    ));

    TorrentIdentityToken *const duplicate_token = duplicate_identity->token;
    lt::client_data_t const duplicate_userdata(duplicate_token);
    REQUIRE(identity_from_client_data(duplicate_userdata) == duplicate_identity);
    client.session.remove_torrent(duplicate);
    BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.mark_conflict_remove_requested(duplicate_hashes, duplicate_identity)
    );

    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.torrent_identities.size())
          == static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT));
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(
        client,
        client.canonical_ids_in_use.contains(duplicate_identity->canonical_id)
    ));
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(
        client,
        client.unidentified_removing_identities.contains(duplicate_identity)
    ));
    CHECK(client.accepts_removed_alert(duplicate_hashes, duplicate_identity));
    for (std::string const &id : duplicate_ids) {
        CHECK(mapped_active_identity(client, id) == survivor_identity);
        CHECK(identity_from_handle(mapped_torrent_handle(client, id)) == survivor_identity);
    }

    {
        std::scoped_lock io_guard(client.resume_io_lock);
        for (std::string const &id : duplicate_ids) {
            client.active_identity_by_id.erase(id);
        }
    }
    std::string const duplicate_canonical_id = duplicate_identity->canonical_id;
    BRIDGE_WITH_CLIENT_LOCK(client, client.finalize_removed(duplicate_hashes, duplicate_identity));

    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.torrent_identities.size())
          == static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT) - 1U);
    CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.ensure_torrent_admission_available(9).has_value()));
    CHECK_FALSE(BRIDGE_WITH_RESUME_IO_LOCK(
        client,
        client.canonical_ids_in_use.contains(duplicate_canonical_id)
    ));
    CHECK_FALSE(BRIDGE_WITH_RESUME_IO_LOCK(
        client,
        client.unidentified_removing_identities.contains(duplicate_identity)
    ));
    CHECK(identity_from_client_data(duplicate_userdata) == nullptr);
    for (std::string const &id : duplicate_ids) {
        CHECK_FALSE(has_mapped_active_identity(client, id));
    }
    std::optional<lt::torrent_handle> const surviving_handle = client.find(
        survivor_identity->token->value
    );
    REQUIRE(surviving_handle.has_value());
    CHECK(identity_from_handle(*surviving_handle) == survivor_identity);
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
            std::scoped_lock guard(client.lock);
            std::scoped_lock io_guard(client.resume_io_lock);
            client.retire_identity_if_unreferenced_locked(identity);
        }
        client.reclaim_retired_identities();
    }

    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.torrent_identities.empty()));
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.retiring_torrent_identities.empty()));
    CHECK(BRIDGE_WITH_RESUME_IO_LOCK(client, client.identity_tokens.size()) == kMaxTorrentIdentityTokenCount);
    BridgeResult const admission = BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.ensure_torrent_admission_available(8)
    );
    REQUIRE_FALSE(admission);
    CHECK(admission.error().code == 8);
    CHECK(admission.error().message
          == "The torrent identity safety limit for this app session has been reached. Restart the app before adding more torrents.");
    CHECK_THROWS_AS(static_cast<void>(client.make_identity(reusable_id)), std::length_error);

    fs::path const preserved_resume =
        temporary_directory.path() / "State" / "ResumeData"
            / (bridge_tests::v1_id('b') + std::string(kResumeExtension));
    bridge_tests::write_text_file(preserved_resume, "preserve after churn");
    client.load_resume_data();
    CHECK(file_exists(preserved_resume));
    std::array<char, 512> error{};
    REQUIRE(client.take_alert_error(std::span{error}));
    CHECK(bridge_tests::string_from_c_buffer(std::span{error})
          == "Resume restore stopped: The torrent identity safety limit for this app session has been reached. Restart the app before adding more torrents. Remaining resume data was preserved.");
}

TEST_CASE("requested resume metadata stages one owned presentation handoff")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TorrentIdentity *identity = client.make_identity(bridge_tests::canonical_id('4'));
    REQUIRE(identity != nullptr);
    lt::add_torrent_params params;
    params.comment = "Metadata from resume data";
    params.creation_date = 12'345;

    BRIDGE_WITH_CLIENT_LOCK(
        client,
        identity->presentation_metadata_refresh_requested = true
    );
    CHECK(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.capture_requested_presentation_metadata(identity, params)
    )
          == kChangeTorrents);
    std::optional<TTorrentPresentationMetadata> const pending = BRIDGE_WITH_CLIENT_LOCK(
        client,
        identity->pending_presentation_metadata
            ? std::optional(*identity->pending_presentation_metadata)
            : std::nullopt
    );
    REQUIRE(pending.has_value());
    CHECK(pending->native_token == identity->token->value);
    CHECK(std::string(pending->comment) == "Metadata from resume data");
    CHECK(pending->created_time == 12'345);
    CHECK(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.capture_requested_presentation_metadata(identity, params)
    ) == 0U);
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

        auto resume_info_parser = std::make_shared<TestOnlyResumeInfoParser>();
        TTorrentClient client(
            state_directory.string(),
            true,
            {},
            resume_info_parser
        );
        client.set_session_shutdown_asynchronous(false);

        CHECK(resume_info_parser->invocation_count() == 1U);
        CHECK(client.session.get_torrents().empty());
        CHECK_FALSE(file_exists(resume_path));

        ResumeSaveResult const rejected = client.write_resume_data_checked(
            params,
            nullptr,
            ResumePolicySnapshot{},
            {}
        );
        REQUIRE_FALSE(rejected);
        CHECK(rejected.error() == "The torrent contains a file path outside its download folder.");
    }
}

TEST_CASE("resume metadata flows through add, Swift-directed save, and reload")
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
    lt::add_torrent_params const claim_params = bridge_tests::load_torrent_params(
        torrent_data,
        "metadata lifecycle claim"
    );
    bridge_tests::TestPayloadBroker broker(temporary_directory.path() / "Payload");
    TTorrentStorageActivation const activation = broker.register_torrent(claim_params);

    std::string canonical_id;
    {
        TTorrentClient client(state_directory.string(), true, broker.context());
        client.set_session_shutdown_asynchronous(false);

        TTorrentAddOptions add_options = default_add_options();
        char added_id[TTORRENT_ID_CAPACITY]{};
        char error[512]{};
        int32_t add_outcome = TTORRENT_ADD_REJECTED;
        REQUIRE(add_test_torrent(
            &client,
            claim_params,
            activation,
            add_options,
            added_id,
            static_cast<int32_t>(sizeof(added_id)),
            &add_outcome,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);

        canonical_id = added_id;
        std::optional<lt::torrent_handle> const handle = client.find(native_token(client, canonical_id));
        REQUIRE(handle.has_value());
        TorrentIdentity *identity = identity_from_handle(*handle);
        REQUIRE(identity != nullptr);
        std::vector<TTorrentPresentationMetadata> const initial_metadata =
            drained_presentation_metadata(client);
        REQUIRE(initial_metadata.size() == 1U);
        CHECK(initial_metadata.front().native_token == identity->token->value);
        CHECK(std::string(initial_metadata.front().comment) == expected_comment);
        CHECK(initial_metadata.front().created_time == expected_creation_date);
        CHECK(drained_presentation_metadata(client).empty());

        BRIDGE_WITH_CLIENT_LOCK(
            client,
            identity->presentation_metadata_refresh_requested = true
        );
        REQUIRE(client.save_resume_data_checked(
            native_token(client, canonical_id),
            ResumeSaveMode::policy
        ));
        std::vector<TTorrentPresentationMetadata> const refreshed_metadata =
            drained_presentation_metadata(client);
        REQUIRE(refreshed_metadata.size() == 1U);
        CHECK(refreshed_metadata.front().native_token == identity->token->value);
        CHECK(std::string(refreshed_metadata.front().comment) == expected_comment);
        CHECK(refreshed_metadata.front().created_time == expected_creation_date);
    }

    auto resume_info_parser = std::make_shared<TestOnlyResumeInfoParser>();
    TTorrentClient reloaded(
        state_directory.string(),
        true,
        broker.context(),
        resume_info_parser
    );
    reloaded.set_session_shutdown_asynchronous(false);
    CHECK(resume_info_parser->invocation_count() == 1U);
    std::vector<TTorrentPresentationMetadata> const reloaded_metadata =
        drained_presentation_metadata(reloaded);
    REQUIRE(reloaded_metadata.size() == 1U);
    CHECK(std::string(reloaded_metadata.front().comment) == expected_comment);
    CHECK(reloaded_metadata.front().created_time == expected_creation_date);
}

TEST_CASE("exact torrent metadata can be copied without re-encoding")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    std::vector<lt::create_file_entry> files;
    files.emplace_back("exact-info.bin", 4);
    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(47U));
    std::vector<char> const torrent_data = creator.generate_buf();
    lt::add_torrent_params const claim_params = bridge_tests::load_torrent_params(
        torrent_data,
        "exact metadata claim"
    );
    bridge_tests::TestPayloadBroker broker(temporary_directory.path() / "Payload");
    TTorrentStorageActivation const activation = broker.register_torrent(claim_params);

    TTorrentClient client((temporary_directory.path() / "State").string(), true, broker.context());
    client.set_session_shutdown_asynchronous(false);
    char added_id[TTORRENT_ID_CAPACITY]{};
    char error[512]{};
    int32_t add_outcome = TTORRENT_ADD_REJECTED;
    REQUIRE(add_test_torrent(
        &client,
        claim_params,
        activation,
        default_add_options(),
        added_id,
        static_cast<int32_t>(sizeof(added_id)),
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    lt::span<char const> const expected = claim_params.ti->info_section();
    int32_t required_count = -1;
    std::uint8_t available = bridge_bool(false);
    CHECK(TorrentClientCopyTorrentMetadata(
        &client,
        added_id,
        nullptr,
        0,
        &required_count,
        &available
    ) == 0);
    REQUIRE(bridge_bool(available));
    REQUIRE(required_count == expected.size());

    std::vector<std::uint8_t> copied(static_cast<std::size_t>(required_count));
    CHECK(TorrentClientCopyTorrentMetadata(
        &client,
        added_id,
        copied.data(),
        static_cast<int32_t>(copied.size()),
        &required_count,
        &available
    ) == required_count);
    std::vector<std::uint8_t> expected_bytes;
    expected_bytes.reserve(static_cast<std::size_t>(expected.size()));
    std::ranges::transform(
        expected,
        std::back_inserter(expected_bytes),
        [](char const byte) { return static_cast<std::uint8_t>(byte); }
    );
    CHECK(copied == expected_bytes);

    required_count = -1;
    available = bridge_bool(true);
    CHECK(::TorrentClientCopyTorrentMetadata(
        &client,
        std::numeric_limits<std::uint64_t>::max(),
        nullptr,
        0,
        &required_count,
        &available
    ) == 0);
    CHECK_FALSE(bridge_bool(available));
    CHECK(required_count == 0);
}

TEST_CASE("known torrent activation hands off an identity only from removal")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    std::vector<lt::create_file_entry> files;
    files.emplace_back("identity-handoff.bin", 4);
    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(53U));
    std::vector<char> const torrent_data = creator.generate_buf();
    lt::add_torrent_params const claim_params = bridge_tests::load_torrent_params(
        torrent_data,
        "identity handoff claim"
    );
    bridge_tests::TestPayloadBroker broker(temporary_directory.path() / "Payload");
    TTorrentStorageActivation const first_activation = broker.register_torrent(claim_params);
    TTorrentStorageActivation second_activation = broker.register_torrent(claim_params);

    TTorrentClient client((temporary_directory.path() / "State").string(), true, broker.context());
    client.set_session_shutdown_asynchronous(false);
    char first_id[TTORRENT_ID_CAPACITY]{};
    char error[512]{};
    int32_t add_outcome = TTORRENT_ADD_REJECTED;
    REQUIRE(add_test_torrent(
        &client,
        claim_params,
        first_activation,
        default_add_options(),
        first_id,
        static_cast<int32_t>(sizeof(first_id)),
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    std::string const canonical_id(first_id);
    REQUIRE(canonical_id.size() == std::size(second_activation.preserved_torrent_id));
    std::ranges::transform(
        canonical_id,
        second_activation.preserved_torrent_id,
        [](char const byte) { return static_cast<std::uint8_t>(byte); }
    );

    char duplicate_id[TTORRENT_ID_CAPACITY]{};
    add_outcome = TTORRENT_ADD_REJECTED;
    CHECK(add_test_torrent(
        &client,
        claim_params,
        second_activation,
        add_options_with_id(canonical_id),
        duplicate_id,
        static_cast<int32_t>(sizeof(duplicate_id)),
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) != 0);
    CHECK(add_outcome == TTORRENT_ADD_REJECTED);

    std::uint8_t removal_committed = bridge_bool(false);
    REQUIRE(TorrentClientRemove(
        &client,
        first_id,
        &removal_committed,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(bridge_bool(removal_committed));

    char promoted_id[TTORRENT_ID_CAPACITY]{};
    add_outcome = TTORRENT_ADD_REJECTED;
    REQUIRE(add_test_torrent(
        &client,
        claim_params,
        second_activation,
        add_options_with_id(canonical_id),
        promoted_id,
        static_cast<int32_t>(sizeof(promoted_id)),
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(std::string(promoted_id) == canonical_id);
    std::optional<lt::torrent_handle> const promoted = client.find(native_token(client, promoted_id));
    REQUIRE(promoted.has_value());
    TorrentIdentity const *const promoted_identity = identity_from_handle(*promoted);
    REQUIRE(promoted_identity != nullptr);
    CHECK(promoted_identity->queue_rank == kUnsetQueueRank);
    CHECK(static_cast<int>(promoted->queue_position()) == 0);
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

    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    REQUIRE(client.copy_files(identity->token->value, {}, &required_count, &available) == 0);
    REQUIRE(bridge_bool(available));
    REQUIRE(required_count == 1);

    std::array<TTorrentFileSnapshot, 1> files{};
    REQUIRE(client.copy_files(identity->token->value, files, &required_count, &available) == 1);
    CHECK(std::string(files.front().path) == "renamed-public.bin");
}

TEST_CASE("tracker host materialization caps rows and backfills its deterministic prefix")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    constexpr std::size_t torrent_count = 11U;
    for (std::size_t torrent = 0; torrent < torrent_count; ++torrent) {
        std::shared_ptr<lt::torrent_info const> const info = make_queue_torrent_info(
            static_cast<unsigned char>(60U + torrent)
        );
        std::vector<lt::announce_entry> trackers;
        trackers.reserve(static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT));
        for (int32_t tracker = 0; tracker < TTORRENT_MAX_TRACKER_COUNT; ++tracker) {
            trackers.emplace_back(
                "https://tracker-" + std::to_string(torrent) + "-" + std::to_string(tracker)
                + ".example/announce"
            );
        }

        TorrentIdentity *identity = nullptr;
        lt::torrent_handle handle = add_metadata_torrent_with_trackers(
            client,
            *info,
            temporary_directory.path(),
            identity,
            trackers
        );
        REQUIRE(identity != nullptr);
        {
            std::scoped_lock guard(client.lock);
            static_cast<void>(client.observe_torrent_handle(handle));
        }
    }

    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    CHECK(client.copy_tracker_hosts({}, &required_count, &available) == 0);
    CHECK(bridge_bool(available));
    CHECK(required_count == TTORRENT_MAX_TRACKER_HOST_ROW_COUNT);
}

TEST_CASE("tracker detail changes invalidate Swift-owned tracker host state")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::shared_ptr<lt::torrent_info const> const info = make_queue_torrent_info(90U);
    std::vector<lt::announce_entry> const trackers{
        lt::announce_entry{"https://first.example/announce"},
    };
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent_with_trackers(
        client,
        *info,
        temporary_directory.path(),
        identity,
        trackers
    );
    REQUIRE(identity != nullptr);

    std::scoped_lock guard(client.lock);
    static_cast<void>(client.observe_torrent_handle(handle));
    DirtyMask const changes = client.observe_trackers(handle);
    CHECK((changes & kChangeTrackers) != 0U);
    CHECK((changes & kChangeTrackerHosts) != 0U);
}

TEST_CASE("tracker host extraction returns owned rows for every snapshot")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::shared_ptr<lt::torrent_info const> const first_info = make_queue_torrent_info(92U);
    std::shared_ptr<lt::torrent_info const> const second_info = make_queue_torrent_info(93U);
    std::vector<lt::announce_entry> const first_trackers{
        lt::announce_entry{"https://first.example/announce"},
    };
    std::vector<lt::announce_entry> const second_trackers{
        lt::announce_entry{"https://second.example/announce"},
    };
    TorrentIdentity *first_identity = nullptr;
    TorrentIdentity *second_identity = nullptr;
    lt::torrent_handle first_handle = add_metadata_torrent_with_trackers(
        client,
        *first_info,
        temporary_directory.path(),
        first_identity,
        first_trackers
    );
    lt::torrent_handle second_handle = add_metadata_torrent_with_trackers(
        client,
        *second_info,
        temporary_directory.path(),
        second_identity,
        second_trackers
    );
    REQUIRE(first_identity != nullptr);
    REQUIRE(second_identity != nullptr);

    {
        std::scoped_lock guard(client.lock);
        static_cast<void>(client.observe_torrent_handle(first_handle));
        static_cast<void>(client.observe_torrent_handle(second_handle));
    }

    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    REQUIRE(client.copy_tracker_hosts({}, &required_count, &available) == 0);
    REQUIRE(bridge_bool(available));
    REQUIRE(required_count == 2);

    std::array<TTorrentTrackerHostSnapshot, 2> rows{};
    REQUIRE(client.copy_tracker_hosts(rows, &required_count, &available) == 2);
    CHECK(rows.at(0).native_token == first_identity->token->value);
    CHECK(std::string_view(rows.at(0).host) == "first.example");
    CHECK(rows.at(1).native_token == second_identity->token->value);
    CHECK(std::string_view(rows.at(1).host) == "second.example");
}

TEST_CASE("tracker host extraction reflects current native tracker topology")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::shared_ptr<lt::torrent_info const> const first_info = make_queue_torrent_info(94U);
    std::shared_ptr<lt::torrent_info const> const second_info = make_queue_torrent_info(95U);
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

    {
        std::scoped_lock guard(client.lock);
        static_cast<void>(client.observe_torrent_handle(first_handle));
        static_cast<void>(client.observe_torrent_handle(second_handle));
    }
    first_handle.replace_trackers({lt::announce_entry{"https://first.example/announce"}});
    second_handle.replace_trackers({lt::announce_entry{"https://second-old.example/announce"}});
    std::vector<lt::announce_entry> const replacement{
        lt::announce_entry{"https://second-new.example/announce"},
    };
    second_handle.replace_trackers(replacement);

    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    std::array<TTorrentTrackerHostSnapshot, 2> rows{};
    REQUIRE(client.copy_tracker_hosts(rows, &required_count, &available) == 2);
    REQUIRE(bridge_bool(available));
    CHECK(std::string_view(rows.at(0).host) == "first.example");
    CHECK(std::string_view(rows.at(1).host) == "second-new.example");
}

TEST_CASE("tracker host extraction follows the current libtorrent session set")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::array<unsigned char, 3> const seeds{96U, 97U, 98U};
    std::array<std::string, 3> const hosts{"first.example", "second.example", "third.example"};
    std::array<TorrentIdentity *, 3> identities{};
    std::array<lt::torrent_handle, 3> handles;
    for (std::size_t index = 0; index < handles.size(); ++index) {
        std::shared_ptr<lt::torrent_info const> const info = make_queue_torrent_info(seeds.at(index));
        std::array<lt::announce_entry, 1> const trackers{
            lt::announce_entry{"https://" + hosts.at(index) + "/announce"},
        };
        handles.at(index) = add_metadata_torrent_with_trackers(
            client,
            *info,
            temporary_directory.path(),
            identities.at(index),
            trackers
        );
        REQUIRE(identities.at(index) != nullptr);
    }

    DirtyMask changes = 0;
    {
        std::scoped_lock guard(client.lock);
        lt::info_hash_t const removed_hashes = handles.at(1).info_hashes();
        client.session.remove_torrent(handles.at(1));
        client.mark_remove_requested(
            removed_hashes,
            identities.at(1)
        );
        changes = client.mark_torrent_removed(
            removed_hashes,
            identities.at(1)->canonical_id
        );
    }

    CHECK((changes & kChangeTrackerHosts) != 0U);
    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    std::array<TTorrentTrackerHostSnapshot, 2> rows{};
    REQUIRE(client.copy_tracker_hosts(rows, &required_count, &available) == 2);
    REQUIRE(bridge_bool(available));
    CHECK(rows.at(0).native_token == identities.front()->token->value);
    CHECK(std::string_view(rows.at(0).host) == hosts.front());
    CHECK(rows.at(1).native_token == identities.back()->token->value);
    CHECK(std::string_view(rows.at(1).host) == hosts.back());
}

TEST_CASE("tracker host extraction recovers a missing handle mapping from native identity")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::shared_ptr<lt::torrent_info const> const first_info = make_queue_torrent_info(103U);
    std::shared_ptr<lt::torrent_info const> const second_info = make_queue_torrent_info(104U);
    std::vector<lt::announce_entry> const first_trackers{
        lt::announce_entry{"https://first.example/announce"},
    };
    std::vector<lt::announce_entry> const second_trackers{
        lt::announce_entry{"https://second.example/announce"},
    };
    TorrentIdentity *first_identity = nullptr;
    TorrentIdentity *second_identity = nullptr;
    lt::torrent_handle first_handle = add_metadata_torrent_with_trackers(
        client,
        *first_info,
        temporary_directory.path(),
        first_identity,
        first_trackers
    );
    lt::torrent_handle second_handle = add_metadata_torrent_with_trackers(
        client,
        *second_info,
        temporary_directory.path(),
        second_identity,
        second_trackers
    );
    REQUIRE(first_identity != nullptr);
    REQUIRE(second_identity != nullptr);

    {
        std::scoped_lock guard(client.lock);
        static_cast<void>(client.observe_torrent_handle(first_handle));
        static_cast<void>(client.observe_torrent_handle(second_handle));
    }

    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    std::array<TTorrentTrackerHostSnapshot, 2> rows{};
    REQUIRE(client.copy_tracker_hosts(rows, &required_count, &available) == 2);
    REQUIRE(bridge_bool(available));
    CHECK(std::string_view(rows.at(0).host) == "first.example");
    CHECK(std::string_view(rows.at(1).host) == "second.example");
}

TEST_CASE("settings application does not mutate Swift-owned peer exchange policy")
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
    settings.network_blocked = bridge_bool(true);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));

    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));

    handle.set_flags(lt::torrent_flags::disable_pex);
    REQUIRE(apply_settings(
        &client,
        settings,
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
    settings.network_blocked = bridge_bool(true);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    TTorrentSourcePolicy policy{};
    REQUIRE(copy_source_policy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK_FALSE(bridge_bool(policy.peer_exchange_locked));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE,
        true,
        error
    ) == 0);
    REQUIRE(copy_source_policy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.peer_exchange_disabled_by_app.contains(identity)));

    BRIDGE_WITH_CLIENT_LOCK(client, client.peer_exchange_plugin_enabled = true);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE,
        true,
        error
    ) == 0);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.peer_exchange_disabled_by_app.contains(identity)
    ));
}

TEST_CASE("per-torrent limits are separate from Swift-owned queue policy")
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
    REQUIRE(copy_torrent_options(
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
        options,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(handle.download_limit() == 512 * 1024);
    CHECK(handle.upload_limit() == 128 * 1024);
    CHECK(handle.max_uploads() == 6);
    CHECK(handle.max_connections() == 80);
    CHECK(identity->queue_priority == TTORRENT_QUEUE_PRIORITY_NORMAL);

    TTorrentOptions copied{};
    REQUIRE(copy_torrent_options(
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
    CHECK(copied.queue_priority == TTORRENT_QUEUE_PRIORITY_NORMAL);

    TTorrentQueuePlacement placement{};
    placement.native_token = identity->token->value;
    placement.priority = TTORRENT_QUEUE_PRIORITY_HIGH;
    REQUIRE(TorrentClientApplyQueueState(
        &client,
        &placement,
        1,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(copy_torrent_options(
        &client,
        identity->canonical_id.c_str(),
        &copied,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(copied.queue_priority == TTORRENT_QUEUE_PRIORITY_HIGH);
}

TEST_CASE("native queue command applies complete Swift-owned state")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    TorrentIdentity *first_identity = nullptr;
    TorrentIdentity *second_identity = nullptr;
    TorrentIdentity *third_identity = nullptr;
    lt::torrent_handle first = add_metadata_torrent(
        client,
        *make_queue_torrent_info(21U),
        temporary_directory.path(),
        first_identity
    );
    lt::torrent_handle second = add_metadata_torrent(
        client,
        *make_queue_torrent_info(22U),
        temporary_directory.path(),
        second_identity
    );
    lt::torrent_handle third = add_metadata_torrent(
        client,
        *make_queue_torrent_info(23U),
        temporary_directory.path(),
        third_identity
    );
    REQUIRE(first_identity != nullptr);
    REQUIRE(second_identity != nullptr);
    REQUIRE(third_identity != nullptr);

    auto placement = [](TorrentIdentity const &identity, int32_t priority) {
        TTorrentQueuePlacement result{};
        result.native_token = identity.token->value;
        result.priority = priority;
        return result;
    };
    std::array<TTorrentQueuePlacement, 3> placements{
        placement(*third_identity, TTORRENT_QUEUE_PRIORITY_HIGH),
        placement(*first_identity, TTORRENT_QUEUE_PRIORITY_NORMAL),
        placement(*second_identity, TTORRENT_QUEUE_PRIORITY_LOW),
    };
    std::array<char, 512> error{};

    REQUIRE(TorrentClientApplyQueueState(
        &client,
        placements.data(),
        static_cast<int32_t>(placements.size()),
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    CHECK(static_cast<int>(third.queue_position()) == 0);
    CHECK(static_cast<int>(first.queue_position()) == 1);
    CHECK(static_cast<int>(second.queue_position()) == 2);
    CHECK(third_identity->queue_priority == TTORRENT_QUEUE_PRIORITY_HIGH);
    CHECK(first_identity->queue_priority == TTORRENT_QUEUE_PRIORITY_NORMAL);
    CHECK(second_identity->queue_priority == TTORRENT_QUEUE_PRIORITY_LOW);
    CHECK(third_identity->queue_rank == 0);
    CHECK(first_identity->queue_rank == 0);
    CHECK(second_identity->queue_rank == 0);
}

TEST_CASE("native queue command rejects incomplete duplicate and invalid-token state")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    TorrentIdentity *first_identity = nullptr;
    TorrentIdentity *second_identity = nullptr;
    lt::torrent_handle first = add_metadata_torrent(
        client,
        *make_queue_torrent_info(31U),
        temporary_directory.path(),
        first_identity
    );
    lt::torrent_handle second = add_metadata_torrent(
        client,
        *make_queue_torrent_info(32U),
        temporary_directory.path(),
        second_identity
    );
    REQUIRE(first_identity != nullptr);
    REQUIRE(second_identity != nullptr);

    auto placement = [](TorrentIdentity const &identity) {
        TTorrentQueuePlacement result{};
        result.native_token = identity.token->value;
        result.priority = TTORRENT_QUEUE_PRIORITY_NORMAL;
        return result;
    };
    TTorrentQueuePlacement const first_placement = placement(*first_identity);
    std::array<char, 512> error{};

    CHECK(TorrentClientApplyQueueState(
        &client,
        &first_placement,
        1,
        error.data(),
        static_cast<int32_t>(error.size())
    ) != 0);

    std::array<TTorrentQueuePlacement, 2> duplicate{
        first_placement,
        first_placement,
    };
    CHECK(TorrentClientApplyQueueState(
        &client,
        duplicate.data(),
        static_cast<int32_t>(duplicate.size()),
        error.data(),
        static_cast<int32_t>(error.size())
    ) != 0);

    std::array<TTorrentQueuePlacement, 2> invalid_token{
        first_placement,
        placement(*second_identity),
    };
    invalid_token.front().native_token = 0;
    CHECK(TorrentClientApplyQueueState(
        &client,
        invalid_token.data(),
        static_cast<int32_t>(invalid_token.size()),
        error.data(),
        static_cast<int32_t>(error.size())
    ) != 0);

    CHECK(static_cast<int>(first.queue_position()) == 0);
    CHECK(static_cast<int>(second.queue_position()) == 1);
    CHECK(first_identity->queue_priority == TTORRENT_QUEUE_PRIORITY_NORMAL);
    CHECK(second_identity->queue_priority == TTORRENT_QUEUE_PRIORITY_NORMAL);
}
TEST_CASE("complete source policy applies independently of session defaults")
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
    settings.network_blocked = bridge_bool(true);
    settings.enable_dht = bridge_bool(true);
    settings.enable_lsd = bridge_bool(true);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.dht_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.peer_exchange_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.lsd_disabled_by_app.contains(identity)));

    TTorrentSourcePolicy policy{};
    REQUIRE(copy_source_policy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(bridge_bool(policy.enable_dht));
    CHECK(bridge_bool(policy.enable_peer_exchange));
    CHECK(bridge_bool(policy.enable_lsd));
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
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.dht_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.peer_exchange_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.lsd_disabled_by_app.contains(identity)));

    REQUIRE(apply_settings(
        &client,
        settings,
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
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.enable_lsd = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.requested_network_blocked));

    BridgeResult const fault = client.fault_persistence(2, "Synthetic persistence fault.");
    REQUIRE_FALSE(fault);

    settings.network_blocked = bridge_bool(true);
    CHECK(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 2);

    CHECK(bridge_tests::string_from_c_buffer(error) == "Synthetic persistence fault.");
    CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.requested_network_blocked));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.dht_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.lsd_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.peer_exchange_disabled_by_app.contains(identity)));
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
    settings.network_blocked = bridge_bool(false);
    settings.incoming_port = 1;
    settings.enable_dht = bridge_bool(true);
    settings.enable_lsd = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    CHECK(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 2);

    CHECK(bridge_tests::string_from_c_buffer(error) == "Incoming port must be 0 or between 1024 and 65535.");
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.dht_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.lsd_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.peer_exchange_disabled_by_app.contains(identity)));
}

TEST_CASE("settings interface input enforces explicit buffer bounds")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings = unblocked_session_settings();
    std::array<char, 512> error{};
    char const interface_name[] = "127.0.0.1";

    CHECK(TorrentClientApplySettings(
        &client,
        settings,
        nullptr,
        1,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 1);
    CHECK(bridge_tests::string_from_c_buffer(error)
        == "Invalid required network interface buffer.");

    CHECK(TorrentClientApplySettings(
        &client,
        settings,
        interface_name,
        -1,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 1);
    CHECK(bridge_tests::string_from_c_buffer(error)
        == "Invalid required network interface buffer.");

    CHECK(TorrentClientApplySettings(
        &client,
        settings,
        interface_name,
        TTORRENT_MAX_NETWORK_INTERFACE_BYTES + 1,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 1);
    CHECK(bridge_tests::string_from_c_buffer(error)
        == "Invalid required network interface buffer.");

    CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.requested_network_blocked));

    REQUIRE(apply_settings(
        &client,
        settings,
        error.data(),
        static_cast<int32_t>(error.size()),
        interface_name
    ) == 0);
    lt::settings_pack const applied = client.session.get_settings();
    CHECK(applied.get_str(lt::settings_pack::outgoing_interfaces) == interface_name);
}

TEST_CASE("zero-length interface buffers clear binding regardless of pointer presence")
{
    for (bool const nonnull_empty : {false, true}) {
        for (bool const network_blocked : {false, true}) {
            CAPTURE(nonnull_empty);
            CAPTURE(network_blocked);
            bridge_tests::TemporaryDirectory temporary_directory;
            TTorrentClient client((temporary_directory.path() / "State").string());
            client.set_session_shutdown_asynchronous(false);

            TTorrentSessionSettings settings = unblocked_session_settings();
            std::array<char, 512> error{};
            char const interface_name[] = "127.0.0.1";
            REQUIRE(apply_settings(
                &client,
                settings,
                error.data(),
                static_cast<int32_t>(error.size()),
                interface_name
            ) == 0);
            REQUIRE(client.session.get_settings().get_str(lt::settings_pack::outgoing_interfaces)
                == interface_name);

            settings.network_blocked = bridge_bool(network_blocked);
            REQUIRE(TorrentClientApplySettings(
                &client,
                settings,
                nonnull_empty ? interface_name : nullptr,
                0,
                error.data(),
                static_cast<int32_t>(error.size())
            ) == 0);
            CHECK(bridge_tests::string_from_c_buffer(error).empty());
            lt::settings_pack const applied = client.session.get_settings();
            CHECK(applied.get_str(lt::settings_pack::outgoing_interfaces).empty());
            CHECK(applied.get_str(lt::settings_pack::listen_interfaces)
                == (network_blocked ? "" : "0.0.0.0:0,[::]:0"));
            CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.requested_network_blocked) == network_blocked);
            CHECK(client.session.is_paused() == network_blocked);
        }
    }
}

TEST_CASE("settings reject invalid DHT discovery policy")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings = unblocked_session_settings();
    settings.dht_discovery_policy = 2;
    std::array<char, 512> error{};

    CHECK(TorrentClientApplySettings(
        &client,
        settings,
        nullptr,
        0,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 1);
    CHECK(bridge_tests::string_from_c_buffer(error) == "Invalid DHT discovery policy.");
}

TEST_CASE("session discovery settings do not persist Swift-owned torrent policy")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    auto info = make_torrent_info(false);
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, *info, temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);

    BRIDGE_WITH_CLIENT_LOCK(client, client.pending_events.clear());

    TTorrentSessionSettings settings{};
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.enable_lsd = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.lsd_disabled_by_app.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.peer_exchange_disabled_by_app.contains(identity)));
    bool const resume_save_requested = BRIDGE_WITH_CLIENT_LOCK(
        client,
        std::ranges::any_of(client.pending_events, [](TTorrentEvent const &event) {
            return event.kind == TTORRENT_EVENT_RESUME_SAVE_REQUESTED;
        })
    );
    CHECK_FALSE(resume_save_requested);
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
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
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
    REQUIRE(copy_source_policy(
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
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(eventually([&] {
        return client.session.is_dht_running();
    }));
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ENABLE_DHT,
        false,
        error
    ) == 0);
    REQUIRE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));

    handle.set_flags(lt::torrent_flags::paused, lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
    REQUIRE(static_cast<bool>(handle.flags() & lt::torrent_flags::paused));
    REQUIRE_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::auto_managed));

    TTorrentSourcePolicy policy{};
    REQUIRE(copy_source_policy(
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
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_ENABLE_DHT,
        false,
        error
    ) == 0);
    REQUIRE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    REQUIRE_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.dht_disabled_by_app.contains(identity)));
    CHECK_FALSE(client.session.is_dht_running());

    settings.enable_dht = bridge_bool(true);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(eventually([&] {
        return client.session.is_dht_running();
    }));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.dht_disabled_by_app.contains(identity)));
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
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};

    REQUIRE(client.session.is_paused());
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(client.session.is_paused());

    client.session.pause();
    REQUIRE(client.session.is_paused());
    settings.enable_dht = bridge_bool(true);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(client.session.is_paused());
}

TEST_CASE("forced network block waits for libtorrent executor acknowledgement")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings = unblocked_session_settings();
    std::array<char, 512> error{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    REQUIRE_FALSE(client.session.is_paused());

    SessionExecutorGate executor_gate(client);
    std::promise<int32_t> result_promise;
    std::future<int32_t> result = result_promise.get_future();
    std::jthread transition([&] {
        result_promise.set_value(TorrentClientBlockNetwork(
            &client,
            error.data(),
            static_cast<int32_t>(error.size())
        ));
    });

    CHECK(result.wait_for(std::chrono::milliseconds(100)) == std::future_status::timeout);
    executor_gate.release();
    transition.join();

    REQUIRE(result.get() == 0);
    lt::settings_pack const current = client.session.get_settings();
    CHECK(current.get_str(lt::settings_pack::listen_interfaces).empty());
    CHECK(current.get_str(lt::settings_pack::outgoing_interfaces).empty());
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_upnp));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_natpmp));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_dht));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_lsd));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_outgoing_tcp));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_incoming_tcp));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_outgoing_utp));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_incoming_utp));
    CHECK_FALSE(current.get_bool(lt::settings_pack::dht_privacy_lookups));
    CHECK(client.session.is_paused());
}

TEST_CASE("network unblock waits for libtorrent executor acknowledgement")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings = unblocked_session_settings();
    settings.dht_read_only = bridge_bool(true);
    std::array<char, 512> error{};
    SessionExecutorGate executor_gate(client);
    std::promise<int32_t> result_promise;
    std::future<int32_t> result = result_promise.get_future();
    std::jthread transition([&] {
        result_promise.set_value(apply_settings(
            &client,
            settings,
            error.data(),
            static_cast<int32_t>(error.size())
        ));
    });

    CHECK(result.wait_for(std::chrono::milliseconds(100)) == std::future_status::timeout);
    executor_gate.release();
    transition.join();

    REQUIRE(result.get() == 0);
    lt::settings_pack const current = client.session.get_settings();
    CHECK(current.get_str(lt::settings_pack::listen_interfaces) == "0.0.0.0:0,[::]:0");
    CHECK(current.get_str(lt::settings_pack::outgoing_interfaces).empty());
    CHECK(current.get_bool(lt::settings_pack::enable_outgoing_tcp));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_incoming_tcp));
    CHECK(current.get_bool(lt::settings_pack::enable_outgoing_utp));
    CHECK_FALSE(current.get_bool(lt::settings_pack::enable_incoming_utp));
    CHECK(current.get_bool(lt::settings_pack::dht_read_only));
    CHECK_FALSE(client.session.is_paused());
}

TEST_CASE("privacy-sensitive tracker and DHT settings are explicit")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::settings_pack initial = client.session.get_settings();
    CHECK(initial.get_bool(lt::settings_pack::anonymous_mode));
    CHECK(initial.get_bool(lt::settings_pack::dht_privacy_lookups));
    CHECK(initial.get_bool(lt::settings_pack::dht_enforce_node_id));
    CHECK(initial.get_bool(lt::settings_pack::dht_prefer_verified_node_ids));
    CHECK(initial.get_bool(lt::settings_pack::dht_restrict_routing_ips));
    CHECK(initial.get_bool(lt::settings_pack::dht_restrict_search_ips));
    CHECK(initial.get_bool(lt::settings_pack::dht_ignore_dark_internet));
    CHECK(initial.get_bool(lt::settings_pack::apply_filter_to_dht));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::use_dht_as_fallback));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::announce_to_all_trackers));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::announce_to_all_tiers));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::prefer_udp_trackers));
    CHECK(initial.get_bool(lt::settings_pack::validate_https_trackers));
    CHECK(initial.get_bool(lt::settings_pack::ssrf_mitigation));
    CHECK_FALSE(initial.get_bool(lt::settings_pack::always_send_user_agent));

    TTorrentSessionSettings settings{};
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.dht_privacy_lookups = bridge_bool(true);
    settings.anonymous_mode = bridge_bool(false);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    char error[512]{};

    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(eventually([&] {
        lt::settings_pack const current = client.session.get_settings();
        return !current.get_bool(lt::settings_pack::anonymous_mode)
            && current.get_bool(lt::settings_pack::dht_privacy_lookups)
            && current.get_bool(lt::settings_pack::dht_enforce_node_id)
            && current.get_bool(lt::settings_pack::dht_prefer_verified_node_ids)
            && current.get_bool(lt::settings_pack::dht_restrict_routing_ips)
            && current.get_bool(lt::settings_pack::dht_restrict_search_ips)
            && current.get_bool(lt::settings_pack::dht_ignore_dark_internet)
            && current.get_bool(lt::settings_pack::apply_filter_to_dht)
            && !current.get_bool(lt::settings_pack::use_dht_as_fallback)
            && !current.get_bool(lt::settings_pack::announce_to_all_trackers)
            && !current.get_bool(lt::settings_pack::announce_to_all_tiers)
            && !current.get_bool(lt::settings_pack::prefer_udp_trackers)
            && current.get_bool(lt::settings_pack::validate_https_trackers)
            && current.get_bool(lt::settings_pack::ssrf_mitigation)
            && !current.get_bool(lt::settings_pack::always_send_user_agent);
    }));
}

TEST_CASE("DHT privacy lookups honor explicit choices and effective DHT availability")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings = unblocked_session_settings();
    char error[512]{};

    for (bool const anonymous_mode : {false, true}) {
        for (bool const privacy_lookups : {false, true}) {
            CAPTURE(anonymous_mode);
            CAPTURE(privacy_lookups);
            settings.anonymous_mode = bridge_bool(anonymous_mode);
            settings.dht_privacy_lookups = bridge_bool(privacy_lookups);
            // Restore availability after disabling DHT and after blocking the
            // network, exercising both transitions without changing the choice.
            for (auto const &[enable_dht, network_blocked] : std::array{
                    std::pair{true, false},
                    std::pair{false, false},
                    std::pair{true, false},
                    std::pair{true, true},
                    std::pair{false, true},
                    std::pair{true, false},
                }) {
                CAPTURE(enable_dht);
                CAPTURE(network_blocked);
                settings.enable_dht = bridge_bool(enable_dht);
                settings.network_blocked = bridge_bool(network_blocked);
                REQUIRE(apply_settings(
                    &client,
                    settings,
                    error,
                    static_cast<int32_t>(sizeof(error))
                ) == 0);
                lt::settings_pack const current = client.session.get_settings();
                CHECK(current.get_bool(lt::settings_pack::anonymous_mode) == anonymous_mode);
                CHECK(current.get_bool(lt::settings_pack::enable_dht) == (enable_dht && !network_blocked));
                CHECK(current.get_bool(lt::settings_pack::dht_privacy_lookups)
                    == (privacy_lookups && enable_dht && !network_blocked));
            }
        }
    }
}

TEST_CASE("invalid DHT privacy lookup flags reject settings before mutation")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings = unblocked_session_settings();
    settings.enable_dht = bridge_bool(false);
    settings.anonymous_mode = bridge_bool(true);
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    for (std::uint8_t const invalid : {std::uint8_t{2}, std::uint8_t{255}}) {
        CAPTURE(invalid);
        settings.dht_privacy_lookups = invalid;
        settings.enable_dht = bridge_bool(true);
        settings.anonymous_mode = bridge_bool(false);
        settings.download_rate_limit = 12345;
        CHECK(apply_settings(
            &client,
            settings,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 1);
        CHECK(std::string(error) == "Invalid DHT privacy lookup setting.");
        lt::settings_pack const current = client.session.get_settings();
        CHECK_FALSE(current.get_bool(lt::settings_pack::enable_dht));
        CHECK_FALSE(current.get_bool(lt::settings_pack::dht_privacy_lookups));
        CHECK(current.get_bool(lt::settings_pack::anonymous_mode));
        CHECK(current.get_int(lt::settings_pack::download_rate_limit) == 0);
    }
}

TEST_CASE("network diagnostics report native DHT status and routing nodes")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentNetworkStatusResult initial = TorrentClientCopyNetworkStatus(&client);
    REQUIRE(initial.status == 1);
    CHECK(initial.network_status.dht_status == TTORRENT_DHT_STATUS_DISABLED);
    CHECK(initial.network_status.dht_routing_nodes == -1);

    TTorrentSessionSettings settings = unblocked_session_settings();
    settings.enable_dht = bridge_bool(true);
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    CHECK(eventually([&] {
        TTorrentNetworkStatusResult const status = TorrentClientCopyNetworkStatus(&client);
        return status.status == 1
            && status.network_status.dht_status == TTORRENT_DHT_STATUS_RUNNING;
    }));
    CHECK(eventually([&] {
        TTorrentNetworkStatusResult const status = TorrentClientCopyNetworkStatus(&client);
        return status.status == 1 && status.network_status.dht_routing_nodes >= 0;
    }));

    settings.enable_dht = bridge_bool(false);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    TTorrentNetworkStatusResult const disabled = TorrentClientCopyNetworkStatus(&client);
    REQUIRE(disabled.status == 1);
    CHECK(disabled.network_status.dht_status == TTORRENT_DHT_STATUS_DISABLED);
    CHECK(disabled.network_status.dht_routing_nodes == -1);
}

TEST_CASE("DHT diagnostics failures preserve authoritative network status")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    BRIDGE_WITH_CLIENT_LOCK(client, static_cast<void>(client.record_network_requested(false)));
    BRIDGE_WITH_CLIENT_LOCK(client, client.has_listener = true);
    BRIDGE_WITH_CLIENT_LOCK(client, client.listen_port = 48123);
    BRIDGE_WITH_CLIENT_LOCK(client, client.listen_endpoint = "192.0.2.1:48123");
    BRIDGE_WITH_CLIENT_LOCK(client, client.fail_next_dht_diagnostics_poll = true);

    TTorrentNetworkStatusResult const result = TorrentClientCopyNetworkStatus(&client);
    REQUIRE(result.status == 1);
    CHECK_FALSE(bridge_bool(result.network_status.network_blocked));
    CHECK(bridge_bool(result.network_status.has_listener));
    CHECK(result.network_status.listen_port == 48123);
    CHECK(std::string(result.network_status.endpoint) == "192.0.2.1:48123");
    CHECK(result.network_status.dht_routing_nodes == -1);
}

TEST_CASE("settings apply toggles reduced DHT contribution")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings = unblocked_session_settings();
    settings.enable_dht = bridge_bool(true);
    settings.dht_read_only = bridge_bool(true);
    char error[512]{};

    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(eventually([&] {
        return client.session.get_settings().get_bool(lt::settings_pack::dht_read_only);
    }));

    settings.dht_read_only = bridge_bool(false);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(eventually([&] {
        return !client.session.get_settings().get_bool(lt::settings_pack::dht_read_only);
    }));
}

TEST_CASE("settings apply switches DHT discovery policy")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    TTorrentSessionSettings settings = unblocked_session_settings();
    settings.enable_dht = bridge_bool(true);
    settings.dht_discovery_policy = TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL;
    char error[512]{};

    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(client.session.get_settings().get_bool(lt::settings_pack::use_dht_as_fallback));

    settings.dht_discovery_policy = TTORRENT_DHT_DISCOVERY_ALONGSIDE_TRACKERS;
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(client.session.get_settings().get_bool(lt::settings_pack::use_dht_as_fallback));
}

TEST_CASE("complete source applications apply Swift-owned HTTPS policy independently of settings")
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
    settings.network_blocked = bridge_bool(true);
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    std::vector<lt::announce_entry> const trackers = handle.trackers();
    REQUIRE(trackers.size() == 2U);
    CHECK(trackers.at(0).url == "http://tracker.example/announce");
    CHECK(trackers.at(0).tier == 0);
    CHECK(trackers.at(1).url == "https://secure-tracker.example/announce");
    CHECK(trackers.at(1).tier == 1);
    CHECK(handle.url_seeds().size() == 2U);

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_REQUIRE,
        error
    ) == 0);

    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.url_seeds().size() == 1U);

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY,
        TTORRENT_HTTPS_POLICY_REQUIRE,
        error
    ) == 0);

    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.url_seeds().contains("https://secure-seed.example/file"));

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_ORIGINAL,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY,
        TTORRENT_HTTPS_POLICY_ORIGINAL,
        error
    ) == 0);
    REQUIRE(handle.trackers().size() == 2U);
    CHECK(handle.trackers().at(0).url == "http://tracker.example/announce");
    CHECK(handle.trackers().at(0).tier == 0);
    CHECK(handle.trackers().at(1).url == "https://secure-tracker.example/announce");
    CHECK(handle.trackers().at(1).tier == 1);
    CHECK(cached_url_seed_count(client, identity->canonical_id) == 2);
}

TEST_CASE("incomplete source-policy rollback contains traffic until full reapplication")
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

    std::array<char, 512> error{};
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_ORIGINAL,
        error
    ) == 0);
    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(client, client.source_policy_reconciled));

    TTorrentSessionSettings settings = unblocked_session_settings();
    REQUIRE(apply_settings(
        &client,
        settings,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    REQUIRE_FALSE(client.session.is_paused());

    BRIDGE_WITH_CLIENT_LOCK(
        client,
        (client.fail_next_source_policy_application = true,
            client.fail_next_source_policy_rollback = true)
    );
    CHECK(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_REQUIRE,
        error
    ) == 2);
    CHECK(bridge_tests::string_from_c_buffer(error)
        == "Synthetic source-policy application failure. Source-policy rollback was incomplete; networking was blocked.");
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.source_policy_reconciled));
    CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.requested_network_blocked));
    CHECK(client.session.is_paused());

    lt::settings_pack const contained = client.session.get_settings();
    CHECK(contained.get_str(lt::settings_pack::listen_interfaces).empty());
    CHECK(contained.get_str(lt::settings_pack::outgoing_interfaces).empty());
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_upnp));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_natpmp));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_dht));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_lsd));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_outgoing_tcp));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_incoming_tcp));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_outgoing_utp));
    CHECK_FALSE(contained.get_bool(lt::settings_pack::enable_incoming_utp));

    CHECK(apply_settings(
        &client,
        settings,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 2);
    CHECK(bridge_tests::string_from_c_buffer(error)
        == "Networking cannot resume until source policy has been fully reconciled.");
    CHECK(client.session.is_paused());

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_REQUIRE,
        error
    ) == 0);
    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(client, client.source_policy_reconciled));
    REQUIRE(handle.trackers().size() == 1U);
    REQUIRE(apply_settings(
        &client,
        settings,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    CHECK_FALSE(client.session.is_paused());
}

TEST_CASE("strict HTTPS policy rejects oversized original magnet sources")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    std::string magnet = "magnet:?xt=urn:btih:" + std::string(40U, '7');
    for (int32_t index = 0; index <= TTORRENT_MAX_TRACKER_COUNT; ++index) {
        magnet += "&tr=http://t/a";
    }
    magnet += "&tr=https://secure.example/announce";
    REQUIRE(magnet.size() <= kMaxMagnetURIBytes);

    TTorrentAddOptions add_options = default_add_options();
    add_options.https_tracker_policy = TTORRENT_HTTPS_POLICY_REQUIRE;
    std::array<char, TTORRENT_ID_CAPACITY> added_id{};
    std::array<char, 512> error{};
    int32_t add_outcome = TTORRENT_ADD_OUTCOME_UNKNOWN;
    std::string const save_path = temporary_directory.path().string();
    CHECK(TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        add_options,
        added_id.data(),
        static_cast<int32_t>(added_id.size()),
        &add_outcome,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 2);
    CHECK(add_outcome == TTORRENT_ADD_REJECTED);
    CHECK(std::string(error.data()) == "The torrent contains too many trackers. The maximum is 2000.");
    CHECK(added_id.front() == '\0');
}

TEST_CASE("HTTPS policy updates preserve libtorrent tracker order when topology is unchanged")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::add_torrent_params source_params = make_source_torrent_params();
    source_params.trackers = {
        "https://first-tracker.example/announce",
        "https://second-tracker.example/announce",
    };
    source_params.tracker_tiers = {0, 0};
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(
        client,
        std::move(source_params),
        temporary_directory.path(),
        identity
    );
    REQUIRE(identity != nullptr);

    std::vector<lt::announce_entry> reordered = handle.trackers();
    REQUIRE(reordered.size() == 2U);
    std::ranges::reverse(reordered);
    handle.replace_trackers(reordered);
    REQUIRE(handle.trackers().front().url == "https://second-tracker.example/announce");

    TTorrentSessionSettings settings{};
    settings.network_blocked = bridge_bool(true);
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(handle.trackers().front().url == "https://second-tracker.example/announce");

    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(handle.trackers().front().url == "https://second-tracker.example/announce");

    settings.dht_read_only = bridge_bool(true);
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(handle.trackers().front().url == "https://second-tracker.example/announce");
}

TEST_CASE("per-torrent original HTTPS policy preserves loaded torrent sources")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);

    lt::add_torrent_params source_params = make_source_torrent_params();
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(client, std::move(source_params), temporary_directory.path(), identity);
    REQUIRE(identity != nullptr);
    identity->https_tracker_policy = HTTPSPolicy::original;
    identity->https_web_seed_policy = HTTPSPolicy::original;

    TTorrentSessionSettings settings{};
    settings.network_blocked = bridge_bool(true);
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
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
    REQUIRE(copy_source_policy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(bridge_bool(policy.enable_dht));
    CHECK(bridge_bool(policy.enable_peer_exchange));
    CHECK(bridge_bool(policy.enable_lsd));
    CHECK(policy.https_tracker_policy == TTORRENT_HTTPS_POLICY_INHERIT);
    CHECK(policy.https_web_seed_policy == TTORRENT_HTTPS_POLICY_INHERIT);
    CHECK(policy.effective_https_tracker_policy == TTORRENT_HTTPS_POLICY_PREFER);
    CHECK(policy.effective_https_web_seed_policy == TTORRENT_HTTPS_POLICY_REQUIRE);
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
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_REQUIRE,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY,
        TTORRENT_HTTPS_POLICY_REQUIRE,
        error
    ) == 0);

    REQUIRE(copy_source_policy(
        &client,
        identity->canonical_id.c_str(),
        &policy,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK_FALSE(bridge_bool(policy.enable_dht));
    CHECK_FALSE(bridge_bool(policy.enable_peer_exchange));
    CHECK_FALSE(bridge_bool(policy.enable_lsd));
    CHECK(policy.https_tracker_policy == TTORRENT_HTTPS_POLICY_REQUIRE);
    CHECK(policy.https_web_seed_policy == TTORRENT_HTTPS_POLICY_REQUIRE);
    CHECK(policy.effective_https_tracker_policy == TTORRENT_HTTPS_POLICY_REQUIRE);
    CHECK(policy.effective_https_web_seed_policy == TTORRENT_HTTPS_POLICY_REQUIRE);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.trackers().front().url == "https://secure-tracker.example/announce");
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(identity->dht_disabled_by_user);
    CHECK(identity->peer_exchange_disabled_by_user);
    CHECK(identity->lsd_disabled_by_user);
    CHECK(identity->https_tracker_policy == HTTPSPolicy::require);
    CHECK(identity->https_web_seed_policy == HTTPSPolicy::require);

    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_ORIGINAL,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY,
        TTORRENT_HTTPS_POLICY_ORIGINAL,
        error
    ) == 0);
    REQUIRE(handle.trackers().size() == 2U);
    CHECK(cached_url_seed_count(client, identity->canonical_id) == 2);
    CHECK(identity->https_tracker_policy == HTTPSPolicy::original);
    CHECK(identity->https_web_seed_policy == HTTPSPolicy::original);
}

TEST_CASE("unrelated source policy mutations preserve explicit HTTPS enforcement")
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
    settings.network_blocked = bridge_bool(true);
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_REQUIRE,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY,
        TTORRENT_HTTPS_POLICY_REQUIRE,
        error
    ) == 0);
    REQUIRE(handle.trackers().size() == 1U);
    REQUIRE(handle.url_seeds().size() == 1U);
    REQUIRE(identity->https_tracker_policy == HTTPSPolicy::require);
    REQUIRE(identity->https_web_seed_policy == HTTPSPolicy::require);

    REQUIRE(set_source_policy_field(client, *identity, TTORRENT_SOURCE_POLICY_ENABLE_DHT, false, error) == 0);

    CHECK(handle.trackers().size() == 1U);
    CHECK(handle.trackers().front().url == "https://secure-tracker.example/announce");
    CHECK(handle.url_seeds().size() == 1U);
    CHECK(handle.url_seeds().contains("https://secure-seed.example/file"));
    CHECK(identity->https_tracker_policy == HTTPSPolicy::require);
    CHECK(identity->https_web_seed_policy == HTTPSPolicy::require);
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

    REQUIRE_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.metadata_validation_pending.contains(identity)));
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
    REQUIRE(copy_source_policy(
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

    REQUIRE(copy_source_policy(
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

    TTorrentPieceMapSnapshot snapshot{};
    int32_t required_count = 0;
    std::uint8_t available = bridge_bool(false);
    REQUIRE(client.copy_piece_map(
        identity->token->value,
        &snapshot,
        {},
        &required_count,
        &available
    ) == 0);
    REQUIRE(bridge_bool(available));

    CHECK(snapshot.total_pieces == info->num_pieces());
    CHECK(snapshot.completed_pieces == 0);
    CHECK(snapshot.available_pieces == info->num_pieces());
    CHECK(required_count == info->num_pieces());

    std::vector<std::uint8_t> pieces(static_cast<std::size_t>(required_count));
    REQUIRE(client.copy_piece_map(
                identity->token->value,
                &snapshot,
                std::span{pieces},
                &required_count,
                &available
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

TEST_CASE("metadata-less magnets expose authoritative empty file and piece details")
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
    int32_t add_outcome = TTORRENT_ADD_REJECTED;

    REQUIRE(TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        add_options,
        added_id,
        static_cast<int32_t>(sizeof(added_id)),
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    REQUIRE(is_canonical_torrent_id(added_id));

    std::optional<lt::torrent_handle> const handle = client.find(native_token(client, added_id));
    REQUIRE(handle.has_value());
    lt::torrent_status const status = handle->status(lt::torrent_handle::query_torrent_file);
    REQUIRE_FALSE(status.has_metadata);
    std::shared_ptr<lt::torrent_info const> const torrent_file = status.torrent_file.lock();
    REQUIRE(torrent_file != nullptr);
    REQUIRE_FALSE(torrent_file->is_valid());

    int32_t required_count = -1;
    std::uint8_t available = bridge_bool(false);
    CHECK(TorrentClientCopyFileBatch(
        &client,
        added_id,
        nullptr,
        0,
        &required_count,
        &available
    ) == 0);
    CHECK(bridge_bool(available));
    CHECK(required_count == 0);

    TTorrentPieceMapSnapshot snapshot{};
    required_count = -1;
    CHECK(TorrentClientCopyPieceMap(
        &client,
        added_id,
        &snapshot,
        nullptr,
        0,
        &required_count,
        &available
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
    REQUIRE(copy_source_policy(
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

    REQUIRE(copy_source_policy(
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
    REQUIRE(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::require, .web_seeds = HTTPSPolicy::require}
    ));
    prepare_add_params(params, temporary_directory.path().string(), false, true);

    TorrentIdentity *identity = client.attach_identity(params, next_test_canonical_id());
    REQUIRE(identity != nullptr);
    REQUIRE(remember_source_policy_sources(*identity, source_params));

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
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_ORIGINAL,
        error
    ) == 0);
    REQUIRE(set_source_policy_field(
        client,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY,
        TTORRENT_HTTPS_POLICY_ORIGINAL,
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
    REQUIRE(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::require, .web_seeds = HTTPSPolicy::require}
    ));
    prepare_add_params(params, temporary_directory.path().string(), false, true);

    TorrentIdentity *identity = client.attach_identity(params, next_test_canonical_id());
    REQUIRE(identity != nullptr);
    REQUIRE(remember_source_policy_sources(*identity, source_params));

    lt::error_code add_error;
    lt::torrent_handle handle = client.session.add_torrent(std::move(params), add_error);
    REQUIRE_FALSE(add_error);
    client.mark_active(handle, identity);

    REQUIRE(handle.trackers().size() == 1U);
    CHECK(handle.url_seeds().size() == 1U);

    BRIDGE_WITH_CLIENT_LOCK(
        client,
        static_cast<void>(client.restore_metadata_source_policy(
            handle,
            identity,
            HTTPSSourcePolicyScope::all,
            HTTPSSourcePolicy{
                .trackers = HTTPSPolicy::require,
                .web_seeds = HTTPSPolicy::require,
            }
        ))
    );

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
    int32_t add_outcome = TTORRENT_ADD_REJECTED;

    REQUIRE(TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        add_options,
        added_id,
        static_cast<int32_t>(sizeof(added_id)),
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(is_canonical_torrent_id(added_id));

    lt::torrent_handle handle = mapped_torrent_handle(client, bridge_tests::v1_id('2'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::block_non_global_peers));
    CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.metadata_validation_pending.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.peer_exchange_disabled_by_app.contains(identity)
    ));
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
    int32_t add_outcome = TTORRENT_ADD_REJECTED;

    {
        TTorrentClient client(state_directory.string());
        client.set_session_shutdown_asynchronous(false);
        REQUIRE(TorrentClientAddMagnet(
            &client,
            magnet.c_str(),
            add_options,
            added_id,
            static_cast<int32_t>(sizeof(added_id)),
            &add_outcome,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);

        lt::torrent_handle handle = mapped_torrent_handle(client, bridge_tests::v1_id('6'));
        TorrentIdentity *identity = identity_from_handle(handle);
        REQUIRE(identity != nullptr);
        CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
        CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
        CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
        CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::block_non_global_peers));
        CHECK(identity->allow_pre_metadata_dht);
        CHECK(BRIDGE_WITH_CLIENT_LOCK(client, client.metadata_validation_pending.contains(identity)));
        TTorrentSourcePolicy policy{};
        REQUIRE(copy_source_policy(
            &client,
            identity->canonical_id.c_str(),
            &policy,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);
        CHECK(bridge_bool(policy.metadata_validation_pending));
        CHECK(bridge_bool(policy.allow_pre_metadata_dht));
    }

    TTorrentClient reloaded(state_directory.string());
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = mapped_torrent_handle(reloaded, bridge_tests::v1_id('6'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK_FALSE(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::block_non_global_peers));
    CHECK(identity->allow_pre_metadata_dht);
    CHECK(BRIDGE_WITH_CLIENT_LOCK(reloaded, reloaded.metadata_validation_pending.contains(identity)));
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
    int32_t add_outcome = TTORRENT_ADD_REJECTED;

    TTorrentClient client(state_directory.string());
    client.set_session_shutdown_asynchronous(false);
    REQUIRE(TorrentClientAddMagnet(
        &client,
        magnet.c_str(),
        add_options,
        added_id,
        static_cast<int32_t>(sizeof(added_id)),
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);

    lt::torrent_handle handle = mapped_torrent_handle(client, bridge_tests::v1_id('7'));
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
    fs::path const resume_path = state_directory / "ResumeData"
        / (resume_id + std::string(kResumeExtension));
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

    TTorrentClient restarted(restart_state.string());
    restarted.set_session_shutdown_asynchronous(false);
    lt::torrent_handle restarted_handle = mapped_torrent_handle(restarted, resume_id);
    TorrentIdentity *restarted_identity = identity_from_handle(restarted_handle);
    REQUIRE(restarted_identity != nullptr);
    CHECK(BRIDGE_WITH_CLIENT_LOCK(
        restarted,
        restarted.metadata_validation_pending.contains(restarted_identity)
    ));
    CHECK_FALSE(restarted_identity->allow_pre_metadata_dht);
    CHECK(static_cast<bool>(restarted_handle.flags() & lt::torrent_flags::disable_dht));
}

TEST_CASE("untracking reports its durable commit without touching payload files")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    TTorrentClient client((temporary_directory.path() / "State").string());
    client.set_session_shutdown_asynchronous(false);
    client.stop_alert_worker();

    std::shared_ptr<lt::torrent_info const> const info = make_torrent_info(false);
    fs::path const payload = temporary_directory.path() / "public.bin";
    bridge_tests::write_text_file(payload, "payload remains GUI-owned");
    TorrentIdentity *identity = nullptr;
    lt::torrent_handle handle = add_metadata_torrent(
        client,
        *info,
        temporary_directory.path(),
        identity
    );
    REQUIRE(identity != nullptr);
    TorrentIdentityToken *const token = identity->token;
    REQUIRE(token != nullptr);

    std::uint8_t removal_committed = bridge_bool(false);
    std::array<char, 512> error{};
    int32_t removal_result = -1;
    std::atomic_bool removal_returned = false;
    std::string const id = identity->canonical_id;
    std::jthread removal([&] {
        removal_result = TorrentClientRemove(
            &client,
            id.c_str(),
            &removal_committed,
            error.data(),
            static_cast<int32_t>(error.size())
        );
        removal_returned.store(true, std::memory_order_release);
    });

    REQUIRE(eventually([&handle] {
        try {
            return !handle.in_session();
        } catch (lt::system_error const &) {
            return true;
        }
    }));
    CHECK_FALSE(removal_returned.load(std::memory_order_acquire));
    CHECK(token->active_identity.load(std::memory_order_acquire) == identity);
    REQUIRE(eventually([&] {
        client.pump_alerts();
        return token->active_identity.load(std::memory_order_acquire) == nullptr;
    }));
    removal.join();

    REQUIRE(removal_result == 0);
    CHECK(bridge_bool(removal_committed));
    CHECK(removal_returned.load(std::memory_order_acquire));
    CHECK(file_exists(payload));
}

TEST_CASE("restored torrents cannot network before complete source-policy reconciliation")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    std::string const hash(40U, 'a');
    std::string const magnet = "magnet:?xt=urn:btih:" + hash
        + "&tr=http%3A%2F%2Ftracker.example%2Fannounce";
    TTorrentAddOptions add_options = default_add_options();
    std::array<char, TTORRENT_ID_CAPACITY> added_id{};
    std::array<char, 512> error{};
    int32_t add_outcome = TTORRENT_ADD_REJECTED;

    {
        TTorrentClient client(state_directory.string());
        client.set_session_shutdown_asynchronous(false);
        REQUIRE(TorrentClientAddMagnet(
            &client,
            magnet.c_str(),
            add_options,
            added_id.data(),
            static_cast<int32_t>(added_id.size()),
            &add_outcome,
            error.data(),
            static_cast<int32_t>(error.size())
        ) == 0);
    }

    TTorrentClient reloaded(state_directory.string());
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = mapped_torrent_handle(reloaded, bridge_tests::v1_id('a'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    REQUIRE(handle.trackers().size() == 1U);
    REQUIRE_FALSE(BRIDGE_WITH_CLIENT_LOCK(reloaded, reloaded.source_policy_reconciled));
    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(reloaded, reloaded.requested_network_blocked));
    REQUIRE(reloaded.session.is_paused());

    TTorrentSessionSettings settings = unblocked_session_settings();
    CHECK(apply_settings(
        &reloaded,
        settings,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 2);
    CHECK(bridge_tests::string_from_c_buffer(error)
        == "Networking cannot resume until source policy has been fully reconciled.");
    CHECK(reloaded.session.is_paused());
    CHECK(handle.trackers().size() == 1U);

    REQUIRE(set_source_policy_field(
        reloaded,
        *identity,
        TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY,
        TTORRENT_HTTPS_POLICY_INHERIT,
        error,
        HTTPSPolicy::require,
        HTTPSPolicy::require
    ) == 0);
    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(reloaded, reloaded.source_policy_reconciled));
    CHECK(handle.trackers().empty());

    REQUIRE(apply_settings(
        &reloaded,
        settings,
        error.data(),
        static_cast<int32_t>(error.size())
    ) == 0);
    CHECK_FALSE(reloaded.session.is_paused());
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
    int32_t add_outcome = TTORRENT_ADD_REJECTED;

    {
        TTorrentClient client(state_directory.string());
        client.set_session_shutdown_asynchronous(false);
        REQUIRE(TorrentClientAddMagnet(
            &client,
            magnet.c_str(),
            add_options,
            added_id,
            static_cast<int32_t>(sizeof(added_id)),
            &add_outcome,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);
    }

    TTorrentClient reloaded(state_directory.string());
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = mapped_torrent_handle(reloaded, bridge_tests::v1_id('3'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK(BRIDGE_WITH_CLIENT_LOCK(reloaded, reloaded.metadata_validation_pending.contains(identity)));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        reloaded,
        reloaded.peer_exchange_disabled_by_app.contains(identity)
    ));
}

TEST_CASE("validated staged magnets retain metadata and user intent across resume reloads")
{
    bool change_priority = false;
    SUBCASE("original magnet file selection") {}
    SUBCASE("file priority changed after metadata arrival") { change_priority = true; }
    for (bool const private_torrent : {false, true}) {
        for (ResumeSaveMode const mode : {ResumeSaveMode::routine, ResumeSaveMode::policy, ResumeSaveMode::full}) {
            CAPTURE(private_torrent);
            CAPTURE(static_cast<int>(mode));
            bridge_tests::TemporaryDirectory temporary;
            fs::path const state = temporary.path() / "State";
            fs::path const restart_state = temporary.path() / "RestartState";
            fs::path const restart_resume_directory = restart_state / "ResumeData";
            REQUIRE(fs::create_directories(restart_resume_directory));
            std::vector<lt::create_file_entry> payload_files;
            payload_files.emplace_back("staged/selected.bin", 4);
            payload_files.emplace_back("staged/unselected.bin", 4);
            lt::create_torrent creator(std::move(payload_files), 16 * 1024, lt::create_torrent::v1_only);
            creator.set_priv(private_torrent);
            creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(9U));
            auto const info = bridge_tests::load_torrent_params(creator.generate_buf(), "staged metadata").ti;
            std::string const resume_id = primary_hash_key(info->info_hashes());
            std::string const magnet = "magnet:?xt=urn:btih:" + resume_id.substr(3U) + "&so=0";
            auto parser = std::make_shared<TestOnlyResumeInfoParser>();
            std::array<char, TTORRENT_ID_CAPACITY> canonical_id{};
            std::array<char, 512> error{};
            {
                TTorrentClient client(state.string(), false, nullptr, parser);
                client.set_session_shutdown_asynchronous(false);
                client.stop_alert_worker();
                TTorrentAddOptions options = default_add_options();
                options.starts_paused = bridge_bool(true);
                options.queue_priority = TTORRENT_QUEUE_PRIORITY_HIGH;
                int32_t outcome = TTORRENT_ADD_REJECTED;
                REQUIRE(TorrentClientAddMagnet(
                    &client, magnet.c_str(), options,
                    canonical_id.data(), static_cast<int32_t>(canonical_id.size()), &outcome,
                    error.data(), static_cast<int32_t>(error.size())
                ) == 0);
                lt::torrent_handle const handle = mapped_torrent_handle(client, resume_id);
                REQUIRE(handle.is_valid());
                REQUIRE(handle.set_metadata(info->info_section()));
                DirtyMask changes = 0U;
                REQUIRE(BRIDGE_WITH_CLIENT_LOCK(
                    client, client.validate_or_remove_loaded_metadata(handle, changes)
                ));
                TorrentIdentity const *identity = identity_from_handle(handle);
                REQUIRE(identity != nullptr);
                REQUIRE_FALSE(identity->storage_activation);
                REQUIRE_FALSE(BRIDGE_WITH_CLIENT_LOCK(
                    client, client.metadata_validation_pending.contains(identity)
                ));
                if (change_priority) {
                    REQUIRE(::TorrentClientSetFilePriority(
                        &client, identity->token->value, 0, TTORRENT_FILE_PRIORITY_HIGH,
                        error.data(), static_cast<int32_t>(error.size())
                    ) == 0);
                }
                REQUIRE(client.save_resume_data_checked(identity->token->value, mode));
                fs::path const resume_path = state / "ResumeData" / (resume_id + std::string(kResumeExtension));
                FileReadResult const persisted = read_file(resume_path, kMaxResumeFileBytes);
                REQUIRE(persisted);
                auto const staged_metadata = staged_metadata_from_resume_data(*persisted);
                REQUIRE(staged_metadata);
                CHECK(*staged_metadata);
                CHECK_FALSE(metadata_validation_pending_from_resume_data(*persisted));
                CHECK_FALSE(storage_activation_from_resume_data(*persisted));
                // Restore the exact save made before teardown, then exercise
                // graceful shutdown persistence through two further reloads.
                REQUIRE(fs::copy_file(resume_path, restart_resume_directory / resume_path.filename()));
            }
            for (int restart = 0; restart < 2; ++restart) {
                CAPTURE(restart);
                std::size_t const previous_parse_count = parser->invocation_count();
                TTorrentClient reloaded(restart_state.string(), false, nullptr, parser);
                reloaded.set_session_shutdown_asynchronous(false);
                reloaded.stop_alert_worker();
                CHECK(parser->invocation_count() == previous_parse_count + 1U);
                std::vector<TTorrentSnapshot> const snapshots = copied_snapshots(reloaded);
                REQUIRE(snapshots.size() == 1U);
                CHECK(std::string(snapshots.front().id) == canonical_id.data());
                CHECK(bridge_bool(snapshots.front().has_metadata));
                CHECK(snapshots.front().queue_priority == TTORRENT_QUEUE_PRIORITY_HIGH);
                lt::torrent_handle const handle = mapped_torrent_handle(reloaded, resume_id);
                REQUIRE(handle.is_valid());
                auto const restored_info = handle.torrent_file();
                REQUIRE(restored_info);
                CHECK(std::ranges::equal(restored_info->info_section(), info->info_section()));
                TorrentIdentity const *identity = identity_from_handle(handle);
                REQUIRE(identity != nullptr);
                CHECK_FALSE(identity->storage_activation);
                CHECK_FALSE(identity->allow_pre_metadata_dht);
                CHECK(identity->dht_locked_by_source == private_torrent);
                CHECK(identity->peer_exchange_locked_by_source == private_torrent);
                CHECK(identity->lsd_locked_by_source == private_torrent);
                CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
                    reloaded, reloaded.metadata_validation_pending.contains(identity)
                ));
                CHECK(handle.get_file_priorities()
                    == std::vector<lt::download_priority_t>{lt::dont_download, lt::dont_download});
                CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::paused));
                CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
                CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex));
                CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd));
                CHECK(handle.status(lt::torrent_handle::query_save_path).save_path
                    == reloaded.staging_path(info->info_hashes()));
                std::array<TTorrentFileSnapshot, 2> files{};
                int32_t required_count = 0;
                std::uint8_t available = 0U;
                REQUIRE(reloaded.copy_files(identity->token->value, files, &required_count, &available) == 2);
                CHECK(bridge_bool(available));
                CHECK(files.front().priority == (change_priority
                    ? TTORRENT_FILE_PRIORITY_HIGH : TTORRENT_FILE_PRIORITY_NORMAL));
                CHECK(files.back().priority == TTORRENT_FILE_PRIORITY_SKIP);
                CHECK_FALSE(reloaded.take_alert_error(error));
            }
        }
    }
}

TEST_CASE("staged metadata resume restoration rejects malformed and conflicting markers")
{
    auto const info = make_torrent_info(false);
    lt::add_torrent_params params;
    params.ti = info;
    params.info_hashes = info->info_hashes();
    TorrentIdentity identity;
    identity.canonical_id = bridge_tests::canonical_id('a');
    std::vector<char> const encoded = encoded_resume_data(params, &identity);
    lt::error_code error;
    lt::bdecode_node const decoded = lt::bdecode(lt::span<char const>(encoded), error);
    REQUIRE_FALSE(error);

    auto rejects = [&]<typename Mutator>(std::string const &label, Mutator mutate, bool const preserves_record) {
        CAPTURE(label);
        bridge_tests::TemporaryDirectory temporary;
        fs::path const state = temporary.path() / "State";
        fs::path const resume_directory = state / "ResumeData";
        REQUIRE(fs::create_directories(resume_directory));
        lt::entry record(decoded);
        mutate(record);
        std::string bytes;
        lt::bencode(std::back_inserter(bytes), record);
        fs::path const path = resume_directory / (primary_hash_key(params.info_hashes) + std::string(kResumeExtension));
        REQUIRE(write_owner_only_file_checked(path, bytes));
        auto parser = std::make_shared<TestOnlyResumeInfoParser>();
        TTorrentClient client(state.string(), false, nullptr, parser);
        client.set_session_shutdown_asynchronous(false);
        CHECK(client.session.get_torrents().empty());
        CHECK(fs::exists(path) == preserves_record);
    };
    rejects("missing marker", [](lt::entry &record) {
        record.dict().erase(std::string(kStagedMetadataResumeKey));
    }, true);
    rejects("non-integer marker", [](lt::entry &record) {
        record[std::string(kStagedMetadataResumeKey)] = "1";
    }, false);
    rejects("unknown marker value", [](lt::entry &record) {
        record[std::string(kStagedMetadataResumeKey)] = 2;
    }, false);
    rejects("missing metadata", [](lt::entry &record) {
        record.dict().erase(std::string(kPreparsedInfoResumeKey));
    }, false);
    rejects("pending validation", [](lt::entry &record) {
        record[std::string(kMetadataValidationPendingResumeKey)] = 1;
    }, false);
    for (std::string_view const key : {kStorageClaimIDResumeKey, kStorageClaimGenerationResumeKey, kStorageManifestDigestResumeKey}) {
        rejects(std::string(key), [key](lt::entry &record) {
            record[std::string(key)] = 1;
        }, false);
    }
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

    TTorrentClient reloaded(state_directory.string());
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = mapped_torrent_handle(reloaded, resume_id);
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);

    CHECK(BRIDGE_WITH_CLIENT_LOCK(reloaded, reloaded.metadata_validation_pending.contains(identity)));
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
    int32_t add_outcome = TTORRENT_ADD_REJECTED;

    {
        TTorrentClient client(state_directory.string());
        client.set_session_shutdown_asynchronous(false);

        TTorrentSessionSettings settings{};
        settings.network_blocked = bridge_bool(false);
        settings.enable_dht = bridge_bool(false);
        settings.active_downloads = 3;
        settings.active_seeds = 5;
        settings.active_limit = 500;
        REQUIRE(apply_settings(
            &client,
            settings,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);

        REQUIRE(TorrentClientAddMagnet(
            &client,
            magnet.c_str(),
            add_options,
            added_id,
            static_cast<int32_t>(sizeof(added_id)),
            &add_outcome,
            error,
            static_cast<int32_t>(sizeof(error))
        ) == 0);

        lt::torrent_handle handle = mapped_torrent_handle(client, bridge_tests::v1_id('4'));
        TorrentIdentity *identity = identity_from_handle(handle);
        REQUIRE(identity != nullptr);
        CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
        CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(client, client.dht_disabled_by_app.contains(identity)));
    }

    TTorrentClient reloaded(state_directory.string());
    reloaded.set_session_shutdown_asynchronous(false);
    lt::torrent_handle handle = mapped_torrent_handle(reloaded, bridge_tests::v1_id('4'));
    TorrentIdentity *identity = identity_from_handle(handle);
    REQUIRE(identity != nullptr);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(reloaded, reloaded.dht_disabled_by_app.contains(identity)));
    REQUIRE(set_source_policy_field(
        reloaded,
        *identity,
        TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT,
        false,
        error
    ) == 0);

    TTorrentSessionSettings settings{};
    settings.network_blocked = bridge_bool(false);
    settings.enable_dht = bridge_bool(true);
    settings.active_downloads = 3;
    settings.active_seeds = 5;
    settings.active_limit = 500;
    REQUIRE(apply_settings(
        &reloaded,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(BRIDGE_WITH_CLIENT_LOCK(reloaded, reloaded.dht_disabled_by_app.contains(identity)));
    CHECK_FALSE(identity->allow_pre_metadata_dht);
}

TEST_CASE("metadata resolution keeps staged payload disabled and owns source policy")
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
    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        (client.metadata_validation_pending.insert(public_identity),
         client.validate_or_remove_loaded_metadata(public_handle, changes))
    ));
    REQUIRE(eventually([&public_handle] {
        std::vector<lt::download_priority_t> const priorities = public_handle.get_file_priorities();
        return priorities.size() == 1U && priorities.front() == lt::dont_download;
    }));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::block_non_global_peers));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.metadata_validation_pending.contains(public_identity)
    ));
    int32_t required_file_count = 0;
    std::uint8_t files_available = bridge_bool(false);
    REQUIRE(client.copy_files(
        public_identity->token->value,
        {},
        &required_file_count,
        &files_available
    ) == 0);
    REQUIRE(bridge_bool(files_available));
    REQUIRE(required_file_count == 1);
    std::array<TTorrentFileSnapshot, 1> files{};
    REQUIRE(client.copy_files(
        public_identity->token->value,
        files,
        &required_file_count,
        &files_available
    ) == 1);
    CHECK(files.front().priority == TTORRENT_FILE_PRIORITY_LOW);

    char priority_error[256]{};
    REQUIRE(TorrentClientSetFilePriority(
        &client,
        public_identity->canonical_id.c_str(),
        0,
        TTORRENT_FILE_PRIORITY_HIGH,
        priority_error,
        static_cast<int32_t>(sizeof(priority_error))
    ) == 0);
    REQUIRE(eventually([&public_handle] {
        std::vector<lt::download_priority_t> const priorities =
            public_handle.get_file_priorities();
        return priorities.size() == 1U
            && priorities.front() == lt::dont_download;
    }));
    REQUIRE(client.copy_files(
        public_identity->token->value,
        files,
        &required_file_count,
        &files_available
    ) == 1);
    CHECK(files.front().priority == TTORRENT_FILE_PRIORITY_HIGH);

    public_identity->dht_locked_by_source = true;
    public_identity->peer_exchange_locked_by_source = true;
    public_identity->lsd_locked_by_source = true;
    public_handle.set_flags(lt::torrent_flags::disable_dht);
    public_handle.set_flags(lt::torrent_flags::disable_pex);
    public_handle.set_flags(lt::torrent_flags::disable_lsd);
    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        (client.metadata_validation_pending.insert(public_identity),
         client.validate_or_remove_loaded_metadata(public_handle, changes))
    ));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_dht));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_lsd));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.metadata_validation_pending.contains(public_identity)
    ));

    public_identity->dht_locked_by_source = false;
    public_identity->peer_exchange_locked_by_source = false;
    public_identity->lsd_locked_by_source = false;
    public_handle.set_flags(lt::torrent_flags::disable_pex);
    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        (client.metadata_validation_pending.insert(public_identity),
         client.peer_exchange_disabled_by_app.insert(public_identity),
         client.validate_or_remove_loaded_metadata(public_handle, changes))
    ));
    CHECK(static_cast<bool>(public_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.metadata_validation_pending.contains(public_identity)
    ));
    CHECK(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.peer_exchange_disabled_by_app.contains(public_identity)
    ));

    auto private_info = make_torrent_info(true);
    TorrentIdentity *private_identity = nullptr;
    lt::torrent_handle private_handle = add_metadata_torrent(client, *private_info, temporary_directory.path(), private_identity);
    REQUIRE(private_identity != nullptr);

    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        (client.metadata_validation_pending.insert(private_identity),
         client.validate_or_remove_loaded_metadata(private_handle, changes))
    ));
    CHECK(static_cast<bool>(private_handle.flags() & lt::torrent_flags::disable_pex));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.metadata_validation_pending.contains(private_identity)
    ));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.peer_exchange_disabled_by_app.contains(private_identity)
    ));

    TTorrentSessionSettings settings{};
    settings.network_blocked = bridge_bool(true);
    char error[512]{};
    REQUIRE(apply_settings(
        &client,
        settings,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(static_cast<bool>(private_handle.flags() & lt::torrent_flags::disable_pex));

    REQUIRE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        (client.peer_exchange_disabled_by_app.insert(private_identity),
         client.metadata_validation_pending.insert(private_identity),
         client.validate_or_remove_loaded_metadata(private_handle, changes))
    ));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.peer_exchange_disabled_by_app.contains(private_identity)
    ));
    CHECK_FALSE(BRIDGE_WITH_CLIENT_LOCK(
        client,
        client.metadata_validation_pending.contains(private_identity)
    ));
}
