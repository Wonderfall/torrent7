#include "TorrentBridgeInternal.hpp"

namespace torrent_bridge::internal {

namespace {

[[nodiscard]] std::uint64_t saturating_increment(std::uint64_t const value) noexcept
{
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

#if defined(TORRENT_BRIDGE_TESTING)
[[nodiscard]] AuthorizedSaveRootMap test_authorized_save_roots(
    AuthorizedSavePathSet const &paths
)
{
    AuthorizedSaveRootMap roots;
    for (std::string const &path : paths) {
        UniqueFileDescriptor descriptor(::open(
            path.c_str(),
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        ));
        if (!descriptor.is_valid()) {
            throw std::system_error(errno, std::generic_category(), "Could not open authorized test root");
        }
        struct ::stat metadata {};
        if (::fstat(descriptor.get(), &metadata) != 0) {
            throw std::system_error(errno, std::generic_category(), "Could not inspect authorized test root");
        }
        lt::error_code root_error;
        std::shared_ptr<lt::aux::storage_root> root = lt::aux::make_storage_root(
            path,
            descriptor.get(),
            static_cast<std::uint64_t>(metadata.st_dev),
            static_cast<std::uint64_t>(metadata.st_ino),
            {},
            root_error
        );
        if (root_error || !root) {
            throw std::runtime_error("Could not create authorized test root: " + root_error.message());
        }
        roots.emplace(path, std::move(root));
    }
    return roots;
}
#endif

} // namespace

std::chrono::milliseconds alert_worker_failure_backoff(std::uint64_t const consecutive_failures) noexcept
{
    auto delay = kAlertWorkerInitialFailureBackoff;
    auto const maximum = std::chrono::duration_cast<std::chrono::milliseconds>(
        kAlertWorkerMaximumFailureBackoff
    );
    std::uint64_t remaining_doublings = consecutive_failures > 1U ? consecutive_failures - 1U : 0U;
    while (remaining_doublings > 0U && delay < maximum) {
        delay = std::min(delay * 2, maximum);
        --remaining_doublings;
    }
    return delay;
}

bool wait_for_alert_worker_backoff(
    std::stop_token const &stop_token,
    std::chrono::milliseconds const duration
) noexcept
{
    try {
        std::mutex wait_lock;
        std::condition_variable_any stopped;
        std::unique_lock guard(wait_lock);
        static_cast<void>(stopped.wait_for(guard, stop_token, duration, [] {
            return false;
        }));
        return !stop_token.stop_requested();
    } catch (...) {
        return false;
    }
}

TTorrentClient::TTorrentClient(std::string_view state_path, bool enable_peer_exchange_plugin)
    : TTorrentClient(state_path, enable_peer_exchange_plugin, AuthorizedSaveRootMap{})
{
}

#if defined(TORRENT_BRIDGE_TESTING)
TTorrentClient::TTorrentClient(
    std::string_view state_path,
    bool enable_peer_exchange_plugin,
    AuthorizedSavePathSet const &authorized_paths
)
    : TTorrentClient(
        state_path,
        enable_peer_exchange_plugin,
        test_authorized_save_roots(authorized_paths)
    )
{
}
#endif

TTorrentClient::TTorrentClient(
    std::string_view state_path,
    bool enable_peer_exchange_plugin,
    AuthorizedSaveRootMap authorized_roots
)
    : state_directory(std::string(state_path)),
      resume_directory(state_directory / "ResumeData"),
      authorized_save_roots(std::move(authorized_roots)),
      session(make_session_params(enable_peer_exchange_plugin)),
      peer_exchange_plugin_enabled(enable_peer_exchange_plugin)
{
    authorized_save_root_lifetimes.reserve(authorized_save_roots.size());
    for (auto const &[path, root] : authorized_save_roots) {
        static_cast<void>(path);
        authorized_save_root_lifetimes.emplace_back(root);
    }

    session.pause();

    std::error_code create_error;
    fs::create_directories(state_directory, create_error);
    if (create_error) {
        throw std::system_error(create_error, "Could not create state directory");
    }
    state_directory_descriptor = open_directory_no_follow(state_directory, "state directory");
    restrict_permissions(state_directory_descriptor.get(), "state directory", FileSystemNodeKind::directory);
    state_lock = acquire_state_directory_lock(state_directory_descriptor.get());

    constexpr mode_t kOwnerDirectoryPermissions = S_IRUSR | S_IWUSR | S_IXUSR;
    if (::mkdirat(state_directory_descriptor.get(), "ResumeData", kOwnerDirectoryPermissions) != 0
        && errno != EEXIST) {
        throw std::system_error(
            std::error_code(errno, std::generic_category()),
            "Could not create resume data directory"
        );
    }
    resume_directory_descriptor = open_directory_at_no_follow(
        state_directory_descriptor.get(),
        "ResumeData",
        "resume data directory"
    );
    restrict_permissions(resume_directory_descriptor.get(), "resume data directory", FileSystemNodeKind::directory);
    remove_orphan_resume_temp_files();
    {
        std::scoped_lock io_guard(resume_io_lock);
        ResumeSaveResult indexed_tombstones = load_removal_tombstone_index_locked(
            RemovalTombstoneIndexLimits{
                .entry_count = kMaxRemovalTombstoneEntryCount,
                .id_membership_count = kMaxRemovalTombstoneIDMembershipCount,
            }
        );
        if (!indexed_tombstones) {
            throw std::runtime_error(indexed_tombstones.error());
        }
    }
    ResumeSaveResult completed_removals = complete_pending_removals();
    if (!completed_removals) {
        throw std::runtime_error(completed_removals.error());
    }
    load_resume_data();
    static_cast<void>(rebuild_snapshot_cache());
    request_snapshot_update();
    start_alert_worker();
}

TTorrentClient::~TTorrentClient() noexcept
{
    clear_wake_callback();
    stop_alert_worker();

    try {
        pump_alerts();
    } catch (...) {
        ignore_shutdown_failure();
    }

    try {
        save_all();
    } catch (...) {
        ignore_shutdown_failure();
    }

    try {
        lt::session_proxy proxy = session.abort();
        deferred_session_shutdown.capture(std::move(proxy), std::move(state_lock));
    } catch (...) {
        ignore_shutdown_failure();
    }
}

void TTorrentClient::set_session_shutdown_asynchronous(bool value) noexcept
{
    deferred_session_shutdown.set_destroy_asynchronously(value);
}

void TTorrentClient::set_wake_callback(TTorrentWakeCallback callback, void *context)
{
    if (callback == nullptr || context == nullptr) {
        throw std::invalid_argument("Wake callback and context are required.");
    }

    WakeCallbackInvocation wake;
    {
        std::unique_lock guard(lock);
        if (wake_callback != nullptr) {
            throw std::logic_error("Wake callback is already installed.");
        }
        wake_callback = callback;
        wake_callback_context = context;
        if (has_dirty_changes(pending_changes) && !wake_pending) {
            wake_pending = true;
            ++wake_callbacks_in_flight;
            wake = WakeCallbackInvocation{.callback = callback, .context = context};
        }
    }
    invoke_wake_callback(wake);
}

void TTorrentClient::clear_wake_callback() noexcept
{
    try {
        std::unique_lock guard(lock);
        wake_callback = nullptr;
        wake_callback_context = nullptr;
        wake_pending = false;
        wake_callback_quiesced.wait(guard, [this] {
            return wake_callbacks_in_flight == 0;
        });
    } catch (...) {
        ignore_shutdown_failure();
    }
}

std::uint64_t TTorrentClient::take_changes(DirtyMask *changes_out) noexcept
{
    try {
        std::scoped_lock guard(lock);
        DirtyMask const changes = pending_changes;
        pending_changes = 0;
        wake_pending = false;
        if (changes_out != nullptr) {
            *changes_out = changes;
        }
        return publication_epoch;
    } catch (...) {
        if (changes_out != nullptr) {
            *changes_out = 0;
        }
        return 0;
    }
}

WakeCallbackInvocation TTorrentClient::publish_changes_locked(DirtyMask changes) noexcept
{
    if (!has_dirty_changes(changes)) {
        return {};
    }

    if ((changes & TTORRENT_DIRTY_TORRENTS) != 0U) {
        ++snapshot_revision;
    }
    if ((changes & TTORRENT_DIRTY_TRACKERS) != 0U) {
        ++tracker_revision;
    }
    if ((changes & TTORRENT_DIRTY_TRACKER_HOSTS) != 0U) {
        ++tracker_host_revision;
    }
    if ((changes & TTORRENT_DIRTY_WEB_SEEDS) != 0U) {
        ++web_seed_revision;
    }
    if ((changes & TTORRENT_DIRTY_FILES) != 0U) {
        ++file_revision;
    }
    if ((changes & TTORRENT_DIRTY_PIECES) != 0U) {
        ++piece_map_revision;
    }

    ++publication_epoch;
    pending_changes |= changes;

    if (wake_callback == nullptr || wake_pending) {
        return {};
    }

    wake_pending = true;
    ++wake_callbacks_in_flight;
    return WakeCallbackInvocation{.callback = wake_callback, .context = wake_callback_context};
}

void TTorrentClient::complete_wake_callback() noexcept
{
    try {
        std::scoped_lock guard(lock);
        if (wake_callbacks_in_flight > 0) {
            --wake_callbacks_in_flight;
        }
        if (wake_callbacks_in_flight == 0) {
            wake_callback_quiesced.notify_all();
        }
    } catch (...) {
        ignore_shutdown_failure();
    }
}

void TTorrentClient::invoke_wake_callback(WakeCallbackInvocation wake) noexcept
{
    if (wake.callback == nullptr) {
        return;
    }

    try {
        wake.callback(wake.context);
    } catch (...) {
        ignore_shutdown_failure();
    }
    complete_wake_callback();
}

void TTorrentClient::start_alert_worker()
{
    alert_thread = std::jthread([this](std::stop_token const &stop_token) {
        alert_loop(stop_token);
    });
}

void TTorrentClient::stop_alert_worker() noexcept
{
    try {
        if (!alert_thread.joinable()) {
            return;
        }

        alert_thread.request_stop();
        alert_thread.join();
    } catch (...) {
        ignore_shutdown_failure();
    }
}

void TTorrentClient::record_synchronous_add_alert_locked() noexcept
{
    if (synchronous_adds_since_alert_drain < kSynchronousAddAlertDrainInterval) {
        ++synchronous_adds_since_alert_drain;
    }
}

void TTorrentClient::drain_synchronous_add_alerts_if_needed() noexcept
{
    {
        std::scoped_lock guard(lock);
        if (synchronous_adds_since_alert_drain < kSynchronousAddAlertDrainInterval) {
            return;
        }
    }

    // The ordinary worker remains the fallback if an opportunistic drain
    // fails. pump_alerts resets the pressure counter only after pop_alerts has
    // successfully transferred ownership of the queued batch.
    try {
        pump_alerts();
    } catch (...) {
        ignore_shutdown_failure();
    }
}

void TTorrentClient::alert_loop(std::stop_token const &stop_token)
{
    using clock = std::chrono::steady_clock;
    auto const advance_deadline = [](clock::time_point deadline, clock::duration interval, clock::time_point now) {
        while (deadline <= now) {
            deadline += interval;
        }
        return deadline;
    };
    auto next_snapshot_update = clock::now();
    auto next_resume_save = clock::now() + kPeriodicResumeSaveInterval;
    auto next_resume_retry = clock::now() + kResumeRetryInterval;

    while (!stop_token.stop_requested()) {
        try {
            auto const now = clock::now();
            auto const next_deadline = std::min({next_snapshot_update, next_resume_save, next_resume_retry});
            auto const remaining = next_deadline > now ? next_deadline - now : clock::duration::zero();
            auto const wait_duration = std::min(
                std::chrono::duration_cast<std::chrono::milliseconds>(remaining),
                kAlertWaitInterval
            );
            session.wait_for_alert(wait_duration);
            pump_alerts();

            auto const after_alerts = clock::now();
            bool const persistence_faulted_now = persistence_is_faulted();
            if (!persistence_faulted_now && after_alerts >= next_resume_retry) {
                retry_resume_writes(false);
                next_resume_retry = advance_deadline(next_resume_retry, kResumeRetryInterval, after_alerts);
            } else if (persistence_faulted_now && after_alerts >= next_resume_retry) {
                next_resume_retry = advance_deadline(next_resume_retry, kResumeRetryInterval, after_alerts);
            }
            if (!persistence_faulted_now && after_alerts >= next_resume_save) {
                request_periodic_resume_saves();
                next_resume_save = advance_deadline(next_resume_save, kPeriodicResumeSaveInterval, after_alerts);
            } else if (persistence_faulted_now && after_alerts >= next_resume_save) {
                next_resume_save = advance_deadline(next_resume_save, kPeriodicResumeSaveInterval, after_alerts);
            }
            if (after_alerts >= next_snapshot_update) {
                request_snapshot_update();
                next_snapshot_update = advance_deadline(next_snapshot_update, kSnapshotUpdateInterval, after_alerts);
            }
            record_alert_worker_recovery();
        } catch (std::exception const &exception) {
            std::uint64_t const failures = record_alert_worker_failure(exception.what());
            if (!wait_for_alert_worker_backoff(stop_token, alert_worker_failure_backoff(failures))) {
                return;
            }
        } catch (...) {
            std::uint64_t const failures = record_alert_worker_failure("Unexpected libtorrent alert worker error.");
            if (!wait_for_alert_worker_backoff(stop_token, alert_worker_failure_backoff(failures))) {
                return;
            }
        }
    }
}

std::uint64_t TTorrentClient::record_alert_worker_failure(std::string_view error) noexcept
{
    constexpr std::string_view kFallbackError = "Unexpected libtorrent alert worker error.";
    constexpr std::string_view kUserErrorPrefix = "Libtorrent alert worker failed and will retry: ";
    constexpr std::size_t kMaximumQueuedErrorBytes = sizeof(TTorrentBridgeHealth::last_alert_worker_error) - 1U;
    std::string_view const detail = error.empty() ? kFallbackError : error;
    std::uint64_t consecutive_failures = 1;
    WakeCallbackInvocation wake;
    try {
        std::scoped_lock guard(lock);
        bridge_health.total_alert_worker_failures = saturating_increment(
            bridge_health.total_alert_worker_failures
        );
        bridge_health.consecutive_alert_worker_failures = saturating_increment(
            bridge_health.consecutive_alert_worker_failures
        );
        consecutive_failures = bridge_health.consecutive_alert_worker_failures;
        bridge_health.alert_worker_degraded = bridge_bool(true);
        copy_string(std::span{bridge_health.last_alert_worker_error}, detail);

        DirtyMask changes = TTORRENT_DIRTY_HEALTH;
        try {
            std::string queued_error(kUserErrorPrefix);
            std::size_t const remaining = kMaximumQueuedErrorBytes - queued_error.size();
            queued_error.append(detail.substr(0, remaining));
            changes |= queue_alert_error(std::move(queued_error));
        } catch (...) {
            // The fixed-size health snapshot still records and publishes the
            // failure if allocating the optional user-facing queue entry fails.
            ignore_shutdown_failure();
        }
        wake = publish_changes_locked(changes);
    } catch (...) {
        return consecutive_failures;
    }
    invoke_wake_callback(wake);
    return consecutive_failures;
}

void TTorrentClient::record_alert_worker_recovery() noexcept
{
    WakeCallbackInvocation wake;
    try {
        std::scoped_lock guard(lock);
        if (bridge_health.consecutive_alert_worker_failures == 0U
            && !bridge_bool(bridge_health.alert_worker_degraded)) {
            return;
        }
        bridge_health.consecutive_alert_worker_failures = 0;
        bridge_health.alert_worker_degraded = bridge_bool(false);
        wake = publish_changes_locked(TTORRENT_DIRTY_HEALTH);
    } catch (...) {
        return;
    }
    invoke_wake_callback(wake);
}

[[nodiscard]] std::string TTorrentClient::reserve_canonical_torrent_id_locked(std::string canonical_id)
{
    if (is_canonical_torrent_id(canonical_id)
        && canonical_ids_in_use.insert(canonical_id).second) {
        return canonical_id;
    }

    constexpr int kMaxCanonicalIDGenerationAttempts = 256;
    for (int attempt = 0; attempt < kMaxCanonicalIDGenerationAttempts; ++attempt) {
        std::string generated = make_canonical_torrent_id();
        if (canonical_ids_in_use.insert(generated).second) {
            return generated;
        }
    }

    throw std::runtime_error("A unique torrent identifier could not be generated.");
}

TorrentIdentity *TTorrentClient::make_identity(std::string canonical_id)
{
    std::scoped_lock io_guard(resume_io_lock);
    if (!torrent_count_allows_admission(torrent_identities.size())) {
        throw std::length_error("The torrent limit has been reached.");
    }
    if (!torrent_identity_token_count_allows_admission(identity_tokens.size())) {
        throw std::length_error(
            "The torrent identity safety limit for this app session has been reached. Restart the app before adding more torrents."
        );
    }

    auto token = std::make_unique<TorrentIdentityToken>();
    auto identity = std::make_unique<TorrentIdentity>();
    identity->generation = next_identity_generation++;
    token->generation = identity->generation;
    identity->canonical_id = reserve_canonical_torrent_id_locked(std::move(canonical_id));
    TorrentIdentity *const raw = identity.get();
    TorrentIdentityToken *const raw_token = token.get();
    identity->token = raw_token;
    raw_token->active_identity.store(raw, std::memory_order_release);
    try {
        identity_tokens.push_back(std::move(token));
        try {
            torrent_identities.push_back(std::move(identity));
        } catch (...) {
            identity_tokens.pop_back();
            throw;
        }
    } catch (...) {
        canonical_ids_in_use.erase(raw->canonical_id);
        throw;
    }
    return raw;
}

TorrentIdentity *TTorrentClient::attach_identity(lt::add_torrent_params &params, std::string canonical_id)
{
    TorrentIdentity *identity = make_identity(std::move(canonical_id));
    std::array<char, sizeof(TTorrentSnapshot::comment)> comment{};
    copy_string(std::span{comment}, params.comment);
    identity->comment = comment.data();
    identity->creation_date = std::max<std::time_t>(params.creation_date, 0);
    params.userdata = identity->token;
    return identity;
}

BridgeResult TTorrentClient::ensure_torrent_admission_available(int32_t code) const
{
    if (session_identity_authority_faulted) {
        return bridge_error(
            code,
            "Torrent admission is blocked because the session identity authority is uncertain. Restart the app to recover."
        );
    }

    std::size_t tracked_count = 0;
    std::size_t identity_token_count = 0;
    {
        std::scoped_lock io_guard(resume_io_lock);
        tracked_count = torrent_identities.size();
        identity_token_count = identity_tokens.size();
    }
    // Every bridge-controlled session add attaches an identity before entering
    // libtorrent, and that identity remains tracked until asynchronous removal
    // completes. This count therefore bounds the session without copying every
    // torrent handle on each admission check.
    if (!torrent_count_allows_admission(tracked_count)) {
        return bridge_error(code, "The torrent limit has been reached.");
    }
    if (!torrent_identity_token_count_allows_admission(identity_token_count)) {
        return bridge_error(
            code,
            "The torrent identity safety limit for this app session has been reached. Restart the app before adding more torrents."
        );
    }
    return {};
}

std::uint64_t TTorrentClient::allocate_resume_generation_locked(TorrentIdentity *identity)
{
    if (identity == nullptr) {
        return 0;
    }
    return identity->resume_save.next_generation++;
}

std::uint64_t TTorrentClient::allocate_resume_generation(TorrentIdentity *identity)
{
    std::scoped_lock io_guard(resume_io_lock);
    return allocate_resume_generation_locked(identity);
}

namespace {

lt::resume_data_flags_t merged_resume_save_flags(lt::resume_data_flags_t existing,
                                                 lt::resume_data_flags_t requested) noexcept
{
    lt::resume_data_flags_t merged = existing | requested;
    bool const existing_only_if_modified =
        static_cast<bool>(existing & lt::torrent_handle::only_if_modified);
    bool const requested_only_if_modified =
        static_cast<bool>(requested & lt::torrent_handle::only_if_modified);
    if (!existing_only_if_modified || !requested_only_if_modified) {
        merged &= ~lt::torrent_handle::only_if_modified;
    }
    return merged;
}

} // namespace

std::optional<std::uint64_t> TTorrentClient::begin_async_resume_save(TorrentIdentity *identity,
                                                                    lt::resume_data_flags_t flags)
{
    if (identity == nullptr) {
        return std::nullopt;
    }

    std::scoped_lock io_guard(resume_io_lock);
    ResumeSaveState &state = identity->resume_save;
    if (state.async_in_flight) {
        state.save_again_flags = state.save_again
            ? merged_resume_save_flags(state.save_again_flags, flags)
            : flags;
        state.save_again = true;
        return std::nullopt;
    }

    std::uint64_t const generation = allocate_resume_generation_locked(identity);
    state.async_in_flight = generation;
    state.save_again = false;
    state.save_again_flags = kRoutineResumeSaveFlags;
    return generation;
}

void TTorrentClient::cancel_async_resume_save(TorrentIdentity *identity, std::uint64_t generation)
{
    if (identity == nullptr) {
        return;
    }

    std::scoped_lock io_guard(resume_io_lock);
    ResumeSaveState &state = identity->resume_save;
    if (state.async_in_flight == generation) {
        state.async_in_flight.reset();
    }
}

std::optional<std::uint64_t> TTorrentClient::async_resume_generation(TorrentIdentity *identity)
{
    if (identity == nullptr) {
        return std::nullopt;
    }

    std::scoped_lock io_guard(resume_io_lock);
    return identity->resume_save.async_in_flight;
}

std::optional<lt::resume_data_flags_t> TTorrentClient::complete_async_resume_save(TorrentIdentity *identity,
                                                                                  std::uint64_t generation)
{
    if (identity == nullptr) {
        return std::nullopt;
    }

    std::scoped_lock io_guard(resume_io_lock);
    ResumeSaveState &state = identity->resume_save;
    if (state.async_in_flight != generation) {
        return std::nullopt;
    }

    state.async_in_flight.reset();
    if (!state.save_again) {
        return std::nullopt;
    }
    lt::resume_data_flags_t const flags = state.save_again_flags;
    state.save_again = false;
    state.save_again_flags = kRoutineResumeSaveFlags;
    return flags;
}

void TTorrentClient::queue_alert_error_threadsafe(std::string message)
{
    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(lock);
        wake = publish_changes_locked(queue_alert_error(std::move(message)));
    }
    invoke_wake_callback(wake);
}

} // namespace torrent_bridge::internal
