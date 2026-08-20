#include "TorrentBridgeInternal.hpp"

extern "C" {
__attribute__((visibility("hidden"), used, retain))
extern char const torrent7_native_deps_build_id[] = TORRENT7_NATIVE_DEPS_BUILD_ID;
}

#if __has_feature(address_sanitizer)
extern "C" __attribute__((visibility("default"), used, retain))
char const *__asan_default_options()
{
    // Enhanced Security helpers are launched by the system and may not inherit
    // the test runner's environment. Make every helper-side violation fail the lane.
    return "halt_on_error=1:abort_on_error=1";
}
#endif

#if __has_feature(thread_sanitizer)
extern "C" __attribute__((visibility("default"), used, retain))
char const *__tsan_default_options()
{
    // Enhanced Security helpers are launched by the system and may not inherit
    // the test runner's environment. Make every helper-side race fail the lane.
    return "halt_on_error=1:exitcode=66:print_full_thread_history=1";
}
#endif

namespace torrent_bridge::internal {

namespace {

constexpr int kUnlimitedTorrentCountLimit = static_cast<int>((1U << 24U) - 1U);

int normalized_torrent_count_limit(int limit)
{
    return limit >= kUnlimitedTorrentCountLimit ? -1 : limit;
}

bool is_valid_torrent_count_limit(int limit)
{
    return limit == -1 || limit >= 2;
}

struct QueueOrderingEntry {
    lt::torrent_handle handle;
    TorrentIdentity *identity = nullptr;
    int position = -1;
    int rank = kUnsetQueueRank;
};

struct ActiveTorrentEntry {
    lt::torrent_handle handle;
    TorrentIdentity *identity = nullptr;
};

std::vector<ActiveTorrentEntry> active_torrent_entries(TTorrentClient const &client)
{
    std::vector<ActiveTorrentEntry> entries;
    std::set<TorrentIdentity *> seen;
    std::scoped_lock io_guard(client.resume_io_lock);
    entries.reserve(client.active_identity_by_id.size());
    for (auto const &[id, identity] : client.active_identity_by_id) {
        if (identity == nullptr || !seen.insert(identity).second) {
            continue;
        }
        auto const handle = client.handle_by_id.find(id);
        if (handle != client.handle_by_id.end()) {
            entries.push_back(ActiveTorrentEntry{
                .handle = handle->second,
                .identity = identity,
            });
        }
    }
    return entries;
}

int queue_priority_sort_rank(int32_t priority)
{
    switch (priority) {
    case TTORRENT_QUEUE_PRIORITY_HIGH:
        return 0;
    case TTORRENT_QUEUE_PRIORITY_NORMAL:
        return 1;
    case TTORRENT_QUEUE_PRIORITY_LOW:
        return 2;
    default:
        return 1;
    }
}

std::optional<int> queue_position_value(lt::torrent_handle const &handle) noexcept
{
    try {
        int const position = static_cast<int>(handle.queue_position());
        if (position < 0) {
            return std::nullopt;
        }
        return position;
    } catch (...) {
        return std::nullopt;
    }
}

std::vector<QueueOrderingEntry> queue_ordering_entries(TTorrentClient const &client)
    TORRENT_BRIDGE_REQUIRES(client.lock, client.resume_io_lock)
{
    std::vector<lt::torrent_handle> handles;
    handles.reserve(client.handle_by_id.size());
    for (auto const &[id, handle] : client.handle_by_id) {
        static_cast<void>(id);
        handles.push_back(handle);
    }

    std::vector<QueueOrderingEntry> entries;
    std::set<TorrentIdentity *> seen;
    for (lt::torrent_handle const &handle : handles) {
        TorrentIdentity *identity = identity_from_handle(handle);
        if (identity == nullptr || !seen.insert(identity).second) {
            continue;
        }
        std::optional<int> const position = queue_position_value(handle);
        if (!position) {
            continue;
        }
        int const rank = is_valid_queue_rank(identity->queue_rank) ? identity->queue_rank : *position;
        entries.push_back(QueueOrderingEntry{
            .handle = handle,
            .identity = identity,
            .position = *position,
            .rank = rank
        });
    }

    std::ranges::sort(entries, [](QueueOrderingEntry const &left, QueueOrderingEntry const &right) {
        int const left_priority_rank = queue_priority_sort_rank(left.identity->queue_priority);
        int const right_priority_rank = queue_priority_sort_rank(right.identity->queue_priority);
        if (left_priority_rank != right_priority_rank) {
            return left_priority_rank < right_priority_rank;
        }
        if (left.rank != right.rank) {
            return left.rank < right.rank;
        }
        if (left.position != right.position) {
            return left.position < right.position;
        }
        return left.identity->canonical_id < right.identity->canonical_id;
    });
    return entries;
}

void append_unique_handle_by_identity(std::vector<lt::torrent_handle> &handles, lt::torrent_handle const &handle)
{
    TorrentIdentity const *identity = identity_from_handle(handle);
    if (identity != nullptr && std::ranges::any_of(handles, [identity](lt::torrent_handle const &existing) {
        return identity_from_handle(existing) == identity;
    })) {
        return;
    }
    handles.push_back(handle);
}

bool contains_handle_identity(std::span<lt::torrent_handle const> handles, lt::torrent_handle const &handle)
{
    TorrentIdentity const *identity = identity_from_handle(handle);
    return identity != nullptr && std::ranges::any_of(handles, [identity](lt::torrent_handle const &existing) {
        return identity_from_handle(existing) == identity;
    });
}

void save_and_publish_policy_handles(TTorrentClient &client, std::span<lt::torrent_handle const> handles,
                                     LockedChangePublisher &publisher) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    for (lt::torrent_handle const &handle : handles) {
        client.request_save(handle, kPolicyResumeSaveFlags);
        publisher.add(client.cache_snapshot(handle));
    }
}

std::vector<lt::torrent_handle> apply_queue_order(
    std::span<QueueOrderingEntry> entries,
    bool *positions_applied_out = nullptr
)
{
    bool positions_applied = true;
    std::vector<lt::torrent_handle> changed_handles;
    changed_handles.reserve(entries.size());

    int position = 0;
    int rank = 0;
    std::optional<int> priority_group;
    for (QueueOrderingEntry &entry : entries) {
        int const entry_priority_group = queue_priority_sort_rank(entry.identity->queue_priority);
        if (!priority_group || *priority_group != entry_priority_group) {
            priority_group = entry_priority_group;
            rank = 0;
        }

        bool changed = entry.position != position;
        if (entry.identity->queue_rank != rank) {
            entry.identity->queue_rank = rank;
            changed = true;
        }

        try {
            entry.handle.queue_position_set(lt::queue_position_t(position));
        } catch (...) {
            positions_applied = false;
            ignore_shutdown_failure();
        }

        if (changed) {
            // queue_ordering_entries already guarantees one entry per identity.
            changed_handles.push_back(entry.handle);
        }
        ++position;
        ++rank;
    }
    if (positions_applied_out != nullptr) {
        *positions_applied_out = positions_applied;
    }
    return changed_handles;
}

bool move_queue_entry(std::vector<QueueOrderingEntry> &entries, TorrentIdentity const *identity, int32_t move) noexcept
{
    auto const selected = std::ranges::find_if(entries, [identity](QueueOrderingEntry const &entry) {
        return entry.identity == identity;
    });
    if (selected == entries.end()) {
        return false;
    }

    int32_t const priority = selected->identity->queue_priority;
    auto const first = std::ranges::find_if(entries, [priority](QueueOrderingEntry const &entry) {
        return entry.identity->queue_priority == priority;
    });
    auto const last = std::find_if_not(first, entries.end(), [priority](QueueOrderingEntry const &entry) {
        return entry.identity->queue_priority == priority;
    });

    auto target = selected;
    switch (move) {
    case TTORRENT_QUEUE_MOVE_TOP:
        target = first;
        break;
    case TTORRENT_QUEUE_MOVE_UP:
        if (selected != first) {
            target = std::prev(selected);
        }
        break;
    case TTORRENT_QUEUE_MOVE_DOWN:
        if (std::next(selected) != last) {
            target = std::next(selected);
        }
        break;
    case TTORRENT_QUEUE_MOVE_BOTTOM:
        target = std::prev(last);
        break;
    default:
        return false;
    }
    if (target == selected) {
        return false;
    }

    if (target < selected) {
        std::rotate(target, selected, std::next(selected));
    } else {
        std::rotate(selected, std::next(selected), std::next(target));
    }
    return true;
}

} // namespace

std::vector<lt::torrent_handle> TTorrentClient::apply_queue_priority_order_locked()
{
    std::scoped_lock io_guard(resume_io_lock);
#if defined(TORRENT_BRIDGE_TESTING)
    ++queue_order_rebuild_count;
    if (fail_next_queue_order_rebuild_before_collection) {
        fail_next_queue_order_rebuild_before_collection = false;
        throw std::runtime_error("Injected queue-order rebuild failure.");
    }
#endif
    std::vector<QueueOrderingEntry> entries = queue_ordering_entries(*this);
    bool positions_applied = false;
    std::vector<lt::torrent_handle> changed_handles = apply_queue_order(entries, &positions_applied);

    queue_order_index.reset();
    for (auto const &owned_identity : torrent_identities) {
        if (owned_identity != nullptr) {
            owned_identity->queue_order_tracked = false;
        }
    }
    queue_order_index.valid = positions_applied;
    if (!positions_applied) {
        return changed_handles;
    }

    for (auto const &entry : entries) {
        auto *const priority = queue_order_index.state(entry.identity->queue_priority);
        if (priority == nullptr) {
            invalidate_queue_order_index_locked();
            break;
        }
        if (priority->count >= static_cast<std::size_t>(std::numeric_limits<int32_t>::max())) {
            invalidate_queue_order_index_locked();
            break;
        }
        ++priority->count;
        priority->next_rank = static_cast<int32_t>(priority->count);
        entry.identity->queue_order_tracked = true;
    }
    return changed_handles;
}

void TTorrentClient::insert_added_queue_priority_order_locked(
    lt::torrent_handle const &handle,
    TorrentIdentity *identity
)
{
    if (identity == nullptr || !is_valid_queue_priority(identity->queue_priority)) {
        invalidate_queue_order_index_locked();
        return;
    }

    std::optional<int> const position = queue_position_value(handle);
    if (!position) {
        identity->queue_rank = kUnsetQueueRank;
        identity->queue_order_tracked = false;
        return;
    }

    auto const queued_count = queue_order_index.total_count();
    if (!queue_order_index.valid) {
        return;
    }
    if (std::cmp_not_equal(*position, queued_count)) {
        invalidate_queue_order_index_locked();
        return;
    }

    auto *const priority = queue_order_index.state(identity->queue_priority);
    auto const insertion_position = queue_order_index.insertion_position(identity->queue_priority);
    if (priority == nullptr || !insertion_position) {
        invalidate_queue_order_index_locked();
        return;
    }
    if (priority->next_rank == std::numeric_limits<int32_t>::max()) {
        invalidate_queue_order_index_locked();
        return;
    }
    if (*insertion_position > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        invalidate_queue_order_index_locked();
        return;
    }

    try {
        if (std::cmp_not_equal(*insertion_position, *position)) {
            handle.queue_position_set(lt::queue_position_t(static_cast<int>(*insertion_position)));
        }
    } catch (...) {
        invalidate_queue_order_index_locked();
        ignore_shutdown_failure();
        return;
    }

    identity->queue_rank = priority->next_rank++;
    identity->queue_order_tracked = true;
    ++priority->count;
}

namespace {

struct NativeNetworkStateExpectation {
    std::string_view listen_interfaces;
    std::string_view outgoing_interfaces;
    bool enable_upnp;
    bool enable_natpmp;
    bool enable_dht;
    bool enable_lsd;
    bool enable_outgoing_tcp;
    bool enable_incoming_tcp;
    bool enable_outgoing_utp;
    bool enable_incoming_utp;
    bool dht_privacy_lookups;
    std::optional<bool> dht_read_only;
    std::optional<bool> use_dht_as_fallback;
    bool session_paused;
};

BridgeResult acknowledge_network_state_locked(
    TTorrentClient &client,
    NativeNetworkStateExpectation const &expected,
    std::string_view failure_message
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    // get_settings() and is_paused() are synchronous libtorrent-context calls.
    // They cannot complete until the settings and pause/resume operations queued
    // before them have run on the session's single network executor.
    lt::settings_pack const current = client.session.get_settings();
    bool const session_paused = client.session.is_paused();
    if (current.get_str(lt::settings_pack::listen_interfaces) != expected.listen_interfaces
        || current.get_str(lt::settings_pack::outgoing_interfaces) != expected.outgoing_interfaces
        || current.get_bool(lt::settings_pack::enable_upnp) != expected.enable_upnp
        || current.get_bool(lt::settings_pack::enable_natpmp) != expected.enable_natpmp
        || current.get_bool(lt::settings_pack::enable_dht) != expected.enable_dht
        || current.get_bool(lt::settings_pack::enable_lsd) != expected.enable_lsd
        || current.get_bool(lt::settings_pack::enable_outgoing_tcp) != expected.enable_outgoing_tcp
        || current.get_bool(lt::settings_pack::enable_incoming_tcp) != expected.enable_incoming_tcp
        || current.get_bool(lt::settings_pack::enable_outgoing_utp) != expected.enable_outgoing_utp
        || current.get_bool(lt::settings_pack::enable_incoming_utp) != expected.enable_incoming_utp
        || current.get_bool(lt::settings_pack::dht_privacy_lookups) != expected.dht_privacy_lookups
        || (expected.dht_read_only
            && current.get_bool(lt::settings_pack::dht_read_only) != *expected.dht_read_only)
        || (expected.use_dht_as_fallback
            && current.get_bool(lt::settings_pack::use_dht_as_fallback) != *expected.use_dht_as_fallback)
        || session_paused != expected.session_paused) {
        return bridge_error(2, std::string(failure_message));
    }
    return {};
}

BridgeResult block_network_locked(
    TTorrentClient &client,
    DirtyMask &changes
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    changes = 0U;

    lt::settings_pack settings;
    settings.set_str(lt::settings_pack::listen_interfaces, "");
    settings.set_str(lt::settings_pack::outgoing_interfaces, "");
    settings.set_bool(lt::settings_pack::enable_upnp, false);
    settings.set_bool(lt::settings_pack::enable_natpmp, false);
    settings.set_bool(lt::settings_pack::enable_dht, false);
    settings.set_bool(lt::settings_pack::enable_lsd, false);
    settings.set_bool(lt::settings_pack::enable_outgoing_tcp, false);
    settings.set_bool(lt::settings_pack::enable_incoming_tcp, false);
    settings.set_bool(lt::settings_pack::enable_outgoing_utp, false);
    settings.set_bool(lt::settings_pack::enable_incoming_utp, false);
    settings.set_bool(lt::settings_pack::dht_privacy_lookups, false);
    client.session.apply_settings(std::move(settings));
    client.session.pause();

    BridgeResult const acknowledged = acknowledge_network_state_locked(
        client,
        NativeNetworkStateExpectation{
            .listen_interfaces = "",
            .outgoing_interfaces = "",
            .enable_upnp = false,
            .enable_natpmp = false,
            .enable_dht = false,
            .enable_lsd = false,
            .enable_outgoing_tcp = false,
            .enable_incoming_tcp = false,
            .enable_outgoing_utp = false,
            .enable_incoming_utp = false,
            .dht_privacy_lookups = false,
            .dht_read_only = std::nullopt,
            .use_dht_as_fallback = std::nullopt,
            .session_paused = true,
        },
        "Native network containment could not be confirmed."
    );
    if (!acknowledged) {
        return acknowledged;
    }

    changes = client.record_network_blocked();
    client.request_snapshot_update_locked();
    return {};
}

using NormalizedLiveSavePathResult = std::expected<std::string, BridgeError>;

NormalizedLiveSavePathResult normalized_live_save_path(std::string_view const save_path)
{
    BridgeResult const valid_save_path = validate_save_path(save_path);
    if (!valid_save_path) {
        return std::unexpected(valid_save_path.error());
    }

    std::optional<std::string> normalized = normalize_authorized_save_path(save_path);
    if (!normalized) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The save path is invalid.",
        });
    }
    return std::move(*normalized);
}

using AuthorizedSaveRootLookupResult =
    std::expected<std::shared_ptr<lt::aux::storage_root>, BridgeError>;

AuthorizedSaveRootLookupResult require_authorized_save_path(
    TTorrentClient const &client,
    std::string const &normalized_save_path
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    auto const root = client.authorized_save_roots.find(normalized_save_path);
    if (root == client.authorized_save_roots.end() || !root->second) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The save path is not authorized.",
        });
    }
    return root->second;
}

BridgeResult prepare_authorized_root_lifetime_replacement(
    TTorrentClient &client,
    AuthorizedSaveRootMap const &replacement
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    std::set<lt::aux::storage_root const *> current_roots;
    for (auto const &[path, root] : client.authorized_save_roots) {
        static_cast<void>(path);
        if (root) {
            current_roots.insert(root.get());
        }
    }

    std::set<lt::aux::storage_root const *> replacement_roots;
    AuthorizedSaveRootWeakList tracked_roots;
    tracked_roots.reserve(client.authorized_save_root_lifetimes.size() + replacement.size());
    for (auto const &[path, root] : replacement) {
        static_cast<void>(path);
        if (root && replacement_roots.insert(root.get()).second) {
            tracked_roots.emplace_back(root);
        }
    }

    std::set<lt::aux::storage_root const *> roots_live_after_replacement = replacement_roots;
    for (std::weak_ptr<lt::aux::storage_root> const &weak_root
         : client.authorized_save_root_lifetimes) {
        long const strong_reference_count = weak_root.use_count();
        std::shared_ptr<lt::aux::storage_root> const root = weak_root.lock();
        if (!root || replacement_roots.contains(root.get())) {
            continue;
        }

        bool const expires_with_current_allowlist = current_roots.contains(root.get())
            && strong_reference_count == 1;
        if (expires_with_current_allowlist) {
            continue;
        }
        if (roots_live_after_replacement.insert(root.get()).second) {
            tracked_roots.emplace_back(root);
        }
    }

    if (roots_live_after_replacement.size()
        > static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT)) {
        return bridge_error(
            TTORRENT_ERROR_AUTHORIZED_SAVE_ROOT_CAPACITY,
            "Too many authorized save roots remain in use."
        );
    }

    client.authorized_save_root_lifetimes.swap(tracked_roots);
    return {};
}

#if defined(__PTRAUTH__)
constexpr ptrauth_extra_data_t kAuthorizedRootRetainCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.authorized-root.retain");
constexpr ptrauth_extra_data_t kAuthorizedRootReleaseCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.authorized-root.release");

static_assert(kWakeCallbackDiscriminator != kAuthorizedRootRetainCallbackDiscriminator);
static_assert(kWakeCallbackDiscriminator != kAuthorizedRootReleaseCallbackDiscriminator);
static_assert(
    kAuthorizedRootRetainCallbackDiscriminator != kAuthorizedRootReleaseCallbackDiscriminator
);
#endif

struct AuthorizedRootLifetimeCallbacks {
#if defined(__PTRAUTH__)
    using RetainCallback = TTorrentAuthorizedRootLifetimeRetainCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kAuthorizedRootRetainCallbackDiscriminator
    );
    using ReleaseCallback = TTorrentAuthorizedRootLifetimeReleaseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kAuthorizedRootReleaseCallbackDiscriminator
    );
#else
    using RetainCallback = TTorrentAuthorizedRootLifetimeRetainCallback;
    using ReleaseCallback = TTorrentAuthorizedRootLifetimeReleaseCallback;
#endif

    RetainCallback retain = nullptr;
    ReleaseCallback release = nullptr;
};

#if defined(__PTRAUTH__)
static_assert(!std::is_trivially_copyable_v<AuthorizedRootLifetimeCallbacks>);
#endif

struct AuthorizedRootLifetime {
    AuthorizedRootLifetime(
        AuthorizedRootLifetimeCallbacks lifetime_callbacks,
        std::uint64_t const lifetime_token
    ) noexcept
        : callbacks(std::move(lifetime_callbacks)), token(lifetime_token)
    {
    }

    AuthorizedRootLifetime(AuthorizedRootLifetime const &) = delete;
    AuthorizedRootLifetime &operator=(AuthorizedRootLifetime const &) = delete;
    AuthorizedRootLifetime(AuthorizedRootLifetime &&) = delete;
    AuthorizedRootLifetime &operator=(AuthorizedRootLifetime &&) = delete;

    ~AuthorizedRootLifetime()
    {
        if (retained) {
            callbacks.release(token);
        }
    }

    [[nodiscard]] bool retain() noexcept
    {
        retained = callbacks.retain(token) != 0U;
        return retained;
    }

    AuthorizedRootLifetimeCallbacks callbacks;
    std::uint64_t token = 0U;
    bool retained = false;
};

#if defined(__PTRAUTH__)
static_assert(!std::is_trivially_copyable_v<AuthorizedRootLifetime>);
#endif

[[nodiscard]] std::uint64_t authorized_root_lifetime_token(
    lt::aux::storage_root const &root
) noexcept
{
    auto const *lifetime = static_cast<AuthorizedRootLifetime const *>(
        root.lifetime_context()
    );
    return lifetime == nullptr ? 0U : lifetime->token;
}

BridgeResult preflight_authorized_root_lifetime_replacement(
    TTorrentClient &client,
    std::uint8_t const *authorized_save_paths_blob,
    int32_t const authorized_save_paths_blob_size,
    TTorrentAuthorizedSaveRoot const *authorized_save_roots,
    int32_t const authorized_save_root_count,
    AuthorizedRootLifetimeCallbacks const &callbacks
)
{
    if (authorized_save_paths_blob_size < 0
        || authorized_save_paths_blob_size > TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES
        || authorized_save_root_count < 0
        || authorized_save_root_count > TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT) {
        return {};
    }
    bool const has_path_blob = authorized_save_paths_blob != nullptr;
    bool const has_path_bytes = authorized_save_paths_blob_size != 0;
    bool const has_roots = authorized_save_roots != nullptr;
    bool const has_root_records = authorized_save_root_count != 0;
    bool const has_retain_callback = callbacks.retain != nullptr;
    bool const has_release_callback = callbacks.release != nullptr;
    if (has_path_blob != has_path_bytes
        || has_roots != has_root_records
        || has_retain_callback != has_release_callback
        || (has_root_records && !has_retain_callback)) {
        return {};
    }

    AuthorizedSavePathListResult const paths = parse_authorized_save_path_list_blob(
        input_span_from_c_buffer(authorized_save_paths_blob, authorized_save_paths_blob_size)
    );
    if (!paths || paths->size() != static_cast<std::size_t>(authorized_save_root_count)) {
        return {};
    }
    std::span<TTorrentAuthorizedSaveRoot const> const borrowed_records =
        input_span_from_c_buffer(authorized_save_roots, authorized_save_root_count);
    std::vector<TTorrentAuthorizedSaveRoot> const records(
        borrowed_records.begin(),
        borrowed_records.end()
    );
    std::set<std::string> unique_paths;
    std::set<std::pair<std::uint64_t, std::uint64_t>> unique_identities;
    for (std::size_t index = 0U; index < records.size(); ++index) {
        TTorrentAuthorizedSaveRoot const &record = records.at(index);
        if (record.directory_descriptor < 0
            || record.lifetime_token == 0U
            || !unique_paths.insert(paths->at(index)).second
            || !unique_identities.emplace(record.device, record.inode).second) {
            return {};
        }
    }

    struct LiveRoot {
        std::shared_ptr<lt::aux::storage_root> root;
        bool expires_with_current_allowlist;
    };

    std::scoped_lock guard(client.lock);
    std::set<lt::aux::storage_root const *> current_roots;
    for (auto const &[path, root] : client.authorized_save_roots) {
        static_cast<void>(path);
        if (root) {
            current_roots.insert(root.get());
        }
    }

    std::vector<LiveRoot> live_roots;
    live_roots.reserve(client.authorized_save_root_lifetimes.size());
    std::set<lt::aux::storage_root const *> seen_roots;
    for (std::weak_ptr<lt::aux::storage_root> const &weak_root
         : client.authorized_save_root_lifetimes) {
        long const strong_reference_count = weak_root.use_count();
        std::shared_ptr<lt::aux::storage_root> root = weak_root.lock();
        if (!root || !seen_roots.insert(root.get()).second) {
            continue;
        }
        bool const expires_with_current_allowlist = current_roots.contains(root.get())
            && strong_reference_count == 1;
        live_roots.push_back(LiveRoot{
            .root = std::move(root),
            .expires_with_current_allowlist = expires_with_current_allowlist,
        });
    }

    std::set<lt::aux::storage_root const *> roots_live_after_replacement;
    for (LiveRoot const &live_root : live_roots) {
        if (!live_root.expires_with_current_allowlist) {
            roots_live_after_replacement.insert(live_root.root.get());
        }
    }

    std::size_t new_root_count = 0U;
    for (std::size_t index = 0U; index < records.size(); ++index) {
        TTorrentAuthorizedSaveRoot const &record = records.at(index);
        auto const reusable = std::ranges::find_if(
            live_roots,
            [&](LiveRoot const &live_root) {
                return live_root.root->path() == paths->at(index)
                    && live_root.root->device() == record.device
                    && live_root.root->inode() == record.inode
                    && authorized_root_lifetime_token(*live_root.root)
                        == record.lifetime_token;
            }
        );
        if (reusable == live_roots.end()) {
            ++new_root_count;
        } else {
            roots_live_after_replacement.insert(reusable->root.get());
        }
    }

    if (roots_live_after_replacement.size() + new_root_count
        > static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT)) {
        return bridge_error(
            TTORRENT_ERROR_AUTHORIZED_SAVE_ROOT_CAPACITY,
            "Too many authorized save roots remain in use."
        );
    }
    return {};
}

using AuthorizedRootLifetimeResult = std::expected<std::shared_ptr<void>, BridgeError>;

[[nodiscard]] AuthorizedRootLifetimeResult retain_authorized_root_lifetime(
    std::uint64_t const token,
    AuthorizedRootLifetimeCallbacks const &callbacks
)
{
    auto lifetime = std::make_shared<AuthorizedRootLifetime>(callbacks, token);
    if (!lifetime->retain()) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "An authorized save root lifetime token is invalid.",
        });
    }
    return std::static_pointer_cast<void>(std::move(lifetime));
}

AuthorizedSaveRootResult authorized_save_roots_from_c_buffer(
    std::uint8_t const *authorized_save_paths_blob,
    int32_t const authorized_save_paths_blob_size,
    TTorrentAuthorizedSaveRoot const *authorized_save_roots,
    int32_t const authorized_save_root_count,
    TTorrentAuthorizedRootLifetimeRetainCallback const retain_authorized_root,
    TTorrentAuthorizedRootLifetimeReleaseCallback const release_authorized_root,
    AuthorizedSaveRootWeakList const *reusable_roots = nullptr
)
{
    if (authorized_save_paths_blob_size < 0
        || authorized_save_paths_blob_size > TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save path list has an invalid size.",
        });
    }
    bool const has_path_blob = authorized_save_paths_blob != nullptr;
    bool const has_path_bytes = authorized_save_paths_blob_size != 0;
    if (has_path_blob != has_path_bytes) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save path list pointer and size do not match.",
        });
    }
    if (authorized_save_root_count < 0
        || authorized_save_root_count > TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save root list has an invalid count.",
        });
    }
    bool const has_roots = authorized_save_roots != nullptr;
    bool const has_root_records = authorized_save_root_count != 0;
    if (has_roots != has_root_records) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save root list pointer and count do not match.",
        });
    }
    bool const has_retain_callback = retain_authorized_root != nullptr;
    bool const has_release_callback = release_authorized_root != nullptr;
    if (has_retain_callback != has_release_callback
        || (has_root_records && !has_retain_callback)) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save root lifetime callbacks are invalid.",
        });
    }

    AuthorizedSavePathListResult paths = parse_authorized_save_path_list_blob(
        input_span_from_c_buffer(authorized_save_paths_blob, authorized_save_paths_blob_size)
    );
    if (!paths) {
        return std::unexpected(paths.error());
    }
    if (paths->size() != static_cast<std::size_t>(authorized_save_root_count)) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save paths and roots do not correspond.",
        });
    }

    AuthorizedSaveRootMap roots;
    std::set<std::pair<std::uint64_t, std::uint64_t>> identities;
    // The retain callback is supplied by the caller and may release or mutate
    // its borrowed input storage. Snapshot every bounded record before the
    // first callback so validation never rereads caller-owned memory.
    std::span<TTorrentAuthorizedSaveRoot const> const borrowed_records =
        input_span_from_c_buffer(authorized_save_roots, authorized_save_root_count);
    std::vector<TTorrentAuthorizedSaveRoot> records(
        borrowed_records.begin(),
        borrowed_records.end()
    );
    auto path = paths->cbegin();
    AuthorizedRootLifetimeCallbacks const lifetime_callbacks{
        .retain = retain_authorized_root,
        .release = release_authorized_root,
    };
    for (TTorrentAuthorizedSaveRoot const &record : records) {
        std::string const &canonical_path = *path;
        ++path;
        if (record.directory_descriptor < 0 || record.lifetime_token == 0U) {
            return std::unexpected(BridgeError{
                .code = 1,
                .message = "An authorized save root record is invalid.",
            });
        }
        if (!identities.emplace(record.device, record.inode).second
            || roots.contains(canonical_path)) {
            return std::unexpected(BridgeError{
                .code = 1,
                .message = "The authorized save root list contains a duplicate.",
            });
        }

        AuthorizedRootLifetimeResult lifetime = retain_authorized_root_lifetime(
            record.lifetime_token,
            lifetime_callbacks
        );
        if (!lifetime) {
            return std::unexpected(lifetime.error());
        }
        lt::error_code root_error;
        std::shared_ptr<lt::aux::storage_root> root = lt::aux::make_storage_root(
            canonical_path,
            record.directory_descriptor,
            record.device,
            record.inode,
            std::move(*lifetime),
            root_error
        );
        if (root_error || !root) {
            bool const descriptor_capacity_exhausted = root_error.value() == EMFILE
                || root_error.value() == ENFILE;
            return std::unexpected(BridgeError{
                .code = descriptor_capacity_exhausted
                    ? TTORRENT_ERROR_AUTHORIZED_SAVE_ROOT_CAPACITY
                    : 1,
                .message = descriptor_capacity_exhausted
                    ? "Too many authorized save roots remain in use."
                    : "An authorized save root does not match its directory capability.",
            });
        }

        if (reusable_roots != nullptr) {
            for (std::weak_ptr<lt::aux::storage_root> const &weak_root : *reusable_roots) {
                std::shared_ptr<lt::aux::storage_root> candidate = weak_root.lock();
                if (candidate
                    && candidate->path() == canonical_path
                    && candidate->device() == record.device
                    && candidate->inode() == record.inode
                    && authorized_root_lifetime_token(*candidate)
                        == record.lifetime_token) {
                    root = std::move(candidate);
                    break;
                }
            }
        }
        roots.emplace(canonical_path, std::move(root));
    }
    return roots;
}

struct SourcePolicyApplicationResult {
    DirtyMask changes = 0;
    std::vector<lt::torrent_handle> handles_to_save;
};

void add_policy_save(SourcePolicyApplicationResult &result, lt::torrent_handle const &handle)
{
    if (handle.is_valid()) {
        result.handles_to_save.push_back(handle);
    }
}

void add_policy_result(SourcePolicyApplicationResult &result, SourcePolicyApplicationResult next)
{
    result.changes |= next.changes;
    result.handles_to_save.insert(
        result.handles_to_save.end(),
        std::make_move_iterator(next.handles_to_save.begin()),
        std::make_move_iterator(next.handles_to_save.end())
    );
}

bool set_torrent_flag_if_needed(lt::torrent_handle const &handle, lt::torrent_flags_t flag)
{
    if (static_cast<bool>(handle.flags() & flag)) {
        return false;
    }
    handle.set_flags(flag);
    return true;
}

bool unset_torrent_flag_if_needed(lt::torrent_handle const &handle, lt::torrent_flags_t flag)
{
    if (!static_cast<bool>(handle.flags() & flag)) {
        return false;
    }
    handle.unset_flags(flag);
    return true;
}

void request_policy_saves(TTorrentClient &client, std::vector<lt::torrent_handle> const &handles)
{
    for (lt::torrent_handle const &handle : handles) {
        client.request_save(handle);
    }
}

SourcePolicyApplicationResult apply_dht_policy_locked(TTorrentClient &client, bool use_dht_by_default)
    TORRENT_BRIDGE_REQUIRES(client.lock)
{
    client.dht_enabled_by_default = use_dht_by_default;
    SourcePolicyApplicationResult result;
    for (ActiveTorrentEntry const &entry : active_torrent_entries(client)) {
        TorrentIdentity *identity = entry.identity;
        lt::torrent_handle const &handle = entry.handle;
        bool changed = false;
        if (identity->dht_locked_by_source) {
            changed = identity->dht_enabled_by_user || identity->dht_disabled_by_user;
            identity->dht_enabled_by_user = false;
            identity->dht_disabled_by_user = false;
            changed = client.dht_disabled_by_app.erase(identity) > 0U || changed;
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_dht) || changed;
            result.changes |= client.clear_peer_cache_if_restricted(handle, identity);
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (client.metadata_validation_pending.contains(identity)) {
            if (use_dht_by_default) {
                changed = client.dht_disabled_by_app.erase(identity) > 0U;
            } else {
                changed = client.dht_disabled_by_app.insert(identity).second;
            }
            if (identity->allow_pre_metadata_dht) {
                changed = unset_torrent_flag_if_needed(handle, lt::torrent_flags::disable_dht) || changed;
            } else {
                changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_dht) || changed;
                result.changes |= client.clear_peer_cache_if_restricted(handle, identity);
            }
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (identity->dht_enabled_by_user) {
            changed = client.dht_disabled_by_app.erase(identity) > 0U;
            changed = unset_torrent_flag_if_needed(handle, lt::torrent_flags::disable_dht) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (identity->dht_disabled_by_user) {
            changed = client.dht_disabled_by_app.erase(identity) > 0U;
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_dht) || changed;
            result.changes |= client.clear_peer_cache_if_restricted(handle, identity);
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (use_dht_by_default) {
            if (client.dht_disabled_by_app.erase(identity) > 0U) {
                changed = true;
                changed = unset_torrent_flag_if_needed(handle, lt::torrent_flags::disable_dht) || changed;
            }
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        changed = client.dht_disabled_by_app.insert(identity).second;
        changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_dht) || changed;
        result.changes |= client.clear_peer_cache_if_restricted(handle, identity);
        if (changed) {
            add_policy_save(result, handle);
        }
    }
    return result;
}

SourcePolicyApplicationResult apply_lsd_policy_locked(TTorrentClient &client, bool use_lsd_by_default)
    TORRENT_BRIDGE_REQUIRES(client.lock)
{
    client.lsd_enabled_by_default = use_lsd_by_default;
    SourcePolicyApplicationResult result;
    for (ActiveTorrentEntry const &entry : active_torrent_entries(client)) {
        TorrentIdentity *identity = entry.identity;
        lt::torrent_handle const &handle = entry.handle;
        bool changed = false;
        if (identity->lsd_locked_by_source) {
            changed = identity->lsd_enabled_by_user || identity->lsd_disabled_by_user;
            identity->lsd_enabled_by_user = false;
            identity->lsd_disabled_by_user = false;
            changed = client.lsd_disabled_by_app.erase(identity) > 0U || changed;
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_lsd) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (client.metadata_validation_pending.contains(identity)) {
            if (use_lsd_by_default) {
                changed = client.lsd_disabled_by_app.erase(identity) > 0U;
            } else {
                changed = client.lsd_disabled_by_app.insert(identity).second;
            }
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_lsd) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (identity->lsd_enabled_by_user) {
            changed = client.lsd_disabled_by_app.erase(identity) > 0U;
            changed = unset_torrent_flag_if_needed(handle, lt::torrent_flags::disable_lsd) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (identity->lsd_disabled_by_user) {
            changed = client.lsd_disabled_by_app.erase(identity) > 0U;
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_lsd) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (use_lsd_by_default) {
            if (client.lsd_disabled_by_app.erase(identity) > 0U) {
                changed = true;
                changed = unset_torrent_flag_if_needed(handle, lt::torrent_flags::disable_lsd) || changed;
            }
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        changed = client.lsd_disabled_by_app.insert(identity).second;
        changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_lsd) || changed;
        if (changed) {
            add_policy_save(result, handle);
        }
    }
    return result;
}

SourcePolicyApplicationResult apply_peer_exchange_policy_locked(TTorrentClient &client, bool use_peer_exchange_by_default)
    TORRENT_BRIDGE_REQUIRES(client.lock)
{
    client.peer_exchange_enabled_by_default = use_peer_exchange_by_default;
    SourcePolicyApplicationResult result;
    for (ActiveTorrentEntry const &entry : active_torrent_entries(client)) {
        TorrentIdentity *identity = entry.identity;
        lt::torrent_handle const &handle = entry.handle;
        bool changed = false;
        if (identity->peer_exchange_locked_by_source) {
            changed = identity->peer_exchange_enabled_by_user || identity->peer_exchange_disabled_by_user;
            identity->peer_exchange_enabled_by_user = false;
            identity->peer_exchange_disabled_by_user = false;
            changed = client.peer_exchange_disabled_by_app.erase(identity) > 0U || changed;
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_pex) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (!client.peer_exchange_plugin_enabled) {
            changed = client.peer_exchange_disabled_by_app.insert(identity).second;
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_pex) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (client.metadata_validation_pending.contains(identity)) {
            bool const intended_enabled = identity->peer_exchange_enabled_by_user
                || (!identity->peer_exchange_disabled_by_user && use_peer_exchange_by_default);
            if (intended_enabled) {
                changed = client.peer_exchange_disabled_by_app.erase(identity) > 0U;
            } else {
                changed = client.peer_exchange_disabled_by_app.insert(identity).second;
            }
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_pex) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (identity->peer_exchange_enabled_by_user) {
            changed = client.peer_exchange_disabled_by_app.erase(identity) > 0U;
            if (!client.metadata_validation_pending.contains(identity)) {
                changed = unset_torrent_flag_if_needed(handle, lt::torrent_flags::disable_pex) || changed;
            }
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (identity->peer_exchange_disabled_by_user) {
            changed = client.peer_exchange_disabled_by_app.erase(identity) > 0U;
            changed = set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_pex) || changed;
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (use_peer_exchange_by_default) {
            bool const was_disabled_by_app = client.peer_exchange_disabled_by_app.erase(identity) > 0U;
            changed = was_disabled_by_app;
            if (was_disabled_by_app && !client.metadata_validation_pending.contains(identity)) {
                changed = unset_torrent_flag_if_needed(handle, lt::torrent_flags::disable_pex) || changed;
            }
            if (changed) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (client.peer_exchange_disabled_by_app.contains(identity)) {
            if (set_torrent_flag_if_needed(handle, lt::torrent_flags::disable_pex)) {
                add_policy_save(result, handle);
            }
            continue;
        }

        if (static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex)) {
            continue;
        }

        handle.set_flags(lt::torrent_flags::disable_pex);
        client.peer_exchange_disabled_by_app.insert(identity);
        add_policy_save(result, handle);
    }
    return result;
}

using TrackerTopologyEntry = std::pair<std::string_view, std::uint8_t>;

std::vector<TrackerTopologyEntry> tracker_topology(std::vector<lt::announce_entry> const &trackers)
{
    std::vector<TrackerTopologyEntry> topology;
    topology.reserve(trackers.size());
    for (lt::announce_entry const &tracker : trackers) {
        topology.emplace_back(tracker.url, tracker.tier);
    }
    std::ranges::sort(topology);
    return topology;
}

bool same_tracker_topology(
    std::vector<lt::announce_entry> const &left,
    std::vector<lt::announce_entry> const &right
)
{
    return tracker_topology(left) == tracker_topology(right);
}

void preserve_runtime_tracker_state(
    std::vector<lt::announce_entry> &desired,
    std::vector<lt::announce_entry> const &current
)
{
    std::map<std::string_view, lt::announce_entry const *> current_by_url;
    for (lt::announce_entry const &tracker : current) {
        current_by_url.emplace(tracker.url, &tracker);
    }

    for (lt::announce_entry &tracker : desired) {
        auto const current_tracker = current_by_url.find(tracker.url);
        if (current_tracker == current_by_url.end()) {
            continue;
        }
        std::uint8_t const desired_tier = tracker.tier;
        tracker = *current_tracker->second;
        tracker.tier = desired_tier;
    }
}

} // namespace

DirtyMask TTorrentClient::enforce_https_source_policy(
    lt::torrent_handle const &handle,
    TorrentIdentity *identity,
    HTTPSSourcePolicyScope const scope
)
{
    if (!handle.is_valid()) {
        return {};
    }

    DirtyMask changes = 0;
    bool changed = false;
    bool trackers_changed = false;
    bool web_seeds_changed = false;

    if (updates_https_trackers(scope)) {
        std::vector<lt::announce_entry> const trackers = handle.trackers();
        std::vector<lt::announce_entry> const effective_trackers = trackers_for_https_policy(
            trackers,
            effective_https_tracker_policy(identity)
        );
        trackers_changed = !same_tracker_topology(trackers, effective_trackers);
        if (trackers_changed) {
            handle.replace_trackers(effective_trackers);
            handle.force_reannounce();
            changes |= cache_trackers(handle, effective_trackers);
            changed = true;
        }
    }

    bool const require_web_seeds = effective_https_web_seed_policy(identity) == HTTPSPolicy::require;
    if (updates_https_web_seeds(scope) && require_web_seeds) {
        for (std::string const &url : handle.url_seeds()) {
            if (!is_https_url(url)) {
                handle.remove_url_seed(url);
                changed = true;
                web_seeds_changed = true;
            }
        }
    }

    if (web_seeds_changed) {
        if (std::optional<std::string> const cache_id = cache_id_for_handle(handle)) {
            if (auto cached = web_seed_cache.find(*cache_id); cached != web_seed_cache.end()) {
                auto const original_size = cached->second.web_seeds.size();
                std::erase_if(cached->second.web_seeds, [](TTorrentWebSeedSnapshot const &snapshot) {
                    return !is_https_url(snapshot.url);
                });
                if (cached->second.web_seeds.size() != original_size) {
                    cached->second.revision = web_seed_revision + 1U;
                    changes |= mark_web_seed_cache_changed();
                }
            }
        }
    }
    if (trackers_changed) {
        changes |= clear_peer_cache_if_restricted(handle, identity);
    }
    if (changed) {
        request_save(handle);
    }

    return changes;
}

DirtyMask TTorrentClient::restore_metadata_source_policy(
    lt::torrent_handle const &handle,
    TorrentIdentity *identity,
    HTTPSSourcePolicyScope const scope
)
{
    if (!handle.is_valid()) {
        return {};
    }

    if (identity == nullptr
        || ((!updates_https_trackers(scope) || identity->source_trackers.empty())
            && (!updates_https_web_seeds(scope) || identity->source_web_seeds.empty()))) {
        return {};
    }

    DirtyMask changes = 0;
    bool changed = false;

    std::vector<lt::announce_entry> const current_trackers = handle.trackers();
    std::vector<lt::announce_entry> restored_trackers = current_trackers;
    bool trackers_changed = false;
    if (updates_https_trackers(scope)) {
        restored_trackers.clear();
        restored_trackers.reserve(identity->source_trackers.size() + current_trackers.size());
        std::set<std::string> tracker_urls;
        for (lt::announce_entry const &tracker : identity->source_trackers) {
            if (tracker_urls.insert(tracker.url).second) {
                restored_trackers.push_back(tracker);
            }
        }
        for (lt::announce_entry const &tracker : current_trackers) {
            if (tracker_urls.insert(tracker.url).second) {
                restored_trackers.push_back(tracker);
            }
        }
        restored_trackers = trackers_for_https_policy(
            std::move(restored_trackers),
            effective_https_tracker_policy(identity)
        );
        preserve_runtime_tracker_state(restored_trackers, current_trackers);
        trackers_changed = !same_tracker_topology(restored_trackers, current_trackers);
    }

    std::set<std::string> const existing_url_seeds = handle.url_seeds();
    std::set<std::string> restored_url_seeds = existing_url_seeds;
    bool web_seeds_changed = false;
    if (updates_https_web_seeds(scope)) {
        bool const require_web_seeds = effective_https_web_seed_policy(identity) == HTTPSPolicy::require;
        auto web_seed_allowed = [require_web_seeds](std::string const &web_seed) noexcept {
            return !require_web_seeds || is_https_url(web_seed);
        };
        std::erase_if(restored_url_seeds, [&](std::string const &web_seed) {
            return !web_seed_allowed(web_seed);
        });
        for (std::string const &web_seed : identity->source_web_seeds) {
            if (web_seed_allowed(web_seed)) {
                restored_url_seeds.insert(web_seed);
            }
        }
        web_seeds_changed = restored_url_seeds != existing_url_seeds;
    }

    lt::add_torrent_params restored_sources;
    for (lt::announce_entry const &tracker : restored_trackers) {
        restored_sources.trackers.push_back(tracker.url);
        restored_sources.tracker_tiers.push_back(tracker.tier);
    }
    restored_sources.url_seeds.assign(restored_url_seeds.begin(), restored_url_seeds.end());
    BridgeResult const valid_sources = validate_torrent_sources(restored_sources);
    if (!valid_sources) {
        changes |= remove_torrent_with_invalid_metadata(handle, valid_sources.error().message);
        return changes;
    }

    if (trackers_changed) {
        handle.replace_trackers(restored_trackers);
        handle.force_reannounce();
        changes |= cache_trackers(handle, restored_trackers);
        changes |= clear_peer_cache_if_restricted(handle, identity);
        changed = true;
    }

    if (web_seeds_changed) {
        changed = true;
        for (std::string const &url : existing_url_seeds) {
            if (!restored_url_seeds.contains(url)) {
                handle.remove_url_seed(url);
            }
        }
        for (std::string const &url : restored_url_seeds) {
            if (!existing_url_seeds.contains(url)) {
                handle.add_url_seed(url);
            }
        }
        if (std::optional<std::string> const cache_id = cache_id_for_handle(handle)) {
            changes |= cache_web_seeds(*cache_id, restored_url_seeds);
        } else {
            changes |= queue_alert_error("Torrent not found.");
        }
    }

    if (changed) {
        request_save(handle);
    }

    return changes;
}

DirtyMask TTorrentClient::clear_peer_cache_if_restricted(
    lt::torrent_handle handle,
    TorrentIdentity *identity
)
{
    if (!handle.is_valid()) {
        return {};
    }

    lt::add_torrent_params policy_view;
    policy_view.flags = handle.flags();
    for (lt::announce_entry const &tracker : handle.trackers()) {
        policy_view.trackers.push_back(tracker.url);
        policy_view.tracker_tiers.push_back(tracker.tier);
    }

    bool const app_disabled_dht =
        identity != nullptr && dht_disabled_by_app.contains(identity);
    if (!should_strip_resume_peer_cache(policy_view, identity, app_disabled_dht)) {
        return {};
    }

    handle.clear_peers();
    request_save(handle);
    request_snapshot_update_locked();
    return TTORRENT_DIRTY_TORRENTS;
}

HTTPSPolicy TTorrentClient::effective_https_tracker_policy(TorrentIdentity const *identity) const noexcept
{
    return identity != nullptr && identity->https_tracker_policy != HTTPSPolicy::inherit
        ? identity->https_tracker_policy
        : https_tracker_policy;
}

HTTPSPolicy TTorrentClient::effective_https_web_seed_policy(TorrentIdentity const *identity) const noexcept
{
    return identity != nullptr && identity->https_web_seed_policy != HTTPSPolicy::inherit
        ? identity->https_web_seed_policy
        : https_web_seed_policy;
}

TTorrentSourcePolicy TTorrentClient::source_policy(lt::torrent_handle const &handle, TorrentIdentity const *identity) const
{
    TTorrentSourcePolicy policy{};
    lt::torrent_flags_t const flags = handle.flags();
    std::shared_ptr<lt::torrent_info const> const torrent_file = handle.torrent_file();
    bool const private_torrent = torrent_file && torrent_file->is_valid() && torrent_file->priv();
    bool const dht_locked =
        private_torrent || (identity != nullptr && identity->dht_locked_by_source);
    bool const peer_exchange_locked =
        private_torrent || (identity != nullptr && identity->peer_exchange_locked_by_source);
    bool const lsd_locked =
        private_torrent || (identity != nullptr && identity->lsd_locked_by_source);
    bool const metadata_pending =
        identity != nullptr && metadata_validation_pending.contains(identity);

    bool dht_enabled = !dht_locked && !static_cast<bool>(flags & lt::torrent_flags::disable_dht);
    if (identity != nullptr && !dht_locked) {
        bool const disabled_by_app = std::ranges::any_of(dht_disabled_by_app, [identity](TorrentIdentity const *entry) {
            return entry == identity;
        });
        if (identity->dht_enabled_by_user) {
            dht_enabled = true;
        } else if (identity->dht_disabled_by_user || disabled_by_app) {
            dht_enabled = false;
        }
        if (metadata_validation_pending.contains(identity)) {
            dht_enabled = identity->allow_pre_metadata_dht;
        }
    }

    bool peer_exchange_enabled =
        peer_exchange_plugin_enabled && !peer_exchange_locked && !static_cast<bool>(flags & lt::torrent_flags::disable_pex);
    if (identity != nullptr && !peer_exchange_locked) {
        bool const disabled_by_app = std::ranges::any_of(
            peer_exchange_disabled_by_app,
            [identity](TorrentIdentity const *entry) {
                return entry == identity;
            }
        );
        if (peer_exchange_plugin_enabled && identity->peer_exchange_enabled_by_user) {
            peer_exchange_enabled = true;
        } else if (identity->peer_exchange_disabled_by_user || disabled_by_app) {
            peer_exchange_enabled = false;
        }
    }

    bool lsd_enabled = !lsd_locked && !static_cast<bool>(flags & lt::torrent_flags::disable_lsd);
    if (identity != nullptr && !lsd_locked) {
        bool const disabled_by_app = std::ranges::any_of(lsd_disabled_by_app, [identity](TorrentIdentity const *entry) {
            return entry == identity;
        });
        if (identity->lsd_enabled_by_user) {
            lsd_enabled = true;
        } else if (identity->lsd_disabled_by_user || disabled_by_app) {
            lsd_enabled = false;
        }
    }

    policy.enable_dht = bridge_bool(dht_enabled);
    policy.enable_peer_exchange = bridge_bool(peer_exchange_enabled);
    policy.enable_lsd = bridge_bool(lsd_enabled);
    policy.https_tracker_policy = static_cast<std::uint8_t>(
        identity != nullptr ? identity->https_tracker_policy : HTTPSPolicy::inherit
    );
    policy.https_web_seed_policy = static_cast<std::uint8_t>(
        identity != nullptr ? identity->https_web_seed_policy : HTTPSPolicy::inherit
    );
    policy.effective_https_tracker_policy = static_cast<std::uint8_t>(
        effective_https_tracker_policy(identity)
    );
    policy.effective_https_web_seed_policy = static_cast<std::uint8_t>(
        effective_https_web_seed_policy(identity)
    );
    policy.dht_locked = bridge_bool(dht_locked);
    policy.peer_exchange_locked = bridge_bool(peer_exchange_locked);
    policy.lsd_locked = bridge_bool(lsd_locked);
    policy.metadata_validation_pending = bridge_bool(metadata_pending);
    policy.allow_pre_metadata_dht = bridge_bool(
        metadata_pending && identity != nullptr && identity->allow_pre_metadata_dht
    );
    return policy;
}

DirtyMask TTorrentClient::set_source_policy_field(
    lt::torrent_handle const &handle,
    TorrentIdentity *identity,
    int32_t field,
    int32_t const value
)
{
    if (identity == nullptr || !handle.is_valid()) {
        return {};
    }

    bool const enabled = value != 0;
    std::shared_ptr<lt::torrent_info const> const torrent_file = handle.torrent_file();
    bool const private_torrent = torrent_file && torrent_file->is_valid() && torrent_file->priv();
    bool const dht_locked = private_torrent || identity->dht_locked_by_source;
    bool const peer_exchange_locked = private_torrent || identity->peer_exchange_locked_by_source;
    bool const lsd_locked = private_torrent || identity->lsd_locked_by_source;
    bool const metadata_pending = metadata_validation_pending.contains(identity);
    TTorrentSourcePolicy const current_policy = source_policy(handle, identity);
    HTTPSSourcePolicy const previous_https_policy{
        .trackers = effective_https_tracker_policy(identity),
        .web_seeds = effective_https_web_seed_policy(identity),
    };
    lt::torrent_flags_t const original_flags = handle.flags();
    bool const updates_dht = field == TTORRENT_SOURCE_POLICY_ENABLE_DHT
        || field == TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT;
    bool const should_force_lsd_announce =
        field == TTORRENT_SOURCE_POLICY_ENABLE_LSD
        && !lsd_locked
        && !metadata_pending
        && enabled
        && !bridge_bool(current_policy.enable_lsd)
        && lsd_service_enabled
        && !requested_network_blocked
        && !static_cast<bool>(original_flags & lt::torrent_flags::paused);

    if (updates_dht && metadata_pending) {
        bool const allow_pre_metadata_dht = !dht_locked && enabled;
        identity->allow_pre_metadata_dht = allow_pre_metadata_dht;
        if (allow_pre_metadata_dht) {
            if (static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht)) {
                handle.unset_flags(lt::torrent_flags::disable_dht);
            }
        } else if (!static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht)) {
            handle.set_flags(lt::torrent_flags::disable_dht);
        }
    } else if (updates_dht && dht_locked) {
        identity->dht_enabled_by_user = false;
        identity->dht_disabled_by_user = false;
        dht_disabled_by_app.erase(identity);
        if (!static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht)) {
            handle.set_flags(lt::torrent_flags::disable_dht);
        }
    } else if (updates_dht && enabled) {
        identity->dht_enabled_by_user = true;
        identity->dht_disabled_by_user = false;
        dht_disabled_by_app.erase(identity);
        if (static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht)) {
            handle.unset_flags(lt::torrent_flags::disable_dht);
        }
    } else if (updates_dht) {
        identity->dht_enabled_by_user = false;
        identity->dht_disabled_by_user = true;
        dht_disabled_by_app.erase(identity);
        if (!static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht)) {
            handle.set_flags(lt::torrent_flags::disable_dht);
        }
    }

    if (field == TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE && peer_exchange_locked) {
        identity->peer_exchange_enabled_by_user = false;
        identity->peer_exchange_disabled_by_user = false;
        peer_exchange_disabled_by_app.erase(identity);
        if (!static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex)) {
            handle.set_flags(lt::torrent_flags::disable_pex);
        }
    } else if (field == TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE && !peer_exchange_plugin_enabled) {
        if (!static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex)) {
            handle.set_flags(lt::torrent_flags::disable_pex);
        }
    } else if (field == TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE && enabled) {
        identity->peer_exchange_enabled_by_user = true;
        identity->peer_exchange_disabled_by_user = false;
        peer_exchange_disabled_by_app.erase(identity);
        if (static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex)) {
            handle.unset_flags(lt::torrent_flags::disable_pex);
        }
    } else if (field == TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE) {
        identity->peer_exchange_enabled_by_user = false;
        identity->peer_exchange_disabled_by_user = true;
        peer_exchange_disabled_by_app.erase(identity);
        if (!static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex)) {
            handle.set_flags(lt::torrent_flags::disable_pex);
        }
    }

    if (field == TTORRENT_SOURCE_POLICY_ENABLE_LSD && lsd_locked) {
        identity->lsd_enabled_by_user = false;
        identity->lsd_disabled_by_user = false;
        lsd_disabled_by_app.erase(identity);
        if (!static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd)) {
            handle.set_flags(lt::torrent_flags::disable_lsd);
        }
    } else if (field == TTORRENT_SOURCE_POLICY_ENABLE_LSD && enabled) {
        identity->lsd_enabled_by_user = true;
        identity->lsd_disabled_by_user = false;
        lsd_disabled_by_app.erase(identity);
        if (static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd)) {
            handle.unset_flags(lt::torrent_flags::disable_lsd);
        }
    } else if (field == TTORRENT_SOURCE_POLICY_ENABLE_LSD) {
        identity->lsd_enabled_by_user = false;
        identity->lsd_disabled_by_user = true;
        lsd_disabled_by_app.erase(identity);
        if (!static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd)) {
            handle.set_flags(lt::torrent_flags::disable_lsd);
        }
    }

    if (field == TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY) {
        identity->https_tracker_policy = https_policy_from_value(value);
    }

    if (field == TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY) {
        identity->https_web_seed_policy = https_policy_from_value(value);
    }

    DirtyMask changes = 0;
    if (field == TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY
        || field == TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY) {
        HTTPSSourcePolicy const current_https_policy{
            .trackers = effective_https_tracker_policy(identity),
            .web_seeds = effective_https_web_seed_policy(identity),
        };
        HTTPSSourcePolicyScope const scope = changed_https_policy_scope(
            previous_https_policy,
            current_https_policy
        );
        if (scope != HTTPSSourcePolicyScope::none) {
            changes |= restore_metadata_source_policy(handle, identity, scope);
            changes |= enforce_https_source_policy(handle, identity, scope);
        }
    }
    if (updates_dht || field == TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE) {
        changes |= clear_peer_cache_if_restricted(handle, identity);
    }
    if (should_force_lsd_announce) {
        handle.force_lsd_announce();
    }
    return changes;
}

DirtyMask TTorrentClient::apply_https_source_policy_locked(
    HTTPSSourcePolicy const previous_global_policy
)
{
    DirtyMask changes = 0;
    for (ActiveTorrentEntry const &entry : active_torrent_entries(*this)) {
        HTTPSSourcePolicy const previous_effective_policy{
            .trackers = entry.identity != nullptr
                    && entry.identity->https_tracker_policy != HTTPSPolicy::inherit
                ? entry.identity->https_tracker_policy
                : previous_global_policy.trackers,
            .web_seeds = entry.identity != nullptr
                    && entry.identity->https_web_seed_policy != HTTPSPolicy::inherit
                ? entry.identity->https_web_seed_policy
                : previous_global_policy.web_seeds,
        };
        HTTPSSourcePolicy const current_effective_policy{
            .trackers = effective_https_tracker_policy(entry.identity),
            .web_seeds = effective_https_web_seed_policy(entry.identity),
        };
        HTTPSSourcePolicyScope const scope = changed_https_policy_scope(
            previous_effective_policy,
            current_effective_policy
        );
        if (scope == HTTPSSourcePolicyScope::none) {
            continue;
        }
        changes |= restore_metadata_source_policy(entry.handle, entry.identity, scope);
        changes |= enforce_https_source_policy(entry.handle, entry.identity, scope);
    }
    return changes;
}

extern "C" const char *TorrentBridgeLibtorrentVersion(void) noexcept
{
    return LIBTORRENT_VERSION;
}

extern "C" TTorrentSourceSecurityInspectionResult TorrentBridgeInspectMagnetSources(
    const char *magnet_uri
) noexcept
{
    TTorrentSourceSecurityInspectionResult output{};
    output.status = run_bridge_operation({}, 3, [&]() -> BridgeResult {
        if (magnet_uri == nullptr) {
            return bridge_error(1, "Missing magnet URI.");
        }

        TorrentLoadResult parsed = parse_sanitized_magnet(c_string_view(magnet_uri));
        if (!parsed) {
            return std::unexpected(parsed.error());
        }

        BridgeResult const valid_sources = validate_torrent_sources(*parsed);
        if (!valid_sources) {
            return valid_sources;
        }

        output.inspection = torrent_source_counts(*parsed);
        return {};
    });
    return output;
}

extern "C" TTorrentClient *TorrentClientCreateWithError(
    const char *state_path,
    uint8_t enable_pex_plugin,
    const uint8_t *authorized_save_paths_blob,
    int32_t authorized_save_paths_blob_size,
    TTorrentAuthorizedSaveRoot const *authorized_save_roots,
    int32_t authorized_save_root_count,
    TTorrentAuthorizedRootLifetimeRetainCallback retain_authorized_root,
    TTorrentAuthorizedRootLifetimeReleaseCallback release_authorized_root,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    std::span<char> const error_buffer = output_buffer(error_out, error_capacity);
    copy_error(error_buffer, "");

    if (state_path == nullptr || std::string_view(state_path).empty()) {
        copy_error(error_buffer, "Missing state path.");
        return nullptr;
    }
    std::string_view const requested_state_path = c_string_view(state_path);

    try {
        AuthorizedSaveRootResult authorized_roots = authorized_save_roots_from_c_buffer(
            authorized_save_paths_blob,
            authorized_save_paths_blob_size,
            authorized_save_roots,
            authorized_save_root_count,
            retain_authorized_root,
            release_authorized_root
        );
        if (!authorized_roots) {
            copy_error(error_buffer, authorized_roots.error().message);
            return nullptr;
        }

        fs::path const state_directory_path{std::string(requested_state_path)};
        if (!state_directory_path.is_absolute()) {
            copy_error(error_buffer, "The state path must be absolute.");
            return nullptr;
        }
        std::string normalized_state_path = state_directory_path.lexically_normal().native();

        return std::make_unique<TTorrentClient>(
            normalized_state_path,
            bridge_bool(enable_pex_plugin),
            std::move(*authorized_roots)
        ).release();
    } catch (std::exception const &exception) {
        copy_error(error_buffer, exception.what());
        return nullptr;
    } catch (...) {
        copy_error(error_buffer, "Unexpected libtorrent error.");
        return nullptr;
    }
}

extern "C" int32_t TorrentClientReplaceAuthorizedSavePaths(
    TTorrentClient *client,
    std::uint8_t const *authorized_save_paths_blob,
    int32_t authorized_save_paths_blob_size,
    TTorrentAuthorizedSaveRoot const *authorized_save_roots,
    int32_t authorized_save_root_count,
    TTorrentAuthorizedRootLifetimeRetainCallback retain_authorized_root,
    TTorrentAuthorizedRootLifetimeReleaseCallback release_authorized_root,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }

        // Root callbacks and descriptor duplication are intentionally outside
        // the general client lock. Serialize the complete replacement so
        // concurrent callers cannot transiently exceed the live-root budget.
        std::scoped_lock replacement_guard(client->authorized_root_replacement_lock);
        BridgeResult const capacity_preflight = preflight_authorized_root_lifetime_replacement(
            *client,
            authorized_save_paths_blob,
            authorized_save_paths_blob_size,
            authorized_save_roots,
            authorized_save_root_count,
            AuthorizedRootLifetimeCallbacks{
                .retain = retain_authorized_root,
                .release = release_authorized_root,
            }
        );
        if (!capacity_preflight) {
            return capacity_preflight;
        }
        AuthorizedSaveRootResult authorized_roots = [&] {
            AuthorizedSaveRootWeakList reusable_roots;
            {
                std::scoped_lock guard(client->lock);
                reusable_roots = client->authorized_save_root_lifetimes;
            }
            return authorized_save_roots_from_c_buffer(
                authorized_save_paths_blob,
                authorized_save_paths_blob_size,
                authorized_save_roots,
                authorized_save_root_count,
                retain_authorized_root,
                release_authorized_root,
                &reusable_roots
            );
        }();
        if (!authorized_roots) {
            return std::unexpected(authorized_roots.error());
        }

        std::scoped_lock guard(client->lock);
        BridgeResult const lifetime_budget = prepare_authorized_root_lifetime_replacement(
            *client,
            *authorized_roots
        );
        if (!lifetime_budget) {
            return lifetime_budget;
        }
        client->authorized_save_roots.swap(*authorized_roots);
        return {};
    });
}

extern "C" void TorrentClientDestroy(TTorrentClient *client) noexcept
{
    try {
        std::unique_ptr<TTorrentClient> owned(client);
    } catch (...) {
        ignore_shutdown_failure();
    }
}

extern "C" void TorrentClientDestroyBlocking(TTorrentClient *client) noexcept
{
    try {
        if (client != nullptr) {
            client->set_session_shutdown_asynchronous(false);
        }
        std::unique_ptr<TTorrentClient> owned(client);
    } catch (...) {
        ignore_shutdown_failure();
    }
}

extern "C" void TorrentClientSetWakeCallback(
    TTorrentClient *client,
    TTorrentWakeCallback callback,
    void *context
) noexcept
{
    if (client == nullptr) {
        return;
    }

    try {
        client->set_wake_callback(callback, context);
    } catch (...) {
        ignore_shutdown_failure();
    }
}

extern "C" uint64_t TorrentClientTakeChanges(TTorrentClient *client, uint32_t *dirty_mask_out) noexcept
{
    if (dirty_mask_out != nullptr) {
        *dirty_mask_out = 0;
    }
    if (client == nullptr) {
        return 0;
    }

    return client->take_changes(dirty_mask_out);
}

extern "C" int32_t TorrentClientAddMagnet(TTorrentClient *client, const char *magnet_uri, const char *save_path,
                                          TTorrentAddOptions options,
                                          char *added_id_out, int32_t added_id_capacity,
                                          int32_t *add_outcome_out,
                                          char *error_out, int32_t error_capacity) noexcept
{
    if (add_outcome_out != nullptr) {
        *add_outcome_out = TTORRENT_ADD_REJECTED;
    }
    WakeCallbackInvocation wake;
    std::span<char> const added_id_buffer = output_buffer(added_id_out, added_id_capacity);
    copy_string_dynamic(added_id_buffer, "");
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 4, [&]() -> BridgeResult {
        if (client == nullptr || magnet_uri == nullptr || save_path == nullptr || add_outcome_out == nullptr) {
            return bridge_error(1, "Missing torrent client, magnet URI, save path, or add outcome output.");
        }
        TTorrentAddOptions const &add_options = options;
        std::string_view const magnet = c_string_view(magnet_uri);
        if (magnet.size() > kMaxMagnetURIBytes) {
            return bridge_error(2, "The magnet link is too large.");
        }
        NormalizedLiveSavePathResult const normalized_save_path = normalized_live_save_path(
            c_string_view(save_path)
        );
        if (!normalized_save_path) {
            return std::unexpected(normalized_save_path.error());
        }
        if (!is_valid_queue_priority(add_options.queue_priority)) {
            return bridge_error(1, "Invalid queue priority.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        AuthorizedSaveRootLookupResult const authorized_save_root = require_authorized_save_path(
            *client,
            *normalized_save_path
        );
        if (!authorized_save_root) {
            return std::unexpected(authorized_save_root.error());
        }
        BridgeResult const persistence = client->ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
        BridgeResult const admission = client->ensure_torrent_admission_available(3);
        if (!admission) {
            return admission;
        }
        TorrentLoadResult parsed = parse_sanitized_magnet(magnet);
        if (!parsed) {
            return std::unexpected(parsed.error());
        }
        lt::add_torrent_params params = std::move(*parsed);
        lt::add_torrent_params const source_params = params;
        BridgeResult const valid_original_sources = validate_torrent_sources(source_params);
        if (!valid_original_sources) {
            return valid_original_sources;
        }

        if (!is_valid_https_tracker_policy(add_options.https_tracker_policy, true)
            || !is_valid_https_web_seed_policy(add_options.https_web_seed_policy, true)) {
            return bridge_error(1, "Invalid HTTPS source policy.");
        }
        HTTPSPolicy const requested_tracker_policy = https_policy_from_value(add_options.https_tracker_policy);
        HTTPSPolicy const requested_web_seed_policy = https_policy_from_value(add_options.https_web_seed_policy);
        HTTPSPolicy const effective_tracker_policy = requested_tracker_policy == HTTPSPolicy::inherit
            ? client->https_tracker_policy
            : requested_tracker_policy;
        HTTPSPolicy const effective_web_seed_policy = requested_web_seed_policy == HTTPSPolicy::inherit
            ? client->https_web_seed_policy
            : requested_web_seed_policy;
        static_cast<void>(apply_https_source_policy(
            params,
            HTTPSSourcePolicy{.trackers = effective_tracker_policy, .web_seeds = effective_web_seed_policy}
        ));
        BridgeResult const valid_effective_sources = validate_torrent_sources(params);
        if (!valid_effective_sources) {
            return valid_effective_sources;
        }
        bool const enable_peer_exchange_value = bridge_bool(add_options.enable_peer_exchange);
        bool const metadata_pending = !params.ti;
        bool const allow_pre_metadata_dht =
            metadata_pending && bridge_bool(add_options.allow_pre_metadata_dht);
        bool const intended_default_dont_download =
            static_cast<bool>(params.flags & lt::torrent_flags::default_dont_download);
        std::vector<lt::download_priority_t> intended_file_priorities = params.file_priorities;
        bool const private_torrent = params.ti && params.ti->priv();
        bool const dht_locked_by_source =
            private_torrent || static_cast<bool>(params.flags & lt::torrent_flags::disable_dht);
        bool const dht_disabled_by_app = !client->dht_enabled_by_default && !dht_locked_by_source;
        bool const lsd_locked_by_source =
            private_torrent || static_cast<bool>(params.flags & lt::torrent_flags::disable_lsd);
        bool const lsd_disabled_by_app = !client->lsd_enabled_by_default && !lsd_locked_by_source;
        bool const peer_exchange_was_disabled =
            static_cast<bool>(params.flags & lt::torrent_flags::disable_pex);
        bool const peer_exchange_locked_by_source = private_torrent || peer_exchange_was_disabled;
        if (dht_locked_by_source) {
            params.flags |= lt::torrent_flags::disable_dht;
        }
        if ((dht_disabled_by_app || metadata_pending) && !allow_pre_metadata_dht) {
            params.flags |= lt::torrent_flags::disable_dht;
        }
        if (allow_pre_metadata_dht && !dht_locked_by_source) {
            params.flags &= ~lt::torrent_flags::disable_dht;
        }
        if (lsd_locked_by_source || lsd_disabled_by_app || metadata_pending) {
            params.flags |= lt::torrent_flags::disable_lsd;
        }
        if (peer_exchange_locked_by_source || metadata_pending) {
            params.flags |= lt::torrent_flags::disable_pex;
        }
        if (metadata_pending) {
            params.file_priorities.clear();
            params.flags |= lt::torrent_flags::default_dont_download;
        }
        prepare_add_params(
            params,
            *normalized_save_path,
            bridge_bool(add_options.starts_paused),
            enable_peer_exchange_value && !metadata_pending
        );
        params.storage_root = *authorized_save_root;
        bool const peer_exchange_disabled_by_app =
            !enable_peer_exchange_value && !peer_exchange_was_disabled && !peer_exchange_locked_by_source;
        if (client->delete_pending_for_hashes(params.info_hashes)) {
            return bridge_error(3, "Torrent data deletion is still pending.");
        }
        TorrentIdentity *identity = client->attach_identity(params);
        UnpublishedIdentityGuard identity_guard(*client, identity);
        identity->https_tracker_policy = requested_tracker_policy;
        identity->https_web_seed_policy = requested_web_seed_policy;
        identity->queue_priority = add_options.queue_priority;
        identity->dht_locked_by_source = dht_locked_by_source;
        identity->lsd_locked_by_source = lsd_locked_by_source;
        identity->peer_exchange_locked_by_source = peer_exchange_locked_by_source;
        identity->allow_pre_metadata_dht = allow_pre_metadata_dht;
        identity->intended_default_dont_download = intended_default_dont_download;
        identity->intended_file_priorities = std::move(intended_file_priorities);
        BridgeResult const remembered_sources = remember_source_policy_sources(*identity, source_params);
        if (!remembered_sources) {
            return remembered_sources;
        }
        lt::add_torrent_params resume_params = params;
        lt::error_code add_error;
        *add_outcome_out = TTORRENT_ADD_OUTCOME_UNKNOWN;
        identity_guard.release();
        lt::torrent_handle handle = client->session.add_torrent(std::move(params), add_error);
        client->record_synchronous_add_alert_locked();
        if (add_error) {
            *add_outcome_out = TTORRENT_ADD_REJECTED;
            client->discard_unpublished_identity(identity);
            return bridge_error(3, add_error.message());
        }
        client->insert_added_queue_priority_order_locked(handle, identity);

        lt::info_hash_t hashes;
        try {
            hashes = handle.info_hashes();
        } catch (...) {
            if (!client->rollback_added_torrent_without_hashes(handle, identity, publisher.changes)) {
                return bridge_error(3, "Torrent was added, but its hashes could not be read.");
            }
            return bridge_error(3, "Torrent hashes could not be read.");
        }
        std::vector<std::string> const resume_ids = hash_keys_with_requested(hashes, identity->canonical_id);
        client->mark_active(hashes, handle, identity);
        if (!client->queue_order_index.valid) {
            static_cast<void>(client->apply_queue_priority_order_locked());
        }
        if (dht_disabled_by_app) {
            client->dht_disabled_by_app.insert(identity);
        }
        if (lsd_disabled_by_app) {
            client->lsd_disabled_by_app.insert(identity);
        }
        if (peer_exchange_disabled_by_app) {
            client->peer_exchange_disabled_by_app.insert(identity);
        }
        if (metadata_pending) {
            client->metadata_validation_pending.insert(identity);
        }
        ResumeSaveResult saved_resume = client->save_added_torrent_resume_data(
            std::move(resume_params),
            hashes,
            identity
        );
        if (!saved_resume) {
            bool const rolled_back = client->rollback_added_torrent(handle, hashes, identity, resume_ids, true, publisher.changes);
            if (rolled_back && dht_disabled_by_app) {
                client->dht_disabled_by_app.erase(identity);
            }
            if (rolled_back && lsd_disabled_by_app) {
                client->lsd_disabled_by_app.erase(identity);
            }
            if (rolled_back && peer_exchange_disabled_by_app) {
                client->peer_exchange_disabled_by_app.erase(identity);
            }
            if (rolled_back && metadata_pending) {
                client->metadata_validation_pending.erase(identity);
            }
            if (!rolled_back) {
                return bridge_error(3,
                                    "Torrent was added, but resume data could not be saved: " + saved_resume.error());
            }
            return bridge_error(3, "Resume data could not be saved: " + saved_resume.error());
        }

        ResumeSaveResult removed_obsolete_resume = client->remove_obsolete_tombstoned_resume_data_for_readd(resume_ids);
        if (!removed_obsolete_resume) {
            bool const rolled_back = client->rollback_added_torrent(handle, hashes, identity, resume_ids, true, publisher.changes);
            if (rolled_back && dht_disabled_by_app) {
                client->dht_disabled_by_app.erase(identity);
            }
            if (rolled_back && lsd_disabled_by_app) {
                client->lsd_disabled_by_app.erase(identity);
            }
            if (rolled_back && peer_exchange_disabled_by_app) {
                client->peer_exchange_disabled_by_app.erase(identity);
            }
            if (rolled_back && metadata_pending) {
                client->metadata_validation_pending.erase(identity);
            }
            if (!rolled_back) {
                return bridge_error(3, "Torrent was added, but obsolete resume "
                                       "data could not be removed: " +
                                           removed_obsolete_resume.error());
            }
            return bridge_error(3, "Obsolete resume data could not be removed: " + removed_obsolete_resume.error());
        }

        ResumeIDListResult tombstone_clear_ids = client->tombstone_ids_overlapping(resume_ids);
        if (!tombstone_clear_ids) {
            bool const rolled_back = client->rollback_added_torrent(handle, hashes, identity, resume_ids, true, publisher.changes);
            if (rolled_back && dht_disabled_by_app) {
                client->dht_disabled_by_app.erase(identity);
            }
            if (rolled_back && lsd_disabled_by_app) {
                client->lsd_disabled_by_app.erase(identity);
            }
            if (rolled_back && peer_exchange_disabled_by_app) {
                client->peer_exchange_disabled_by_app.erase(identity);
            }
            if (rolled_back && metadata_pending) {
                client->metadata_validation_pending.erase(identity);
            }
            if (!rolled_back) {
                return bridge_error(3, "Torrent was added, but removal markers "
                                       "could not be scanned: " +
                                           tombstone_clear_ids.error());
            }
            return bridge_error(3, "Removal markers could not be scanned: " + tombstone_clear_ids.error());
        }
        if (!tombstone_clear_ids->empty()) {
            ResumeSaveResult cleared_tombstones = client->clear_removal_tombstones(*tombstone_clear_ids);
            if (!cleared_tombstones) {
                bool const rolled_back = client->rollback_added_torrent(handle, hashes, identity, resume_ids, true, publisher.changes);
                if (rolled_back && peer_exchange_disabled_by_app) {
                    client->peer_exchange_disabled_by_app.erase(identity);
                }
                if (rolled_back && dht_disabled_by_app) {
                    client->dht_disabled_by_app.erase(identity);
                }
                if (rolled_back && lsd_disabled_by_app) {
                    client->lsd_disabled_by_app.erase(identity);
                }
                if (rolled_back && metadata_pending) {
                    client->metadata_validation_pending.erase(identity);
                }
                if (!rolled_back) {
                    return bridge_error(3, "Torrent was added, but removal marker "
                                           "could not be cleared: " +
                                               cleared_tombstones.error());
                }
                return bridge_error(3, "Removal marker could not be cleared: " + cleared_tombstones.error());
            }
        }
        publisher.add(client->cache_snapshot(handle));
        client->request_snapshot_update_locked();
        copy_string_dynamic(added_id_buffer, identity->canonical_id);
        *add_outcome_out = TTORRENT_ADD_COMMITTED;
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
        client->drain_synchronous_add_alerts_if_needed();
    }
    return result;
}

namespace {

TorrentLoadResult load_torrent_data_from_c_buffer(void const *torrent_data, int32_t torrent_data_size)
{
    if (torrent_data == nullptr) {
        return std::unexpected(BridgeError{.code = 1, .message = "Missing torrent data."});
    }
    if (torrent_data_size < 0) {
        return std::unexpected(BridgeError{.code = 1, .message = "Invalid torrent data size."});
    }

    return load_torrent_data(input_span_from_c_buffer(
        static_cast<char const *>(torrent_data),
        torrent_data_size
    ));
}

template <typename LoadTorrent>
int32_t add_torrent_file_data_with_priorities(
    TTorrentClient *client,
    const char *save_path,
    TTorrentAddOptions const &options,
    bool apply_file_priority_overrides,
    const TTorrentFilePriorityEntry *file_priorities,
    int32_t file_priority_count,
    char *added_id_out,
    int32_t added_id_capacity,
    int32_t *add_outcome_out,
    char *error_out,
    int32_t error_capacity,
    LoadTorrent load_torrent
) noexcept
{
    if (add_outcome_out != nullptr) {
        *add_outcome_out = TTORRENT_ADD_REJECTED;
    }
    WakeCallbackInvocation wake;
    std::span<char> const added_id_buffer = output_buffer(added_id_out, added_id_capacity);
    copy_string_dynamic(added_id_buffer, "");
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || save_path == nullptr || add_outcome_out == nullptr) {
            return bridge_error(1, "Missing torrent client, save path, or add outcome output.");
        }
        TTorrentAddOptions const &add_options = options;
        if (file_priority_count < 0) {
            return bridge_error(1, "Invalid file priority count.");
        }
        if (file_priority_count > TTORRENT_MAX_FILE_COUNT) {
            return bridge_error(1, "Invalid file priority count.");
        }
        if (file_priority_count > 0 && file_priorities == nullptr) {
            return bridge_error(1, "Missing file priorities.");
        }
        NormalizedLiveSavePathResult const normalized_save_path = normalized_live_save_path(
            c_string_view(save_path)
        );
        if (!normalized_save_path) {
            return std::unexpected(normalized_save_path.error());
        }
        if (!is_valid_queue_priority(add_options.queue_priority)) {
            return bridge_error(1, "Invalid queue priority.");
        }
        TorrentLoadResult loaded_torrent = load_torrent();
        if (!loaded_torrent) {
            return std::unexpected(loaded_torrent.error());
        }

        lt::add_torrent_params params = std::move(*loaded_torrent);
        BridgeResult const valid_info = validate_torrent_info(params);
        if (!valid_info) {
            return valid_info;
        }
        sanitize_resume_endpoint_hints(params);
        lt::add_torrent_params const source_params = params;
        BridgeResult const valid_original_sources = validate_torrent_sources(source_params);
        if (!valid_original_sources) {
            return valid_original_sources;
        }
        if (apply_file_priority_overrides
            && file_priority_count > params.ti->layout().num_files()) {
            return bridge_error(2, "The file priorities are invalid.");
        }

        std::optional<std::span<TTorrentFilePriorityEntry const>> priority_entries;
        if (apply_file_priority_overrides) {
            priority_entries = input_span_from_c_buffer(file_priorities, file_priority_count);
        }
        BridgeResult const valid_file_policy = apply_file_priorities(params, priority_entries);
        if (!valid_file_policy) {
            return valid_file_policy;
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        AuthorizedSaveRootLookupResult const authorized_save_root = require_authorized_save_path(
            *client,
            *normalized_save_path
        );
        if (!authorized_save_root) {
            return std::unexpected(authorized_save_root.error());
        }
        BridgeResult const persistence =
            client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }
        BridgeResult const admission = client->ensure_torrent_admission_available(2);
        if (!admission) {
            return admission;
        }
        if (!is_valid_https_tracker_policy(add_options.https_tracker_policy, true)
            || !is_valid_https_web_seed_policy(add_options.https_web_seed_policy, true)) {
            return bridge_error(1, "Invalid HTTPS source policy.");
        }
        HTTPSPolicy const requested_tracker_policy = https_policy_from_value(add_options.https_tracker_policy);
        HTTPSPolicy const requested_web_seed_policy = https_policy_from_value(add_options.https_web_seed_policy);
        HTTPSPolicy const effective_tracker_policy = requested_tracker_policy == HTTPSPolicy::inherit
            ? client->https_tracker_policy
            : requested_tracker_policy;
        HTTPSPolicy const effective_web_seed_policy = requested_web_seed_policy == HTTPSPolicy::inherit
            ? client->https_web_seed_policy
            : requested_web_seed_policy;
        static_cast<void>(apply_https_source_policy(
            params,
            HTTPSSourcePolicy{.trackers = effective_tracker_policy, .web_seeds = effective_web_seed_policy}
        ));
        BridgeResult const valid_effective_sources = validate_torrent_sources(params);
        if (!valid_effective_sources) {
            return valid_effective_sources;
        }
        bool const enable_peer_exchange_value = bridge_bool(add_options.enable_peer_exchange);
        bool const private_torrent = params.ti && params.ti->priv();
        bool const dht_locked_by_source =
            private_torrent || static_cast<bool>(params.flags & lt::torrent_flags::disable_dht);
        bool const dht_disabled_by_app = !client->dht_enabled_by_default && !dht_locked_by_source;
        bool const lsd_locked_by_source =
            private_torrent || static_cast<bool>(params.flags & lt::torrent_flags::disable_lsd);
        bool const lsd_disabled_by_app = !client->lsd_enabled_by_default && !lsd_locked_by_source;
        bool const peer_exchange_was_disabled =
            static_cast<bool>(params.flags & lt::torrent_flags::disable_pex);
        bool const peer_exchange_locked_by_source = private_torrent || peer_exchange_was_disabled;
        if (dht_locked_by_source) {
            params.flags |= lt::torrent_flags::disable_dht;
        }
        if (dht_disabled_by_app) {
            params.flags |= lt::torrent_flags::disable_dht;
        }
        if (lsd_locked_by_source || lsd_disabled_by_app) {
            params.flags |= lt::torrent_flags::disable_lsd;
        }
        if (peer_exchange_locked_by_source) {
            params.flags |= lt::torrent_flags::disable_pex;
        }
        prepare_add_params(
            params,
            *normalized_save_path,
            bridge_bool(add_options.starts_paused),
            enable_peer_exchange_value
        );
        params.storage_root = *authorized_save_root;
        bool const peer_exchange_disabled_by_app =
            !enable_peer_exchange_value && !peer_exchange_was_disabled && !peer_exchange_locked_by_source;
        if (client->delete_pending_for_hashes(params.info_hashes)) {
            return bridge_error(2, "Torrent data deletion is still pending.");
        }

        TorrentIdentity *identity = client->attach_identity(params);
        UnpublishedIdentityGuard identity_guard(*client, identity);
        identity->https_tracker_policy = requested_tracker_policy;
        identity->https_web_seed_policy = requested_web_seed_policy;
        identity->queue_priority = add_options.queue_priority;
        identity->dht_locked_by_source = dht_locked_by_source;
        identity->lsd_locked_by_source = lsd_locked_by_source;
        identity->peer_exchange_locked_by_source = peer_exchange_locked_by_source;
        BridgeResult const remembered_sources = remember_source_policy_sources(*identity, source_params);
        if (!remembered_sources) {
            return remembered_sources;
        }
        lt::add_torrent_params resume_params = params;
        lt::error_code add_error;
        *add_outcome_out = TTORRENT_ADD_OUTCOME_UNKNOWN;
        identity_guard.release();
        lt::torrent_handle handle = client->session.add_torrent(std::move(params), add_error);
        client->record_synchronous_add_alert_locked();
        if (add_error) {
            *add_outcome_out = TTORRENT_ADD_REJECTED;
            client->discard_unpublished_identity(identity);
            return bridge_error(2, add_error.message());
        }
        client->insert_added_queue_priority_order_locked(handle, identity);

        lt::info_hash_t hashes;
        try {
            hashes = handle.info_hashes();
        } catch (...) {
            if (!client->rollback_added_torrent_without_hashes(handle, identity, publisher.changes)) {
                return bridge_error(2, "Torrent was added, but its hashes could not be read.");
            }
            return bridge_error(2, "Torrent hashes could not be read.");
        }
        std::vector<std::string> const resume_ids = hash_keys_with_requested(hashes, identity->canonical_id);
        client->mark_active(hashes, handle, identity);
        if (!client->queue_order_index.valid) {
            static_cast<void>(client->apply_queue_priority_order_locked());
        }
        if (dht_disabled_by_app) {
            client->dht_disabled_by_app.insert(identity);
        }
        if (lsd_disabled_by_app) {
            client->lsd_disabled_by_app.insert(identity);
        }
        if (peer_exchange_disabled_by_app) {
            client->peer_exchange_disabled_by_app.insert(identity);
        }
        ResumeSaveResult saved_resume = client->save_added_torrent_resume_data(
            std::move(resume_params),
            hashes,
            identity
        );
        if (!saved_resume) {
            bool const rolled_back = client->rollback_added_torrent(handle, hashes, identity, resume_ids, true, publisher.changes);
            if (rolled_back && dht_disabled_by_app) {
                client->dht_disabled_by_app.erase(identity);
            }
            if (rolled_back && lsd_disabled_by_app) {
                client->lsd_disabled_by_app.erase(identity);
            }
            if (rolled_back && peer_exchange_disabled_by_app) {
                client->peer_exchange_disabled_by_app.erase(identity);
            }
            if (!rolled_back) {
                return bridge_error(2, "Torrent was added, but resume data could not be saved: " + saved_resume.error());
            }
            return bridge_error(2, "Resume data could not be saved: " + saved_resume.error());
        }

        ResumeSaveResult removed_obsolete_resume = client->remove_obsolete_tombstoned_resume_data_for_readd(resume_ids);
        if (!removed_obsolete_resume) {
            bool const rolled_back = client->rollback_added_torrent(handle, hashes, identity, resume_ids, true, publisher.changes);
            if (rolled_back && dht_disabled_by_app) {
                client->dht_disabled_by_app.erase(identity);
            }
            if (rolled_back && lsd_disabled_by_app) {
                client->lsd_disabled_by_app.erase(identity);
            }
            if (rolled_back && peer_exchange_disabled_by_app) {
                client->peer_exchange_disabled_by_app.erase(identity);
            }
            if (!rolled_back) {
                return bridge_error(2, "Torrent was added, but obsolete resume data could not be removed: " + removed_obsolete_resume.error());
            }
            return bridge_error(2, "Obsolete resume data could not be removed: " + removed_obsolete_resume.error());
        }

        ResumeIDListResult tombstone_clear_ids = client->tombstone_ids_overlapping(resume_ids);
        if (!tombstone_clear_ids) {
            bool const rolled_back = client->rollback_added_torrent(handle, hashes, identity, resume_ids, true, publisher.changes);
            if (rolled_back && dht_disabled_by_app) {
                client->dht_disabled_by_app.erase(identity);
            }
            if (rolled_back && lsd_disabled_by_app) {
                client->lsd_disabled_by_app.erase(identity);
            }
            if (rolled_back && peer_exchange_disabled_by_app) {
                client->peer_exchange_disabled_by_app.erase(identity);
            }
            if (!rolled_back) {
                return bridge_error(2, "Torrent was added, but removal markers could not be scanned: " + tombstone_clear_ids.error());
            }
            return bridge_error(2, "Removal markers could not be scanned: " + tombstone_clear_ids.error());
        }
        if (!tombstone_clear_ids->empty()) {
            ResumeSaveResult cleared_tombstones = client->clear_removal_tombstones(*tombstone_clear_ids);
            if (!cleared_tombstones) {
                bool const rolled_back = client->rollback_added_torrent(handle, hashes, identity, resume_ids, true, publisher.changes);
                if (rolled_back && dht_disabled_by_app) {
                    client->dht_disabled_by_app.erase(identity);
                }
                if (rolled_back && lsd_disabled_by_app) {
                    client->lsd_disabled_by_app.erase(identity);
                }
                if (rolled_back && peer_exchange_disabled_by_app) {
                    client->peer_exchange_disabled_by_app.erase(identity);
                }
                if (!rolled_back) {
                    return bridge_error(2, "Torrent was added, but removal marker could not be cleared: " + cleared_tombstones.error());
                }
                return bridge_error(2, "Removal marker could not be cleared: " + cleared_tombstones.error());
            }
        }
        publisher.add(client->cache_snapshot(handle));
        client->request_snapshot_update_locked();
        copy_string_dynamic(added_id_buffer, identity->canonical_id);
        *add_outcome_out = TTORRENT_ADD_COMMITTED;
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
        client->drain_synchronous_add_alerts_if_needed();
    }
    return result;
}

} // namespace

extern "C" int32_t TorrentClientAddTorrentFileData(
    TTorrentClient *client,
    std::uint8_t const *torrent_data,
    int32_t torrent_data_size,
    const char *save_path,
    TTorrentAddOptions options,
    char *added_id_out,
    int32_t added_id_capacity,
    int32_t *add_outcome_out,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return add_torrent_file_data_with_priorities(
        client,
        save_path,
        options,
        false,
        nullptr,
        0,
        added_id_out,
        added_id_capacity,
        add_outcome_out,
        error_out,
        error_capacity,
        [torrent_data, torrent_data_size]() {
            return load_torrent_data_from_c_buffer(torrent_data, torrent_data_size);
        }
    );
}

extern "C" int32_t TorrentClientAddTorrentFileDataWithPriorities(
    TTorrentClient *client,
    std::uint8_t const *torrent_data,
    int32_t torrent_data_size,
    const char *save_path,
    TTorrentAddOptions options,
    const TTorrentFilePriorityEntry *file_priorities,
    int32_t file_priority_count,
    char *added_id_out,
    int32_t added_id_capacity,
    int32_t *add_outcome_out,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return add_torrent_file_data_with_priorities(
        client,
        save_path,
        options,
        true,
        file_priorities,
        file_priority_count,
        added_id_out,
        added_id_capacity,
        add_outcome_out,
        error_out,
        error_capacity,
        [torrent_data, torrent_data_size]() {
            return load_torrent_data_from_c_buffer(torrent_data, torrent_data_size);
        }
    );
}

namespace {

template <typename LoadTorrent>
int32_t preview_torrent_file_with_loader(
    TTorrentClient *client,
    TTorrentFilePreview *preview,
    TTorrentFileSnapshot *files,
    int32_t capacity,
    int32_t *required_count_out,
    char *error_out,
    int32_t error_capacity,
    LoadTorrent load_torrent
) noexcept
{
    if (preview != nullptr) {
        *preview = TTorrentFilePreview{};
    }
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }

    return run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }

        TorrentLoadResult loaded_torrent = load_torrent();
        if (!loaded_torrent) {
            return std::unexpected(loaded_torrent.error());
        }

        lt::add_torrent_params const &params = *loaded_torrent;
        BridgeResult const valid_info = validate_torrent_info(params);
        if (!valid_info) {
            return valid_info;
        }
        BridgeResult const valid_sources = validate_torrent_sources(params);
        if (!valid_sources) {
            return valid_sources;
        }

        lt::torrent_info const &info = *params.ti;
        if (required_count_out != nullptr) {
            *required_count_out = info.layout().num_files();
        }
        copy_torrent_preview(params, preview);
        copy_torrent_preview_files(params, output_span_from_c_buffer(files, capacity));
        return {};
    });
}

} // namespace

extern "C" int32_t TorrentClientPreviewTorrentFileData(
    TTorrentClient *client,
    std::uint8_t const *torrent_data,
    int32_t torrent_data_size,
    TTorrentFilePreview *preview,
    TTorrentFileSnapshot *files,
    int32_t capacity,
    int32_t *required_count_out,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return preview_torrent_file_with_loader(
        client,
        preview,
        files,
        capacity,
        required_count_out,
        error_out,
        error_capacity,
        [torrent_data, torrent_data_size]() {
            return load_torrent_data_from_c_buffer(torrent_data, torrent_data_size);
        }
    );
}

extern "C" int32_t TorrentClientCopySnapshotBatch(
    TTorrentClient *client,
    TTorrentSnapshot *snapshots,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out
) noexcept
{
    clear_count_outputs(revision_out, required_count_out);
    if (client == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentSnapshot> output = output_span_from_c_buffer(snapshots, capacity);
        return client->copy_snapshots(output, revision_out, required_count_out);
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientRequestSources(
    TTorrentClient *client,
    const char *torrent_id,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        return client->request_sources(std::string(c_string_view(torrent_id)), publisher.changes);
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" TTorrentSourcePolicyResult TorrentClientCopySourcePolicy(
    TTorrentClient *client,
    const char *torrent_id,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    TTorrentSourcePolicyResult output{};
    output.status = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        output.policy = client->source_policy(*handle, identity_from_handle(*handle));
        return {};
    });
    return output;
}

extern "C" int32_t TorrentClientSetSourcePolicyField(
    TTorrentClient *client,
    const char *torrent_id,
    int32_t field,
    int32_t value,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }
        if (field < TTORRENT_SOURCE_POLICY_ENABLE_DHT
            || field > TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT) {
            return bridge_error(1, "Invalid source policy field.");
        }
        bool const tracker_policy_field = field == TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY;
        bool const web_seed_policy_field = field == TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY;
        if ((tracker_policy_field && !is_valid_https_tracker_policy(value, true))
            || (web_seed_policy_field && !is_valid_https_web_seed_policy(value, true))
            || (!tracker_policy_field && !web_seed_policy_field && value != 0 && value != 1)) {
            return bridge_error(1, "Invalid source policy value.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        TorrentIdentity *identity = identity_from_handle(*handle);
        if (identity == nullptr) {
            return bridge_error(2, "Torrent identity not found.");
        }

        bool const metadata_pending = client->metadata_validation_pending.contains(identity);
        if ((metadata_pending && field != TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT
                && field <= TTORRENT_SOURCE_POLICY_ENABLE_LSD)
            || (!metadata_pending && field == TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT)) {
            return bridge_error(2, "This source policy field is unavailable for the current metadata state.");
        }

        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }

        DirtyMask const source_policy_changes = client->set_source_policy_field(
            *handle,
            identity,
            field,
            value
        );
        publisher.add(source_policy_changes);
        ResumeSaveResult const saved_policy = client->save_source_policy_resume_data(*handle, identity);
        if (!saved_policy) {
            return client->fault_persistence(
                2,
                "Source policy could not be saved: " + saved_policy.error()
            );
        }
        if ((source_policy_changes & TTORRENT_DIRTY_TRACKERS) == 0U) {
            publisher.add(client->cache_trackers(*handle, handle->trackers()));
        }
        if ((source_policy_changes & TTORRENT_DIRTY_WEB_SEEDS) == 0U) {
            BridgeResult const cached_web_seeds = client->cache_web_seeds(*handle, publisher.changes);
            if (!cached_web_seeds) {
                return cached_web_seeds;
            }
        }
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" TTorrentOptionsResult TorrentClientCopyTorrentOptions(
    TTorrentClient *client,
    const char *torrent_id,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    TTorrentOptionsResult output{};
    output.status = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        TorrentIdentity const *identity = identity_from_handle(*handle);
        output.options.download_rate_limit = handle->download_limit();
        output.options.upload_rate_limit = handle->upload_limit();
        output.options.max_uploads = normalized_torrent_count_limit(handle->max_uploads());
        output.options.max_connections = normalized_torrent_count_limit(handle->max_connections());
        output.options.queue_priority = identity == nullptr ? TTORRENT_QUEUE_PRIORITY_NORMAL : identity->queue_priority;
        return {};
    });
    return output;
}

extern "C" int32_t TorrentClientSetTorrentOptions(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentOptions options,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }
        if (options.download_rate_limit < -1 || options.upload_rate_limit < -1) {
            return bridge_error(1, "Torrent rate limits must be unlimited or nonnegative.");
        }
        if (!is_valid_torrent_count_limit(options.max_uploads)
            || !is_valid_torrent_count_limit(options.max_connections)) {
            return bridge_error(1, "Torrent count limits must be unlimited or at least 2.");
        }
        if (!is_valid_queue_priority(options.queue_priority)) {
            return bridge_error(1, "Invalid queue priority.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        TorrentIdentity *identity = identity_from_handle(*handle);
        if (identity == nullptr) {
            return bridge_error(2, "Torrent identity not found.");
        }

        if (handle->download_limit() != options.download_rate_limit) {
            handle->set_download_limit(options.download_rate_limit);
        }
        if (handle->upload_limit() != options.upload_rate_limit) {
            handle->set_upload_limit(options.upload_rate_limit);
        }
        if (normalized_torrent_count_limit(handle->max_uploads()) != options.max_uploads) {
            handle->set_max_uploads(options.max_uploads);
        }
        if (normalized_torrent_count_limit(handle->max_connections()) != options.max_connections) {
            handle->set_max_connections(options.max_connections);
        }
        std::vector<lt::torrent_handle> queue_handles_to_save;
        bool queue_priority_changed = false;
        if (identity->queue_priority != options.queue_priority) {
            client->invalidate_queue_order_index_locked();
            identity->queue_priority = options.queue_priority;
            identity->queue_rank = kUnsetQueueRank;
            queue_handles_to_save = client->apply_queue_priority_order_locked();
            queue_priority_changed = true;
        }
        if (!queue_priority_changed) {
            client->request_save(*handle);
            publisher.add(client->cache_snapshot(*handle));
        } else {
            append_unique_handle_by_identity(queue_handles_to_save, *handle);
            save_and_publish_policy_handles(
                *client,
                std::span<lt::torrent_handle const>(queue_handles_to_save),
                publisher
            );
        }
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientMoveTorrentInQueue(
    TTorrentClient *client,
    const char *torrent_id,
    int32_t move,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }
        if (move < TTORRENT_QUEUE_MOVE_TOP || move > TTORRENT_QUEUE_MOVE_BOTTOM) {
            return bridge_error(1, "Invalid queue move.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        TorrentIdentity *identity = identity_from_handle(*handle);
        if (identity == nullptr) {
            return bridge_error(2, "Torrent identity not found.");
        }

        std::vector<QueueOrderingEntry> entries;
        {
            std::scoped_lock io_guard(client->resume_io_lock);
            entries = queue_ordering_entries(*client);
        }
        if (move_queue_entry(entries, identity, move)) {
            bool positions_applied = false;
            std::vector<lt::torrent_handle> queue_handles_to_save = apply_queue_order(
                entries,
                &positions_applied
            );
            if (!positions_applied) {
                client->invalidate_queue_order_index_locked();
            }
            append_unique_handle_by_identity(queue_handles_to_save, *handle);
            save_and_publish_policy_handles(
                *client,
                std::span<lt::torrent_handle const>(queue_handles_to_save),
                publisher
            );
            client->request_snapshot_update_locked();
        }
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientCopyTrackerBatch(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentTrackerSnapshot *trackers,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out,
    uint8_t *resident_out
) noexcept
{
    clear_count_outputs(revision_out, required_count_out);
    if (resident_out != nullptr) {
        *resident_out = bridge_bool(false);
    }
    if (client == nullptr || torrent_id == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentTrackerSnapshot> output = output_span_from_c_buffer(trackers, capacity);
        return client->copy_trackers(
            std::string(c_string_view(torrent_id)),
            output,
            revision_out,
            required_count_out,
            resident_out
        );
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientCopyTrackerHostBatch(
    TTorrentClient *client,
    TTorrentTrackerHostSnapshot *hosts,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out
) noexcept
{
    clear_count_outputs(revision_out, required_count_out);
    if (client == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentTrackerHostSnapshot> output = output_span_from_c_buffer(hosts, capacity);
        return client->copy_tracker_hosts(output, revision_out, required_count_out);
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientCopyWebSeedBatch(TTorrentClient *client, const char *torrent_id,
                                                 TTorrentWebSeedSnapshot *web_seeds, int32_t capacity,
                                                 uint64_t *revision_out, int32_t *required_count_out,
                                                 uint8_t *resident_out) noexcept
{
    clear_count_outputs(revision_out, required_count_out);
    if (resident_out != nullptr) {
        *resident_out = bridge_bool(false);
    }
    if (client == nullptr || torrent_id == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentWebSeedSnapshot> output = output_span_from_c_buffer(web_seeds, capacity);
        return client->copy_web_seeds(
            std::string(c_string_view(torrent_id)),
            output,
            revision_out,
            required_count_out,
            resident_out
        );
    } catch (...) {
        return 0;
    }
}

extern "C" TTorrentWebSeedActivityResult TorrentClientCopyWebSeedActivity(
    TTorrentClient *client,
    const char *torrent_id
) noexcept
{
    TTorrentWebSeedActivityResult output{};
    if (client == nullptr || torrent_id == nullptr) {
        return output;
    }

    try {
        output.status = client->copy_web_seed_activity(
            std::string(c_string_view(torrent_id)),
            &output.activity,
            &output.revision
        ) ? 1 : 0;
    } catch (...) {
        output = {};
    }
    return output;
}

extern "C" TTorrentPeerSourcesResult TorrentClientCopyPeerSources(
    TTorrentClient *client,
    const char *torrent_id
) noexcept
{
    TTorrentPeerSourcesResult output{};
    if (client == nullptr || torrent_id == nullptr) {
        return output;
    }

    try {
        output.status = client->copy_peer_sources(
            std::string(c_string_view(torrent_id)),
            &output.sources,
            &output.revision
        ) ? 1 : 0;
    } catch (...) {
        output = {};
    }
    return output;
}

extern "C" int32_t TorrentClientRequestFiles(TTorrentClient *client, const char *torrent_id, char *error_out,
                                             int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        return client->request_files(std::string(c_string_view(torrent_id)), publisher.changes);
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientCopyFileBatch(TTorrentClient *client, const char *torrent_id,
                                              TTorrentFileSnapshot *files, int32_t capacity, uint64_t *revision_out,
                                              int32_t *required_count_out, uint8_t *resident_out) noexcept
{
    clear_count_outputs(revision_out, required_count_out);
    if (resident_out != nullptr) {
        *resident_out = bridge_bool(false);
    }
    if (client == nullptr || torrent_id == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentFileSnapshot> output = output_span_from_c_buffer(files, capacity);
        return client->copy_files(
            std::string(c_string_view(torrent_id)),
            output,
            revision_out,
            required_count_out,
            resident_out
        );
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientRequestPieceMap(TTorrentClient *client, const char *torrent_id, char *error_out,
                                                int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        return client->request_piece_map(std::string(c_string_view(torrent_id)), publisher.changes);
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientCopyPieceMap(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentPieceMapSnapshot *snapshot,
    uint8_t *pieces,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out,
    uint8_t *resident_out
) noexcept
{
    clear_count_outputs(revision_out, required_count_out);
    if (resident_out != nullptr) {
        *resident_out = bridge_bool(false);
    }
    if (snapshot != nullptr) {
        *snapshot = TTorrentPieceMapSnapshot{};
    }
    if (client == nullptr || torrent_id == nullptr) {
        return 0;
    }

    try {
        std::span<std::uint8_t> output = output_span_from_c_buffer(pieces, capacity);
        return client->copy_piece_map(
            std::string(c_string_view(torrent_id)),
            snapshot,
            output,
            revision_out,
            required_count_out,
            resident_out
        );
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientSetFilePriority(
    TTorrentClient *client,
    const char *torrent_id,
    int32_t file_index,
    int32_t priority,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }
        if (file_index < 0 || !is_valid_file_priority(priority)) {
            return bridge_error(1, "Invalid file priority.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }

        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        std::shared_ptr<lt::torrent_info const> const torrent_file = handle->torrent_file();
        if (!torrent_file || !torrent_file->is_valid()) {
            return bridge_error(2, "Torrent metadata is not available.");
        }

        lt::renamed_files const renamed_files = handle->get_renamed_files();
        BridgeResult const valid_info = validate_torrent_info(
            *torrent_file,
            renamed_files.export_filenames(torrent_file->layout())
        );
        if (!valid_info) {
            return valid_info;
        }
        if (file_index >= torrent_file->layout().num_files()) {
            return bridge_error(2, "File not found.");
        }

        handle->file_priority(lt::file_index_t(file_index), file_priority_from_bridge(priority));
        client->request_save(*handle);
        BridgeResult const cached_files = client->cache_file_metadata(*handle, publisher.changes);
        if (!cached_files) {
            return cached_files;
        }
        publisher.add(client->cache_snapshot(*handle));
        handle->post_file_progress(lt::torrent_handle::piece_granularity);
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientPause(TTorrentClient *client, const char *torrent_id, char *error_out,
                                      int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        client->invalidate_queue_order_index_locked();
        handle->set_flags(lt::torrent_flags::paused, lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
        client->request_save(*handle);
        publisher.add(client->cache_snapshot(*handle));
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientResume(TTorrentClient *client, const char *torrent_id, char *error_out,
                                       int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        client->invalidate_queue_order_index_locked();
        handle->set_flags(lt::torrent_flags::auto_managed, lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
        std::vector<lt::torrent_handle> queue_handles_to_save = client->apply_queue_priority_order_locked();
        std::span<lt::torrent_handle const> queue_handles_span(queue_handles_to_save);
        if (!queue_handles_to_save.empty()) {
            save_and_publish_policy_handles(*client, queue_handles_span, publisher);
        }
        if (!contains_handle_identity(queue_handles_span, *handle)) {
            client->request_save(*handle);
            publisher.add(client->cache_snapshot(*handle));
        }
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientReannounce(TTorrentClient *client, const char *torrent_id, char *error_out,
                                           int32_t error_capacity) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        handle->force_reannounce();
        return {};
    });
}

extern "C" int32_t TorrentClientForceRecheck(TTorrentClient *client, const char *torrent_id, char *error_out,
                                             int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr) {
            return bridge_error(1, "Missing torrent client or torrent id.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        handle->force_recheck();
        publisher.add(client->cache_snapshot(*handle));
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientRemove(TTorrentClient *client, const char *torrent_id, uint8_t delete_files,
                                       uint8_t delete_partfile, std::uint64_t *request_token_out,
                                       uint8_t *removal_committed_out, char *error_out, int32_t error_capacity) noexcept
{
    if (request_token_out != nullptr) {
        *request_token_out = 0;
    }
    if (removal_committed_out != nullptr) {
        *removal_committed_out = bridge_bool(false);
    }
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr || request_token_out == nullptr
            || removal_committed_out == nullptr) {
            return bridge_error(1, "Missing torrent client, torrent id, or removal operation output.");
        }

        std::string const id(c_string_view(torrent_id));
        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
        auto handle = client->find(id);
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        lt::remove_flags_t flags{};
        if (bridge_bool(delete_files)) {
            flags |= lt::session_handle::delete_files;
        }
        if (bridge_bool(delete_partfile)) {
            flags |= lt::session_handle::delete_partfile;
        }
        bool const waits_for_delete = bridge_bool(delete_files) || bridge_bool(delete_partfile);
        lt::info_hash_t const hashes = handle->info_hashes();
        TorrentIdentity *identity = identity_from_handle(*handle);
        std::vector<std::string> const removal_ids = client->removal_ids_for_identity(hashes, id, identity);
        std::uint64_t const request_token = waits_for_delete ? client->begin_delete_request(hashes) : 0;
        BridgeResult tombstoned;
        try {
            tombstoned = client->persist_removal_tombstones(
                removal_ids,
                waits_for_delete ? RemovalTombstoneState::awaiting_payload_delete : RemovalTombstoneState::resume_cleanup,
                bridge_bool(delete_files), bridge_bool(delete_partfile));
        } catch (...) {
            client->abandon_removal_request(request_token);
            throw;
        }
        if (!tombstoned) {
            client->abandon_removal_request(request_token);
            return tombstoned;
        }

        client->invalidate_queue_order_index_locked();
        try {
            client->session.remove_torrent(*handle, flags);
        } catch (std::exception const &exception) {
            client->abandon_removal_request(request_token);
            return client->cancel_tombstoned_operation_or_fault(removal_ids, 3, exception.what());
        } catch (...) {
            client->abandon_removal_request(request_token);
            return client->cancel_tombstoned_operation_or_fault(removal_ids, 3, "Torrent could not be removed.");
        }
        *request_token_out = request_token;
        *removal_committed_out = bridge_bool(true);
        client->mark_remove_requested(hashes, id, identity);
        if (waits_for_delete) {
            client->remember_pending_delete(hashes, removal_ids);
        } else {
            ResumeSaveResult removed_resume = client->remove_resume_files_for_ids_checked(removal_ids);
            if (!removed_resume) {
                client->remember_pending_resume_cleanup(removal_ids);
                publisher.add(client->queue_alert_error("Torrent was removed, but resume cleanup is pending: " + removed_resume.error() + "."));
            } else {
                ResumeSaveResult cleared_tombstones = client->clear_removal_tombstones(removal_ids);
                if (!cleared_tombstones) {
                    publisher.add(client->queue_alert_error(
                        "Torrent was removed, but removal marker cleanup is pending: "
                        + cleared_tombstones.error()
                        + "."
                    ));
                }
            }
        }
        publisher.add(client->remove_snapshot(hashes, id));
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" TTorrentRemovalReadResult TorrentClientTakeRemovalResult(
    TTorrentClient *client,
    std::uint64_t request_token,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    TTorrentRemovalReadResult output{};
    output.status = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }

        std::scoped_lock guard(client->lock);
        return client->take_removal_result(request_token, &output.result);
    });
    return output;
}

extern "C" int32_t TorrentClientApplySettings(
    TTorrentClient *client,
    TTorrentSessionSettings requested,
    char const *required_network_interface,
    int32_t required_network_interface_size,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }
        bool const has_network_interface = required_network_interface != nullptr;
        bool const has_network_interface_bytes = required_network_interface_size != 0;
        if (required_network_interface_size < 0
            || required_network_interface_size > TTORRENT_MAX_NETWORK_INTERFACE_BYTES
            || has_network_interface != has_network_interface_bytes) {
            return bridge_error(1, "Invalid required network interface buffer.");
        }

        std::span<char const> const network_interface_bytes = input_span_from_c_buffer(
            required_network_interface,
            required_network_interface_size
        );
        std::string const network_interface(
            network_interface_bytes.begin(),
            network_interface_bytes.end()
        );
        bool const accept_incoming_connections = bridge_bool(requested.accept_incoming_connections);
        bool const enable_port_forwarding = bridge_bool(requested.enable_port_forwarding);
        bool const enable_dht = bridge_bool(requested.enable_dht);
        bool const use_dht_by_default = bridge_bool(requested.use_dht_by_default);
        bool const dht_read_only = bridge_bool(requested.dht_read_only);
        if (!is_valid_dht_discovery_policy(requested.dht_discovery_policy)) {
            return bridge_error(1, "Invalid DHT discovery policy.");
        }
        bool const use_dht_as_fallback = requested.dht_discovery_policy
            == TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL;
        bool const enable_lsd = bridge_bool(requested.enable_lsd);
        bool const use_lsd_by_default = bridge_bool(requested.use_lsd_by_default);
        bool const use_pex_by_default = bridge_bool(requested.use_pex_by_default);
        if (!is_valid_https_tracker_policy(requested.https_tracker_policy, false)
            || !is_valid_https_web_seed_policy(requested.https_web_seed_policy, false)) {
            return bridge_error(1, "Invalid HTTPS source policy.");
        }
        HTTPSPolicy const https_tracker_policy = https_policy_from_value(requested.https_tracker_policy);
        HTTPSPolicy const https_web_seed_policy = https_policy_from_value(requested.https_web_seed_policy);
        bool const anonymous_mode = bridge_bool(requested.anonymous_mode);
        bool const network_blocked = bridge_bool(requested.network_blocked);
        if (!is_valid_encryption_policy(requested.encryption_policy)) {
            return bridge_error(1, "Invalid encryption policy.");
        }
        if (!network_blocked) {
            static_cast<void>(network_binding(network_interface));
        }
        std::string const listen_interface_settings =
            listen_interfaces(requested.incoming_port, network_interface, network_blocked);
        std::string const outgoing_interface_settings =
            outgoing_interfaces(network_interface, network_blocked);

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        if (network_blocked) {
            DirtyMask containment_changes = 0U;
            BridgeResult const containment = block_network_locked(
                *client,
                containment_changes
            );
            if (!containment) {
                return containment;
            }
            publisher.add(containment_changes);
        }

        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }

        bool const should_resume_session = client->requested_network_blocked && !network_blocked;
        bool const expected_session_paused = network_blocked
            || (!should_resume_session && client->session.is_paused());
        HTTPSSourcePolicy const previous_https_source_policy{
            .trackers = client->https_tracker_policy,
            .web_seeds = client->https_web_seed_policy,
        };
        SourcePolicyApplicationResult source_policy_application;
        add_policy_result(source_policy_application, apply_dht_policy_locked(*client, use_dht_by_default));
        client->lsd_service_enabled = enable_lsd;
        add_policy_result(source_policy_application, apply_lsd_policy_locked(*client, use_lsd_by_default));

        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces, listen_interface_settings);
        settings.set_str(lt::settings_pack::outgoing_interfaces, outgoing_interface_settings);
        settings.set_int(lt::settings_pack::download_rate_limit, requested.download_rate_limit);
        settings.set_int(lt::settings_pack::upload_rate_limit, requested.upload_rate_limit);
        settings.set_int(lt::settings_pack::active_downloads, requested.active_downloads);
        settings.set_int(lt::settings_pack::active_seeds, requested.active_seeds);
        settings.set_int(lt::settings_pack::active_limit, requested.active_limit);
        settings.set_bool(lt::settings_pack::dont_count_slow_torrents, false);
        settings.set_int(lt::settings_pack::share_ratio_limit, requested.share_ratio_limit);
        settings.set_int(lt::settings_pack::seed_time_limit, requested.seed_time_limit);
        settings.set_bool(lt::settings_pack::enable_upnp, !network_blocked && enable_port_forwarding);
        settings.set_bool(lt::settings_pack::enable_natpmp, !network_blocked && enable_port_forwarding);
        settings.set_bool(lt::settings_pack::enable_dht, !network_blocked && enable_dht);
        settings.set_bool(lt::settings_pack::dht_read_only, dht_read_only);
        settings.set_bool(lt::settings_pack::use_dht_as_fallback, use_dht_as_fallback);
        settings.set_bool(lt::settings_pack::enable_lsd, !network_blocked && enable_lsd);
        settings.set_bool(lt::settings_pack::enable_outgoing_tcp, !network_blocked);
        settings.set_bool(lt::settings_pack::enable_incoming_tcp, !network_blocked && accept_incoming_connections);
        settings.set_bool(lt::settings_pack::enable_outgoing_utp, !network_blocked);
        settings.set_bool(lt::settings_pack::enable_incoming_utp, !network_blocked && accept_incoming_connections);
        settings.set_bool(lt::settings_pack::anonymous_mode, anonymous_mode);
        settings.set_bool(lt::settings_pack::dht_privacy_lookups, !network_blocked && enable_dht);
        settings.set_bool(lt::settings_pack::announce_to_all_trackers, false);
        settings.set_bool(lt::settings_pack::announce_to_all_tiers, false);
        settings.set_bool(lt::settings_pack::prefer_udp_trackers, false);
        settings.set_bool(lt::settings_pack::validate_https_trackers, true);
        settings.set_bool(lt::settings_pack::ssrf_mitigation, true);
        settings.set_bool(lt::settings_pack::always_send_user_agent, false);
        settings.set_int(lt::settings_pack::out_enc_policy, encryption_policy(requested.encryption_policy));
        settings.set_int(lt::settings_pack::in_enc_policy, encryption_policy(requested.encryption_policy));
        settings.set_int(lt::settings_pack::allowed_enc_level, static_cast<int>(lt::settings_pack::pe_both));
        settings.set_bool(lt::settings_pack::prefer_rc4, false);
        client->session.apply_settings(std::move(settings));
        add_policy_result(source_policy_application, apply_peer_exchange_policy_locked(*client, use_pex_by_default));
        client->https_tracker_policy = https_tracker_policy;
        client->https_web_seed_policy = https_web_seed_policy;
        publisher.add(source_policy_application.changes);
        request_policy_saves(*client, source_policy_application.handles_to_save);
        publisher.add(client->apply_https_source_policy_locked(previous_https_source_policy));

        if (network_blocked) {
            client->session.pause();
        } else if (should_resume_session) {
            client->session.resume();
        }

        BridgeResult const acknowledged = acknowledge_network_state_locked(
            *client,
            NativeNetworkStateExpectation{
                .listen_interfaces = listen_interface_settings,
                .outgoing_interfaces = outgoing_interface_settings,
                .enable_upnp = !network_blocked && enable_port_forwarding,
                .enable_natpmp = !network_blocked && enable_port_forwarding,
                .enable_dht = !network_blocked && enable_dht,
                .enable_lsd = !network_blocked && enable_lsd,
                .enable_outgoing_tcp = !network_blocked,
                .enable_incoming_tcp = !network_blocked && accept_incoming_connections,
                .enable_outgoing_utp = !network_blocked,
                .enable_incoming_utp = !network_blocked && accept_incoming_connections,
                .dht_privacy_lookups = !network_blocked && enable_dht,
                .dht_read_only = dht_read_only,
                .use_dht_as_fallback = use_dht_as_fallback,
                .session_paused = expected_session_paused,
            },
            network_blocked
                ? "Native network containment could not be confirmed."
                : "Native network binding could not be confirmed."
        );
        if (!acknowledged) {
            return acknowledged;
        }

        if (network_blocked) {
            publisher.add(client->record_network_blocked());
        } else {
            publisher.add(client->record_network_requested(false));
        }
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientBlockNetwork(
    TTorrentClient *client,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 1, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        DirtyMask changes = 0U;
        BridgeResult const containment = block_network_locked(*client, changes);
        if (!containment) {
            return containment;
        }
        publisher.add(changes);
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" TTorrentNetworkStatusResult TorrentClientCopyNetworkStatus(TTorrentClient *client) noexcept
{
    TTorrentNetworkStatusResult output{};
    if (client == nullptr) {
        return output;
    }

    try {
        std::scoped_lock guard(client->lock);
        output.network_status = client->network_status();
        output.status = 1;
    } catch (...) {
        output = {};
    }
    return output;
}

extern "C" TTorrentBridgeHealthResult TorrentClientCopyHealth(TTorrentClient *client) noexcept
{
    TTorrentBridgeHealthResult output{};
    if (client == nullptr) {
        return output;
    }

    try {
        std::scoped_lock guard(client->lock);
        output.health = client->health_status();
        output.status = 1;
    } catch (...) {
        output = {};
    }
    return output;
}

extern "C" int32_t TorrentClientSaveAllChecked(
    TTorrentClient *client,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }

        return client->save_all_checked();
    });
}

extern "C" void TorrentClientSaveAll(TTorrentClient *client) noexcept
{
    if (client == nullptr) {
        return;
    }

    try {
        client->save_all();
    } catch (...) {
        ignore_shutdown_failure();
    }
}

extern "C" int32_t TorrentClientTakeAlertError(
    TTorrentClient *client,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    std::span<char> const error_buffer = output_buffer(error_out, error_capacity);
    copy_error(error_buffer, "");
    if (client == nullptr) {
        return 0;
    }

    try {
        return client->take_alert_error(error_buffer) ? 1 : 0;
    } catch (...) {
        copy_error(error_buffer, "Unexpected libtorrent error.");
        return error_buffer.empty() ? 0 : 1;
    }
}

} // namespace torrent_bridge::internal
