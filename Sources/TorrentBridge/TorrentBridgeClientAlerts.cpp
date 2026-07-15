#include "TorrentBridgeInternal.hpp"

std::optional<PendingResumeRequest> TTorrentClient::release_async_resume_state_for_alert(lt::alert const *alert)
{
    if (auto const *resume = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
        TorrentIdentity *identity = identity_from_resume_alert(*resume);
        std::optional<std::uint64_t> const generation = async_resume_generation(identity);
        if (generation) {
            if (std::optional<lt::resume_data_flags_t> flags = complete_async_resume_save(identity, *generation)) {
                return PendingResumeRequest{.handle = resume->handle, .flags = *flags};
            }
        }
        return std::nullopt;
    }

    if (auto const *resume_failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
        TorrentIdentity *identity = identity_from_handle(resume_failed->handle);
        std::optional<std::uint64_t> const generation = async_resume_generation(identity);
        if (generation) {
            if (std::optional<lt::resume_data_flags_t> flags = complete_async_resume_save(identity, *generation)) {
                return PendingResumeRequest{.handle = resume_failed->handle, .flags = *flags};
            }
        }
    }
    return std::nullopt;
}

void TTorrentClient::enqueue_repeat_resume_save(
    std::vector<PendingResumeRequest> &repeat_resume_requests,
    PendingResumeRequest const &request
)
{
    try {
        repeat_resume_requests.push_back(request);
    } catch (...) {
        request_save(request.handle, request.flags);
        ignore_shutdown_failure();
    }
}

void TTorrentClient::complete_async_resume_write(
    PendingResumeWrite const &write,
    std::vector<PendingResumeRequest> &repeat_resume_requests
)
{
    if (!write.async) {
        return;
    }

    try {
        if (std::optional<lt::resume_data_flags_t> flags = complete_async_resume_save(write.identity, write.generation)) {
            enqueue_repeat_resume_save(
                repeat_resume_requests,
                PendingResumeRequest{.handle = write.handle, .flags = *flags}
            );
        }
    } catch (...) {
        ignore_shutdown_failure();
    }
}

void TTorrentClient::pump_alerts()
{
    std::vector<PendingResumeWrite> resume_data;
    std::vector<PendingResumeHandle> forced_resume_handles;
    std::vector<PendingResumeRequest> repeat_resume_requests;
    std::vector<lt::alert *> alerts;
    bool rebuild_cache = false;
    bool force_resume_save = false;
    WakeCallbackInvocation wake;
    {
        std::scoped_lock guard(lock);
        session.pop_alerts(&alerts);
        DirtyMask changes = 0;

        for (lt::alert const *alert : alerts) {
            try {
                if (auto const *dropped = lt::alert_cast<lt::alerts_dropped_alert>(alert)) {
                    rebuild_cache = true;
                    force_resume_save = true;
                    changes |= fail_dropped_delete_request(*dropped);
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
                    changes |= remove_snapshot(removed->info_hashes, "");
                    continue;
                }

                if (auto const *state_update = lt::alert_cast<lt::state_update_alert>(alert)) {
                    changes |= update_snapshot_cache(state_update->status);
                    continue;
                }

                if (auto const *trackers = lt::alert_cast<lt::tracker_list_alert>(alert)) {
                    changes |= cache_trackers(trackers->handle, trackers->trackers);
                    continue;
                }

                if (auto const *peers = lt::alert_cast<lt::peer_info_alert>(alert)) {
                    cache_peer_sources(peers->handle, peers->peer_info);
                    changes |= cache_web_seed_activity(peers->handle, peers->peer_info);
                    continue;
                }

                if (auto const *file_progress = lt::alert_cast<lt::file_progress_alert>(alert)) {
                    changes |= cache_file_progress(file_progress->handle, file_progress->files);
                    continue;
                }

                if (auto const *file_priority = lt::alert_cast<lt::file_prio_alert>(alert)) {
                    if (file_priority->error) {
                        changes |= queue_alert_error("File priorities could not be changed" +
                                                     torrent_context(*file_priority) + ": " +
                                                     file_priority->error.message() + ".");
                        continue;
                    }

                    BridgeResult const cached_files = cache_file_metadata(file_priority->handle, changes);
                    if (!cached_files) {
                        changes |= queue_alert_error("File priorities could not be refreshed" +
                                                     torrent_context(*file_priority) + ": " +
                                                     cached_files.error().message + ".");
                        continue;
                    }

                    request_save(file_priority->handle, kPolicyResumeSaveFlags);
                    file_priority->handle.post_file_progress(lt::torrent_handle::piece_granularity);
                    continue;
                }

                if (auto const *resume = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
                    TorrentIdentity *identity = identity_from_resume_alert(*resume);
                    std::optional<std::uint64_t> const generation = async_resume_generation(identity);
                    if (!generation) {
                        continue;
                    }

                    changes |= cache_resume_metadata(identity, resume->params);
                    resume_data.push_back(
                        PendingResumeWrite{.params = resume->params,
                                           .handle = resume->handle,
                                           .identity = identity,
                                           .policy = resume_policy_snapshot_locked(identity),
                                           .generation = *generation,
                                           .async = true,
                                           .cleanups = cleanups_for_write(identity, *generation)});
                    continue;
                }

                if (auto const *deleted = lt::alert_cast<lt::torrent_deleted_alert>(alert)) {
                    complete_delete_request(deleted->info_hashes, TTORRENT_REMOVAL_SUCCEEDED);
                    changes |= complete_pending_delete(deleted->info_hashes, "");
                    continue;
                }

                if (auto const *delete_failed = lt::alert_cast<lt::torrent_delete_failed_alert>(alert)) {
                    constexpr std::string_view generic_failure =
                        "Downloaded data could not be deleted. Some files may remain on disk.";
                    complete_delete_request(
                        delete_failed->info_hashes,
                        TTORRENT_REMOVAL_FAILED,
                        generic_failure
                    );

                    std::string failure_message(generic_failure);
                    if (delete_failed->error) {
                        failure_message = "Downloaded data could not be deleted. Some files may remain on disk: " +
                            delete_failed->error.message() + ".";
                    }
                    changes |= complete_pending_delete(
                        delete_failed->info_hashes,
                        failure_message);
                    continue;
                }

                if (auto const *resume_failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
                    TorrentIdentity *identity = identity_from_handle(resume_failed->handle);
                    std::optional<std::uint64_t> const generation = async_resume_generation(identity);
                    if (generation) {
                        if (std::optional<lt::resume_data_flags_t> flags = complete_async_resume_save(identity, *generation)) {
                            enqueue_repeat_resume_save(
                                repeat_resume_requests,
                                PendingResumeRequest{.handle = resume_failed->handle, .flags = *flags}
                            );
                        }
                    }
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
                    request_save(metadata->handle);
                    continue;
                }

                if (auto const *finished = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
                    request_save(finished->handle);
                    continue;
                }

                if (auto const *paused = lt::alert_cast<lt::torrent_paused_alert>(alert)) {
                    request_save(paused->handle);
                    continue;
                }
            } catch (std::exception const &exception) {
                if (std::optional<PendingResumeRequest> repeat = release_async_resume_state_for_alert(alert)) {
                    enqueue_repeat_resume_save(repeat_resume_requests, *repeat);
                }
                changes |= queue_alert_error("Libtorrent alert could not be processed (" + alert_label(alert) +
                                             "): " + exception.what() + ".");
                continue;
            } catch (...) {
                if (std::optional<PendingResumeRequest> repeat = release_async_resume_state_for_alert(alert)) {
                    enqueue_repeat_resume_save(repeat_resume_requests, *repeat);
                }
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

        if (rebuild_cache) {
            changes |= invalidate_detail_caches_locked();
            changes |= rebuild_snapshot_cache();
            request_snapshot_update_locked();
        }

        if (force_resume_save && !persistence_is_faulted()) {
            forced_resume_handles = collect_resume_handles();
        }
        wake = publish_changes_locked(changes);
    }
    invoke_wake_callback(wake);

    if (!persistence_is_faulted() && !forced_resume_handles.empty()) {
        try {
            std::vector<PendingResumeWrite> forced_resume_data =
                collect_resume_data(forced_resume_handles, kFullResumeSaveFlags);
            resume_data.insert(resume_data.end(), std::make_move_iterator(forced_resume_data.begin()),
                               std::make_move_iterator(forced_resume_data.end()));
        } catch (std::exception const &exception) {
            queue_alert_error_threadsafe(std::string("Forced resume data could not be collected: ") +
                                         exception.what() + ".");
        } catch (...) {
            queue_alert_error_threadsafe("Forced resume data could not be collected.");
        }
    }

    for (PendingResumeWrite const &write : resume_data) {
        try {
            if (persistence_is_faulted()) {
                complete_async_resume_write(write, repeat_resume_requests);
                continue;
            }
            ResumeSaveResult saved = write_resume_data(write);
            if (!saved) {
                ignore_shutdown_failure();
            }
            complete_async_resume_write(write, repeat_resume_requests);
        } catch (std::exception const &exception) {
            complete_async_resume_write(write, repeat_resume_requests);
            queue_alert_error_threadsafe(
                std::string("Resume data could not be saved: ")
                + exception.what()
                + "."
            );
        } catch (...) {
            complete_async_resume_write(write, repeat_resume_requests);
            queue_alert_error_threadsafe("Resume data could not be saved.");
        }
    }

    for (PendingResumeRequest const &request : repeat_resume_requests) {
        request_save(request.handle, request.flags);
    }
}

std::optional<lt::torrent_handle> TTorrentClient::find(std::string const &id)
{
    {
        std::scoped_lock io_guard(resume_io_lock);
        auto const mapped = handle_by_id.find(id);
        if (mapped != handle_by_id.end() && mapped->second.is_valid()) {
            return mapped->second;
        }
    }

    for (auto const &handle : session.get_torrents()) {
        if (!handle.is_valid()) {
            continue;
        }

        if (TorrentIdentity *identity = identity_from_handle(handle)) {
            if (identity->canonical_id == id) {
                mark_active(handle, identity);
                return handle;
            }
        }

        if (hash_matches(handle.info_hashes(), id)) {
            mark_active(handle, identity_from_handle(handle));
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
    return sync_directory(resume_directory);
}

BridgeResult TTorrentClient::persist_removal_tombstones(std::vector<std::string> const &ids,
                                        RemovalTombstoneState state,
                                        bool delete_files, bool delete_partfile)
{
    std::scoped_lock io_guard(resume_io_lock);
    BridgeResult const persistence = ensure_persistence_available_locked(3);
    if (!persistence) {
        return persistence;
    }

    TombstoneCommitResult saved = persist_removal_tombstones_locked(ids, state, delete_files, delete_partfile);
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
    if (!cleared) {
        remember_pending_tombstone_clear_locked(ids);
        return cleared;
    }
    forget_pending_resume_cleanup_locked(ids);
    forget_pending_tombstone_clear_locked(ids);
    return {};
}
