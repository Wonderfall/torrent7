#include "TorrentBridgeInternal.hpp"

constexpr int kUnlimitedTorrentCountLimit = (1 << 24) - 1;

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
{
    std::vector<QueueOrderingEntry> entries;
    std::set<TorrentIdentity *> seen;
    for (auto const &[id, handle] : client.handle_by_id) {
        static_cast<void>(id);
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
                                     LockedChangePublisher &publisher)
{
    for (lt::torrent_handle const &handle : handles) {
        client.request_save(handle, kPolicyResumeSaveFlags);
        publisher.add(client.cache_snapshot(handle));
    }
}

std::vector<lt::torrent_handle> apply_queue_order(std::span<QueueOrderingEntry> entries)
{
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
            ignore_shutdown_failure();
        }

        if (changed) {
            append_unique_handle_by_identity(changed_handles, entry.handle);
        }
        ++position;
        ++rank;
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

std::vector<lt::torrent_handle> TTorrentClient::apply_queue_priority_order_locked()
{
    std::vector<QueueOrderingEntry> entries = queue_ordering_entries(*this);
    return apply_queue_order(entries);
}

DirtyMask block_network_locked(TTorrentClient &client)
{
    client.session.pause();

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
    client.session.apply_settings(std::move(settings));

    client.session.pause();
    DirtyMask changes = client.record_network_blocked();
    client.request_snapshot_update_locked();
    return changes;
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

BridgeResult require_authorized_save_path(
    TTorrentClient const &client,
    std::string const &normalized_save_path
)
{
    if (!client.authorized_save_paths.contains(normalized_save_path)) {
        return bridge_error(1, "The save path is not authorized.");
    }
    return {};
}

AuthorizedSavePathResult authorized_save_paths_from_c_buffer(
    std::uint8_t const *authorized_save_paths_blob,
    int32_t const authorized_save_paths_blob_size
)
{
    if (authorized_save_paths_blob_size < 0
        || authorized_save_paths_blob_size > TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save path list has an invalid size.",
        });
    }

    bool const has_authorized_save_paths_blob = authorized_save_paths_blob != nullptr;
    bool const has_authorized_save_paths_bytes = authorized_save_paths_blob_size != 0;
    if (has_authorized_save_paths_blob != has_authorized_save_paths_bytes) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save path list pointer and size do not match.",
        });
    }

    return parse_authorized_save_paths_blob(
        input_span_from_c_buffer(authorized_save_paths_blob, authorized_save_paths_blob_size)
    );
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
{
    client.dht_enabled_by_default = use_dht_by_default;
    SourcePolicyApplicationResult result;
    std::set<TorrentIdentity *> visited;
    for (auto const &entry : client.active_identity_by_id) {
        TorrentIdentity *identity = entry.second;
        if (identity == nullptr) {
            continue;
        }

        auto handle_iterator = client.handle_by_id.find(entry.first);
        if (handle_iterator == client.handle_by_id.end()) {
            continue;
        }
        if (!visited.insert(identity).second) {
            continue;
        }

        lt::torrent_handle &handle = handle_iterator->second;
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
{
    client.lsd_enabled_by_default = use_lsd_by_default;
    SourcePolicyApplicationResult result;
    std::set<TorrentIdentity *> visited;
    for (auto const &entry : client.active_identity_by_id) {
        TorrentIdentity *identity = entry.second;
        if (identity == nullptr) {
            continue;
        }

        auto handle_iterator = client.handle_by_id.find(entry.first);
        if (handle_iterator == client.handle_by_id.end()) {
            continue;
        }
        if (!visited.insert(identity).second) {
            continue;
        }

        lt::torrent_handle &handle = handle_iterator->second;
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
{
    client.peer_exchange_enabled_by_default = use_peer_exchange_by_default;
    SourcePolicyApplicationResult result;
    std::set<TorrentIdentity *> visited;
    for (auto const &entry : client.active_identity_by_id) {
        TorrentIdentity *identity = entry.second;
        if (identity == nullptr) {
            continue;
        }

        auto handle_iterator = client.handle_by_id.find(entry.first);
        if (handle_iterator == client.handle_by_id.end()) {
            continue;
        }
        if (!visited.insert(identity).second) {
            continue;
        }

        lt::torrent_handle &handle = handle_iterator->second;
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

DirtyMask TTorrentClient::enforce_https_source_policy(lt::torrent_handle const &handle, TorrentIdentity *identity)
{
    bool const require_trackers = requires_https_trackers(identity);
    bool const require_web_seeds = requires_https_web_seeds(identity);
    if ((!require_trackers && !require_web_seeds) || !handle.is_valid()) {
        return {};
    }

    DirtyMask changes = 0;
    bool changed = false;

    if (require_trackers) {
        std::vector<lt::announce_entry> const trackers = handle.trackers();
        std::vector<lt::announce_entry> https_trackers;
        https_trackers.reserve(trackers.size());
        std::ranges::copy_if(trackers, std::back_inserter(https_trackers), [](lt::announce_entry const &entry) {
            return is_https_url(entry.url);
        });
        if (https_trackers.size() != trackers.size()) {
            handle.replace_trackers(https_trackers);
            changes |= cache_trackers(handle, https_trackers);
            changed = true;
        }
    }

    if (require_web_seeds) {
        for (std::string const &url : handle.url_seeds()) {
            if (!is_https_url(url)) {
                handle.remove_url_seed(url);
                changed = true;
            }
        }
    }

    if (changed && require_web_seeds) {
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
    changes |= clear_peer_cache_if_restricted(handle, identity);
    if (changed) {
        request_save(handle);
    }

    return changes;
}

DirtyMask TTorrentClient::restore_metadata_source_policy(lt::torrent_handle const &handle, TorrentIdentity const *identity)
{
    if (!handle.is_valid()) {
        return {};
    }

    if (identity == nullptr
        || (identity->source_trackers.empty() && identity->source_web_seeds.empty())) {
        return {};
    }

    DirtyMask changes = 0;
    bool changed = false;

    bool const require_trackers = requires_https_trackers(identity);
    bool const require_web_seeds = requires_https_web_seeds(identity);

    auto tracker_allowed = [require_trackers](lt::announce_entry const &tracker) noexcept {
        return !require_trackers || is_https_url(tracker.url);
    };
    auto web_seed_allowed = [require_web_seeds](std::string const &web_seed) noexcept {
        return !require_web_seeds || is_https_url(web_seed);
    };

    std::vector<lt::announce_entry> const current_trackers = handle.trackers();
    std::vector<lt::announce_entry> restored_trackers;
    restored_trackers.reserve(current_trackers.size());
    std::set<std::string> tracker_urls;
    for (lt::announce_entry const &tracker : current_trackers) {
        if (tracker_allowed(tracker) && tracker_urls.insert(tracker.url).second) {
            restored_trackers.push_back(tracker);
        }
    }
    for (lt::announce_entry const &tracker : identity->source_trackers) {
        if (restored_trackers.size() < static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT)
            && tracker_allowed(tracker)
            && tracker_urls.insert(tracker.url).second) {
            restored_trackers.push_back(tracker);
        }
    }
    bool const trackers_changed = restored_trackers.size() != current_trackers.size()
        || !std::ranges::equal(restored_trackers, current_trackers, [](auto const &left, auto const &right) {
            return left.url == right.url && left.tier == right.tier;
        });

    std::set<std::string> current_url_seeds = handle.url_seeds();
    bool web_seeds_changed = false;
    for (std::string const &web_seed : identity->source_web_seeds) {
        if (current_url_seeds.size() >= static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT)) {
            break;
        }
        if (web_seed_allowed(web_seed) && current_url_seeds.insert(web_seed).second) {
            web_seeds_changed = true;
            changed = true;
        }
    }

    lt::add_torrent_params restored_sources;
    for (lt::announce_entry const &tracker : restored_trackers) {
        restored_sources.trackers.push_back(tracker.url);
        restored_sources.tracker_tiers.push_back(tracker.tier);
    }
    restored_sources.url_seeds.assign(current_url_seeds.begin(), current_url_seeds.end());
    BridgeResult const valid_sources = validate_torrent_sources(restored_sources);
    if (!valid_sources) {
        changes |= remove_torrent_with_invalid_metadata(handle, valid_sources.error().message);
        return changes;
    }

    if (trackers_changed) {
        handle.replace_trackers(restored_trackers);
        changes |= cache_trackers(handle, restored_trackers);
        changed = true;
    }

    if (web_seeds_changed) {
        std::set<std::string> const existing_url_seeds = handle.url_seeds();
        for (std::string const &url : current_url_seeds) {
            if (!existing_url_seeds.contains(url)) {
                handle.add_url_seed(url);
            }
        }
        if (std::optional<std::string> const cache_id = cache_id_for_handle(handle)) {
            changes |= cache_web_seeds(*cache_id, current_url_seeds);
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

bool TTorrentClient::requires_https_trackers(TorrentIdentity const *identity) const noexcept
{
    if (identity == nullptr) {
        return require_https_trackers;
    }
    return identity->requires_https_trackers || (require_https_trackers && !identity->allows_non_https_trackers);
}

bool TTorrentClient::requires_https_web_seeds(TorrentIdentity const *identity) const noexcept
{
    if (identity == nullptr) {
        return require_https_web_seeds;
    }
    return identity->requires_https_web_seeds || (require_https_web_seeds && !identity->allows_non_https_web_seeds);
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
    policy.require_https_trackers = bridge_bool(requires_https_trackers(identity));
    policy.require_https_web_seeds = bridge_bool(requires_https_web_seeds(identity));
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
    bool enabled
)
{
    if (identity == nullptr || !handle.is_valid()) {
        return {};
    }

    std::shared_ptr<lt::torrent_info const> const torrent_file = handle.torrent_file();
    bool const private_torrent = torrent_file && torrent_file->is_valid() && torrent_file->priv();
    bool const dht_locked = private_torrent || identity->dht_locked_by_source;
    bool const peer_exchange_locked = private_torrent || identity->peer_exchange_locked_by_source;
    bool const lsd_locked = private_torrent || identity->lsd_locked_by_source;
    bool const metadata_pending = metadata_validation_pending.contains(identity);
    TTorrentSourcePolicy const current_policy = source_policy(handle, identity);
    lt::torrent_flags_t const original_flags = handle.flags();
    bool const updates_dht = field == TTORRENT_SOURCE_POLICY_ENABLE_DHT
        || field == TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT;
    bool const should_force_dht_announce =
        updates_dht
        && !dht_locked
        && enabled
        && !(metadata_pending
            ? bridge_bool(current_policy.allow_pre_metadata_dht)
            : bridge_bool(current_policy.enable_dht))
        && dht_node_enabled
        && !requested_network_blocked
        && !static_cast<bool>(original_flags & lt::torrent_flags::paused);
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

    if (field == TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_TRACKERS) {
        identity->requires_https_trackers = enabled;
        identity->allows_non_https_trackers = !enabled && require_https_trackers;
    }

    if (field == TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_WEB_SEEDS) {
        identity->requires_https_web_seeds = enabled;
        identity->allows_non_https_web_seeds = !enabled && require_https_web_seeds;
    }

    DirtyMask changes = 0;
    if (field == TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_TRACKERS
        || field == TTORRENT_SOURCE_POLICY_REQUIRE_HTTPS_WEB_SEEDS) {
        changes |= restore_metadata_source_policy(handle, identity);
        changes |= enforce_https_source_policy(handle, identity);
    }
    if (updates_dht || field == TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE) {
        changes |= clear_peer_cache_if_restricted(handle, identity);
    }
    if (should_force_dht_announce) {
        handle.force_dht_announce();
    }
    if (should_force_lsd_announce) {
        handle.force_lsd_announce();
    }
    return changes;
}

DirtyMask TTorrentClient::apply_https_source_policy_locked()
{
    DirtyMask changes = 0;
    std::set<TorrentIdentity *> visited;
    for (auto const &entry : active_identity_by_id) {
        TorrentIdentity *identity = entry.second;
        if (identity == nullptr || !visited.insert(identity).second) {
            continue;
        }

        auto const handle_iterator = handle_by_id.find(entry.first);
        if (handle_iterator == handle_by_id.end()) {
            continue;
        }

        changes |= restore_metadata_source_policy(handle_iterator->second, identity);
        changes |= enforce_https_source_policy(handle_iterator->second, identity);
    }
    return changes;
}

extern "C" const char *TorrentBridgeLibtorrentVersion(void) noexcept
{
    return LIBTORRENT_VERSION;
}

extern "C" int32_t TorrentBridgeInspectMagnetSources(
    const char *magnet_uri,
    TTorrentSourceSecurityInspection *inspection
) noexcept
{
    if (inspection != nullptr) {
        *inspection = {};
    }

    return run_bridge_operation({}, 3, [&]() -> BridgeResult {
        if (magnet_uri == nullptr || inspection == nullptr) {
            return bridge_error(1, "Missing magnet URI or source inspection output.");
        }

        TorrentLoadResult parsed = parse_sanitized_magnet(c_string_view(magnet_uri));
        if (!parsed) {
            return std::unexpected(parsed.error());
        }

        BridgeResult const valid_sources = validate_torrent_sources(*parsed);
        if (!valid_sources) {
            return valid_sources;
        }

        *inspection = torrent_source_counts(*parsed);
        return {};
    });
}

extern "C" TTorrentClient *TorrentClientCreateWithError(
    const char *state_path,
    uint8_t enable_pex_plugin,
    const uint8_t *authorized_save_paths_blob,
    int32_t authorized_save_paths_blob_size,
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
        AuthorizedSavePathResult authorized_save_paths = authorized_save_paths_from_c_buffer(
            authorized_save_paths_blob,
            authorized_save_paths_blob_size
        );
        if (!authorized_save_paths) {
            copy_error(error_buffer, authorized_save_paths.error().message);
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
            std::move(*authorized_save_paths)
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
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }

        AuthorizedSavePathResult authorized_save_paths = authorized_save_paths_from_c_buffer(
            authorized_save_paths_blob,
            authorized_save_paths_blob_size
        );
        if (!authorized_save_paths) {
            return std::unexpected(authorized_save_paths.error());
        }

        std::scoped_lock guard(client->lock);
        client->authorized_save_paths.swap(*authorized_save_paths);
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
                                          const TTorrentAddOptions *options,
                                          char *added_id_out, int32_t added_id_capacity,
                                          char *error_out, int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    std::span<char> const added_id_buffer = output_buffer(added_id_out, added_id_capacity);
    copy_string_dynamic(added_id_buffer, "");
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 4, [&]() -> BridgeResult {
        if (client == nullptr || magnet_uri == nullptr || save_path == nullptr || options == nullptr) {
            return bridge_error(1, "Missing torrent client, magnet URI, save path, or add options.");
        }
        TTorrentAddOptions const add_options = *options;
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
        BridgeResult const authorized_save_path = require_authorized_save_path(
            *client,
            *normalized_save_path
        );
        if (!authorized_save_path) {
            return authorized_save_path;
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

        bool const allows_non_https_trackers = bridge_bool(add_options.allow_non_https_trackers);
        bool const allows_non_https_web_seeds = bridge_bool(add_options.allow_non_https_web_seeds);
        bool const require_https_trackers = client->require_https_trackers && !allows_non_https_trackers;
        bool const require_https_web_seeds = client->require_https_web_seeds && !allows_non_https_web_seeds;
        if (require_https_trackers || require_https_web_seeds) {
            static_cast<void>(filter_non_https_sources(params, require_https_trackers, require_https_web_seeds));
        }
        BridgeResult const valid_sources = validate_torrent_sources(params);
        if (!valid_sources) {
            return valid_sources;
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
            params.flags |= lt::torrent_flags::block_non_global_peers;
        }
        prepare_add_params(
            params,
            *normalized_save_path,
            bridge_bool(add_options.starts_paused),
            enable_peer_exchange_value && !metadata_pending
        );
        bool const peer_exchange_disabled_by_app =
            !enable_peer_exchange_value && !peer_exchange_was_disabled && !peer_exchange_locked_by_source;
        if (client->delete_pending_for_hashes(params.info_hashes)) {
            return bridge_error(3, "Torrent data deletion is still pending.");
        }
        TorrentIdentity *identity = client->attach_identity(params);
        identity->allows_non_https_trackers = allows_non_https_trackers;
        identity->allows_non_https_web_seeds = allows_non_https_web_seeds;
        identity->queue_priority = add_options.queue_priority;
        identity->dht_locked_by_source = dht_locked_by_source;
        identity->lsd_locked_by_source = lsd_locked_by_source;
        identity->peer_exchange_locked_by_source = peer_exchange_locked_by_source;
        identity->allow_pre_metadata_dht = allow_pre_metadata_dht;
        identity->intended_default_dont_download = intended_default_dont_download;
        identity->intended_file_priorities = std::move(intended_file_priorities);
        remember_source_policy_sources(*identity, source_params);
        lt::add_torrent_params resume_params = params;
        lt::error_code add_error;
        lt::torrent_handle handle = client->session.add_torrent(std::move(params), add_error);
        if (add_error) {
            client->discard_unpublished_identity(identity);
            return bridge_error(3, add_error.message());
        }

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
        client->apply_queue_priority_order_locked();
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
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

TorrentLoadResult load_torrent_data_from_c_buffer(char const *torrent_data, int32_t torrent_data_size)
{
    if (torrent_data == nullptr) {
        return std::unexpected(BridgeError{.code = 1, .message = "Missing torrent data."});
    }
    if (torrent_data_size < 0) {
        return std::unexpected(BridgeError{.code = 1, .message = "Invalid torrent data size."});
    }

    return load_torrent_data(input_span_from_c_buffer(torrent_data, torrent_data_size));
}

template <typename LoadTorrent>
int32_t add_torrent_file_data_with_priorities(
    TTorrentClient *client,
    const char *save_path,
    const TTorrentAddOptions *options,
    const TTorrentFilePriorityEntry *file_priorities,
    int32_t file_priority_count,
    char *added_id_out,
    int32_t added_id_capacity,
    char *error_out,
    int32_t error_capacity,
    LoadTorrent load_torrent
) noexcept
{
    WakeCallbackInvocation wake;
    std::span<char> const added_id_buffer = output_buffer(added_id_out, added_id_capacity);
    copy_string_dynamic(added_id_buffer, "");
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || save_path == nullptr || options == nullptr) {
            return bridge_error(1, "Missing torrent client, save path, or add options.");
        }
        TTorrentAddOptions const add_options = *options;
        if (file_priority_count < -1) {
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
        if (file_priority_count > params.ti->layout().num_files()) {
            return bridge_error(2, "The file priorities are invalid.");
        }

        std::optional<std::span<TTorrentFilePriorityEntry const>> priority_entries;
        if (file_priority_count >= 0) {
            priority_entries = input_span_from_c_buffer(file_priorities, file_priority_count);
        }
        BridgeResult const valid_file_policy = apply_file_priorities(params, priority_entries);
        if (!valid_file_policy) {
            return valid_file_policy;
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const authorized_save_path = require_authorized_save_path(
            *client,
            *normalized_save_path
        );
        if (!authorized_save_path) {
            return authorized_save_path;
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
        bool const allows_non_https_trackers = bridge_bool(add_options.allow_non_https_trackers);
        bool const allows_non_https_web_seeds = bridge_bool(add_options.allow_non_https_web_seeds);
        bool const require_https_trackers = client->require_https_trackers && !allows_non_https_trackers;
        bool const require_https_web_seeds = client->require_https_web_seeds && !allows_non_https_web_seeds;
        if (require_https_trackers || require_https_web_seeds) {
            static_cast<void>(filter_non_https_sources(params, require_https_trackers, require_https_web_seeds));
        }
        BridgeResult const valid_sources = validate_torrent_sources(params);
        if (!valid_sources) {
            return valid_sources;
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
        bool const peer_exchange_disabled_by_app =
            !enable_peer_exchange_value && !peer_exchange_was_disabled && !peer_exchange_locked_by_source;
        if (client->delete_pending_for_hashes(params.info_hashes)) {
            return bridge_error(2, "Torrent data deletion is still pending.");
        }

        TorrentIdentity *identity = client->attach_identity(params);
        identity->allows_non_https_trackers = allows_non_https_trackers;
        identity->allows_non_https_web_seeds = allows_non_https_web_seeds;
        identity->queue_priority = add_options.queue_priority;
        identity->dht_locked_by_source = dht_locked_by_source;
        identity->lsd_locked_by_source = lsd_locked_by_source;
        identity->peer_exchange_locked_by_source = peer_exchange_locked_by_source;
        remember_source_policy_sources(*identity, source_params);
        lt::add_torrent_params resume_params = params;
        lt::error_code add_error;
        lt::torrent_handle handle = client->session.add_torrent(std::move(params), add_error);
        if (add_error) {
            client->discard_unpublished_identity(identity);
            return bridge_error(2, add_error.message());
        }

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
        if (dht_disabled_by_app) {
            client->dht_disabled_by_app.insert(identity);
        }
        if (lsd_disabled_by_app) {
            client->lsd_disabled_by_app.insert(identity);
        }
        if (peer_exchange_disabled_by_app) {
            client->peer_exchange_disabled_by_app.insert(identity);
        }
        client->apply_queue_priority_order_locked();
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
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientAddTorrentFileData(
    TTorrentClient *client,
    const char *torrent_data,
    int32_t torrent_data_size,
    const char *save_path,
    const TTorrentAddOptions *options,
    char *added_id_out,
    int32_t added_id_capacity,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return add_torrent_file_data_with_priorities(
        client,
        save_path,
        options,
        nullptr,
        -1,
        added_id_out,
        added_id_capacity,
        error_out,
        error_capacity,
        [torrent_data, torrent_data_size]() {
            return load_torrent_data_from_c_buffer(torrent_data, torrent_data_size);
        }
    );
}

extern "C" int32_t TorrentClientAddTorrentFileDataWithPriorities(
    TTorrentClient *client,
    const char *torrent_data,
    int32_t torrent_data_size,
    const char *save_path,
    const TTorrentAddOptions *options,
    const TTorrentFilePriorityEntry *file_priorities,
    int32_t file_priority_count,
    char *added_id_out,
    int32_t added_id_capacity,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return add_torrent_file_data_with_priorities(
        client,
        save_path,
        options,
        file_priorities,
        file_priority_count,
        added_id_out,
        added_id_capacity,
        error_out,
        error_capacity,
        [torrent_data, torrent_data_size]() {
            return load_torrent_data_from_c_buffer(torrent_data, torrent_data_size);
        }
    );
}

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

extern "C" int32_t TorrentClientPreviewTorrentFileData(
    TTorrentClient *client,
    const char *torrent_data,
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

extern "C" int32_t TorrentClientCopySourcePolicy(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentSourcePolicy *policy,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    if (policy != nullptr) {
        *policy = TTorrentSourcePolicy{};
    }

    return run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr || policy == nullptr) {
            return bridge_error(1, "Missing torrent client, torrent id, or source policy.");
        }

        std::scoped_lock guard(client->lock);
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        *policy = client->source_policy(*handle, identity_from_handle(*handle));
        return {};
    });
}

extern "C" int32_t TorrentClientSetSourcePolicyField(
    TTorrentClient *client,
    const char *torrent_id,
    int32_t field,
    uint8_t enabled,
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
        if (enabled > 1U) {
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
            bridge_bool(enabled)
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

extern "C" int32_t TorrentClientCopyTorrentOptions(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentOptions *options,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    if (options != nullptr) {
        *options = TTorrentOptions{};
    }

    return run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr || options == nullptr) {
            return bridge_error(1, "Missing torrent client, torrent id, or options.");
        }

        std::scoped_lock guard(client->lock);
        auto handle = client->find(std::string(c_string_view(torrent_id)));
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        TorrentIdentity const *identity = identity_from_handle(*handle);
        options->download_rate_limit = handle->download_limit();
        options->upload_rate_limit = handle->upload_limit();
        options->max_uploads = normalized_torrent_count_limit(handle->max_uploads());
        options->max_connections = normalized_torrent_count_limit(handle->max_connections());
        options->queue_priority = identity == nullptr ? TTORRENT_QUEUE_PRIORITY_NORMAL : identity->queue_priority;
        return {};
    });
}

extern "C" int32_t TorrentClientSetTorrentOptions(
    TTorrentClient *client,
    const char *torrent_id,
    const TTorrentOptions *options,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || torrent_id == nullptr || options == nullptr) {
            return bridge_error(1, "Missing torrent client, torrent id, or options.");
        }
        if (options->download_rate_limit < -1 || options->upload_rate_limit < -1) {
            return bridge_error(1, "Torrent rate limits must be unlimited or nonnegative.");
        }
        if (!is_valid_torrent_count_limit(options->max_uploads)
            || !is_valid_torrent_count_limit(options->max_connections)) {
            return bridge_error(1, "Torrent count limits must be unlimited or at least 2.");
        }
        if (!is_valid_queue_priority(options->queue_priority)) {
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

        if (handle->download_limit() != options->download_rate_limit) {
            handle->set_download_limit(options->download_rate_limit);
        }
        if (handle->upload_limit() != options->upload_rate_limit) {
            handle->set_upload_limit(options->upload_rate_limit);
        }
        if (normalized_torrent_count_limit(handle->max_uploads()) != options->max_uploads) {
            handle->set_max_uploads(options->max_uploads);
        }
        if (normalized_torrent_count_limit(handle->max_connections()) != options->max_connections) {
            handle->set_max_connections(options->max_connections);
        }
        std::vector<lt::torrent_handle> queue_handles_to_save;
        bool queue_priority_changed = false;
        if (identity->queue_priority != options->queue_priority) {
            identity->queue_priority = options->queue_priority;
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

        std::vector<QueueOrderingEntry> entries = queue_ordering_entries(*client);
        if (move_queue_entry(entries, identity, move)) {
            std::vector<lt::torrent_handle> queue_handles_to_save = apply_queue_order(entries);
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

extern "C" int32_t TorrentClientCopyWebSeedActivity(TTorrentClient *client, const char *torrent_id,
                                                    TTorrentWebSeedActivitySnapshot *activity,
                                                    uint64_t *revision_out) noexcept
{
    if (activity != nullptr) {
        *activity = TTorrentWebSeedActivitySnapshot{};
    }
    if (revision_out != nullptr) {
        *revision_out = 0;
    }
    if (client == nullptr || torrent_id == nullptr) {
        return 0;
    }

    try {
        return client->copy_web_seed_activity(std::string(c_string_view(torrent_id)), activity, revision_out) ? 1 : 0;
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientCopyPeerSources(TTorrentClient *client, const char *torrent_id,
                                                TTorrentPeerSourceSnapshot *sources,
                                                uint64_t *revision_out) noexcept
{
    if (sources != nullptr) {
        *sources = TTorrentPeerSourceSnapshot{};
    }
    if (revision_out != nullptr) {
        *revision_out = 0;
    }
    if (client == nullptr || torrent_id == nullptr) {
        return 0;
    }

    try {
        return client->copy_peer_sources(std::string(c_string_view(torrent_id)), sources, revision_out) ? 1 : 0;
    } catch (...) {
        return 0;
    }
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

extern "C" int32_t TorrentClientTakeRemovalResult(TTorrentClient *client, std::uint64_t request_token,
                                                   TTorrentRemovalResult *result, char *error_out,
                                                   int32_t error_capacity) noexcept
{
    if (result != nullptr) {
        *result = {};
    }
    return run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || result == nullptr) {
            return bridge_error(1, "Missing torrent client or removal result output.");
        }

        std::scoped_lock guard(client->lock);
        return client->take_removal_result(request_token, result);
    });
}

extern "C" int32_t TorrentClientApplySettings(TTorrentClient *client, TTorrentSessionSettings const *requested,
                                              char *error_out, int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || requested == nullptr) {
            return bridge_error(1, "Missing torrent client or settings.");
        }

        std::string_view const network_interface = c_string_view(requested->required_network_interface);
        bool const accept_incoming_connections = bridge_bool(requested->accept_incoming_connections);
        bool const enable_port_forwarding = bridge_bool(requested->enable_port_forwarding);
        bool const enable_dht = bridge_bool(requested->enable_dht);
        bool const use_dht_by_default = bridge_bool(requested->use_dht_by_default);
        bool const enable_lsd = bridge_bool(requested->enable_lsd);
        bool const use_lsd_by_default = bridge_bool(requested->use_lsd_by_default);
        bool const use_pex_by_default = bridge_bool(requested->use_pex_by_default);
        bool const require_https_trackers = bridge_bool(requested->require_https_trackers);
        bool const require_https_web_seeds = bridge_bool(requested->require_https_web_seeds);
        bool const anonymous_mode = bridge_bool(requested->anonymous_mode);
        bool const network_blocked = bridge_bool(requested->network_blocked);
        if (!is_valid_encryption_policy(requested->encryption_policy)) {
            return bridge_error(1, "Invalid encryption policy.");
        }
        if (!network_blocked) {
            static_cast<void>(network_binding(network_interface));
        }
        std::string const listen_interface_settings =
            listen_interfaces(requested->incoming_port, network_interface, network_blocked);
        std::string const outgoing_interface_settings =
            outgoing_interfaces(network_interface, network_blocked);

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        if (network_blocked) {
            publisher.add(block_network_locked(*client));
        }

        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }

        bool const should_resume_session = client->requested_network_blocked && !network_blocked;
        if (network_blocked) {
            client->session.pause();
        }
        client->dht_node_enabled = enable_dht;
        SourcePolicyApplicationResult source_policy_application;
        add_policy_result(source_policy_application, apply_dht_policy_locked(*client, use_dht_by_default));
        client->lsd_service_enabled = enable_lsd;
        add_policy_result(source_policy_application, apply_lsd_policy_locked(*client, use_lsd_by_default));

        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces, listen_interface_settings);
        settings.set_str(lt::settings_pack::outgoing_interfaces, outgoing_interface_settings);
        settings.set_int(lt::settings_pack::download_rate_limit, requested->download_rate_limit);
        settings.set_int(lt::settings_pack::upload_rate_limit, requested->upload_rate_limit);
        settings.set_int(lt::settings_pack::active_downloads, requested->active_downloads);
        settings.set_int(lt::settings_pack::active_seeds, requested->active_seeds);
        settings.set_int(lt::settings_pack::active_limit, requested->active_limit);
        settings.set_bool(lt::settings_pack::dont_count_slow_torrents, false);
        settings.set_int(lt::settings_pack::share_ratio_limit, requested->share_ratio_limit);
        settings.set_int(lt::settings_pack::seed_time_limit, requested->seed_time_limit);
        settings.set_bool(lt::settings_pack::enable_upnp, !network_blocked && enable_port_forwarding);
        settings.set_bool(lt::settings_pack::enable_natpmp, !network_blocked && enable_port_forwarding);
        settings.set_bool(lt::settings_pack::enable_dht, !network_blocked && enable_dht);
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
        settings.set_int(lt::settings_pack::out_enc_policy, encryption_policy(requested->encryption_policy));
        settings.set_int(lt::settings_pack::in_enc_policy, encryption_policy(requested->encryption_policy));
        settings.set_int(lt::settings_pack::allowed_enc_level, static_cast<int>(lt::settings_pack::pe_both));
        settings.set_bool(lt::settings_pack::prefer_rc4, false);
        client->session.apply_settings(std::move(settings));
        add_policy_result(source_policy_application, apply_peer_exchange_policy_locked(*client, use_pex_by_default));
        client->require_https_trackers = require_https_trackers;
        client->require_https_web_seeds = require_https_web_seeds;
        publisher.add(source_policy_application.changes);
        request_policy_saves(*client, source_policy_application.handles_to_save);
        publisher.add(client->apply_https_source_policy_locked());

        if (network_blocked) {
            client->session.pause();
            publisher.add(client->record_network_blocked());
        } else {
            publisher.add(client->record_network_requested(false));
            if (should_resume_session) {
                client->session.resume();
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
        publisher.add(block_network_locked(*client));
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientCopyNetworkStatus(
    TTorrentClient *client,
    TTorrentNetworkStatus *status
) noexcept
{
    if (status != nullptr) {
        *status = TTorrentNetworkStatus{};
    }
    if (client == nullptr || status == nullptr) {
        return 0;
    }

    try {
        std::scoped_lock guard(client->lock);
        *status = client->network_status();
        return 1;
    } catch (...) {
        *status = TTorrentNetworkStatus{};
        return 0;
    }
}

extern "C" int32_t TorrentClientCopyHealth(
    TTorrentClient *client,
    TTorrentBridgeHealth *health
) noexcept
{
    if (health != nullptr) {
        *health = TTorrentBridgeHealth{};
    }
    if (client == nullptr || health == nullptr) {
        return 0;
    }

    try {
        std::scoped_lock guard(client->lock);
        *health = client->health_status();
        return 1;
    } catch (...) {
        *health = TTorrentBridgeHealth{};
        return 0;
    }
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
