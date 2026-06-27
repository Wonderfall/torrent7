#include "TorrentBridgeInternal.hpp"

ResumeSaveResult TTorrentClient::remember_resume_write_failure_locked(PendingEncodedResumeWrite write, std::string message)
{
    if (write.identity != nullptr && resume_write_is_installable_locked(write)) {
        ResumeSaveState &state = write.identity->resume_save;
        if (!state.retry || write.generation >= state.retry->generation) {
            state.retry = std::move(write);
        }
    }
    return std::unexpected(std::move(message));
}

void TTorrentClient::mark_resume_write_installed_locked(PendingEncodedResumeWrite const &write)
{
    if (write.identity == nullptr) {
        return;
    }

    ResumeSaveState &state = write.identity->resume_save;
    state.installed_generation = std::max(state.installed_generation, write.generation);
    if (state.retry && state.retry->generation < state.installed_generation) {
        state.retry.reset();
    }
}

void TTorrentClient::mark_resume_write_committed_locked(PendingEncodedResumeWrite const &write)
{
    if (write.identity == nullptr) {
        return;
    }

    ResumeSaveState &state = write.identity->resume_save;
    state.installed_generation = std::max(state.installed_generation, write.generation);
    state.committed_generation = std::max(state.committed_generation, write.generation);
    if (state.retry && state.retry->generation <= state.committed_generation) {
        state.retry.reset();
    }
}

[[nodiscard]] bool TTorrentClient::resume_cleanups_are_eligible_locked(PendingEncodedResumeWrite const &write) const
{
    if (write.cleanups.empty()) {
        return false;
    }
    if (write.identity == nullptr) {
        return true;
    }

    std::uint64_t const committed_generation = write.identity->resume_save.committed_generation;
    return std::ranges::all_of(write.cleanups, [committed_generation](PendingResumeCleanup const &cleanup) {
        return cleanup.after_generation == 0 || cleanup.after_generation <= committed_generation;
    });
}

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
    return sync_directory(resume_directory);
}

ResumeSaveResult TTorrentClient::complete_resume_cleanups_locked(PendingEncodedResumeWrite const &write)
{
    if (persistence_is_faulted_locked()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }
    if (!resume_cleanups_are_eligible_locked(write)) {
        return {};
    }

    ResumeSaveResult cleaned = perform_resume_cleanups_locked(write.cleanups);
    if (!cleaned) {
        remember_resume_cleanup_failure_locked(write.identity, write.cleanups);
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
        remember_pending_tombstone_clear_locked(cleanup_ids);
        remember_resume_cleanup_failure_locked(write.identity, write.cleanups);
        return std::unexpected("Removal tombstone could not be cleared: " + cleared_tombstones.error());
    }
    forget_pending_tombstone_clear_locked(cleanup_ids);

    mark_resume_cleanups_completed_locked(write.identity, write.cleanups);
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
    if (write.identity != nullptr && !resume_write_is_installable_locked(write)) {
        ResumeSaveResult cleaned = complete_resume_cleanups_locked(write);
        if (!cleaned) {
            return cleaned;
        }
        return {};
    }

    fs::path const final_path = resume_directory / (id + std::string(kResumeExtension));
    ResumeTempFileResult opened_temp_file = open_resume_temp_file(final_path);
    if (!opened_temp_file) {
        return remember_resume_write_failure_locked(std::move(write), opened_temp_file.error());
    }

    ResumeTempFile temp_file = std::move(*opened_temp_file);
    fs::path const &temp_path = temp_file.path;

    ResumeSaveResult written = write_all(temp_file.descriptor.get(), std::span<char const>{write.encoded});
    if (!written) {
        std::error_code const close_error = temp_file.descriptor.close();
        if (close_error) {
            ignore_shutdown_failure();
        }
        remove_file_quietly(temp_path);
        return remember_resume_write_failure_locked(std::move(write), written.error());
    }

    ResumeSaveResult synced = sync_file(temp_file.descriptor.get());
    if (!synced) {
        std::error_code const close_error = temp_file.descriptor.close();
        if (close_error) {
            ignore_shutdown_failure();
        }
        remove_file_quietly(temp_path);
        return remember_resume_write_failure_locked(std::move(write), synced.error());
    }

    ResumeSaveResult closed = close_resume_temp_file(temp_file.descriptor);
    if (!closed) {
        remove_file_quietly(temp_path);
        return remember_resume_write_failure_locked(std::move(write), closed.error());
    }

    if (::rename(temp_path.c_str(), final_path.c_str()) != 0) {
        int const error_number = errno;
        remove_file_quietly(temp_path);
        return remember_resume_write_failure_locked(
            std::move(write), system_error_message("Resume data could not be committed", error_number));
    }
    mark_resume_write_installed_locked(write);

    PendingResumeCleanup alias_cleanup{.after_generation = write.generation, .resume_ids = {}};
    for (std::string const &alias : hash_keys(write.hashes)) {
        if (alias != id) {
            append_unique(alias_cleanup.resume_ids, alias);
        }
    }
    if (!alias_cleanup.resume_ids.empty()) {
        append_cleanup_ids_locked(write.cleanups, std::move(alias_cleanup));
    }

    ResumeSaveResult directory_synced = sync_directory(resume_directory);
    if (!directory_synced) {
        return remember_resume_write_failure_locked(std::move(write), directory_synced.error());
    }

    mark_resume_write_committed_locked(write);
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
    std::uint64_t generation,
    std::vector<PendingResumeCleanup> cleanups
)
{
    if (persistence_is_faulted()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }

    if (params.ti) {
        BridgeResult const valid_info = validate_torrent_info(*params.ti);
        if (!valid_info) {
            return std::unexpected(valid_info.error().message);
        }
    }
    BridgeResult const valid_sources = validate_torrent_sources(params);
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

    lt::add_torrent_params persisted_params = params;
    bool const strip_peer_cache =
        should_strip_resume_peer_cache(persisted_params, policy);
    restore_source_policy_sources(persisted_params, policy);
    BridgeResult const valid_persisted_sources = validate_torrent_sources(persisted_params);
    if (!valid_persisted_sources) {
        return std::unexpected(valid_persisted_sources.error().message);
    }
    if (strip_peer_cache) {
        strip_resume_peer_cache(persisted_params);
    }
    if (policy.app_disabled_dht) {
        persisted_params.flags &= ~lt::torrent_flags::disable_dht;
    }
    if (policy.app_disabled_lsd) {
        persisted_params.flags &= ~lt::torrent_flags::disable_lsd;
    }
    if (policy.has_identity
        && policy.app_disabled_peer_exchange
        && !policy.peer_exchange_pending_metadata) {
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
                                                                        .generation = generation,
                                                                        .encoded = std::move(encoded),
                                                                        .cleanups = std::move(cleanups)});
}

ResumeSaveResult TTorrentClient::write_resume_data(PendingResumeWrite const &write)
{
    ResumeSaveResult result =
        write_resume_data_checked(write.params, write.identity, write.policy, write.generation, write.cleanups);
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

    std::uint64_t const generation = allocate_resume_generation(identity);
    return write_resume_data_checked(params, identity, resume_policy_snapshot_locked(identity), generation, {});
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

std::vector<std::string> TTorrentClient::retry_terminal_cleanups(bool reports_errors)
{
    std::vector<std::string> errors;
    std::vector<std::string> cleanup_errors = retry_resume_cleanups(reports_errors);
    errors.insert(
        errors.end(),
        std::make_move_iterator(cleanup_errors.begin()),
        std::make_move_iterator(cleanup_errors.end())
    );
    std::vector<std::string> resume_cleanup_errors = retry_pending_resume_cleanups(reports_errors);
    errors.insert(
        errors.end(),
        std::make_move_iterator(resume_cleanup_errors.begin()),
        std::make_move_iterator(resume_cleanup_errors.end())
    );
    std::vector<std::string> delete_cleanup_errors = retry_pending_delete_cleanups(reports_errors);
    errors.insert(
        errors.end(),
        std::make_move_iterator(delete_cleanup_errors.begin()),
        std::make_move_iterator(delete_cleanup_errors.end())
    );
    std::vector<std::string> tombstone_clear_errors = retry_pending_tombstone_clears(reports_errors);
    errors.insert(
        errors.end(),
        std::make_move_iterator(tombstone_clear_errors.begin()),
        std::make_move_iterator(tombstone_clear_errors.end())
    );
    return errors;
}

std::vector<std::string> TTorrentClient::retry_resume_writes(bool reports_errors)
{
    std::vector<std::string> errors;
    if (persistence_is_faulted()) {
        return errors;
    }

    std::vector<PendingEncodedResumeWrite> retries = claim_resume_retries();
    for (PendingEncodedResumeWrite &retry : retries) {
        ResumeSaveResult result = commit_encoded_resume_data_checked(std::move(retry));
        if (!result) {
            errors.push_back(result.error());
            if (reports_errors) {
                queue_alert_error_threadsafe("Resume data retry failed: " + result.error() + ".");
            }
        }
    }
    std::vector<std::string> cleanup_errors = retry_terminal_cleanups(reports_errors);
    errors.insert(
        errors.end(),
        std::make_move_iterator(cleanup_errors.begin()),
        std::make_move_iterator(cleanup_errors.end())
    );
    return errors;
}

void TTorrentClient::request_save(lt::torrent_handle const &handle, lt::resume_data_flags_t flags)
{
    if (persistence_is_faulted()) {
        return;
    }
    if (!handle.is_valid()) {
        return;
    }

    TorrentIdentity *identity = identity_from_handle(handle);
    std::scoped_lock capture_guard(resume_capture_lock);
    std::optional<std::uint64_t> const generation = begin_async_resume_save(identity, flags);
    if (!generation) {
        return;
    }
    try {
        handle.save_resume_data(flags);
    } catch (...) {
        cancel_async_resume_save(identity, *generation);
        return;
    }
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

    retry_resume_writes(false);
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

ResumeHandleResult TTorrentClient::collect_resume_handles_checked()
{
    std::vector<PendingResumeHandle> handles;
    for (auto const &handle : session.get_torrents()) {
        if (!handle.is_valid()) {
            return std::unexpected("A torrent handle became invalid while saving resume data.");
        }

        TorrentIdentity *identity = identity_from_handle(handle);
        if (identity == nullptr) {
            return std::unexpected("Resume data is missing torrent identity.");
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

ResumeHandleReport TTorrentClient::collect_resume_handles_report()
{
    ResumeHandleReport report;
    for (auto const &handle : session.get_torrents()) {
        if (!handle.is_valid()) {
            report.errors.emplace_back("A torrent handle became invalid while saving resume data.");
            continue;
        }

        TorrentIdentity *identity = identity_from_handle(handle);
        if (identity == nullptr) {
            report.errors.emplace_back("Resume data is missing torrent identity.");
            continue;
        }

        report.handles.push_back(PendingResumeHandle{
            .handle = handle,
            .identity = identity,
            .policy = resume_policy_snapshot_locked(identity),
            .cleanups = {}
        });
    }
    return report;
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

        std::uint64_t const generation = allocate_resume_generation(pending.identity);
        try {
            lt::add_torrent_params params = pending.handle.get_resume_data(flags);
            resume_data.push_back(PendingResumeWrite{
                .params = std::move(params),
                .handle = pending.handle,
                .identity = pending.identity,
                .policy = pending.policy,
                .generation = generation,
                .async = false,
                .cleanups = cleanups_for_write(pending.identity, generation, pending.cleanups)
            });
        } catch (...) {
            continue;
        }
    }
    return resume_data;
}

ResumeDataReport TTorrentClient::collect_resume_data_report(
    std::span<PendingResumeHandle const> handles,
    lt::resume_data_flags_t flags
)
{
    ResumeDataReport report;
    std::scoped_lock capture_guard(resume_capture_lock);
    for (PendingResumeHandle const &pending : handles) {
        if (!pending.handle.is_valid()) {
            report.errors.emplace_back("A torrent handle became invalid while saving resume data.");
            continue;
        }

        if (pending.identity == nullptr) {
            report.errors.emplace_back("Resume data is missing torrent identity.");
            continue;
        }

        std::uint64_t const generation = allocate_resume_generation(pending.identity);
        try {
            lt::add_torrent_params params = pending.handle.get_resume_data(flags);
            report.writes.push_back(PendingResumeWrite{
                .params = std::move(params),
                .handle = pending.handle,
                .identity = pending.identity,
                .policy = pending.policy,
                .generation = generation,
                .async = false,
                .cleanups = cleanups_for_write(pending.identity, generation, pending.cleanups)
            });
        } catch (std::exception const &exception) {
            report.errors.emplace_back(std::string("Resume data could not be collected: ") + exception.what());
        } catch (...) {
            report.errors.emplace_back("Resume data could not be collected.");
        }
    }
    return report;
}

ResumeDataResult TTorrentClient::collect_resume_data_checked(std::span<PendingResumeHandle const> handles,
                                             lt::resume_data_flags_t flags)
{
    std::vector<PendingResumeWrite> resume_data;
    std::scoped_lock capture_guard(resume_capture_lock);
    for (PendingResumeHandle const &pending : handles) {
        if (!pending.handle.is_valid()) {
            return std::unexpected("A torrent handle became invalid while saving resume data.");
        }

        if (pending.identity == nullptr) {
            return std::unexpected("Resume data is missing torrent identity.");
        }

        std::uint64_t const generation = allocate_resume_generation(pending.identity);
        try {
            lt::add_torrent_params params = pending.handle.get_resume_data(flags);
            resume_data.push_back(
                PendingResumeWrite{.params = std::move(params),
                                   .handle = pending.handle,
                                   .identity = pending.identity,
                                   .policy = pending.policy,
                                   .generation = generation,
                                   .async = false,
                                   .cleanups = cleanups_for_write(pending.identity, generation, pending.cleanups)});
        } catch (std::exception const &exception) {
            return std::unexpected(std::string("Resume data could not be collected: ") + exception.what());
        } catch (...) {
            return std::unexpected("Resume data could not be collected.");
        }
    }
    return resume_data;
}

void TTorrentClient::save_all()
{
    if (persistence_is_faulted()) {
        return;
    }

    retry_resume_writes(false);
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

BridgeResult TTorrentClient::save_all_checked()
{
    {
        std::scoped_lock guard(lock);
        BridgeResult const persistence = ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
    }
    static_cast<void>(retry_resume_writes(false));
    std::vector<std::string> errors;
    ResumeHandleReport handle_report;
    {
        std::scoped_lock guard(lock);
        handle_report = collect_resume_handles_report();
    }
    errors.insert(
        errors.end(),
        std::make_move_iterator(handle_report.errors.begin()),
        std::make_move_iterator(handle_report.errors.end())
    );

    ResumeDataReport collected = collect_resume_data_report(handle_report.handles, kFullResumeSaveFlags);
    errors.insert(
        errors.end(),
        std::make_move_iterator(collected.errors.begin()),
        std::make_move_iterator(collected.errors.end())
    );

    for (PendingResumeWrite const &write : collected.writes) {
        ResumeSaveResult saved = write_resume_data_checked(
            write.params,
            write.identity,
            write.policy,
            write.generation,
            write.cleanups
        );
        if (!saved) {
            errors.push_back(saved.error());
        }
    }
    std::vector<std::string> cleanup_errors = retry_terminal_cleanups(false);
    errors.insert(
        errors.end(),
        std::make_move_iterator(cleanup_errors.begin()),
        std::make_move_iterator(cleanup_errors.end())
    );
    if (!errors.empty()) {
        return bridge_error(3, joined_error_messages(errors));
    }
    return {};
}
