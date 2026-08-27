#include "TorrentBridgeInternal.hpp"

namespace torrent_bridge::internal {

namespace {

[[nodiscard]] std::uint8_t resume_save_mode(lt::resume_data_flags_t const flags) noexcept
{
    if (static_cast<bool>(flags & lt::torrent_handle::flush_disk_cache)) {
        return TTORRENT_RESUME_SAVE_FULL;
    }
    if (static_cast<bool>(flags & lt::torrent_handle::only_if_modified)) {
        return TTORRENT_RESUME_SAVE_ROUTINE;
    }
    return TTORRENT_RESUME_SAVE_POLICY;
}

[[nodiscard]] std::optional<lt::resume_data_flags_t> resume_save_flags(ResumeSaveMode const mode) noexcept
{
    switch (mode) {
    case ResumeSaveMode::routine:
        return kRoutineResumeSaveFlags;
    case ResumeSaveMode::policy:
        return kPolicyResumeSaveFlags;
    case ResumeSaveMode::full:
        return kFullResumeSaveFlags;
    default:
        return std::nullopt;
    }
}

void append_resume_cleanup(
    std::vector<PendingResumeCleanup> &destination,
    PendingResumeCleanup cleanup
)
{
    if (cleanup.resume_ids.empty()) {
        return;
    }
    if (destination.empty()) {
        destination.push_back(std::move(cleanup));
        return;
    }
    for (std::string const &id : cleanup.resume_ids) {
        append_unique(destination.front().resume_ids, id);
    }
}

} // namespace

ResumeSaveResult TTorrentClient::perform_resume_cleanups_locked(std::vector<PendingResumeCleanup> const &cleanups)
{
    bool removed = false;
    for (PendingResumeCleanup const &cleanup : cleanups) {
        for (std::string const &id : cleanup.resume_ids) {
            if (id.empty()) {
                continue;
            }

            ResumeRemoveResult removed_files = remove_resume_files_for_id_checked_locked(id);
            if (!removed_files) {
                return std::unexpected(removed_files.error());
            }
            removed = *removed_files || removed;
        }
    }

    if (!removed) {
        return {};
    }
    return sync_directory(resume_directory_descriptor.get());
}

ResumeSaveResult TTorrentClient::complete_resume_cleanups_locked(PendingEncodedResumeWrite const &write)
{
    if (persistence_is_faulted_locked()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }
    if (write.cleanups.empty()) {
        return {};
    }

    ResumeSaveResult cleaned = perform_resume_cleanups_locked(write.cleanups);
    if (!cleaned) {
        return std::unexpected("Obsolete resume data could not be removed: " + cleaned.error());
    }

    std::vector<std::string> cleanup_ids;
    for (PendingResumeCleanup const &cleanup : write.cleanups) {
        for (std::string const &id : cleanup.resume_ids) {
            append_unique(cleanup_ids, id);
        }
    }
    ResumeSaveResult cleared_tombstones = clear_removal_tombstones_locked(cleanup_ids);
    if (!cleared_tombstones) {
        return std::unexpected("Removal tombstone could not be cleared: " + cleared_tombstones.error());
    }
    return {};
}

ResumeSaveResult TTorrentClient::commit_encoded_resume_data_checked(PendingEncodedResumeWrite write)
{
    if (persistence_is_faulted()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }

    std::string const id = primary_hash_key(write.hashes);
    if (id.empty()) {
        return std::unexpected("Resume data is missing a torrent identifier.");
    }
    if (write.encoded.empty()) {
        return std::unexpected("Resume data could not be encoded.");
    }
    if (static_cast<std::uintmax_t>(write.encoded.size()) > kMaxResumeFileBytes) {
        return std::unexpected("Resume data is too large.");
    }

    std::scoped_lock io_guard(resume_io_lock);
    if (persistence_is_faulted_locked()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }
    if (!reconcile_current_for_write_locked(write.hashes, write.identity)) {
        return {};
    }
    std::string const final_filename = id + std::string(kResumeExtension);
    ResumeTempFileResult opened_temp_file = open_resume_temp_file_at(
        resume_directory_descriptor.get(),
        final_filename
    );
    if (!opened_temp_file) {
        return std::unexpected(opened_temp_file.error());
    }

    ResumeTempFile temp_file = std::move(*opened_temp_file);
    std::string const temp_filename = temp_file.path.string();

    ResumeSaveResult written = write_all(temp_file.descriptor.get(), std::span<char const>{write.encoded});
    if (!written) {
        std::error_code const close_error = temp_file.descriptor.close();
        if (close_error) {
            ignore_shutdown_failure();
        }
        remove_file_at_quietly(resume_directory_descriptor.get(), temp_filename);
        return std::unexpected(written.error());
    }

    ResumeSaveResult synced = sync_file(temp_file.descriptor.get());
    if (!synced) {
        std::error_code const close_error = temp_file.descriptor.close();
        if (close_error) {
            ignore_shutdown_failure();
        }
        remove_file_at_quietly(resume_directory_descriptor.get(), temp_filename);
        return std::unexpected(synced.error());
    }

    ResumeSaveResult closed = close_resume_temp_file(temp_file.descriptor);
    if (!closed) {
        remove_file_at_quietly(resume_directory_descriptor.get(), temp_filename);
        return std::unexpected(closed.error());
    }

    if (::renameat(
            resume_directory_descriptor.get(),
            temp_filename.c_str(),
            resume_directory_descriptor.get(),
            final_filename.c_str()
        ) != 0) {
        int const error_number = errno;
        remove_file_at_quietly(resume_directory_descriptor.get(), temp_filename);
        return std::unexpected(system_error_message(
            "Resume data could not be committed",
            error_number
        ));
    }
    PendingResumeCleanup alias_cleanup{.resume_ids = {}};
    for (std::string const &alias : hash_keys(write.hashes)) {
        if (alias != id) {
            append_unique(alias_cleanup.resume_ids, alias);
        }
    }
    if (!alias_cleanup.resume_ids.empty()) {
        append_resume_cleanup(write.cleanups, std::move(alias_cleanup));
    }

    ResumeSaveResult directory_synced = sync_directory(resume_directory_descriptor.get());
    if (!directory_synced) {
        return std::unexpected(directory_synced.error());
    }

    ResumeSaveResult cleaned = complete_resume_cleanups_locked(write);
    if (!cleaned) {
        return cleaned;
    }
    return {};
}

ResumeSaveResult TTorrentClient::write_resume_data_checked(
    lt::add_torrent_params const &params,
    TorrentIdentity *identity,
    ResumePolicySnapshot const &policy,
    std::vector<PendingResumeCleanup> cleanups
)
{
    if (persistence_is_faulted()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }

    lt::add_torrent_params persisted_params = params;
    if (policy.metadata_validation_pending) {
        persisted_params.ti.reset();
        persisted_params.file_priorities = policy.intended_file_priorities;
        if (policy.intended_default_dont_download) {
            persisted_params.flags |= lt::torrent_flags::default_dont_download;
        } else {
            persisted_params.flags &= ~lt::torrent_flags::default_dont_download;
        }
        if (policy.dht_locked_by_source) {
            persisted_params.flags |= lt::torrent_flags::disable_dht;
        } else {
            persisted_params.flags &= ~lt::torrent_flags::disable_dht;
        }
        if (policy.peer_exchange_locked_by_source) {
            persisted_params.flags |= lt::torrent_flags::disable_pex;
        } else {
            persisted_params.flags &= ~lt::torrent_flags::disable_pex;
        }
        if (policy.lsd_locked_by_source) {
            persisted_params.flags |= lt::torrent_flags::disable_lsd;
        } else {
            persisted_params.flags &= ~lt::torrent_flags::disable_lsd;
        }
        sanitize_magnet_endpoint_hints(persisted_params);
    } else {
        sanitize_resume_endpoint_hints(persisted_params);
    }

    if (persisted_params.ti) {
        BridgeResult const valid_info = validate_torrent_info(persisted_params);
        if (!valid_info) {
            return std::unexpected(valid_info.error().message);
        }
    }
    BridgeResult const valid_sources = validate_torrent_sources(persisted_params);
    if (!valid_sources) {
        return std::unexpected(valid_sources.error().message);
    }

    std::string const id = primary_hash_key(params.info_hashes);
    if (id.empty()) {
        return std::unexpected("Resume data is missing a torrent identifier.");
    }

    if (!resume_write_is_current(params.info_hashes, identity)) {
        return {};
    }

    bool const strip_peer_cache = !policy.metadata_validation_pending
        && should_strip_resume_peer_cache(persisted_params, policy);
    restore_source_policy_sources(persisted_params, policy);
    BridgeResult const valid_persisted_sources = validate_torrent_sources(persisted_params);
    if (!valid_persisted_sources) {
        return std::unexpected(valid_persisted_sources.error().message);
    }
    if (strip_peer_cache) {
        strip_resume_peer_cache(persisted_params);
    }
    if (policy.app_disabled_dht && !policy.dht_locked_by_source) {
        persisted_params.flags &= ~lt::torrent_flags::disable_dht;
    }
    if (policy.app_disabled_lsd && !policy.lsd_locked_by_source) {
        persisted_params.flags &= ~lt::torrent_flags::disable_lsd;
    }
    if (policy.has_identity
        && policy.app_disabled_peer_exchange
        && !policy.peer_exchange_locked_by_source) {
        persisted_params.flags &= ~lt::torrent_flags::disable_pex;
    }

    std::vector<char> encoded = encoded_resume_data(
        persisted_params,
        policy
    );
    if (encoded.empty()) {
        return std::unexpected("Resume data could not be encoded.");
    }
    if (static_cast<std::uintmax_t>(encoded.size()) > kMaxResumeFileBytes) {
        return std::unexpected("Resume data is too large.");
    }

    return commit_encoded_resume_data_checked(PendingEncodedResumeWrite{.hashes = params.info_hashes,
                                                                        .identity = identity,
                                                                        .encoded = std::move(encoded),
                                                                        .cleanups = std::move(cleanups)});
}

ResumeSaveResult TTorrentClient::write_resume_data(PendingResumeWrite const &write)
{
    ResumeSaveResult result =
        write_resume_data_checked(write.params, write.identity, write.policy, write.cleanups);
    if (!result) {
        queue_alert_error_threadsafe("Resume data could not be saved: " + result.error() + ".");
        return result;
    }
    return {};
}

ResumeSaveResult TTorrentClient::save_added_torrent_resume_data(lt::add_torrent_params params, lt::info_hash_t const &hashes,
                                                TorrentIdentity *identity)
{
    params.info_hashes = hashes;

    return write_resume_data_checked(params, identity, resume_policy_snapshot_locked(identity), {});
}

ResumeSaveResult TTorrentClient::remove_obsolete_tombstoned_resume_data_for_readd(std::vector<std::string> const &resume_ids)
{
    ResumeIDListResult matched_ids = tombstone_ids_overlapping(resume_ids);
    if (!matched_ids) {
        return std::unexpected(matched_ids.error());
    }
    if (matched_ids->empty()) {
        return {};
    }

    std::string primary_id;
    for (std::string const &id : resume_ids) {
        if (id.starts_with("v1:") || id.starts_with("v2:")) {
            primary_id = id;
            break;
        }
    }
    if (!primary_id.empty()) {
        std::erase(*matched_ids, primary_id);
    }
    return remove_resume_files_for_ids_checked(*matched_ids);
}

void TTorrentClient::request_save_locked(lt::torrent_handle const &handle, lt::resume_data_flags_t const flags)
{
    if (!handle.is_valid()) {
        return;
    }

    TorrentIdentity *identity = identity_from_handle(handle);
    if (identity == nullptr || identity->token == nullptr || identity->token->value == 0U) {
        return;
    }

    try {
        bool const resync_already_pending = std::ranges::any_of(
            pending_events,
            [](TTorrentEvent const &event) {
                return event.kind == TTORRENT_EVENT_RESYNC_REQUIRED;
            }
        );
        if (resync_already_pending) {
            return;
        }

        std::uint8_t const requested_mode = resume_save_mode(flags);
        auto const existing = std::ranges::find_if(
            pending_events,
            [native_token = identity->token->value](TTorrentEvent const &event) {
                return event.kind == TTORRENT_EVENT_RESUME_SAVE_REQUESTED
                    && event.native_token == native_token;
            }
        );
        if (existing != pending_events.end()) {
            existing->resume_save_mode = std::max(existing->resume_save_mode, requested_mode);
            return;
        }

        if (pending_events.size() >= static_cast<std::size_t>(TTORRENT_MAX_EVENT_COUNT)) {
            pending_events.clear();
            pending_events.push_back(TTorrentEvent{
                .native_token = 0U,
                .kind = TTORRENT_EVENT_RESYNC_REQUIRED,
                .resume_save_mode = TTORRENT_RESUME_SAVE_FULL,
                .critical_faults = 0U,
            });
            return;
        }
        pending_events.push_back(TTorrentEvent{
            .native_token = identity->token->value,
            .kind = TTORRENT_EVENT_RESUME_SAVE_REQUESTED,
            .resume_save_mode = requested_mode,
            .critical_faults = 0U,
        });
    } catch (...) {
        pending_events.clear();
        try {
            pending_events.push_back(TTorrentEvent{
                .native_token = 0U,
                .kind = TTORRENT_EVENT_RESYNC_REQUIRED,
                .resume_save_mode = TTORRENT_RESUME_SAVE_FULL,
                .critical_faults = 0U,
            });
        } catch (...) {
            ignore_shutdown_failure();
        }
    }
}

void TTorrentClient::request_save(lt::torrent_handle const &handle, lt::resume_data_flags_t const flags)
{
    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(lock);
        request_save_locked(handle, flags);
        wake = publish_changes_locked(0U);
    }
    invoke_wake_callback(wake);
}

void TTorrentClient::request_resume_retry()
{
    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(lock);
        bool const retry_already_pending = std::ranges::any_of(
            pending_events,
            [](TTorrentEvent const &event) {
                return event.kind == TTORRENT_EVENT_RESUME_RETRY_REQUESTED
                    || event.kind == TTORRENT_EVENT_RESYNC_REQUIRED;
            }
        );
        if (!retry_already_pending) {
            if (pending_events.size() >= static_cast<std::size_t>(TTORRENT_MAX_EVENT_COUNT)) {
                pending_events.clear();
                pending_events.push_back(TTorrentEvent{
                    .native_token = 0U,
                    .kind = TTORRENT_EVENT_RESYNC_REQUIRED,
                    .resume_save_mode = TTORRENT_RESUME_SAVE_FULL,
                    .critical_faults = 0U,
                });
            } else {
                pending_events.push_back(TTorrentEvent{
                    .native_token = 0U,
                    .kind = TTORRENT_EVENT_RESUME_RETRY_REQUESTED,
                    .resume_save_mode = TTORRENT_RESUME_SAVE_ROUTINE,
                    .critical_faults = 0U,
                });
            }
        }
        wake = publish_changes_locked(0U);
    }
    invoke_wake_callback(wake);
}

BridgeResult TTorrentClient::save_resume_data_checked(
    std::uint64_t const native_token,
    ResumeSaveMode const save_mode
)
{
    std::optional<lt::resume_data_flags_t> const flags = resume_save_flags(save_mode);
    if (native_token == 0U || !flags) {
        return bridge_error(1, "Invalid Swift resume-save request.");
    }

    [[maybe_unused]] IdentityReclamationBlock identity_reclamation_block(*this);
    PendingResumeHandle pending;
    {
        std::scoped_lock guard(lock);
        BridgeResult const persistence = ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
        std::optional<lt::torrent_handle> const handle = find(native_token);
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }
        TorrentIdentity *identity = identity_from_handle(*handle);
        if (identity == nullptr) {
            return bridge_error(2, "Resume data is missing torrent identity.");
        }
        pending = PendingResumeHandle{
            .handle = *handle,
            .identity = identity,
            .policy = resume_policy_snapshot_locked(identity),
            .cleanups = {},
        };
    }

    lt::add_torrent_params params;
    try {
        std::scoped_lock capture_guard(resume_capture_lock);
        if (!pending.handle.is_valid()) {
            return bridge_error(2, "Torrent handle became invalid while saving resume data.");
        }
        params = pending.handle.get_resume_data(*flags);
    } catch (std::exception const &exception) {
        return bridge_error(3, std::string("Resume data could not be collected: ") + exception.what());
    } catch (...) {
        return bridge_error(3, "Resume data could not be collected.");
    }

    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(lock);
        DirtyMask const changes = capture_requested_presentation_metadata(pending.identity, params);
        if (has_dirty_changes(changes)) {
            request_snapshot_update_locked();
        }
        wake = publish_changes_locked(changes);
    }
    invoke_wake_callback(wake);

    ResumeSaveResult const saved = write_resume_data_checked(
        params,
        pending.identity,
        pending.policy,
        pending.cleanups
    );
    if (!saved) {
        return bridge_error(3, saved.error());
    }
    return {};
}

std::vector<lt::torrent_handle> TTorrentClient::collect_torrent_handles()
{
    std::vector<lt::torrent_handle> handles;
    for (auto const &handle : session.get_torrents()) {
        if (handle.is_valid()) {
            handles.push_back(handle);
        }
    }
    return handles;
}

void TTorrentClient::request_periodic_resume_saves()
{
    if (persistence_is_faulted()) {
        return;
    }

    std::vector<lt::torrent_handle> handles;
    {
        std::scoped_lock guard(lock);
        handles = collect_torrent_handles();
    }

    for (lt::torrent_handle const &handle : handles) {
        request_save(handle);
    }
}

std::vector<PendingResumeHandle> TTorrentClient::collect_resume_handles()
{
    std::vector<PendingResumeHandle> handles;
    for (auto const &handle : session.get_torrents()) {
        if (!handle.is_valid()) {
            continue;
        }

        TorrentIdentity *identity = identity_from_handle(handle);
        if (identity == nullptr) {
            continue;
        }

        handles.push_back(PendingResumeHandle{
            .handle = handle,
            .identity = identity,
            .policy = resume_policy_snapshot_locked(identity),
            .cleanups = {}
        });
    }
    return handles;
}

std::vector<PendingResumeWrite> TTorrentClient::collect_resume_data(
    std::span<PendingResumeHandle const> handles,
    lt::resume_data_flags_t flags
)
{
    std::vector<PendingResumeWrite> resume_data;
    std::scoped_lock capture_guard(resume_capture_lock);
    for (PendingResumeHandle const &pending : handles) {
        if (!pending.handle.is_valid()) {
            continue;
        }

        if (pending.identity == nullptr) {
            continue;
        }

        try {
            lt::add_torrent_params params = pending.handle.get_resume_data(flags);
            resume_data.push_back(PendingResumeWrite{
                .params = std::move(params),
                .identity = pending.identity,
                .policy = pending.policy,
                .cleanups = pending.cleanups
            });
        } catch (...) {
            continue;
        }
    }
    return resume_data;
}

void TTorrentClient::save_all()
{
    [[maybe_unused]] IdentityReclamationBlock identity_reclamation_block(*this);
    if (persistence_is_faulted()) {
        return;
    }

    std::vector<PendingResumeHandle> handles;
    {
        std::scoped_lock guard(lock);
        handles = collect_resume_handles();
    }

    std::vector<PendingResumeWrite> resume_data = collect_resume_data(handles, kFullResumeSaveFlags);
    for (PendingResumeWrite const &write : resume_data) {
        ResumeSaveResult saved = write_resume_data(write);
        if (!saved) {
            ignore_shutdown_failure();
        }
    }
}

} // namespace torrent_bridge::internal
