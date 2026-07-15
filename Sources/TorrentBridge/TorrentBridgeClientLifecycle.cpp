#include "TorrentBridgeInternal.hpp"

TTorrentClient::TTorrentClient(std::string_view state_path, bool enable_peer_exchange_plugin)
    : state_directory(std::string(state_path)),
      resume_directory(state_directory / "ResumeData"),
      session(make_session_params(enable_peer_exchange_plugin)),
      peer_exchange_plugin_enabled(enable_peer_exchange_plugin)
{
    session.pause();

    std::error_code create_error;
    fs::create_directories(state_directory, create_error);
    if (create_error) {
        throw std::system_error(create_error, "Could not create state directory");
    }
    UniqueFileDescriptor state_directory_descriptor = open_directory_no_follow(state_directory, "state directory");
    restrict_permissions(state_directory_descriptor.get(), "state directory", FileSystemNodeKind::directory);
    state_lock = acquire_state_directory_lock(state_directory_descriptor.get());

    fs::create_directories(resume_directory, create_error);
    if (create_error) {
        throw std::system_error(create_error, "Could not create resume data directory");
    }
    UniqueFileDescriptor resume_directory_descriptor = open_directory_no_follow(resume_directory, "resume data directory");
    restrict_permissions(resume_directory_descriptor.get(), "resume data directory", FileSystemNodeKind::directory);
    remove_orphan_resume_temp_files();
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
        } catch (std::exception const &) {
            continue;
        } catch (...) {
            continue;
        }
    }
}

[[nodiscard]] bool TTorrentClient::canonical_id_in_collection_locked(
    std::vector<std::unique_ptr<TorrentIdentity>> const &identities,
    std::string_view canonical_id
) const
{
    if (!is_canonical_torrent_id(canonical_id)) {
        return false;
    }

    return std::ranges::any_of(identities, [canonical_id](auto const &identity) {
        return identity != nullptr && identity->canonical_id == canonical_id;
    });
}

[[nodiscard]] bool TTorrentClient::canonical_id_in_use_locked(std::string_view canonical_id) const
{
    return canonical_id_in_collection_locked(torrent_identities, canonical_id)
        || canonical_id_in_collection_locked(retired_torrent_identities, canonical_id);
}

[[nodiscard]] std::string TTorrentClient::make_unique_canonical_torrent_id_locked() const
{
    constexpr int kMaxCanonicalIDGenerationAttempts = 256;
    for (int attempt = 0; attempt < kMaxCanonicalIDGenerationAttempts; ++attempt) {
        std::string canonical_id = make_canonical_torrent_id();
        if (!canonical_id_in_use_locked(canonical_id)) {
            return canonical_id;
        }
    }

    throw std::runtime_error("A unique torrent identifier could not be generated.");
}

TorrentIdentity *TTorrentClient::make_identity(std::string canonical_id)
{
    std::scoped_lock io_guard(resume_io_lock);
    auto identity = std::make_unique<TorrentIdentity>();
    identity->generation = next_identity_generation++;
    identity->canonical_id = canonical_id_in_use_locked(canonical_id)
        ? make_unique_canonical_torrent_id_locked()
        : std::move(canonical_id);
    if (!is_canonical_torrent_id(identity->canonical_id)) {
        identity->canonical_id = make_unique_canonical_torrent_id_locked();
    }
    TorrentIdentity *raw = identity.get();
    torrent_identities.push_back(std::move(identity));
    return raw;
}

TorrentIdentity *TTorrentClient::attach_identity(lt::add_torrent_params &params, std::string canonical_id)
{
    TorrentIdentity *identity = make_identity(std::move(canonical_id));
    std::array<char, sizeof(TTorrentSnapshot::comment)> comment{};
    copy_string(std::span{comment}, params.comment);
    identity->comment = comment.data();
    identity->creation_date = std::max<std::time_t>(params.creation_date, 0);
    params.userdata = identity;
    return identity;
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
