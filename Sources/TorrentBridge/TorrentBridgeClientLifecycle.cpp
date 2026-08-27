#include "TorrentBridgeInternal.hpp"

namespace torrent_bridge::internal {

namespace {

[[nodiscard]] std::uint64_t saturating_increment(std::uint64_t const value) noexcept
{
    return value == std::numeric_limits<std::uint64_t>::max() ? value : value + 1U;
}

struct ChangeEventMapping {
    DirtyMask change;
    std::uint8_t event_kind;
};

constexpr std::array kChangeEventMappings{
    ChangeEventMapping{.change = kChangeTorrents, .event_kind = TTORRENT_EVENT_TORRENTS_CHANGED},
    ChangeEventMapping{.change = kChangeTrackers, .event_kind = TTORRENT_EVENT_TRACKERS_CHANGED},
    ChangeEventMapping{.change = kChangeWebSeeds, .event_kind = TTORRENT_EVENT_WEB_SEEDS_CHANGED},
    ChangeEventMapping{.change = kChangeFiles, .event_kind = TTORRENT_EVENT_FILES_CHANGED},
    ChangeEventMapping{.change = kChangeNetwork, .event_kind = TTORRENT_EVENT_NETWORK_CHANGED},
    ChangeEventMapping{.change = kChangeErrors, .event_kind = TTORRENT_EVENT_ERRORS_AVAILABLE},
    ChangeEventMapping{.change = kChangePieces, .event_kind = TTORRENT_EVENT_PIECES_CHANGED},
    ChangeEventMapping{.change = kChangeTrackerHosts, .event_kind = TTORRENT_EVENT_TRACKER_HOSTS_CHANGED},
    ChangeEventMapping{.change = kChangeHealth, .event_kind = TTORRENT_EVENT_HEALTH_CHANGED},
};

constexpr DirtyMask kKnownChanges = kChangeTorrents
    | kChangeTrackers
    | kChangeWebSeeds
    | kChangeFiles
    | kChangeNetwork
    | kChangeErrors
    | kChangePieces
    | kChangeTrackerHosts
    | kChangeHealth;

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
    : TTorrentClient(state_path, enable_peer_exchange_plugin, nullptr)
{
}

TTorrentClient::TTorrentClient(
    std::string_view state_path,
    bool enable_peer_exchange_plugin,
    std::shared_ptr<PayloadBrokerContext> broker
)
    : part_files_directory(fs::path{std::string(state_path)} / "PartFiles"),
      staging_directory(fs::path{std::string(state_path)} / "Staging"),
      payload_broker(std::move(broker)),
      session(make_session_params(enable_peer_exchange_plugin)),
      peer_exchange_plugin_enabled(enable_peer_exchange_plugin)
{
    fs::path const state_directory{std::string(state_path)};
    session.pause();
    pending_events.reserve(static_cast<std::size_t>(TTORRENT_MAX_EVENT_COUNT));

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
    auto create_private_directory = [&](char const *name, std::string_view label) {
        if (::mkdirat(state_directory_descriptor.get(), name, kOwnerDirectoryPermissions) != 0
            && errno != EEXIST) {
            throw std::system_error(
                std::error_code(errno, std::generic_category()),
                "Could not create " + std::string(label)
            );
        }
        UniqueFileDescriptor descriptor = open_directory_at_no_follow(
            state_directory_descriptor.get(),
            name,
            label
        );
        restrict_permissions(descriptor.get(), label, FileSystemNodeKind::directory);
        return descriptor;
    };
    part_files_directory_descriptor = create_private_directory("PartFiles", "part files directory");
    staging_directory_descriptor = create_private_directory("Staging", "magnet staging directory");
    remove_orphan_resume_temp_files();
    ResumeSaveResult completed_removals = complete_pending_removals();
    if (!completed_removals) {
        throw std::runtime_error(completed_removals.error());
    }
    load_resume_data();
    {
        std::scoped_lock guard(lock);
        std::scoped_lock io_guard(resume_io_lock);
        source_policy_reconciled = handle_by_native_token.empty();
    }
    static_cast<void>(refresh_torrent_statuses());
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

std::shared_ptr<lt::aux::payload_file_provider> TTorrentClient::make_payload_provider(
    TTorrentStorageActivation const &activation
) const
{
    if (!payload_broker) {
        throw std::logic_error("The payload broker is unavailable.");
    }
    return std::make_shared<BridgePayloadFileProvider>(payload_broker, activation);
}

std::string TTorrentClient::part_file_path(TTorrentStorageActivation const &activation) const
{
    return (part_files_directory / storage_claim_key(activation)).native();
}

std::string TTorrentClient::staging_path(lt::info_hash_t const &hashes) const
{
    std::string key = primary_hash_key(hashes);
    std::ranges::replace(key, ':', '_');
    if (key.empty()) {
        throw std::invalid_argument("The magnet has no usable info hash.");
    }
    return (staging_directory / key).native();
}

void TTorrentClient::set_wake_callback(TTorrentWakeCallback callback, void *context)
{
    if (callback == nullptr || context == nullptr) {
        throw std::invalid_argument("Wake callback and context are required.");
    }

    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(lock);
        if (wake_callback != nullptr) {
            throw std::logic_error("Wake callback is already installed.");
        }
        wake_callback = callback;
        wake_callback_context = context;
        if ((!pending_events.empty() || pending_critical_faults != 0U) && !wake_pending) {
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
        AnalyzedUniqueLock guard(lock);
        wake_callback = nullptr;
        wake_callback_context = nullptr;
        wake_pending = false;
        wake_callback_quiesced.wait(guard.native(), [this]() TORRENT_BRIDGE_REQUIRES(lock) {
            return wake_callbacks_in_flight == 0;
        });
    } catch (...) {
        ignore_shutdown_failure();
    }
}

int32_t TTorrentClient::drain_events(
    std::span<TTorrentEvent> output,
    int32_t *required_count_out,
    std::uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    try {
        std::scoped_lock guard(lock);
        std::size_t const critical_event_count = pending_critical_faults == 0U ? 0U : 1U;
        std::size_t const event_count = pending_events.size() + critical_event_count;
        if (required_count_out != nullptr) {
            *required_count_out = static_cast<int32_t>(event_count);
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(true);
        }
        if (output.size() < event_count) {
            return 0;
        }

        auto destination = output.begin();
        if (pending_critical_faults != 0U) {
            *destination = TTorrentEvent{
                .native_token = 0U,
                .kind = TTORRENT_EVENT_CRITICAL_FAULT,
                .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                .critical_faults = pending_critical_faults,
            };
            ++destination;
        }
        if (!pending_events.empty()) {
            std::ranges::copy(pending_events, destination);
        }
        pending_critical_faults = 0U;
        pending_events.clear();
        wake_pending = false;
        return static_cast<int32_t>(event_count);
    } catch (...) {
        return 0;
    }
}

int32_t TTorrentClient::drain_presentation_metadata(
    std::span<TTorrentPresentationMetadata> output,
    int32_t *required_count_out,
    std::uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    try {
        std::scoped_lock guard(lock);
        std::scoped_lock io_guard(resume_io_lock);
        std::size_t pending_count = 0;
        for (std::unique_ptr<TorrentIdentity> const &owned : torrent_identities) {
            TorrentIdentity *const identity = owned.get();
            if (identity == nullptr || !identity->pending_presentation_metadata) {
                continue;
            }
            if (identity->token == nullptr
                || identity->token->active_identity.load(std::memory_order_acquire) != identity
                || !handle_by_native_token.contains(identity->token->value)) {
                identity->pending_presentation_metadata.reset();
                continue;
            }
            ++pending_count;
        }

        if (required_count_out != nullptr) {
            *required_count_out = static_cast<int32_t>(pending_count);
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(true);
        }
        if (output.size() < pending_count) {
            return 0;
        }

        auto destination = output.begin();
        for (std::unique_ptr<TorrentIdentity> const &owned : torrent_identities) {
            TorrentIdentity *const identity = owned.get();
            if (identity == nullptr || !identity->pending_presentation_metadata) {
                continue;
            }
            *destination = *identity->pending_presentation_metadata;
            identity->pending_presentation_metadata.reset();
            ++destination;
        }
        return static_cast<int32_t>(pending_count);
    } catch (...) {
        return 0;
    }
}

DirtyMask TTorrentClient::record_critical_fault_locked(std::uint32_t faults) noexcept
{
    constexpr std::uint32_t kKnownCriticalFaults =
        TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY
        | TTORRENT_CRITICAL_FAULT_NETWORK_CONTAINMENT_UNCONFIRMED;
    faults &= kKnownCriticalFaults;
    if (faults == 0U) {
        return 0U;
    }

    DirtyMask changes = 0U;
    try {
        BridgeResult const contained = contain_network_for_critical_fault_locked(changes);
        if (!contained) {
            faults |= TTORRENT_CRITICAL_FAULT_NETWORK_CONTAINMENT_UNCONFIRMED;
        }
    } catch (...) {
        faults |= TTORRENT_CRITICAL_FAULT_NETWORK_CONTAINMENT_UNCONFIRMED;
    }

    pending_critical_faults |= faults;
    try {
        if (pending_events.size() >= static_cast<std::size_t>(TTORRENT_MAX_EVENT_COUNT)) {
            pending_events.clear();
            pending_events.push_back(TTorrentEvent{
                .native_token = 0U,
                .kind = TTORRENT_EVENT_RESYNC_REQUIRED,
                .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                .critical_faults = 0U,
            });
        }
    } catch (...) {
        pending_events.clear();
    }
    return changes;
}

WakeCallbackInvocation TTorrentClient::publish_changes_locked(DirtyMask changes) noexcept
{
    if (!has_dirty_changes(changes)
        && pending_events.empty()
        && pending_critical_faults == 0U) {
        return {};
    }

    try {
        std::size_t const event_capacity = static_cast<std::size_t>(TTORRENT_MAX_EVENT_COUNT)
            - (pending_critical_faults == 0U ? 0U : 1U);
        if (pending_events.size() >= event_capacity) {
            pending_events.clear();
            pending_events.push_back(TTorrentEvent{
                .native_token = 0U,
                .kind = TTORRENT_EVENT_RESYNC_REQUIRED,
                .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                .critical_faults = 0U,
            });
        }
        bool const resync_already_pending = std::ranges::any_of(
            pending_events,
            [](TTorrentEvent const &event) {
                return event.kind == TTORRENT_EVENT_RESYNC_REQUIRED;
            }
        );
        if (!resync_already_pending) {
            if ((changes & ~kKnownChanges) != 0U) {
                pending_events.clear();
                pending_events.push_back(TTorrentEvent{
                    .native_token = 0U,
                    .kind = TTORRENT_EVENT_RESYNC_REQUIRED,
                    .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                    .critical_faults = 0U,
                });
            } else {
                for (ChangeEventMapping const &mapping : kChangeEventMappings) {
                    if ((changes & mapping.change) == 0U) {
                        continue;
                    }
                    if (pending_events.size() >= event_capacity) {
                        pending_events.clear();
                        pending_events.push_back(
                            TTorrentEvent{
                                .native_token = 0U,
                                .kind = TTORRENT_EVENT_RESYNC_REQUIRED,
                                .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                                .critical_faults = 0U,
                            }
                        );
                        break;
                    }
                    pending_events.push_back(TTorrentEvent{
                        .native_token = 0U,
                        .kind = mapping.event_kind,
                        .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                        .critical_faults = 0U,
                    });
                }
            }
        }
    } catch (...) {
        pending_events.clear();
        try {
            pending_events.push_back(TTorrentEvent{
                .native_token = 0U,
                .kind = TTORRENT_EVENT_RESYNC_REQUIRED,
                .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                .critical_faults = 0U,
            });
        } catch (...) {
            return {};
        }
    }

    if ((pending_events.empty() && pending_critical_faults == 0U)
        || wake_callback == nullptr
        || wake_pending) {
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

void TTorrentClient::invoke_wake_callback(WakeCallbackInvocation const &wake) noexcept
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
                request_resume_retry();
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

        DirtyMask changes = kChangeHealth;
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
        wake = publish_changes_locked(kChangeHealth);
    } catch (...) {
        return;
    }
    invoke_wake_callback(wake);
}

[[nodiscard]] std::string TTorrentClient::reserve_canonical_torrent_id_locked(
    std::string canonical_id,
    bool const allow_reuse_from_removing,
    int32_t *const preserved_queue_rank_out
)
{
    if (preserved_queue_rank_out != nullptr) {
        *preserved_queue_rank_out = kUnsetQueueRank;
    }
    if (!is_canonical_torrent_id(canonical_id)) {
        throw std::invalid_argument("The requested torrent identifier is invalid.");
    }
    if (canonical_ids_in_use.insert(canonical_id).second) {
        return canonical_id;
    }

    if (allow_reuse_from_removing) {
        auto const previous = std::ranges::find_if(
            torrent_identities,
            [&canonical_id](auto const &owned) {
                return owned != nullptr && owned->canonical_id == canonical_id;
            }
        );
        if (previous != torrent_identities.end()) {
            TorrentIdentity *const identity = previous->get();
            auto const references_identity = [identity](auto const &entry) {
                return entry.second == identity;
            };
            bool const is_active = std::ranges::any_of(
                active_identity_by_id,
                references_identity
            );
            bool const is_removing = unidentified_removing_identities.contains(identity)
                || std::ranges::any_of(removing_identity_by_id, references_identity);
            if (!is_active && is_removing) {
                if (preserved_queue_rank_out != nullptr) {
                    *preserved_queue_rank_out = identity->queue_rank;
                }
                identity->canonical_id.clear();
                return canonical_id;
            }
        }
    }

    throw std::runtime_error("The requested torrent identifier is already in use.");
}

TorrentIdentity *TTorrentClient::make_identity(
    std::string canonical_id,
    bool const allow_reuse_from_removing
)
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
    int32_t preserved_queue_rank = kUnsetQueueRank;
    if (next_native_token == 0U) {
        throw std::length_error("The native torrent token space has been exhausted.");
    }
    token->value = next_native_token++;
    identity->canonical_id = reserve_canonical_torrent_id_locked(
        std::move(canonical_id),
        allow_reuse_from_removing,
        &preserved_queue_rank
    );
    identity->queue_rank = preserved_queue_rank;
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

TorrentIdentity *TTorrentClient::attach_identity(
    lt::add_torrent_params &params,
    std::string canonical_id,
    bool const allow_reuse_from_removing
)
{
    TorrentIdentity *identity = make_identity(
        std::move(canonical_id),
        allow_reuse_from_removing
    );
    stage_presentation_metadata(*identity, params);
    params.userdata = identity->token;
    return identity;
}

BridgeResult TTorrentClient::ensure_torrent_admission_available(int32_t code) const
{
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
