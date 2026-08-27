#include "TorrentBridgeInternal.hpp"

namespace torrent_bridge::internal {

void TTorrentClient::pump_alerts()
{
    // Alert batches carry direct identity pointers beyond the client lock.
    [[maybe_unused]] IdentityReclamationBlock identity_reclamation_block(*this);
    std::vector<PendingResumeHandle> forced_resume_handles;
    std::vector<lt::alert *> alerts;
    bool refresh_statuses = false;
    bool force_resume_save = false;
    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(lock);
        session.pop_alerts(&alerts);
        synchronous_adds_since_alert_drain = 0U;
        DirtyMask changes = 0;

        for (lt::alert const *alert : alerts) {
            try {
                if (lt::alert_cast<lt::alerts_dropped_alert>(alert) != nullptr) {
                    refresh_statuses = true;
                    force_resume_save = true;
                    changes |= invalidate_dht_diagnostics();
                    changes |= mark_trackers_changed();
                    changes |= mark_web_seeds_changed();
                    changes |= mark_files_changed();
                    changes |= mark_piece_map_changed();
                    changes |= queue_alert_error(
                        "Internal libtorrent alerts were dropped. Torrent details may be temporarily stale.");
                    continue;
                }

                if (auto const *removed = lt::alert_cast<lt::torrent_removed_alert>(alert)) {
                    TorrentIdentity *identity = identity_from_client_data(removed->userdata);
                    if (!accepts_removed_alert(removed->info_hashes, identity)) {
                        continue;
                    }

                    finalize_removed(removed->info_hashes, identity);
                    changes |= mark_torrent_removed(removed->info_hashes, "");
                    continue;
                }

                if (auto const *state_update = lt::alert_cast<lt::state_update_alert>(alert)) {
                    changes |= observe_torrent_statuses(state_update->status);
                    continue;
                }

                if (auto const *session_stats = lt::alert_cast<lt::session_stats_alert>(alert)) {
                    changes |= cache_dht_diagnostics(*session_stats);
                    continue;
                }

                if (auto const *trackers = lt::alert_cast<lt::tracker_list_alert>(alert)) {
                    changes |= observe_trackers(trackers->handle);
                    continue;
                }

                if (auto const *file_priority = lt::alert_cast<lt::file_prio_alert>(alert)) {
                    if (file_priority->error) {
                        changes |= queue_alert_error("File priorities could not be changed" +
                                                     torrent_context(*file_priority) + ": " +
                                                     file_priority->error.message() + ".");
                        continue;
                    }

                    changes |= mark_files_changed();
                    request_save_locked(file_priority->handle, kPolicyResumeSaveFlags);
                    continue;
                }

                if (auto const *resume_failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
                    if (resume_failed->error != lt::errors::resume_data_not_modified) {
                        changes |= queue_alert_error("Resume data could not be generated" + torrent_context(*resume_failed) +
                                                     ": " + resume_failed->error.message() + ".");
                    }
                    continue;
                }

                if (auto const *torrent_error = lt::alert_cast<lt::torrent_error_alert>(alert)) {
                    std::string const filename = safe_c_string(torrent_error->filename());
                    changes |= queue_alert_error("Torrent error" + torrent_context(*torrent_error) +
                                                 (filename.empty() ? std::string() : " for " + filename) + ": " +
                                                 torrent_error->error.message() + ".");
                    continue;
                }

                if (auto const *file_error = lt::alert_cast<lt::file_error_alert>(alert)) {
                    std::string const filename = safe_c_string(file_error->filename());
                    changes |= queue_alert_error("File operation failed" + torrent_context(*file_error) +
                                                 (filename.empty() ? std::string() : " for " + filename) + ": " +
                                                 file_error->error.message() + " during " + operation_label(file_error->op) +
                                                 ".");
                    continue;
                }

                if (auto const *fastresume = lt::alert_cast<lt::fastresume_rejected_alert>(alert)) {
                    std::string const path = safe_c_string(fastresume->file_path());
                    changes |= queue_alert_error("Resume data was rejected" + torrent_context(*fastresume) +
                                                 (path.empty() ? std::string() : " for " + path) + ": " +
                                                 fastresume->error.message() + " during " + operation_label(fastresume->op) +
                                                 ".");
                    continue;
                }

                if (auto const *metadata_failed = lt::alert_cast<lt::metadata_failed_alert>(alert)) {
                    changes |= queue_alert_error("Torrent metadata could not be verified" + torrent_context(*metadata_failed) +
                                                 ": " + metadata_failed->error.message() + ".");
                    continue;
                }

                if (auto const *conflict = lt::alert_cast<lt::torrent_conflict_alert>(alert)) {
                    changes |= resolve_torrent_conflict(*conflict, forced_resume_handles);
                    continue;
                }

                if (auto const *listen_failed = lt::alert_cast<lt::listen_failed_alert>(alert)) {
                    changes |= record_listen_failed(*listen_failed);
                    continue;
                }

                if (auto const *listen_succeeded = lt::alert_cast<lt::listen_succeeded_alert>(alert)) {
                    changes |= record_listen_succeeded(*listen_succeeded);
                    continue;
                }

                if (auto const *session_error = lt::alert_cast<lt::session_error_alert>(alert)) {
                    changes |= queue_alert_error("Libtorrent session error: " + session_error->error.message() + ".");
                    continue;
                }

                if (auto const *portmap_error = lt::alert_cast<lt::portmap_error_alert>(alert)) {
                    changes |= queue_alert_error("Port mapping failed on " + address_string(portmap_error->local_address) +
                                                 ": " + portmap_error->error.message() + ".");
                    continue;
                }

                if (auto const *metadata = lt::alert_cast<lt::metadata_received_alert>(alert)) {
                    BridgeResult const valid_metadata = validate_or_remove_loaded_metadata(metadata->handle, changes);
                    if (!valid_metadata) {
                        continue;
                    }
                    request_save_locked(metadata->handle);
                    continue;
                }

                if (auto const *finished = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
                    request_save_locked(finished->handle);
                    continue;
                }

                if (auto const *paused = lt::alert_cast<lt::torrent_paused_alert>(alert)) {
                    request_save_locked(paused->handle);
                    continue;
                }
            } catch (std::exception const &exception) {
                changes |= queue_alert_error("Libtorrent alert could not be processed (" + alert_label(alert) +
                                             "): " + exception.what() + ".");
                continue;
            } catch (...) {
                changes |= queue_alert_error("Libtorrent alert could not be processed (" + alert_label(alert) + ").");
                continue;
            }
        }

        try {
            validate_pending_metadata(changes);
        } catch (std::exception const &exception) {
            changes |= queue_alert_error(
                "Pending torrent metadata could not be validated: " + std::string(exception.what()) + "."
            );
        } catch (...) {
            changes |= queue_alert_error("Pending torrent metadata could not be validated.");
        }

        if (refresh_statuses) {
            changes |= refresh_torrent_statuses();
            request_snapshot_update_locked();
        }

        if (force_resume_save && !persistence_is_faulted()) {
            forced_resume_handles = collect_resume_handles();
        }
        wake = publish_changes_locked(changes);
    }
    invoke_wake_callback(wake);

    for (PendingResumeHandle const &pending : forced_resume_handles) {
        if (pending.cleanups.empty()) {
            request_save(pending.handle, kFullResumeSaveFlags);
            continue;
        }

        std::array<PendingResumeHandle, 1> const handles{pending};
        std::vector<PendingResumeWrite> writes = collect_resume_data(handles, kFullResumeSaveFlags);
        if (writes.size() != 1U || !write_resume_data(writes.front())) {
            // The durable tombstone remains authoritative. Swift owns the
            // subsequent full-save retry and tombstone recovery schedule.
            request_save(pending.handle, kFullResumeSaveFlags);
        }
    }
}

std::optional<lt::torrent_handle> TTorrentClient::find(std::uint64_t const native_token)
{
    if (native_token == 0U) {
        return std::nullopt;
    }
    {
        std::scoped_lock io_guard(resume_io_lock);
        auto const mapped = handle_by_native_token.find(native_token);
        if (mapped != handle_by_native_token.end() && mapped->second.is_valid()) {
            return mapped->second;
        }
    }

    for (auto const &handle : session.get_torrents()) {
        if (!handle.is_valid()) {
            continue;
        }

        TorrentIdentity *identity = identity_from_handle(handle);
        if (identity != nullptr
            && identity->token != nullptr
            && identity->token->value == native_token) {
            mark_active(handle, identity);
            return handle;
        }
    }

    return std::nullopt;
}

ResumeSaveResult TTorrentClient::remove_resume_files_for_ids_checked(std::vector<std::string> const &ids)
{
    if (persistence_is_faulted()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }

    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized) {
        return std::unexpected(normalized.error());
    }
    if (normalized->empty()) {
        return {};
    }

    std::scoped_lock io_guard(resume_io_lock);
    if (persistence_is_faulted_locked()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }
    bool removed = false;
    for (std::string const &id : *normalized) {
        if (id.empty()) {
            continue;
        }

        ResumeRemoveResult removed_files = remove_resume_files_for_id_checked_locked(id);
        if (!removed_files) {
            return std::unexpected(removed_files.error());
        }
        removed = *removed_files || removed;
    }

    if (!removed) {
        return {};
    }
    return sync_directory(resume_directory_descriptor.get());
}

BridgeResult TTorrentClient::persist_removal_tombstones(std::vector<std::string> const &ids)
{
    std::scoped_lock io_guard(resume_io_lock);
    BridgeResult const persistence = ensure_persistence_available_locked(3);
    if (!persistence) {
        return persistence;
    }

    TombstoneCommitResult saved = persist_removal_tombstones_locked(ids);
    if (!saved) {
        return bridge_error(3, saved.error());
    }
    if (!saved->directory_synced) {
        return fault_persistence_and_pause_locked(3, "Removal tombstone commit outcome is uncertain.");
    }
    return {};
}

ResumeIDListResult TTorrentClient::tombstone_ids_overlapping(std::vector<std::string> const &ids)
{
    std::scoped_lock io_guard(resume_io_lock);
    return tombstone_ids_overlapping_locked(ids);
}

ResumeSaveResult TTorrentClient::clear_removal_tombstones(std::vector<std::string> const &ids)
{
    std::scoped_lock io_guard(resume_io_lock);
    if (persistence_is_faulted_locked()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }

    ResumeSaveResult cleared = clear_removal_tombstones_locked(ids);
    return cleared;
}

ResumeSaveResult TTorrentClient::clear_removal_tombstone_file(std::string_view const filename)
{
    if (filename.empty()
        || filename.contains('/')
        || filename.contains('\0')
        || !is_removal_tombstone_path(fs::path(filename))) {
        return std::unexpected("Removal tombstone filename is invalid.");
    }

    std::scoped_lock io_guard(resume_io_lock);
    if (persistence_is_faulted_locked()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }
    ResumeRemoveResult const removed = remove_resume_file_checked_locked(filename);
    if (!removed) {
        return std::unexpected("Removal tombstone could not be cleared: " + removed.error());
    }
    if (*removed) {
        ResumeSaveResult const synced = sync_directory(resume_directory_descriptor.get());
        if (!synced) {
            return std::unexpected("Removal tombstone cleanup could not be synced: " + synced.error());
        }
    }
    return {};
}

} // namespace torrent_bridge::internal
