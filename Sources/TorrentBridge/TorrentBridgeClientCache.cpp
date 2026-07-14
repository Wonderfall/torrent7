#include "TorrentBridgeInternal.hpp"

namespace {

template <std::size_t Count>
[[nodiscard]] bool char_arrays_equal(char const (&lhs)[Count], char const (&rhs)[Count]) noexcept
{
    return std::ranges::equal(std::span{lhs}, std::span{rhs});
}

[[nodiscard]] bool snapshots_equal(TTorrentSnapshot const &lhs, TTorrentSnapshot const &rhs) noexcept
{
    return char_arrays_equal(lhs.id, rhs.id)
        && char_arrays_equal(lhs.info_hash, rhs.info_hash)
        && char_arrays_equal(lhs.name, rhs.name)
        && char_arrays_equal(lhs.save_path, rhs.save_path)
        && char_arrays_equal(lhs.error, rhs.error)
        && char_arrays_equal(lhs.comment, rhs.comment)
        && lhs.progress == rhs.progress
        && lhs.total_done == rhs.total_done
        && lhs.total_wanted == rhs.total_wanted
        && lhs.total_size == rhs.total_size
        && lhs.total_upload == rhs.total_upload
        && lhs.total_download == rhs.total_download
        && lhs.total_payload_upload == rhs.total_payload_upload
        && lhs.total_payload_download == rhs.total_payload_download
        && lhs.all_time_upload == rhs.all_time_upload
        && lhs.all_time_download == rhs.all_time_download
        && lhs.added_time == rhs.added_time
        && lhs.created_time == rhs.created_time
        && lhs.completed_time == rhs.completed_time
        && lhs.download_rate == rhs.download_rate
        && lhs.upload_rate == rhs.upload_rate
        && lhs.download_payload_rate == rhs.download_payload_rate
        && lhs.upload_payload_rate == rhs.upload_payload_rate
        && lhs.peers == rhs.peers
        && lhs.known_peers == rhs.known_peers
        && lhs.seeds == rhs.seeds
        && lhs.state == rhs.state
        && lhs.queue_position == rhs.queue_position
        && lhs.queue_priority == rhs.queue_priority
        && lhs.paused == rhs.paused
        && lhs.auto_managed == rhs.auto_managed
        && lhs.seeding == rhs.seeding
        && lhs.finished == rhs.finished
        && lhs.has_metadata == rhs.has_metadata
        && lhs.private_torrent == rhs.private_torrent;
}

[[nodiscard]] bool tracker_snapshots_equal(
    TTorrentTrackerSnapshot const &lhs,
    TTorrentTrackerSnapshot const &rhs
) noexcept
{
    return char_arrays_equal(lhs.url, rhs.url)
        && char_arrays_equal(lhs.message, rhs.message)
        && lhs.tier == rhs.tier
        && lhs.fail_count == rhs.fail_count
        && lhs.scrape_seeders == rhs.scrape_seeders
        && lhs.scrape_leechers == rhs.scrape_leechers
        && lhs.scrape_downloaded == rhs.scrape_downloaded
        && lhs.updating == rhs.updating
        && lhs.verified == rhs.verified
        && lhs.has_error == rhs.has_error
        && lhs.enabled == rhs.enabled;
}

[[nodiscard]] bool web_seed_snapshots_equal(
    TTorrentWebSeedSnapshot const &lhs,
    TTorrentWebSeedSnapshot const &rhs
) noexcept
{
    return char_arrays_equal(lhs.url, rhs.url);
}

[[nodiscard]] bool file_snapshots_equal(TTorrentFileSnapshot const &lhs, TTorrentFileSnapshot const &rhs) noexcept
{
    return char_arrays_equal(lhs.path, rhs.path)
        && lhs.size == rhs.size
        && lhs.downloaded == rhs.downloaded
        && lhs.progress == rhs.progress
        && lhs.index == rhs.index
        && lhs.priority == rhs.priority
        && lhs.pad_file == rhs.pad_file;
}

[[nodiscard]] bool piece_map_snapshots_equal(
    TTorrentPieceMapSnapshot const &lhs,
    TTorrentPieceMapSnapshot const &rhs
) noexcept
{
    return lhs.total_pieces == rhs.total_pieces
        && lhs.completed_pieces == rhs.completed_pieces
        && lhs.available_pieces == rhs.available_pieces
        && lhs.map_available == rhs.map_available
        && lhs.map_truncated == rhs.map_truncated;
}

[[nodiscard]] bool peer_source_snapshots_equal(
    TTorrentPeerSourceSnapshot const &lhs,
    TTorrentPeerSourceSnapshot const &rhs
) noexcept
{
    return lhs.connected == rhs.connected
        && lhs.tracker == rhs.tracker
        && lhs.dht == rhs.dht
        && lhs.peer_exchange == rhs.peer_exchange
        && lhs.local_service_discovery == rhs.local_service_discovery
        && lhs.resume_data == rhs.resume_data
        && lhs.incoming == rhs.incoming
        && lhs.web_seed == rhs.web_seed
        && lhs.other == rhs.other;
}

template <typename Value, typename Equal>
[[nodiscard]] bool vectors_equal(std::vector<Value> const &lhs, std::vector<Value> const &rhs, Equal equal) noexcept
{
    return lhs.size() == rhs.size()
        && std::ranges::equal(lhs, rhs, equal);
}

} // namespace

DirtyMask TTorrentClient::rebuild_snapshot_cache()
{
    bool const had_snapshots = !snapshot_cache.empty();
    bool const had_tracker_hosts = !tracker_host_cache.empty();
    std::vector<lt::torrent_status> const statuses = session.get_torrent_status(
        [](lt::torrent_status const &) {
            return true;
        },
        kSnapshotStatusFlags
    );
    snapshot_cache.clear();
    snapshot_indices.clear();
    tracker_host_cache.clear();
    DirtyMask changes = update_snapshot_cache(statuses);

    if (had_snapshots && snapshot_cache.empty()) {
        changes |= mark_snapshot_cache_changed();
    }
    if (had_tracker_hosts && tracker_host_cache.empty()) {
        changes |= mark_tracker_host_cache_changed();
    }
    return changes;
}

DirtyMask TTorrentClient::mark_snapshot_cache_changed() noexcept
{
    return TTORRENT_DIRTY_TORRENTS;
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

DirtyMask TTorrentClient::cache_snapshot(lt::torrent_status const &status)
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
        DirtyMask changes = 0;
        for (std::string const &removed_id : ids) {
            changes |= remove_snapshot(removed_id);
        }
        return changes;
    }
    mark_active(status.handle, identity);

    DirtyMask changes = 0;
    std::string const id = identity_snapshot_id(identity, status.info_hashes);
    for (std::string const &alias : ids) {
        if (alias != id) {
            changes |= remove_snapshot(alias);
        }
    }

    TTorrentSnapshot snapshot = snapshot_from_status(status, identity);
    copy_string(std::span{snapshot.id}, id);
    snapshot.queue_priority = identity == nullptr ? TTORRENT_QUEUE_PRIORITY_NORMAL : identity->queue_priority;
    auto const existing = snapshot_indices.find(id);
    if (existing != snapshot_indices.end()) {
        changes |= cache_tracker_hosts(status.handle, id);
        TTorrentSnapshot &current = snapshot_cache.at(existing->second);
        if (!snapshots_equal(current, snapshot)) {
            current = snapshot;
            changes |= mark_snapshot_cache_changed();
        }
        return changes;
    }
    if (snapshot_cache.size() >= static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT)) {
        return changes;
    }

    changes |= cache_tracker_hosts(status.handle, id);
    snapshot_indices.emplace(id, snapshot_cache.size());
    snapshot_cache.push_back(snapshot);
    return changes | mark_snapshot_cache_changed();
}

DirtyMask TTorrentClient::cache_snapshot(lt::torrent_handle const &handle)
{
    if (!handle.is_valid()) {
        return 0;
    }

    try {
        return cache_snapshot(handle.status(kSnapshotStatusFlags));
    } catch (...) {
        return 0;
    }
}

DirtyMask TTorrentClient::cache_resume_metadata(
    TorrentIdentity *identity,
    lt::add_torrent_params const &params
)
{
    if (identity == nullptr) {
        return 0;
    }

    bool changed = false;
    if (!params.comment.empty()) {
        std::array<char, sizeof(TTorrentSnapshot::comment)> comment{};
        copy_string(std::span{comment}, params.comment);
        std::string const bounded_comment(comment.data());
        if (identity->comment != bounded_comment) {
            identity->comment = bounded_comment;
            changed = true;
        }
    }
    if (params.creation_date > 0 && identity->creation_date != params.creation_date) {
        identity->creation_date = params.creation_date;
        changed = true;
    }
    if (!changed) {
        return 0;
    }

    auto const snapshot = snapshot_indices.find(identity->canonical_id);
    if (snapshot == snapshot_indices.end()) {
        request_snapshot_update_locked();
        return 0;
    }

    TTorrentSnapshot &cached = snapshot_cache.at(snapshot->second);
    copy_string(std::span{cached.comment}, identity->comment);
    cached.created_time = static_cast<int64_t>(identity->creation_date);
    return mark_snapshot_cache_changed();
}

DirtyMask TTorrentClient::update_snapshot_cache(std::vector<lt::torrent_status> const &statuses)
{
    DirtyMask changes = 0;
    for (lt::torrent_status const &status : statuses) {
        changes |= cache_snapshot(status);
    }
    return changes;
}

DirtyMask TTorrentClient::remove_snapshot(std::string_view id)
{
    if (id.empty()) {
        return 0;
    }

    DirtyMask changes = 0;
    changes |= remove_tracker_hosts(id);
    changes |= remove_trackers(id);
    changes |= remove_web_seeds(id);
    remove_peer_sources(id);
    changes |= remove_files(id);
    changes |= remove_piece_map(id);

    auto const existing = snapshot_indices.find(std::string(id));
    if (existing == snapshot_indices.end()) {
        return changes;
    }

    std::size_t const index = existing->second;
    std::size_t const last_index = snapshot_cache.size() - 1U;
    std::string const removed_id(id);
    if (index != last_index) {
        snapshot_cache.at(index) = snapshot_cache.at(last_index);
        std::string const moved_id(snapshot_cache.at(index).id);
        snapshot_indices.insert_or_assign(moved_id, index);
    }
    snapshot_cache.pop_back();
    snapshot_indices.erase(removed_id);
    return changes | mark_snapshot_cache_changed();
}

DirtyMask TTorrentClient::mark_tracker_host_cache_changed() noexcept
{
    return TTORRENT_DIRTY_TRACKER_HOSTS;
}

DirtyMask TTorrentClient::cache_tracker_hosts(std::string const &id, std::vector<lt::announce_entry> const &trackers)
{
    if (id.empty()) {
        return 0;
    }

    std::set<std::string> unique_hosts;
    for (lt::announce_entry const &tracker : trackers) {
        if (std::optional<std::string> host = normalized_tracker_host(tracker.url)) {
            unique_hosts.insert(std::move(*host));
        }
    }

    std::vector<std::string> hosts(unique_hosts.begin(), unique_hosts.end());
    auto const existing = tracker_host_cache.find(id);
    if (existing != tracker_host_cache.end() && existing->second == hosts) {
        return 0;
    }
    if (hosts.empty()) {
        if (existing == tracker_host_cache.end()) {
            return 0;
        }
        tracker_host_cache.erase(existing);
        return mark_tracker_host_cache_changed();
    }
    tracker_host_cache.insert_or_assign(id, std::move(hosts));
    return mark_tracker_host_cache_changed();
}

DirtyMask TTorrentClient::cache_tracker_hosts(lt::torrent_handle const &handle, std::string const &id)
{
    if (!handle.is_valid()) {
        return remove_tracker_hosts(id);
    }

    try {
        return cache_tracker_hosts(id, handle.trackers());
    } catch (...) {
        return 0;
    }
}

DirtyMask TTorrentClient::remove_tracker_hosts(std::string_view id)
{
    if (id.empty()) {
        return 0;
    }

    if (tracker_host_cache.erase(std::string(id)) > 0) {
        return mark_tracker_host_cache_changed();
    }
    return 0;
}

DirtyMask TTorrentClient::mark_tracker_cache_changed() noexcept
{
    return TTORRENT_DIRTY_TRACKERS;
}

DirtyMask TTorrentClient::remove_trackers(std::string_view id)
{
    if (id.empty()) {
        return 0;
    }

    if (tracker_cache.erase(std::string(id)) > 0) {
        return mark_tracker_cache_changed();
    }
    return 0;
}

DirtyMask TTorrentClient::mark_web_seed_cache_changed() noexcept
{
    return TTORRENT_DIRTY_WEB_SEEDS;
}

DirtyMask TTorrentClient::remove_web_seeds(std::string_view id)
{
    if (id.empty()) {
        return 0;
    }

    if (web_seed_cache.erase(std::string(id)) > 0) {
        return mark_web_seed_cache_changed();
    }
    return 0;
}

void TTorrentClient::remove_peer_sources(std::string_view id)
{
    if (id.empty()) {
        return;
    }

    peer_source_cache.erase(std::string(id));
}

DirtyMask TTorrentClient::mark_file_cache_changed() noexcept
{
    return TTORRENT_DIRTY_FILES;
}

DirtyMask TTorrentClient::remove_files(std::string_view id)
{
    if (id.empty()) {
        return 0;
    }

    if (file_cache.erase(std::string(id)) > 0) {
        return mark_file_cache_changed();
    }
    return 0;
}

DirtyMask TTorrentClient::mark_piece_map_cache_changed() noexcept
{
    return TTORRENT_DIRTY_PIECES;
}

DirtyMask TTorrentClient::remove_piece_map(std::string_view id)
{
    if (id.empty()) {
        return 0;
    }

    if (piece_map_cache.erase(std::string(id)) > 0) {
        return mark_piece_map_cache_changed();
    }
    return 0;
}

DirtyMask TTorrentClient::invalidate_detail_caches_locked()
{
    DirtyMask changes = 0;
    if (!tracker_cache.empty()) {
        tracker_cache.clear();
        changes |= mark_tracker_cache_changed();
    }
    if (!web_seed_cache.empty()) {
        web_seed_cache.clear();
        changes |= mark_web_seed_cache_changed();
    }
    peer_source_cache.clear();
    if (!file_cache.empty()) {
        file_cache.clear();
        changes |= mark_file_cache_changed();
    }
    if (!piece_map_cache.empty()) {
        piece_map_cache.clear();
        changes |= mark_piece_map_cache_changed();
    }
    return changes;
}

DirtyMask TTorrentClient::cache_trackers(lt::torrent_handle const &handle, std::vector<lt::announce_entry> const &trackers)
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
        return 0;
    case TorrentIdentityState::absent:
        DirtyMask changes = 0;
        for (std::string const &removed_id : ids) {
            changes |= remove_trackers(removed_id);
        }
        return changes;
    }

    DirtyMask changes = 0;
    std::string const id = identity_snapshot_id(identity, hashes);
    for (std::string const &alias : ids) {
        if (alias != id) {
            changes |= remove_trackers(alias);
        }
    }

    std::vector<TTorrentTrackerSnapshot> snapshots;
    std::size_t const count = std::min(
        trackers.size(),
        static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT)
    );
    snapshots.reserve(count);
    for (lt::announce_entry const &tracker : trackers) {
        if (snapshots.size() >= count) {
            break;
        }
        snapshots.push_back(tracker_snapshot_from_entry(tracker, hashes));
    }

    auto &entry = tracker_cache[id];
    if (vectors_equal(entry.trackers, snapshots, tracker_snapshots_equal)) {
        return changes | cache_tracker_hosts(id, trackers);
    }
    entry.trackers = std::move(snapshots);
    entry.revision = tracker_revision + 1U;
    return changes | cache_tracker_hosts(id, trackers) | mark_tracker_cache_changed();
}

std::optional<std::string> TTorrentClient::cache_id_for_handle(lt::torrent_handle const &handle)
{
    if (!handle.is_valid()) {
        return std::nullopt;
    }

    lt::info_hash_t const hashes = handle.info_hashes();
    std::vector<std::string> const ids = hash_keys(hashes);
    if (ids.empty()) {
        return std::nullopt;
    }

    TorrentIdentity *identity = identity_from_handle(handle);
    switch (identity_state_for_status(ids, identity)) {
    case TorrentIdentityState::current:
        break;
    case TorrentIdentityState::stale:
    case TorrentIdentityState::absent:
        return std::nullopt;
    }

    return identity_snapshot_id(identity, hashes);
}

BridgeResult TTorrentClient::cache_web_seeds(lt::torrent_handle const &handle, DirtyMask &changes)
{
    std::optional<std::string> const cache_id = cache_id_for_handle(handle);
    if (!cache_id) {
        return bridge_error(2, "Torrent not found.");
    }

    std::set<std::string> const url_seeds = handle.url_seeds();

    std::vector<TTorrentWebSeedSnapshot> snapshots;
    std::size_t const count = std::min(
        url_seeds.size(),
        static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT)
    );
    snapshots.reserve(count);
    append_web_seed_snapshots(snapshots, url_seeds, count);

    for (std::string const &alias : hash_keys(handle.info_hashes())) {
        if (alias != *cache_id) {
            changes |= remove_web_seeds(alias);
        }
    }

    auto &entry = web_seed_cache[*cache_id];
    if (vectors_equal(entry.web_seeds, snapshots, web_seed_snapshots_equal)) {
        return {};
    }
    entry.web_seeds = std::move(snapshots);
    entry.revision = web_seed_revision + 1U;
    changes |= mark_web_seed_cache_changed();
    return {};
}

DirtyMask TTorrentClient::cache_web_seeds(
    std::string_view id,
    std::set<std::string> const &url_seeds
)
{
    if (id.empty()) {
        return 0;
    }

    std::vector<TTorrentWebSeedSnapshot> snapshots;
    std::size_t const count = std::min(
        url_seeds.size(),
        static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT)
    );
    snapshots.reserve(count);
    append_web_seed_snapshots(snapshots, url_seeds, count);

    auto &entry = web_seed_cache[std::string(id)];
    if (vectors_equal(entry.web_seeds, snapshots, web_seed_snapshots_equal)) {
        return 0;
    }
    entry.web_seeds = std::move(snapshots);
    entry.revision = web_seed_revision + 1U;
    return mark_web_seed_cache_changed();
}

BridgeResult TTorrentClient::cache_file_metadata(lt::torrent_handle const &handle, DirtyMask &changes)
{
    std::optional<std::string> const cache_id = cache_id_for_handle(handle);
    if (!cache_id) {
        return bridge_error(2, "Torrent not found.");
    }

    std::shared_ptr<lt::torrent_info const> const torrent_file = handle.torrent_file();
    if (!torrent_file || !torrent_file->is_valid()) {
        auto existing = file_cache.find(*cache_id);
        if (existing != file_cache.end() && !existing->second.files.empty()) {
            existing->second.files.clear();
            existing->second.revision = file_revision + 1U;
            changes |= mark_file_cache_changed();
        }
        return {};
    }

    lt::file_storage const &layout = torrent_file->layout();
    lt::renamed_files const renamed_files = handle.get_renamed_files();
    BridgeResult const valid_info = validate_torrent_info(
        *torrent_file,
        renamed_files.export_filenames(layout)
    );
    if (!valid_info) {
        if (auto existing = file_cache.find(*cache_id); existing != file_cache.end() && !existing->second.files.empty()) {
            existing->second.files.clear();
            existing->second.revision = file_revision + 1U;
            changes |= mark_file_cache_changed();
        }
        return valid_info;
    }
    lt::filenames const files(layout, renamed_files);

    std::vector<lt::download_priority_t> priorities = handle.get_file_priorities();
    std::unordered_map<int32_t, TTorrentFileSnapshot> previous_files;
    if (auto const previous = file_cache.find(*cache_id); previous != file_cache.end()) {
        previous_files.reserve(previous->second.files.size());
        for (TTorrentFileSnapshot const &file : previous->second.files) {
            previous_files.emplace(file.index, file);
        }
    }

    std::vector<TTorrentFileSnapshot> snapshots;
    snapshots.reserve(static_cast<std::size_t>(files.num_files()));
    for (lt::file_index_t const file : files.file_range()) {
        auto priority = static_cast<int32_t>(static_cast<std::uint8_t>(lt::default_priority));
        auto const priority_index = static_cast<std::size_t>(static_cast<int32_t>(file));
        if (priority_index < priorities.size()) {
            priority = static_cast<int32_t>(static_cast<std::uint8_t>(priorities.at(priority_index)));
        }

        TTorrentFileSnapshot snapshot = file_snapshot_from_files(files, file, priority);
        if (auto const previous = previous_files.find(snapshot.index); previous != previous_files.end()) {
            snapshot.downloaded = std::clamp<std::int64_t>(previous->second.downloaded, 0, snapshot.size);
            snapshot.progress = snapshot.size <= 0
                ? 1.0
                : std::clamp(static_cast<double>(snapshot.downloaded) / static_cast<double>(snapshot.size), 0.0, 1.0);
        }
        snapshots.push_back(snapshot);
    }

    for (std::string const &alias : hash_keys(handle.info_hashes())) {
        if (alias != *cache_id) {
            changes |= remove_files(alias);
        }
    }

    auto &entry = file_cache[*cache_id];
    if (vectors_equal(entry.files, snapshots, file_snapshots_equal)) {
        return {};
    }
    entry.files = std::move(snapshots);
    entry.revision = file_revision + 1U;
    changes |= mark_file_cache_changed();
    return {};
}

DirtyMask TTorrentClient::cache_file_progress(lt::torrent_handle const &handle, lt::aux::vector<std::int64_t, lt::file_index_t> const &progress)
{
    std::optional<std::string> const cache_id = cache_id_for_handle(handle);
    if (!cache_id) {
        return 0;
    }

    DirtyMask changes = 0;
    auto cached = file_cache.find(*cache_id);
    if (cached == file_cache.end()) {
        BridgeResult const cached_metadata = cache_file_metadata(handle, changes);
        if (!cached_metadata) {
            return changes;
        }
        cached = file_cache.find(*cache_id);
        if (cached == file_cache.end()) {
            return changes;
        }
    }

    bool changed = false;
    std::vector<TTorrentFileSnapshot> &files = cached->second.files;
    for (TTorrentFileSnapshot &file : files) {
        if (file.index < 0) {
            continue;
        }

        auto const progress_index = static_cast<std::size_t>(file.index);
        if (progress_index >= progress.size()) {
            continue;
        }

        std::int64_t const downloaded = std::clamp<std::int64_t>(progress.at(progress_index), 0, file.size);
        double const file_progress = file.size <= 0
            ? 1.0
            : std::clamp(static_cast<double>(downloaded) / static_cast<double>(file.size), 0.0, 1.0);
        if (file.downloaded == downloaded && file.progress == file_progress) {
            continue;
        }

        file.downloaded = downloaded;
        file.progress = file_progress;
        changed = true;
    }

    if (changed) {
        cached->second.revision = file_revision + 1U;
        changes |= mark_file_cache_changed();
    }
    return changes;
}

DirtyMask TTorrentClient::cache_piece_map(lt::torrent_status const &status)
{
    std::vector<std::string> const ids = hash_keys(status.info_hashes);
    if (ids.empty() || !status.handle.is_valid()) {
        return 0;
    }

    TorrentIdentity *identity = identity_from_handle(status.handle);
    switch (identity_state_for_status(ids, identity)) {
    case TorrentIdentityState::current:
        break;
    case TorrentIdentityState::stale:
        return 0;
    case TorrentIdentityState::absent:
        DirtyMask changes = 0;
        for (std::string const &removed_id : ids) {
            changes |= remove_piece_map(removed_id);
        }
        return changes;
    }

    std::string const id = identity_snapshot_id(identity, status.info_hashes);
    DirtyMask changes = 0;
    for (std::string const &alias : ids) {
        if (alias != id) {
            changes |= remove_piece_map(alias);
        }
    }

    std::shared_ptr<lt::torrent_info const> const torrent_file = status.torrent_file.lock();
    int const total_pieces = torrent_file == nullptr || !torrent_file->is_valid()
        ? status.pieces.size()
        : torrent_file->num_pieces();

    TTorrentPieceMapSnapshot snapshot{};
    snapshot.total_pieces = std::max(0, total_pieces);
    snapshot.completed_pieces = std::clamp(status.pieces.count(), 0, snapshot.total_pieces);
    snapshot.available_pieces = std::clamp(
        status.pieces.size(),
        0,
        std::min(snapshot.total_pieces, TTORRENT_MAX_PIECE_MAP_COUNT)
    );
    snapshot.map_available = bridge_bool(snapshot.available_pieces > 0);
    snapshot.map_truncated = bridge_bool(snapshot.available_pieces < snapshot.total_pieces);

    std::vector<std::uint8_t> pieces;
    if (bridge_bool(snapshot.map_available)) {
        pieces.reserve(static_cast<std::size_t>(snapshot.available_pieces));
        for (int32_t piece = 0; piece < snapshot.available_pieces; ++piece) {
            pieces.push_back(bridge_bool(status.pieces.get_bit(lt::piece_index_t{piece})));
        }
    }

    auto &entry = piece_map_cache[id];
    if (piece_map_snapshots_equal(entry.snapshot, snapshot) && entry.pieces == pieces) {
        return changes;
    }

    entry.snapshot = snapshot;
    entry.pieces = std::move(pieces);
    entry.revision = piece_map_revision + 1U;
    return changes | mark_piece_map_cache_changed();
}

DirtyMask TTorrentClient::cache_web_seed_activity(lt::torrent_handle const &handle, std::vector<lt::peer_info> const &peers)
{
    std::optional<std::string> const cache_id = cache_id_for_handle(handle);
    if (!cache_id) {
        return 0;
    }

    TTorrentWebSeedActivitySnapshot activity{};
    for (lt::peer_info const &peer : peers) {
        if (!is_web_seed_peer(peer)) {
            continue;
        }

        ++activity.active_count;
        activity.download_rate += std::max(0, peer.payload_down_speed);
        activity.total_download += std::max<int64_t>(0, peer.total_download);
    }

    auto &entry = web_seed_cache[*cache_id];
    if (entry.activity.active_count == activity.active_count
        && entry.activity.download_rate == activity.download_rate
        && entry.activity.total_download == activity.total_download) {
        return 0;
    }

    entry.activity = activity;
    entry.revision = web_seed_revision + 1U;
    return mark_web_seed_cache_changed();
}

void TTorrentClient::cache_peer_sources(lt::torrent_handle const &handle, std::vector<lt::peer_info> const &peers)
{
    std::optional<std::string> const cache_id = cache_id_for_handle(handle);
    if (!cache_id) {
        return;
    }

    TTorrentPeerSourceSnapshot const sources = peer_source_snapshot(peers);
    auto &entry = peer_source_cache[*cache_id];
    if (peer_source_snapshots_equal(entry.sources, sources)) {
        return;
    }

    entry.sources = sources;
    entry.revision = ++peer_source_revision;
}

BridgeResult TTorrentClient::request_sources(std::string const &id, DirtyMask &changes)
{
    auto handle = find(id);
    if (!handle) {
        return bridge_error(2, "Torrent not found.");
    }

    BridgeResult const cached_web_seeds = cache_web_seeds(*handle, changes);
    if (!cached_web_seeds) {
        return cached_web_seeds;
    }

    handle->post_trackers();
    handle->post_peer_info();
    return {};
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

    mark_remove_requested(hashes, "", identity);
    ResumeSaveResult removed_resume = remove_resume_files_for_ids_checked(removal_ids);
    if (!removed_resume) {
        remember_pending_resume_cleanup(removal_ids);
        changes |= queue_alert_error("Invalid torrent metadata was removed, but resume cleanup is pending: " + removed_resume.error() + ".");
    } else {
        ResumeSaveResult cleared = clear_removal_tombstones(removal_ids);
        if (!cleared) {
            changes |= queue_alert_error("Invalid torrent metadata was removed, but removal marker cleanup is pending: " + cleared.error() + ".");
        }
    }
    changes |= remove_snapshot(hashes, "");
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

    return candidate->generation <= other->generation;
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
                .after_generation = 0,
                .resume_ids = cleanup_ids
            });
            remember_pending_cleanups(survivor_identity, pending_cleanups);
        }
        PendingResumeHandle forced_save{
            .handle = survivor,
            .identity = survivor_identity,
            .policy = resume_policy_snapshot_locked(survivor_identity),
            .cleanups = {}
        };
        forced_resume_handles.push_back(std::move(forced_save));
    } else {
        changes |= queue_alert_error("Hybrid torrent conflict resume data could not be saved because the preserved entry identity was missing.");
        ResumeSaveResult removed_resume = remove_resume_files_for_ids_checked(cleanup_ids);
        if (!removed_resume) {
            remember_pending_resume_cleanup(cleanup_ids);
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
        forget_removed_identity_aliases(duplicate_hashes, duplicate_identity);
        changes |= remove_snapshot(duplicate_hashes, duplicate_canonical_id);
    }
    changes |= cache_snapshot(survivor);
    request_snapshot_update_locked();
    changes |= queue_alert_error("Duplicate hybrid torrent entry was removed while preserving the older app entry.");
    return changes;
}

BridgeResult TTorrentClient::validate_or_remove_loaded_metadata(lt::torrent_handle const &handle, DirtyMask &changes)
{
    if (!handle.is_valid()) {
        return {};
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

    if (TorrentIdentity *identity = identity_from_handle(handle); identity != nullptr) {
        remember_source_policy_sources(*identity, metadata_sources);
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
            peer_exchange_disabled_until_metadata.erase(identity);
            peer_exchange_disabled_by_app.erase(identity);
            handle.set_flags(lt::torrent_flags::disable_dht);
            handle.set_flags(lt::torrent_flags::disable_pex);
            handle.set_flags(lt::torrent_flags::disable_lsd);
            if (policy_changed) {
                request_save(handle);
            }
        } else if (peer_exchange_disabled_until_metadata.erase(identity) > 0U
                   && !peer_exchange_disabled_by_app.contains(identity)
                   && !identity->peer_exchange_disabled_by_user
                   && !identity->peer_exchange_locked_by_source
                   && peer_exchange_plugin_enabled
                   && (peer_exchange_enabled_by_default || identity->peer_exchange_enabled_by_user)) {
            handle.unset_flags(lt::torrent_flags::disable_pex);
        }
        changes |= enforce_https_source_policy(handle, identity);
    }
    return valid_info;
}

BridgeResult TTorrentClient::request_files(std::string const &id, DirtyMask &changes)
{
    auto handle = find(id);
    if (!handle) {
        return bridge_error(2, "Torrent not found.");
    }

    BridgeResult const cached_files = cache_file_metadata(*handle, changes);
    if (!cached_files) {
        return cached_files;
    }

    handle->post_file_progress(lt::torrent_handle::piece_granularity);
    return {};
}

BridgeResult TTorrentClient::request_piece_map(std::string const &id, DirtyMask &changes)
{
    auto handle = find(id);
    if (!handle) {
        return bridge_error(2, "Torrent not found.");
    }

    lt::torrent_status const status = handle->status(
        lt::torrent_handle::query_torrent_file
        | lt::torrent_handle::query_pieces
    );
    changes |= cache_piece_map(status);
    return {};
}

int32_t TTorrentClient::copy_trackers(
    std::string const &id,
    std::span<TTorrentTrackerSnapshot> output,
    std::uint64_t *revision_out,
    int32_t *required_count_out
)
{
    std::scoped_lock guard(lock);
    auto const cached = tracker_cache.find(id);
    if (cached == tracker_cache.end()) {
        if (revision_out != nullptr) {
            *revision_out = tracker_revision;
        }
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        return 0;
    }

    std::vector<TTorrentTrackerSnapshot> const &trackers = cached->second.trackers;
    if (revision_out != nullptr) {
        *revision_out = cached->second.revision;
    }
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(trackers.size());
    }

    std::size_t const count = std::min(output.size(), trackers.size());
    if (count > 0) {
        std::ranges::copy_n(
            trackers.begin(),
            static_cast<std::ptrdiff_t>(count),
            output.begin()
        );
    }
    return static_cast<int32_t>(count);
}

int32_t TTorrentClient::copy_web_seeds(
    std::string const &id,
    std::span<TTorrentWebSeedSnapshot> output,
    std::uint64_t *revision_out,
    int32_t *required_count_out
)
{
    std::scoped_lock guard(lock);
    auto const cached = web_seed_cache.find(id);
    if (cached == web_seed_cache.end()) {
        if (revision_out != nullptr) {
            *revision_out = web_seed_revision;
        }
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        return 0;
    }

    std::vector<TTorrentWebSeedSnapshot> const &web_seeds = cached->second.web_seeds;
    if (revision_out != nullptr) {
        *revision_out = cached->second.revision;
    }
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(web_seeds.size());
    }

    std::size_t const count = std::min(output.size(), web_seeds.size());
    if (count > 0) {
        std::ranges::copy_n(
            web_seeds.begin(),
            static_cast<std::ptrdiff_t>(count),
            output.begin()
        );
    }
    return static_cast<int32_t>(count);
}

bool TTorrentClient::copy_web_seed_activity(
    std::string const &id,
    TTorrentWebSeedActivitySnapshot *activity_out,
    std::uint64_t *revision_out
)
{
    std::scoped_lock guard(lock);
    auto const cached = web_seed_cache.find(id);
    if (cached == web_seed_cache.end()) {
        if (revision_out != nullptr) {
            *revision_out = web_seed_revision;
        }
        if (activity_out != nullptr) {
            *activity_out = TTorrentWebSeedActivitySnapshot{};
        }
        return false;
    }

    if (revision_out != nullptr) {
        *revision_out = cached->second.revision;
    }
    if (activity_out != nullptr) {
        *activity_out = cached->second.activity;
    }
    return true;
}

bool TTorrentClient::copy_peer_sources(
    std::string const &id,
    TTorrentPeerSourceSnapshot *sources_out,
    std::uint64_t *revision_out
)
{
    std::scoped_lock guard(lock);
    auto const cached = peer_source_cache.find(id);
    if (cached == peer_source_cache.end()) {
        if (revision_out != nullptr) {
            *revision_out = peer_source_revision;
        }
        if (sources_out != nullptr) {
            *sources_out = TTorrentPeerSourceSnapshot{};
        }
        return false;
    }

    if (revision_out != nullptr) {
        *revision_out = cached->second.revision;
    }
    if (sources_out != nullptr) {
        *sources_out = cached->second.sources;
    }
    return true;
}

int32_t TTorrentClient::copy_files(
    std::string const &id,
    std::span<TTorrentFileSnapshot> output,
    std::uint64_t *revision_out,
    int32_t *required_count_out
)
{
    std::scoped_lock guard(lock);
    auto const cached = file_cache.find(id);
    if (cached == file_cache.end()) {
        if (revision_out != nullptr) {
            *revision_out = file_revision;
        }
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        return 0;
    }

    std::vector<TTorrentFileSnapshot> const &files = cached->second.files;
    if (revision_out != nullptr) {
        *revision_out = cached->second.revision;
    }
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(files.size());
    }

    std::size_t const count = std::min(output.size(), files.size());
    if (count > 0) {
        std::ranges::copy_n(
            files.begin(),
            static_cast<std::ptrdiff_t>(count),
            output.begin()
        );
    }
    return static_cast<int32_t>(count);
}

int32_t TTorrentClient::copy_piece_map(
    std::string const &id,
    TTorrentPieceMapSnapshot *snapshot,
    std::span<std::uint8_t> output,
    std::uint64_t *revision_out,
    int32_t *required_count_out
)
{
    std::scoped_lock guard(lock);
    auto const cached = piece_map_cache.find(id);
    if (cached == piece_map_cache.end()) {
        if (revision_out != nullptr) {
            *revision_out = piece_map_revision;
        }
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        if (snapshot != nullptr) {
            *snapshot = TTorrentPieceMapSnapshot{};
        }
        return 0;
    }

    PieceMapCacheEntry const &entry = cached->second;
    if (revision_out != nullptr) {
        *revision_out = entry.revision;
    }
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(entry.pieces.size());
    }
    if (snapshot != nullptr) {
        *snapshot = entry.snapshot;
    }

    std::size_t const count = std::min(output.size(), entry.pieces.size());
    if (count > 0) {
        std::ranges::copy_n(
            entry.pieces.begin(),
            static_cast<std::ptrdiff_t>(count),
            output.begin()
        );
    }
    return static_cast<int32_t>(count);
}

DirtyMask TTorrentClient::remove_snapshot(lt::info_hash_t const &hashes, std::string_view requested_id)
{
    std::vector<std::string> ids = hash_keys(hashes);
    append_unique(ids, std::string(requested_id));
    {
        std::scoped_lock io_guard(resume_io_lock);
        for (std::string const &hash_id : hash_keys(hashes)) {
            auto const active = active_identity_by_id.find(hash_id);
            if (active != active_identity_by_id.end()) {
                append_unique(ids, active->second->canonical_id);
            }

            auto const removing = removing_identity_by_id.find(hash_id);
            if (removing != removing_identity_by_id.end()) {
                append_unique(ids, removing->second->canonical_id);
            }
        }
    }

    DirtyMask changes = 0;
    for (std::string const &id : ids) {
        changes |= remove_snapshot(id);
    }
    return changes;
}

int32_t TTorrentClient::copy_snapshots(std::span<TTorrentSnapshot> output, std::uint64_t *revision_out, int32_t *required_count_out)
{
    std::scoped_lock guard(lock);
    if (revision_out != nullptr) {
        *revision_out = snapshot_revision;
    }
    std::size_t const capped_count = std::min(
        snapshot_cache.size(),
        static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT)
    );
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(capped_count);
    }

    std::size_t const count = std::min(output.size(), capped_count);
    if (count > 0) {
        std::ranges::copy_n(snapshot_cache.begin(), static_cast<std::ptrdiff_t>(count), output.begin());
    }
    return static_cast<int32_t>(count);
}

int32_t TTorrentClient::copy_tracker_hosts(
    std::span<TTorrentTrackerHostSnapshot> output,
    std::uint64_t *revision_out,
    int32_t *required_count_out
)
{
    std::scoped_lock guard(lock);
    if (revision_out != nullptr) {
        *revision_out = tracker_host_revision;
    }

    std::size_t required_count = 0;
    for (auto const &[id, hosts] : tracker_host_cache) {
        static_cast<void>(id);
        required_count += hosts.size();
        if (required_count >= static_cast<std::size_t>(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT)) {
            required_count = static_cast<std::size_t>(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT);
            break;
        }
    }
    if (required_count_out != nullptr) {
        *required_count_out = static_cast<int32_t>(required_count);
    }

    std::size_t copied = 0;
    for (TTorrentSnapshot const &snapshot : snapshot_cache) {
        if (copied >= output.size() || copied >= static_cast<std::size_t>(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT)) {
            break;
        }
        auto const cached = tracker_host_cache.find(snapshot.id);
        if (cached == tracker_host_cache.end()) {
            continue;
        }
        for (std::string const &host : cached->second) {
            if (copied >= output.size() || copied >= static_cast<std::size_t>(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT)) {
                break;
            }
            TTorrentTrackerHostSnapshot row{};
            copy_string(std::span{row.torrent_id}, std::string_view(snapshot.id));
            copy_string(std::span{row.host}, host);
            *std::next(output.begin(), static_cast<std::ptrdiff_t>(copied)) = row;
            ++copied;
        }
    }
    return static_cast<int32_t>(copied);
}

DirtyMask TTorrentClient::queue_alert_error(std::string message)
{
    if (pending_alert_errors.size() >= kMaxPendingAlertErrors) {
        pending_alert_errors.erase(pending_alert_errors.begin());
    }
    pending_alert_errors.push_back(std::move(message));
    return TTORRENT_DIRTY_ERRORS;
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
    return TTORRENT_DIRTY_NETWORK;
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
    return TTORRENT_DIRTY_NETWORK;
}

DirtyMask TTorrentClient::record_network_requested(bool blocked)
{
    requested_network_blocked = blocked;
    has_listener = false;
    listen_port = 0;
    listen_endpoint.clear();
    last_network_error.clear();
    ++requested_network_revision;
    submitted_network_revision = requested_network_revision;
    return TTORRENT_DIRTY_NETWORK;
}

DirtyMask TTorrentClient::record_network_blocked() { return record_network_requested(true); }

[[nodiscard]] TTorrentNetworkStatus TTorrentClient::network_status() const
{
    TTorrentNetworkStatus status{};
    status.requested_revision = requested_network_revision;
    status.submitted_revision = submitted_network_revision;
    status.listen_port = listen_port;
    status.network_blocked = bridge_bool(requested_network_blocked);
    status.has_listener = bridge_bool(has_listener);
    copy_string(std::span{status.endpoint}, listen_endpoint);
    copy_string(std::span{status.last_error}, last_network_error);
    return status;
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
