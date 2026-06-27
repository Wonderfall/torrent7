#include "TorrentBridgeInternal.hpp"

bool TTorrentClient::identity_is_referenced_locked(TorrentIdentity const *identity) const
{
    if (identity == nullptr) {
        return false;
    }

    auto const references_identity = [identity](auto const &entry) {
        return entry.second == identity;
    };
    return std::ranges::any_of(active_identity_by_id, references_identity)
        || std::ranges::any_of(removing_identity_by_id, references_identity)
        || std::ranges::any_of(unidentified_removing_identities, [identity](TorrentIdentity const *entry) {
            return entry == identity;
        });
}

void TTorrentClient::retire_identity_if_unreferenced_locked(TorrentIdentity *identity)
{
    if (identity == nullptr || identity_is_referenced_locked(identity)) {
        return;
    }

    auto const existing = std::ranges::find_if(torrent_identities, [identity](auto const &owned) {
        return owned.get() == identity;
    });
    if (existing == torrent_identities.end()) {
        return;
    }

    dht_disabled_by_app.erase(identity);
    lsd_disabled_by_app.erase(identity);
    peer_exchange_disabled_by_app.erase(identity);
    peer_exchange_disabled_until_metadata.erase(identity);
    retired_torrent_identities.push_back(std::move(*existing));
    torrent_identities.erase(existing);
}

ResumePolicySnapshot TTorrentClient::resume_policy_snapshot_locked(TorrentIdentity *identity) const
{
    ResumePolicySnapshot policy = resume_policy_snapshot(identity, false, false, false, false);
    if (identity == nullptr) {
        return policy;
    }

    policy.peer_exchange_pending_metadata = peer_exchange_disabled_until_metadata.contains(identity);
    policy.app_disabled_dht = dht_disabled_by_app.contains(identity);
    policy.app_disabled_lsd = lsd_disabled_by_app.contains(identity);
    policy.app_disabled_peer_exchange = peer_exchange_disabled_by_app.contains(identity);
    return policy;
}

TorrentIdentityState TTorrentClient::reconcile_identity_for_hashes_locked(std::vector<std::string> const &ids, TorrentIdentity *identity)
{
    if (identity == nullptr) {
        return TorrentIdentityState::stale;
    }

    bool matched_current_alias = false;
    for (std::string const &id : ids) {
        auto const active = active_identity_by_id.find(id);
        if (active == active_identity_by_id.end()) {
            continue;
        }

        if (active->second != identity) {
            return TorrentIdentityState::stale;
        }
        matched_current_alias = true;
    }

    if (!matched_current_alias) {
        return TorrentIdentityState::absent;
    }

    for (std::string const &id : ids) {
        active_identity_by_id[id] = identity;
        removing_identity_by_id.erase(id);
    }

    return TorrentIdentityState::current;
}

TorrentIdentityState TTorrentClient::identity_state_for_status(std::vector<std::string> const &ids, TorrentIdentity *identity)
{
    std::scoped_lock io_guard(resume_io_lock);
    return reconcile_identity_for_hashes_locked(ids, identity);
}

bool TTorrentClient::reconcile_current_for_write_locked(lt::info_hash_t const &hashes, TorrentIdentity *identity)
{
    std::vector<std::string> const ids = hash_keys(hashes);
    if (ids.empty()) {
        return false;
    }

    return reconcile_identity_for_hashes_locked(ids, identity) == TorrentIdentityState::current;
}

void TTorrentClient::mark_active(lt::torrent_handle const &handle, TorrentIdentity *identity)
{
    if (!handle.is_valid()) {
        return;
    }

    lt::info_hash_t const hashes = handle.info_hashes();
    mark_active(hashes, handle, identity);
}

void TTorrentClient::mark_active(lt::info_hash_t const &hashes, lt::torrent_handle const &handle, TorrentIdentity *identity)
{
    if (!handle.is_valid()) {
        return;
    }

    std::vector<std::string> const ids = hash_keys(hashes);
    if (ids.empty() || identity == nullptr) {
        return;
    }

    std::scoped_lock io_guard(resume_io_lock);
    for (std::string const &id : ids) {
        active_identity_by_id[id] = identity;
        handle_by_id[id] = handle;
        removing_identity_by_id.erase(id);
    }
    handle_by_id[identity->canonical_id] = handle;
}

void TTorrentClient::remember_canonical_handle(lt::torrent_handle const &handle, TorrentIdentity *identity)
{
    if (!handle.is_valid() || identity == nullptr) {
        return;
    }

    std::scoped_lock io_guard(resume_io_lock);
    handle_by_id[identity->canonical_id] = handle;
}

void TTorrentClient::mark_unidentified_remove_requested(TorrentIdentity *identity)
{
    if (identity == nullptr) {
        return;
    }

    std::scoped_lock io_guard(resume_io_lock);
    discard_pending_resume_saves_locked(identity);
    handle_by_id.erase(identity->canonical_id);
    removing_identity_by_id.erase(identity->canonical_id);
    unidentified_removing_identities.insert(identity);
}

[[nodiscard]] bool TTorrentClient::rollback_added_torrent_without_hashes(
    lt::torrent_handle const &handle,
    TorrentIdentity *identity,
    DirtyMask &changes
)
{
    if (!handle.is_valid()) {
        discard_unpublished_identity(identity);
        return true;
    }

    try {
        session.remove_torrent(handle);
    } catch (...) {
        remember_canonical_handle(handle, identity);
        request_snapshot_update_locked();
        BridgeResult const rollback_fault = fault_persistence(3, "Added torrent rollback could not be "
                                                                 "completed; resume persistence is uncertain.");
        changes |= queue_alert_error(rollback_fault.error().message);
        ignore_shutdown_failure();
        return false;
    }
    mark_unidentified_remove_requested(identity);
    return true;
}

[[nodiscard]] bool TTorrentClient::rollback_added_torrent(
    lt::torrent_handle const &handle,
    lt::info_hash_t const &hashes,
    TorrentIdentity *identity,
    std::vector<std::string> const &resume_ids,
    bool publish_tombstone,
    DirtyMask &changes
)
{
    if (!handle.is_valid()) {
        discard_unpublished_identity(identity);
        return true;
    }

    bool tombstone_published = false;
    if (publish_tombstone && !resume_ids.empty()) {
        BridgeResult tombstoned = persist_removal_tombstones(resume_ids);
        if (!tombstoned) {
            mark_active(hashes, handle, identity);
            changes |= cache_snapshot(handle);
            request_snapshot_update_locked();
            changes |= queue_alert_error("Added torrent rollback could not be made durable: " + tombstoned.error().message +
                                         ".");
            return false;
        }
        tombstone_published = true;
    }

    try {
        session.remove_torrent(handle);
    } catch (...) {
        if (tombstone_published) {
            BridgeResult cancelled = cancel_tombstoned_operation_or_fault(
                resume_ids,
                3,
                "Added torrent rollback could not remove the torrent."
            );
            if (!cancelled) {
                changes |= queue_alert_error(cancelled.error().message);
            }
        }
        mark_active(hashes, handle, identity);
        changes |= cache_snapshot(handle);
        request_snapshot_update_locked();
        ignore_shutdown_failure();
        return false;
    }

    mark_remove_requested(hashes, "", identity);
    changes |= remove_snapshot(hashes, "");
    ResumeSaveResult removed_resume = remove_resume_files_for_ids_checked(resume_ids);
    if (!removed_resume) {
        remember_pending_resume_cleanup(resume_ids);
        changes |= queue_alert_error("Added torrent rollback left resume cleanup pending: " + removed_resume.error() + ".");
    } else if (tombstone_published) {
        ResumeSaveResult cleared = clear_removal_tombstones(resume_ids);
        if (!cleared) {
            changes |= queue_alert_error("Added torrent rollback left removal marker cleanup pending: " + cleared.error() +
                                         ".");
        }
    }
    return true;
}

void TTorrentClient::mark_remove_requested(lt::info_hash_t const &hashes, std::string_view requested_id, TorrentIdentity *identity)
{
    std::vector<std::string> const ids = hash_keys(hashes);
    std::scoped_lock io_guard(resume_io_lock);
    if (identity != nullptr) {
        discard_pending_resume_saves_locked(identity);
    }

    for (std::string const &id : ids) {
        if (id.empty()) {
            continue;
        }

        auto const active = active_identity_by_id.find(id);
        if (active != active_identity_by_id.end() && (identity == nullptr || active->second == identity)) {
            active_identity_by_id.erase(active);
        }
        handle_by_id.erase(id);

        if (identity != nullptr) {
            removing_identity_by_id[id] = identity;
        }
    }
    if (!requested_id.empty()) {
        handle_by_id.erase(std::string(requested_id));
    }
    if (identity != nullptr) {
        handle_by_id.erase(identity->canonical_id);
        removing_identity_by_id.erase(identity->canonical_id);
    }
}

void TTorrentClient::forget_removed_identity_aliases(lt::info_hash_t const &hashes, TorrentIdentity *identity)
{
    if (identity == nullptr) {
        return;
    }

    std::scoped_lock io_guard(resume_io_lock);
    discard_pending_resume_saves_locked(identity);
    for (std::string const &id : hash_keys(hashes)) {
        auto const active = active_identity_by_id.find(id);
        if (active != active_identity_by_id.end() && active->second == identity) {
            active_identity_by_id.erase(active);
        }

        auto const removing = removing_identity_by_id.find(id);
        if (removing != removing_identity_by_id.end() && removing->second == identity) {
            removing_identity_by_id.erase(removing);
        }

        auto const mapped = handle_by_id.find(id);
        if (mapped != handle_by_id.end() && identity_from_handle(mapped->second) == identity) {
            handle_by_id.erase(mapped);
        }
    }
    handle_by_id.erase(identity->canonical_id);
    removing_identity_by_id.erase(identity->canonical_id);
    retire_identity_if_unreferenced_locked(identity);
}

bool TTorrentClient::accepts_removed_alert(lt::info_hash_t const &hashes, TorrentIdentity *identity)
{
    if (identity == nullptr) {
        return false;
    }

    std::vector<std::string> const ids = hash_keys(hashes);
    if (ids.empty()) {
        return false;
    }

    std::scoped_lock io_guard(resume_io_lock);
    bool const matched_unidentified_remove = unidentified_removing_identities.contains(identity);
    bool matched_pending_remove = false;
    for (std::string const &id : ids) {
        auto const active = active_identity_by_id.find(id);
        if (active != active_identity_by_id.end() && active->second != identity) {
            return false;
        }

        auto const removing = removing_identity_by_id.find(id);
        if (removing != removing_identity_by_id.end() && removing->second == identity) {
            matched_pending_remove = true;
        }
    }

    return matched_pending_remove || matched_unidentified_remove;
}

void TTorrentClient::finalize_removed(lt::info_hash_t const &hashes, TorrentIdentity *identity)
{
    if (identity == nullptr) {
        return;
    }

    std::scoped_lock io_guard(resume_io_lock);
    discard_pending_resume_saves_locked(identity);
    unidentified_removing_identities.erase(identity);
    for (std::string const &id : hash_keys(hashes)) {
        auto const active = active_identity_by_id.find(id);
        if (active != active_identity_by_id.end() && active->second == identity) {
            active_identity_by_id.erase(active);
        }
        handle_by_id.erase(id);

        auto const removing = removing_identity_by_id.find(id);
        if (removing != removing_identity_by_id.end() && removing->second == identity) {
            removing_identity_by_id.erase(removing);
        }
    }
    handle_by_id.erase(identity->canonical_id);
    removing_identity_by_id.erase(identity->canonical_id);
    retire_identity_if_unreferenced_locked(identity);
}

bool TTorrentClient::resume_write_is_current(lt::info_hash_t const &hashes, TorrentIdentity *identity)
{
    std::scoped_lock io_guard(resume_io_lock);
    return reconcile_current_for_write_locked(hashes, identity);
}
