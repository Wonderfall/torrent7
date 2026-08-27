#include "TorrentBridgeInternal.hpp"

namespace torrent_bridge::internal {

namespace {

[[nodiscard]] std::vector<std::string> normalized_tracker_hosts(
    std::vector<libtorrent::announce_entry> const &trackers
)
{
    std::set<std::string> unique_hosts;
    for (libtorrent::announce_entry const &tracker : trackers) {
        if (std::optional<std::string> host = normalized_tracker_host(tracker.url)) {
            unique_hosts.insert(std::move(*host));
        }
    }
    return {unique_hosts.begin(), unique_hosts.end()};
}

struct TrackerHostRowValue {
    std::uint64_t native_token;
    std::string_view host;
};

void append_tracker_host_row(
    std::vector<TTorrentTrackerHostSnapshot> &rows,
    TrackerHostRowValue value
)
{
    constexpr auto maximum_row_count = static_cast<std::size_t>(
        TTORRENT_MAX_TRACKER_HOST_ROW_COUNT
    );
    if (rows.size() >= maximum_row_count) {
        return;
    }
    if (rows.size() == rows.capacity()) {
        constexpr std::size_t initial_capacity = 16U;
        std::size_t const next_capacity = std::min(
            maximum_row_count,
            rows.capacity() == 0U ? initial_capacity : rows.capacity() * 2U
        );
        rows.reserve(next_capacity);
        if (rows.capacity() > maximum_row_count) {
            throw std::length_error("Torrent tracker-host extraction exceeded its capacity bound.");
        }
    }

    TTorrentTrackerHostSnapshot row{};
    row.native_token = value.native_token;
    copy_string(std::span{row.host}, value.host);
    rows.push_back(row);
}

[[nodiscard]] std::vector<TTorrentSnapshot> materialized_snapshots(TTorrentClient &client)
    TORRENT_BRIDGE_REQUIRES(client.lock) TORRENT_BRIDGE_REQUIRES_NOT(client.resume_io_lock)
{
    constexpr auto maximum_snapshot_count = static_cast<std::size_t>(
        TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT
    );
    std::vector<lt::torrent_status> const statuses = client.session.get_torrent_status(
        [](lt::torrent_status const &) {
            return true;
        },
        kSnapshotStatusFlags
    );

    std::vector<TTorrentSnapshot> snapshots;
    snapshots.reserve(std::min(statuses.size(), maximum_snapshot_count));
    std::set<std::string> seen_ids;
    for (lt::torrent_status const &status : statuses) {
        if (snapshots.size() >= maximum_snapshot_count) {
            break;
        }
        if (!status.handle.is_valid()) {
            continue;
        }
        std::vector<std::string> const ids = hash_keys(status.info_hashes);
        if (ids.empty()) {
            continue;
        }

        TorrentIdentity *identity = identity_from_handle(status.handle);
        if (client.identity_state_for_status(ids, identity) != TorrentIdentityState::current) {
            continue;
        }
        client.mark_active(status.handle, identity);

        std::string const id = identity_snapshot_id(identity);
        if (id.empty() || !seen_ids.insert(id).second) {
            continue;
        }
        TTorrentSnapshot snapshot = snapshot_from_status(status, identity);
        copy_string(std::span{snapshot.id}, id);
        snapshot.queue_priority = identity == nullptr
            ? TTORRENT_QUEUE_PRIORITY_NORMAL
            : identity->queue_priority;
        snapshots.push_back(snapshot);
    }
    return snapshots;
}

} // namespace

DirtyMask TTorrentClient::refresh_torrent_statuses()
{
    std::vector<lt::torrent_status> const statuses = session.get_torrent_status(
        [](lt::torrent_status const &) {
            return true;
        },
        kSnapshotStatusFlags
    );
    return observe_torrent_statuses(statuses)
        | mark_torrents_changed()
        | mark_tracker_hosts_changed();
}

DirtyMask TTorrentClient::mark_torrents_changed() noexcept
{
    return kChangeTorrents;
}

void TTorrentClient::request_snapshot_update()
{
    std::scoped_lock guard(lock);
    request_snapshot_update_locked();
}

void TTorrentClient::request_snapshot_update_locked()
{
    try {
        session.post_torrent_updates(kSnapshotStatusFlags);
    } catch (...) {
        return;
    }
}

DirtyMask TTorrentClient::observe_torrent_status(lt::torrent_status const &status)
{
    std::vector<std::string> const ids = hash_keys(status.info_hashes);
    if (ids.empty()) {
        return 0;
    }
    if (!status.handle.is_valid()) {
        return 0;
    }

    TorrentIdentity *identity = identity_from_handle(status.handle);
    switch (identity_state_for_status(ids, identity)) {
    case TorrentIdentityState::current:
        break;
    case TorrentIdentityState::stale:
        return 0;
    case TorrentIdentityState::absent:
        return mark_torrents_changed() | mark_tracker_hosts_changed();
    }
    mark_active(status.handle, identity);
    return mark_torrents_changed();
}

DirtyMask TTorrentClient::observe_torrent_handle(lt::torrent_handle const &handle)
{
    if (!handle.is_valid()) {
        return 0;
    }

    try {
        return observe_torrent_status(handle.status(kSnapshotStatusFlags));
    } catch (...) {
        return 0;
    }
}

DirtyMask TTorrentClient::capture_requested_presentation_metadata(
    TorrentIdentity *identity,
    lt::add_torrent_params const &params
)
{
    if (identity == nullptr || !identity->presentation_metadata_refresh_requested) {
        return 0;
    }
    stage_presentation_metadata(*identity, params);
    identity->presentation_metadata_refresh_requested = false;
    return mark_torrents_changed();
}

DirtyMask TTorrentClient::observe_torrent_statuses(std::vector<lt::torrent_status> const &statuses)
{
    DirtyMask changes = 0;
    for (lt::torrent_status const &status : statuses) {
        changes |= observe_torrent_status(status);
    }
    return changes;
}

DirtyMask TTorrentClient::mark_tracker_hosts_changed() noexcept
{
    return kChangeTrackerHosts;
}

DirtyMask TTorrentClient::mark_trackers_changed() noexcept
{
    return kChangeTrackers;
}

DirtyMask TTorrentClient::mark_web_seeds_changed() noexcept
{
    return kChangeWebSeeds;
}

DirtyMask TTorrentClient::mark_files_changed() noexcept
{
    return kChangeFiles;
}

DirtyMask TTorrentClient::mark_piece_map_changed() noexcept
{
    return kChangePieces;
}

DirtyMask TTorrentClient::observe_trackers(lt::torrent_handle const &handle)
{
    if (!handle.is_valid()) {
        return 0;
    }

    lt::info_hash_t const hashes = handle.info_hashes();
    std::vector<std::string> const ids = hash_keys(hashes);
    if (ids.empty()) {
        return 0;
    }

    TorrentIdentity *identity = identity_from_handle(handle);
    switch (identity_state_for_status(ids, identity)) {
    case TorrentIdentityState::current:
        break;
    case TorrentIdentityState::stale:
    case TorrentIdentityState::absent:
        return 0;
    }

    return mark_trackers_changed() | mark_tracker_hosts_changed();
}

DirtyMask TTorrentClient::remove_torrent_with_invalid_metadata(lt::torrent_handle const &handle, std::string const &reason)
{
    if (!handle.is_valid()) {
        return 0;
    }

    DirtyMask changes = 0;
    lt::info_hash_t const hashes = handle.info_hashes();
    TorrentIdentity *identity = identity_from_handle(handle);
    std::vector<std::string> const removal_ids = removal_ids_for_identity(hashes, "", identity);
    BridgeResult tombstoned = persist_removal_tombstones(removal_ids);
    if (!tombstoned) {
        if (identity != nullptr) {
            identity->metadata_validation_retry_after =
                std::chrono::steady_clock::now() + kResumeRetryInterval;
        }
        try {
            handle.pause();
            handle.set_flags(lt::torrent_flags::disable_dht);
            handle.set_flags(lt::torrent_flags::disable_pex);
            handle.set_flags(lt::torrent_flags::disable_lsd);
        } catch (...) {
            ignore_shutdown_failure();
        }
        return queue_alert_error("Invalid torrent metadata could not be removed durably: " + tombstoned.error().message + ".");
    }
    try {
        session.remove_torrent(handle);
    } catch (...) {
        BridgeResult cancelled = cancel_tombstoned_operation_or_fault(
            removal_ids,
            3,
            "Invalid torrent metadata could not be removed automatically."
        );
        if (!cancelled) {
            changes |= queue_alert_error(cancelled.error().message);
        }
        return changes;
    }

    mark_remove_requested(hashes, identity);
    ResumeSaveResult removed_resume = remove_resume_files_for_ids_checked(removal_ids);
    if (!removed_resume) {
        changes |= queue_alert_error("Invalid torrent metadata was removed, but resume cleanup is pending: " + removed_resume.error() + ".");
    } else {
        ResumeSaveResult cleared = clear_removal_tombstones(removal_ids);
        if (!cleared) {
            changes |= queue_alert_error("Invalid torrent metadata was removed, but removal marker cleanup is pending: " + cleared.error() + ".");
        }
    }
    changes |= mark_torrent_removed(hashes, "");
    request_snapshot_update_locked();
    changes |= queue_alert_error("Torrent was removed: " + reason);
    return changes;
}

bool TTorrentClient::conflict_participant_is_preferred(TorrentIdentity const *candidate, TorrentIdentity const *other) noexcept
{
    if (candidate == other) {
        return true;
    }
    if (candidate == nullptr) {
        return other == nullptr;
    }
    if (other == nullptr) {
        return true;
    }

    if (candidate->token == nullptr) {
        return other->token == nullptr;
    }
    if (other->token == nullptr) {
        return true;
    }
    return candidate->token->value <= other->token->value;
}

DirtyMask TTorrentClient::resolve_torrent_conflict(
    lt::torrent_conflict_alert const &conflict,
    std::vector<PendingResumeHandle> &forced_resume_handles
)
{
    DirtyMask changes = 0;
    lt::torrent_handle const metadata_handle = conflict.handle;
    lt::torrent_handle const conflicting_handle = conflict.conflicting_torrent;
    if (!metadata_handle.is_valid() || !conflicting_handle.is_valid()) {
        return queue_alert_error("A hybrid torrent conflict was detected, but one of the torrent handles was no longer valid.");
    }

    TorrentIdentity *metadata_identity = identity_from_handle(metadata_handle);
    TorrentIdentity *conflicting_identity = identity_from_handle(conflicting_handle);
    if (metadata_identity == nullptr || conflicting_identity == nullptr) {
        return record_critical_fault_locked(
            TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY
        );
    }
    bool const preserve_metadata_handle = conflict_participant_is_preferred(
        metadata_identity,
        conflicting_identity
    );
    lt::torrent_handle const survivor = preserve_metadata_handle ? metadata_handle : conflicting_handle;
    lt::torrent_handle const duplicate = preserve_metadata_handle ? conflicting_handle : metadata_handle;
    TorrentIdentity *survivor_identity = preserve_metadata_handle ? metadata_identity : conflicting_identity;
    TorrentIdentity *duplicate_identity = preserve_metadata_handle ? conflicting_identity : metadata_identity;

    lt::info_hash_t survivor_hashes;
    lt::info_hash_t duplicate_hashes;
    try {
        survivor_hashes = survivor.info_hashes();
        duplicate_hashes = duplicate.info_hashes();
    } catch (...) {
        return queue_alert_error("A duplicate hybrid torrent could not be inspected automatically.");
    }

    std::vector<std::string> cleanup_ids = hash_keys(duplicate_hashes);
    std::vector<std::string> const survivor_ids = hash_keys(survivor_hashes);
    std::erase_if(cleanup_ids, [&survivor_ids](std::string const &id) {
        return std::ranges::find(survivor_ids, id) != survivor_ids.end();
    });
    if (
        duplicate_identity != nullptr
        && duplicate_identity != survivor_identity
        && (
            survivor_identity == nullptr
            || duplicate_identity->canonical_id != survivor_identity->canonical_id
        )
    ) {
        append_unique(cleanup_ids, duplicate_identity->canonical_id);
    }

    BridgeResult tombstoned = persist_removal_tombstones(cleanup_ids);
    if (!tombstoned) {
        return queue_alert_error("A duplicate hybrid torrent could not be removed durably: " + tombstoned.error().message + ".");
    }

    try {
        session.remove_torrent(duplicate);
    } catch (...) {
        BridgeResult cancelled = cancel_tombstoned_operation_or_fault(
            cleanup_ids,
            3,
            "A duplicate hybrid torrent could not be removed automatically."
        );
        if (!cancelled) {
            changes |= queue_alert_error(cancelled.error().message);
        }
        return changes;
    }

    try {
        survivor.clear_error();
    } catch (...) {
        ignore_shutdown_failure();
    }

    if (survivor_identity != nullptr) {
        mark_active(survivor, survivor_identity);
        std::vector<PendingResumeCleanup> pending_cleanups;
        if (!cleanup_ids.empty()) {
            pending_cleanups.push_back(PendingResumeCleanup{
                .resume_ids = cleanup_ids
            });
        }
        PendingResumeHandle forced_save{
            .handle = survivor,
            .identity = survivor_identity,
            .policy = resume_policy_snapshot_locked(survivor_identity),
            .cleanups = std::move(pending_cleanups)
        };
        forced_resume_handles.push_back(std::move(forced_save));
    } else {
        changes |= queue_alert_error("Hybrid torrent conflict resume data could not be saved because the preserved entry identity was missing.");
        ResumeSaveResult removed_resume = remove_resume_files_for_ids_checked(cleanup_ids);
        if (!removed_resume) {
            changes |= queue_alert_error("Duplicate hybrid torrent resume cleanup is pending: " + removed_resume.error() + ".");
        } else {
            ResumeSaveResult cleared = clear_removal_tombstones(cleanup_ids);
            if (!cleared) {
                changes |= queue_alert_error("Duplicate hybrid torrent removal marker cleanup is pending: " + cleared.error() + ".");
            }
        }
    }
    if (duplicate_identity != survivor_identity) {
        std::string_view const duplicate_canonical_id = duplicate_identity == nullptr
            ? std::string_view()
            : std::string_view(duplicate_identity->canonical_id);
        mark_conflict_remove_requested(duplicate_hashes, duplicate_identity);
        changes |= mark_torrent_removed(duplicate_hashes, duplicate_canonical_id);
    }
    changes |= observe_torrent_handle(survivor);
    request_snapshot_update_locked();
    changes |= queue_alert_error("Duplicate hybrid torrent entry was removed while preserving the older app entry.");
    return changes;
}

BridgeResult TTorrentClient::validate_or_remove_loaded_metadata(lt::torrent_handle const &handle, DirtyMask &changes)
{
    if (!handle.is_valid()) {
        return {};
    }

    TorrentIdentity *identity = identity_from_handle(handle);
    if (identity != nullptr
        && metadata_validation_pending.contains(identity)
        && identity->metadata_validation_retry_after > std::chrono::steady_clock::now()) {
        return bridge_error(3, "Invalid torrent metadata removal is waiting to retry.");
    }

    std::shared_ptr<lt::torrent_info const> const torrent_file = handle.torrent_file();
    if (!torrent_file || !torrent_file->is_valid()) {
        return {};
    }

    lt::file_storage const &layout = torrent_file->layout();
    lt::renamed_files const renamed_files = handle.get_renamed_files();
    BridgeResult const valid_info = validate_torrent_info(
        *torrent_file,
        renamed_files.export_filenames(layout)
    );
    if (!valid_info) {
        changes |= remove_torrent_with_invalid_metadata(handle, valid_info.error().message);
        return valid_info;
    }

    lt::add_torrent_params metadata_sources;
    for (lt::announce_entry const &tracker : handle.trackers()) {
        metadata_sources.trackers.push_back(tracker.url);
        metadata_sources.tracker_tiers.push_back(tracker.tier);
    }
    std::set<std::string> const url_seeds = handle.url_seeds();
    metadata_sources.url_seeds.assign(url_seeds.begin(), url_seeds.end());
    BridgeResult const valid_sources = validate_torrent_sources(metadata_sources);
    if (!valid_sources) {
        changes |= remove_torrent_with_invalid_metadata(handle, valid_sources.error().message);
        return valid_sources;
    }

    if (identity != nullptr) {
        identity->metadata_validation_retry_after = {};
        BridgeResult const remembered_sources = remember_source_policy_sources(*identity, metadata_sources);
        if (!remembered_sources) {
            changes |= remove_torrent_with_invalid_metadata(handle, remembered_sources.error().message);
            return remembered_sources;
        }
        bool const was_pending = metadata_validation_pending.contains(identity);
        if (was_pending) {
            handle.prioritize_files(std::vector<lt::download_priority_t>(
                static_cast<std::size_t>(layout.num_files()),
                lt::dont_download
            ));
        }
        if (torrent_file->priv()) {
            bool const policy_changed = identity->dht_enabled_by_user
                || identity->dht_disabled_by_user
                || identity->peer_exchange_enabled_by_user
                || identity->peer_exchange_disabled_by_user
                || identity->lsd_enabled_by_user
                || identity->lsd_disabled_by_user
                || !identity->dht_locked_by_source
                || !identity->peer_exchange_locked_by_source
                || !identity->lsd_locked_by_source
                || !static_cast<bool>(handle.flags() & lt::torrent_flags::disable_dht)
                || !static_cast<bool>(handle.flags() & lt::torrent_flags::disable_pex)
                || !static_cast<bool>(handle.flags() & lt::torrent_flags::disable_lsd);
            identity->dht_enabled_by_user = false;
            identity->dht_disabled_by_user = false;
            identity->peer_exchange_enabled_by_user = false;
            identity->peer_exchange_disabled_by_user = false;
            identity->lsd_enabled_by_user = false;
            identity->lsd_disabled_by_user = false;
            identity->dht_locked_by_source = true;
            identity->peer_exchange_locked_by_source = true;
            identity->lsd_locked_by_source = true;
            dht_disabled_by_app.erase(identity);
            lsd_disabled_by_app.erase(identity);
            peer_exchange_disabled_by_app.erase(identity);
            handle.set_flags(lt::torrent_flags::disable_dht);
            handle.set_flags(lt::torrent_flags::disable_pex);
            handle.set_flags(lt::torrent_flags::disable_lsd);
            if (policy_changed) {
                request_save_locked(handle);
            }
        } else if (was_pending) {
            // Metadata arrival changes native facts; it does not resolve app
            // policy. Stay fail-closed until the Swift actor observes the new
            // facts and submits one complete policy application.
            handle.set_flags(lt::torrent_flags::disable_dht);
            handle.set_flags(lt::torrent_flags::disable_pex);
            handle.set_flags(lt::torrent_flags::disable_lsd);
        }
        if (was_pending) {
            metadata_validation_pending.erase(identity);
            identity->allow_pre_metadata_dht = false;
            identity->presentation_metadata_refresh_requested = true;
            request_save_locked(handle);
            changes |= kChangeTorrents;
        }
    }
    return valid_info;
}

void TTorrentClient::validate_pending_metadata(DirtyMask &changes)
{
    std::vector<lt::torrent_handle> candidates;
    {
        std::scoped_lock io_guard(resume_io_lock);
        candidates.reserve(metadata_validation_pending.size());
        for (TorrentIdentity const *identity : metadata_validation_pending) {
            if (identity == nullptr
                || identity->token == nullptr) {
                continue;
            }
            auto const handle = handle_by_native_token.find(identity->token->value);
            if (handle != handle_by_native_token.end()) {
                candidates.push_back(handle->second);
            }
        }
    }

    for (lt::torrent_handle const &handle : candidates) {
        std::shared_ptr<lt::torrent_info const> const torrent_file = handle.torrent_file();
        if (!torrent_file || !torrent_file->is_valid()) {
            continue;
        }
        BridgeResult const validated = validate_or_remove_loaded_metadata(handle, changes);
        if (!validated) {
            continue;
        }
    }
}

int32_t TTorrentClient::copy_trackers(
    std::uint64_t const native_token,
    std::span<TTorrentTrackerSnapshot> output,
    int32_t *required_count_out,
    std::uint8_t *available_out
)
{
    std::scoped_lock guard(lock);
    std::optional<lt::torrent_handle> const handle = find(native_token);
    if (!handle) {
        return 0;
    }

    std::vector<lt::announce_entry> const trackers = handle->trackers();
    std::size_t const required_count = std::min(
        trackers.size(),
        static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT)
    );
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(required_count);
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(true);
    }

    lt::info_hash_t const hashes = handle->info_hashes();
    std::size_t const copied_count = std::min(output.size(), required_count);
    auto destination = output.begin();
    for (std::size_t index = 0; index < copied_count; ++index, ++destination) {
        *destination = tracker_snapshot_from_entry(trackers.at(index), hashes);
    }
    return static_cast<int32_t>(copied_count);
}

int32_t TTorrentClient::copy_web_seeds(
    std::uint64_t const native_token,
    std::span<TTorrentWebSeedSnapshot> output,
    int32_t *required_count_out,
    std::uint8_t *available_out
)
{
    std::scoped_lock guard(lock);
    std::optional<lt::torrent_handle> const handle = find(native_token);
    if (!handle) {
        return 0;
    }

    std::set<std::string> const web_seeds = handle->url_seeds();
    std::size_t const required_count = std::min(
        web_seeds.size(),
        static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT)
    );
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(required_count);
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(true);
    }

    std::size_t const copied_count = std::min(output.size(), required_count);
    auto web_seed = web_seeds.begin();
    auto destination = output.begin();
    for (std::size_t index = 0; index < copied_count; ++index, ++web_seed, ++destination) {
        *destination = web_seed_snapshot(*web_seed);
    }
    return static_cast<int32_t>(copied_count);
}

bool TTorrentClient::copy_web_seed_activity(
    std::uint64_t const native_token,
    TTorrentWebSeedActivitySnapshot *activity_out
)
{
    std::scoped_lock guard(lock);
    std::optional<lt::torrent_handle> const handle = find(native_token);
    if (!handle) {
        return false;
    }

    std::vector<lt::peer_info> peers;
    handle->get_peer_info(peers);
    TTorrentWebSeedActivitySnapshot activity{};
    for (lt::peer_info const &peer : peers) {
        if (!is_web_seed_peer(peer)) {
            continue;
        }
        if (activity.active_count < std::numeric_limits<int32_t>::max()) {
            ++activity.active_count;
        }
        activity.download_rate = static_cast<int32_t>(std::min<std::int64_t>(
            std::numeric_limits<int32_t>::max(),
            static_cast<std::int64_t>(activity.download_rate) + std::max(0, peer.payload_down_speed)
        ));
        std::int64_t const downloaded = std::max<int64_t>(0, peer.total_download);
        std::int64_t const remaining = std::numeric_limits<int64_t>::max()
            - activity.total_download;
        activity.total_download += std::min(downloaded, remaining);
    }
    if (activity_out != nullptr) {
        *activity_out = activity;
    }
    return true;
}

bool TTorrentClient::copy_peer_sources(
    std::uint64_t const native_token,
    TTorrentPeerSourceSnapshot *sources_out
)
{
    std::scoped_lock guard(lock);
    std::optional<lt::torrent_handle> const handle = find(native_token);
    if (!handle) {
        return false;
    }

    std::vector<lt::peer_info> peers;
    handle->get_peer_info(peers);
    if (sources_out != nullptr) {
        *sources_out = peer_source_snapshot(peers);
    }
    return true;
}

int32_t TTorrentClient::copy_files(
    std::uint64_t const native_token,
    std::span<TTorrentFileSnapshot> output,
    int32_t *required_count_out,
    std::uint8_t *available_out
)
{
    std::scoped_lock guard(lock);
    std::optional<lt::torrent_handle> const handle = find(native_token);
    if (!handle) {
        return 0;
    }

    std::shared_ptr<lt::torrent_info const> const torrent_file = handle->torrent_file();
    if (!torrent_file || !torrent_file->is_valid()) {
        if (available_out != nullptr) {
            *available_out = bridge_bool(true);
        }
        return 0;
    }

    lt::file_storage const &layout = torrent_file->layout();
    lt::renamed_files const renamed_files = handle->get_renamed_files();
    BridgeResult const valid_info = validate_torrent_info(
        *torrent_file,
        renamed_files.export_filenames(layout)
    );
    if (!valid_info) {
        return 0;
    }
    lt::filenames const files(layout, renamed_files);
    auto const required_count = static_cast<std::size_t>(files.num_files());
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(required_count);
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(true);
    }

    std::vector<lt::download_priority_t> priorities = handle->get_file_priorities();
    TorrentIdentity const *const identity = identity_from_handle(*handle);
    if (identity != nullptr && !identity->storage_activation) {
        priorities.assign(
            required_count,
            identity->intended_default_dont_download
                ? lt::dont_download
                : lt::default_priority
        );
        std::copy_n(
            identity->intended_file_priorities.begin(),
            std::min(priorities.size(), identity->intended_file_priorities.size()),
            priorities.begin()
        );
    }
    std::vector<std::int64_t> const progress = handle->file_progress(
        lt::torrent_handle::piece_granularity
    );

    std::size_t const copied_count = std::min(output.size(), required_count);
    auto destination = output.begin();
    for (std::size_t index = 0; index < copied_count; ++index, ++destination) {
        lt::file_index_t const file{static_cast<int32_t>(index)};
        auto priority = static_cast<int32_t>(static_cast<std::uint8_t>(lt::default_priority));
        if (index < priorities.size()) {
            priority = static_cast<int32_t>(static_cast<std::uint8_t>(priorities.at(index)));
        }
        TTorrentFileSnapshot snapshot = file_snapshot_from_files(files, file, priority);
        if (index < progress.size()) {
            snapshot.downloaded = std::clamp<std::int64_t>(progress.at(index), 0, snapshot.size);
            snapshot.progress = snapshot.size <= 0
                ? 1.0
                : std::clamp(
                    static_cast<double>(snapshot.downloaded) / static_cast<double>(snapshot.size),
                    0.0,
                    1.0
                );
        }
        *destination = snapshot;
    }
    return static_cast<int32_t>(copied_count);
}

int32_t TTorrentClient::copy_piece_map(
    std::uint64_t const native_token,
    TTorrentPieceMapSnapshot *snapshot,
    std::span<std::uint8_t> output,
    int32_t *required_count_out,
    std::uint8_t *available_out
)
{
    std::scoped_lock guard(lock);
    std::optional<lt::torrent_handle> const handle = find(native_token);
    if (!handle) {
        return 0;
    }

    lt::torrent_status const status = handle->status(
        lt::torrent_handle::query_torrent_file
        | lt::torrent_handle::query_pieces
    );
    std::shared_ptr<lt::torrent_info const> const torrent_file = status.torrent_file.lock();
    int const total_pieces = torrent_file == nullptr || !torrent_file->is_valid()
        ? status.pieces.size()
        : torrent_file->num_pieces();

    TTorrentPieceMapSnapshot value{};
    value.total_pieces = std::max(0, total_pieces);
    value.completed_pieces = std::clamp(status.pieces.count(), 0, value.total_pieces);
    value.available_pieces = std::clamp(
        status.pieces.size(),
        0,
        std::min(value.total_pieces, TTORRENT_MAX_PIECE_MAP_COUNT)
    );
    value.map_available = bridge_bool(value.available_pieces > 0);
    value.map_truncated = bridge_bool(value.available_pieces < value.total_pieces);
    if (required_count_out != nullptr) {
        *required_count_out = value.available_pieces;
    }
    if (snapshot != nullptr) {
        *snapshot = value;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(true);
    }

    std::size_t const copied_count = std::min(
        output.size(),
        static_cast<std::size_t>(value.available_pieces)
    );
    auto destination = output.begin();
    for (std::size_t piece = 0; piece < copied_count; ++piece, ++destination) {
        *destination = bridge_bool(status.pieces.get_bit(
            lt::piece_index_t{static_cast<int32_t>(piece)}
        ));
    }
    return static_cast<int32_t>(copied_count);
}

DirtyMask TTorrentClient::mark_torrent_removed(
    lt::info_hash_t const &hashes,
    std::string_view requested_id
)
{
    if (hash_keys(hashes).empty() && requested_id.empty()) {
        return 0;
    }
    return mark_torrents_changed() | mark_tracker_hosts_changed();
}

int32_t TTorrentClient::copy_snapshots(std::span<TTorrentSnapshot> output, int32_t *required_count_out)
{
    std::scoped_lock guard(lock);
    std::vector<TTorrentSnapshot> const snapshots = materialized_snapshots(*this);
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(snapshots.size());
    }

    std::size_t const count = std::min(output.size(), snapshots.size());
    if (count > 0) {
        std::ranges::copy_n(
            snapshots.begin(),
            static_cast<std::ptrdiff_t>(count),
            output.begin()
        );
    }
    return static_cast<int32_t>(count);
}

int32_t TTorrentClient::copy_tracker_hosts(
    std::span<TTorrentTrackerHostSnapshot> output,
    int32_t *required_count_out,
    std::uint8_t *available_out
)
{
    std::scoped_lock guard(lock);
    constexpr auto maximum_row_count = static_cast<std::size_t>(
        TTORRENT_MAX_TRACKER_HOST_ROW_COUNT
    );
    std::vector<TTorrentTrackerHostSnapshot> rows;
    std::vector<TTorrentSnapshot> const snapshots = materialized_snapshots(*this);
    for (TTorrentSnapshot const &snapshot : snapshots) {
        if (rows.size() >= maximum_row_count) {
            break;
        }
        std::optional<lt::torrent_handle> const handle = find(snapshot.native_token);
        if (!handle) {
            return 0;
        }
        std::vector<std::string> const hosts = normalized_tracker_hosts(handle->trackers());
        std::size_t const retained_count = std::min(
            hosts.size(),
            maximum_row_count - rows.size()
        );
        for (std::string const &host : std::span{hosts}.first(retained_count)) {
            append_tracker_host_row(rows, {.native_token = snapshot.native_token, .host = host});
        }
    }

    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(rows.size());
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(true);
    }

    std::size_t const copied = std::min(output.size(), rows.size());
    if (copied > 0) {
        std::ranges::copy_n(
            rows.begin(),
            static_cast<std::ptrdiff_t>(copied),
            output.begin()
        );
    }
    return static_cast<int32_t>(copied);
}

DirtyMask TTorrentClient::queue_alert_error(std::string message)
{
    if (pending_alert_errors.size() >= kMaxPendingAlertErrors) {
        pending_alert_errors.erase(pending_alert_errors.begin());
    }
    pending_alert_errors.push_back(std::move(message));
    return kChangeErrors;
}

DirtyMask TTorrentClient::record_listen_failed(lt::listen_failed_alert const &alert)
{
    if (requested_network_blocked) {
        return 0;
    }

    std::string const next_error = "Listener failed on " + safe_c_string(alert.listen_interface()) + " " +
                                   endpoint_string(alert.address, alert.port) + ": " + alert.error.message() +
                                   " during " + operation_label(alert.op) + ".";
    if (last_network_error == next_error) {
        return 0;
    }

    last_network_error = next_error;
    return kChangeNetwork;
}

DirtyMask TTorrentClient::record_listen_succeeded(lt::listen_succeeded_alert const &alert)
{
    if (requested_network_blocked) {
        return 0;
    }

    std::string const next_endpoint = endpoint_string(alert.address, alert.port);
    if (has_listener && listen_port == alert.port && listen_endpoint == next_endpoint && last_network_error.empty()) {
        return 0;
    }

    has_listener = true;
    listen_port = alert.port;
    listen_endpoint = next_endpoint;
    last_network_error.clear();
    return kChangeNetwork;
}

DirtyMask TTorrentClient::record_network_requested(bool blocked)
{
    requested_network_blocked = blocked;
    has_listener = false;
    listen_port = 0;
    listen_endpoint.clear();
    last_network_error.clear();
    return kChangeNetwork;
}

DirtyMask TTorrentClient::record_network_blocked() { return record_network_requested(true); }

DirtyMask TTorrentClient::cache_dht_diagnostics(lt::session_stats_alert const &alert)
{
    if (!dht_diagnostics_request_pending) {
        return 0U;
    }

    dht_diagnostics_request_pending = false;
    static int const routing_nodes_index = lt::find_metric_idx("dht.dht_nodes");
    auto const counters = alert.counters();
    auto const counter_index = static_cast<std::ptrdiff_t>(routing_nodes_index);
    if (routing_nodes_index < 0
        || counter_index >= counters.size()) {
        return invalidate_dht_diagnostics();
    }

    std::int64_t const native_count = std::max<std::int64_t>(
        0,
        counters.subspan(counter_index, 1).front()
    );
    int32_t const next_count = static_cast<int32_t>(std::min<std::int64_t>(
        native_count,
        std::numeric_limits<int32_t>::max()
    ));
    bool const changed = !dht_routing_nodes_available || dht_routing_nodes != next_count;
    dht_routing_nodes = next_count;
    dht_routing_nodes_available = true;
    return changed ? kChangeNetwork : 0U;
}

DirtyMask TTorrentClient::invalidate_dht_diagnostics() noexcept
{
    bool const changed = dht_routing_nodes_available;
    dht_diagnostics_request_pending = false;
    dht_routing_nodes_available = false;
    dht_routing_nodes = 0;
    return changed ? kChangeNetwork : 0U;
}

[[nodiscard]] TTorrentNetworkStatus TTorrentClient::network_status() noexcept
{
    TTorrentNetworkStatus status{};
    status.listen_port = listen_port;
    status.network_blocked = bridge_bool(requested_network_blocked);
    status.has_listener = bridge_bool(has_listener);
    copy_string(std::span{status.endpoint}, listen_endpoint);
    copy_string(std::span{status.last_error}, last_network_error);

    // Diagnostics are best-effort and must never invalidate the authoritative
    // containment fields copied above. Preserve the last observed DHT state if
    // libtorrent cannot service a diagnostic request, and invalidate only the
    // routing-table measurement.
    try {
#if defined(TORRENT_BRIDGE_TESTING)
        if (fail_next_dht_diagnostics_poll) {
            fail_next_dht_diagnostics_poll = false;
            throw std::runtime_error("Injected DHT diagnostics failure.");
        }
#endif
        lt::settings_pack const settings = session.get_settings();
        bool const dht_enabled = settings.get_bool(lt::settings_pack::enable_dht);
        bool const dht_running = dht_enabled && session.is_dht_running();
        if (dht_enabled != observed_dht_enabled || dht_running != observed_dht_running) {
            static_cast<void>(invalidate_dht_diagnostics());
            observed_dht_enabled = dht_enabled;
            observed_dht_running = dht_running;
            last_dht_diagnostics_request = {};
        }

        auto const now = std::chrono::steady_clock::now();
        if (dht_running
            && !dht_diagnostics_request_pending
            && now - last_dht_diagnostics_request >= kDHTDiagnosticsRefreshInterval) {
            dht_diagnostics_request_pending = true;
            last_dht_diagnostics_request = now;
            session.post_session_stats();
        }
    } catch (...) {
        static_cast<void>(invalidate_dht_diagnostics());
    }

    if (!observed_dht_enabled) {
        status.dht_status = TTORRENT_DHT_STATUS_DISABLED;
        status.dht_routing_nodes = -1;
    } else if (!observed_dht_running) {
        status.dht_status = TTORRENT_DHT_STATUS_STARTING;
        status.dht_routing_nodes = -1;
    } else {
        status.dht_status = TTORRENT_DHT_STATUS_RUNNING;
        status.dht_routing_nodes = dht_routing_nodes_available ? dht_routing_nodes : -1;
    }
    return status;
}

[[nodiscard]] TTorrentBridgeHealth TTorrentClient::health_status() const noexcept
{
    return bridge_health;
}

bool TTorrentClient::take_alert_error(std::span<char> output)
{
    std::scoped_lock guard(lock);
    if (output.empty() || pending_alert_errors.empty()) {
        return false;
    }

    copy_error(output, pending_alert_errors.front());
    pending_alert_errors.erase(pending_alert_errors.begin());
    return true;
}

[[nodiscard]] BridgeResult TTorrentClient::ensure_persistence_available(int32_t code) const
{
    std::scoped_lock io_guard(resume_io_lock);
    return ensure_persistence_available_locked(code);
}

[[nodiscard]] BridgeResult TTorrentClient::ensure_persistence_available_locked(int32_t code) const
{
    if (!persistence_faulted) {
        return {};
    }
    return bridge_error(code, persistence_fault_message.empty() ? "Resume persistence is in an uncertain state."
                                                                : persistence_fault_message);
}

[[nodiscard]] bool TTorrentClient::persistence_is_faulted() const
{
    std::scoped_lock io_guard(resume_io_lock);
    return persistence_is_faulted_locked();
}

[[nodiscard]] bool TTorrentClient::persistence_is_faulted_locked() const noexcept
{
    return persistence_faulted;
}

[[nodiscard]] BridgeResult TTorrentClient::fault_persistence_locked(int32_t code, std::string message)
{
    if (!persistence_faulted) {
        persistence_faulted = true;
        persistence_fault_message = std::move(message);
    }

    std::string report = persistence_fault_message.empty()
        ? "Resume persistence is in an uncertain state."
        : persistence_fault_message;
    return bridge_error(code, std::move(report));
}

void TTorrentClient::pause_session_for_persistence_fault()
{
    try {
        session.pause();
    } catch (...) {
        ignore_shutdown_failure();
    }
}

[[nodiscard]] BridgeResult TTorrentClient::fault_persistence(int32_t code, std::string message)
{
    BridgeResult fault = {};
    {
        std::scoped_lock io_guard(resume_io_lock);
        fault = fault_persistence_locked(code, std::move(message));
    }
    pause_session_for_persistence_fault();
    return fault;
}

[[nodiscard]] BridgeResult TTorrentClient::fault_persistence_and_pause_locked(int32_t code, std::string message)
{
    BridgeResult fault = fault_persistence_locked(code, std::move(message));
    pause_session_for_persistence_fault();
    return fault;
}

[[nodiscard]] BridgeResult TTorrentClient::cancel_tombstoned_operation_or_fault(
    std::vector<std::string> const &ids,
    int32_t code,
    std::string operation_error
)
{
    ResumeSaveResult cleared = clear_removal_tombstones(ids);
    if (!cleared) {
        return fault_persistence(
            code,
            "The operation failed and its durable removal marker could not be cleared: " + cleared.error() + "."
        );
    }
    return bridge_error(code, std::move(operation_error));
}

} // namespace torrent_bridge::internal
