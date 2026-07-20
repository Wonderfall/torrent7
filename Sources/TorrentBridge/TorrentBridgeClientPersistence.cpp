#include "TorrentBridgeInternal.hpp"

#include <dirent.h>

namespace torrent_bridge::internal {

namespace {

using DirectoryNamesResult = std::expected<std::vector<std::string>, std::string>;
using RegularFileResult = std::expected<bool, std::string>;
// Leave room for every bounded removal marker, every resume file named by a
// marker, and one final plus one transient file for each live torrent. This
// keeps all states admitted by the persistence budgets enumerable on restart.
constexpr std::size_t kMaxResumeDirectoryEntryCount =
    kMaxRemovalTombstoneEntryCount
    + kMaxRemovalTombstoneIDMembershipCount
    + (2U * static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT));

static_assert(kMaxResumeDirectoryEntryCount > kMaxRemovalTombstoneEntryCount);

DirectoryNamesResult directory_entry_names(
    int const directory_descriptor,
    std::string_view const description
)
{
    int const enumeration_descriptor = ::openat(
        directory_descriptor,
        ".",
        O_RDONLY | O_DIRECTORY | O_CLOEXEC
    );
    if (enumeration_descriptor < 0) {
        return std::unexpected(system_error_message(description, errno));
    }

    DIR *const raw_directory = ::fdopendir(enumeration_descriptor);
    if (raw_directory == nullptr) {
        int const error_number = errno;
        static_cast<void>(::close(enumeration_descriptor));
        return std::unexpected(system_error_message(description, error_number));
    }
    std::unique_ptr<DIR, decltype(&::closedir)> directory(raw_directory, &::closedir);

    std::vector<std::string> names;
    while (true) {
        errno = 0;
        dirent const *const entry = ::readdir(directory.get());
        if (entry == nullptr) {
            if (errno != 0) {
                return std::unexpected(system_error_message(description, errno));
            }
            break;
        }

        std::string const name(entry->d_name);
        if (name != "." && name != "..") {
            if (names.size() >= kMaxResumeDirectoryEntryCount) {
                return std::unexpected(std::string(description) + ": too many entries");
            }
            names.push_back(name);
        }
    }
    return names;
}

RegularFileResult is_regular_file_at(
    int const directory_descriptor,
    std::string const &filename,
    std::string_view const description
)
{
    struct stat metadata{};
    if (::fstatat(
            directory_descriptor,
            filename.c_str(),
            &metadata,
            AT_SYMLINK_NOFOLLOW
        ) != 0) {
        return std::unexpected(system_error_message(description, errno));
    }
    return S_ISREG(metadata.st_mode);
}

} // namespace

[[nodiscard]] bool TTorrentClient::resume_write_is_installable_locked(PendingEncodedResumeWrite const &write) const
{
    if (write.identity == nullptr) {
        return true;
    }

    return write.generation >= write.identity->resume_save.installed_generation;
}

std::vector<PendingEncodedResumeWrite> TTorrentClient::claim_resume_retries()
{
    std::vector<PendingEncodedResumeWrite> retries;
    std::scoped_lock io_guard(resume_io_lock);
    for (auto const &identity : torrent_identities) {
        if (!identity->resume_save.retry) {
            continue;
        }

        PendingEncodedResumeWrite retry = std::move(*identity->resume_save.retry);
        identity->resume_save.retry.reset();
        retries.push_back(std::move(retry));
    }
    return retries;
}

std::vector<std::string> TTorrentClient::retry_resume_cleanups(bool reports_errors)
{
    std::vector<std::string> errors;
    if (persistence_is_faulted()) {
        return errors;
    }

    {
        std::scoped_lock io_guard(resume_io_lock);
        for (auto const &identity : torrent_identities) {
            std::vector<PendingResumeCleanup> const cleanups = identity->resume_save.cleanup_retry;
            if (cleanups.empty()) {
                continue;
            }
            PendingEncodedResumeWrite cleanup_write{.hashes = {},
                                                    .identity = identity.get(),
                                                    .generation = identity->resume_save.committed_generation,
                                                    .encoded = {},
                                                    .cleanups = cleanups};
            if (!resume_cleanups_are_eligible_locked(cleanup_write)) {
                continue;
            }

            ResumeSaveResult cleaned = complete_resume_cleanups_locked(cleanup_write);
            if (!cleaned) {
                errors.push_back(cleaned.error());
                continue;
            }
        }
    }

    if (reports_errors) {
        for (std::string const &error : errors) {
            queue_alert_error_threadsafe("Resume cleanup retry failed: " + error + ".");
        }
    }
    return errors;
}

void TTorrentClient::discard_pending_resume_saves_locked(TorrentIdentity *identity) noexcept
{
    if (identity == nullptr) {
        return;
    }

    identity->resume_save.async_in_flight.reset();
    identity->resume_save.save_again = false;
    identity->resume_save.retry.reset();
    identity->resume_save.pending_cleanups.clear();
    identity->resume_save.cleanup_retry.clear();
}

void TTorrentClient::discard_unpublished_identity(TorrentIdentity *identity) noexcept
{
    std::scoped_lock io_guard(resume_io_lock);
    dht_disabled_by_app.erase(identity);
    lsd_disabled_by_app.erase(identity);
    peer_exchange_disabled_by_app.erase(identity);
    metadata_validation_pending.erase(identity);
    untrack_queue_identity_locked(identity);
    auto const owned_identity = std::ranges::find_if(torrent_identities, [identity](auto const &owned) {
        return owned.get() == identity;
    });
    if (owned_identity == torrent_identities.end()) {
        return;
    }

    TorrentIdentityToken *const token = identity->token;
    if (token != nullptr) {
        token->active_identity.store(nullptr, std::memory_order_release);
    }
    canonical_ids_in_use.erase(identity->canonical_id);
    torrent_identities.erase(owned_identity);

    auto const owned_token = std::ranges::find_if(identity_tokens, [token](auto const &owned) {
        return owned.get() == token;
    });
    if (owned_token != identity_tokens.end()) {
        identity_tokens.erase(owned_token);
    }
}

void TTorrentClient::append_cleanup_ids_locked(std::vector<PendingResumeCleanup> &destination, PendingResumeCleanup cleanup)
{
    if (cleanup.resume_ids.empty()) {
        return;
    }

    auto const existing = std::ranges::find_if(destination, [&cleanup](PendingResumeCleanup const &entry) {
        return entry.after_generation == cleanup.after_generation;
    });
    if (existing == destination.end()) {
        destination.push_back(std::move(cleanup));
        return;
    }

    for (std::string const &id : cleanup.resume_ids) {
        append_unique(existing->resume_ids, id);
    }
}

void TTorrentClient::remember_pending_cleanups_locked(TorrentIdentity *identity, std::vector<PendingResumeCleanup> cleanups)
{
    if (identity == nullptr) {
        return;
    }

    for (PendingResumeCleanup &cleanup : cleanups) {
        cleanup.after_generation = 0;
        append_cleanup_ids_locked(identity->resume_save.pending_cleanups, std::move(cleanup));
    }
}

void TTorrentClient::remember_pending_cleanups(TorrentIdentity *identity, std::vector<PendingResumeCleanup> cleanups)
{
    std::scoped_lock io_guard(resume_io_lock);
    remember_pending_cleanups_locked(identity, std::move(cleanups));
}

std::vector<PendingResumeCleanup>
TTorrentClient::cleanups_for_write(TorrentIdentity *identity, std::uint64_t generation,
                   std::vector<PendingResumeCleanup> const &explicit_cleanups)
{
    std::vector<PendingResumeCleanup> cleanups;
    if (identity != nullptr) {
        std::scoped_lock io_guard(resume_io_lock);
        for (PendingResumeCleanup cleanup : identity->resume_save.pending_cleanups) {
            cleanup.after_generation = generation;
            append_cleanup_ids_locked(cleanups, std::move(cleanup));
        }
    }
    for (PendingResumeCleanup cleanup : explicit_cleanups) {
        cleanup.after_generation = generation;
        append_cleanup_ids_locked(cleanups, std::move(cleanup));
    }
    return cleanups;
}

void TTorrentClient::remove_cleanup_ids_locked(std::vector<PendingResumeCleanup> &target,
                               std::vector<PendingResumeCleanup> const &completed)
{
    std::vector<std::string> completed_ids;
    for (PendingResumeCleanup const &cleanup : completed) {
        for (std::string const &id : cleanup.resume_ids) {
            append_unique(completed_ids, id);
        }
    }
    if (completed_ids.empty()) {
        return;
    }

    for (PendingResumeCleanup &cleanup : target) {
        std::erase_if(cleanup.resume_ids, [&completed_ids](std::string const &id) {
            return std::ranges::find(completed_ids, id) != completed_ids.end();
        });
    }
    std::erase_if(target, [](PendingResumeCleanup const &cleanup) { return cleanup.resume_ids.empty(); });
}

void TTorrentClient::mark_resume_cleanups_completed_locked(TorrentIdentity *identity,
                                           std::vector<PendingResumeCleanup> const &cleanups)
{
    if (identity == nullptr) {
        return;
    }

    remove_cleanup_ids_locked(identity->resume_save.pending_cleanups, cleanups);
    remove_cleanup_ids_locked(identity->resume_save.cleanup_retry, cleanups);
}

void TTorrentClient::remember_resume_cleanup_failure_locked(TorrentIdentity *identity, std::vector<PendingResumeCleanup> cleanups)
{
    if (identity == nullptr) {
        return;
    }

    for (PendingResumeCleanup &cleanup : cleanups) {
        append_cleanup_ids_locked(identity->resume_save.cleanup_retry, std::move(cleanup));
    }
}

std::vector<std::string> TTorrentClient::removal_ids_for_identity(lt::info_hash_t const &hashes, std::string_view requested_id,
                                                  TorrentIdentity *identity)
{
    std::vector<std::string> ids = hash_keys_with_requested(hashes, requested_id);
    std::scoped_lock io_guard(resume_io_lock);
    if (identity == nullptr) {
        return ids;
    }

    append_unique(ids, identity->canonical_id);
    auto append_cleanup_ids = [&ids](std::vector<PendingResumeCleanup> const &cleanups) {
        for (PendingResumeCleanup const &cleanup : cleanups) {
            for (std::string const &id : cleanup.resume_ids) {
                append_unique(ids, id);
            }
        }
    };
    append_cleanup_ids(identity->resume_save.pending_cleanups);
    append_cleanup_ids(identity->resume_save.cleanup_retry);
    return ids;
}

bool TTorrentClient::delete_pending_for_hashes(lt::info_hash_t const &hashes)
{
    std::scoped_lock io_guard(resume_io_lock);
    std::vector<std::string> const ids = hash_keys(hashes);
    for (std::string const &id : ids) {
        if (awaiting_delete_resume_ids_by_id.contains(id)) {
            return true;
        }
        if (pending_resume_cleanup_ids_by_id.contains(id)) {
            return true;
        }
        if (terminal_delete_cleanup_ids_by_id.contains(id)) {
            return true;
        }
        if (pending_tombstone_clear_ids_by_id.contains(id)) {
            return true;
        }
    }

    for (std::string const &id : ids) {
        auto const indexed = removal_tombstones_by_id.find(id);
        if (indexed == removal_tombstones_by_id.end()) {
            continue;
        }
        if (std::ranges::any_of(indexed->second, [](RemovalTombstoneEntry const *entry) {
                return entry != nullptr
                    && entry->state == RemovalTombstoneState::awaiting_payload_delete;
            })) {
            return true;
        }
    }
    return false;
}

void TTorrentClient::remember_pending_delete(lt::info_hash_t const &hashes, std::vector<std::string> const &resume_ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(resume_ids);
    if (!normalized || normalized->empty()) {
        return;
    }

    std::scoped_lock io_guard(resume_io_lock);
    for (std::string const &id : hash_keys(hashes)) {
        awaiting_delete_resume_ids_by_id[id] = *normalized;
    }
}

void TTorrentClient::remember_pending_resume_cleanup_locked(std::vector<std::string> const &ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized || normalized->empty()) {
        return;
    }

    for (std::string const &id : *normalized) {
        pending_resume_cleanup_ids_by_id[id] = *normalized;
    }
}

void TTorrentClient::remember_pending_resume_cleanup(std::vector<std::string> const &ids)
{
    std::scoped_lock io_guard(resume_io_lock);
    remember_pending_resume_cleanup_locked(ids);
}

void TTorrentClient::forget_pending_resume_cleanup_locked(std::vector<std::string> const &ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized) {
        return;
    }

    for (std::string const &id : *normalized) {
        pending_resume_cleanup_ids_by_id.erase(id);
    }
}

std::vector<std::vector<std::string>> TTorrentClient::pending_resume_cleanup_id_groups()
{
    std::vector<std::vector<std::string>> groups;
    std::scoped_lock io_guard(resume_io_lock);
    for (auto const &entry : pending_resume_cleanup_ids_by_id) {
        if (std::ranges::find(groups, entry.second) == groups.end()) {
            groups.push_back(entry.second);
        }
    }
    return groups;
}

ResumeSaveResult TTorrentClient::complete_pending_resume_cleanup(std::vector<std::string> const &resume_ids)
{
    if (persistence_is_faulted()) {
        return std::unexpected("Resume persistence is in an uncertain state.");
    }

    ResumeSaveResult removed_resume = remove_resume_files_for_ids_checked(resume_ids);
    if (!removed_resume) {
        return std::unexpected("resume cleanup is pending: " + removed_resume.error());
    }

    ResumeSaveResult cleared = clear_removal_tombstones(resume_ids);
    if (!cleared) {
        return std::unexpected("removal marker cleanup is pending: " + cleared.error());
    }
    return {};
}

std::vector<std::string> TTorrentClient::retry_pending_resume_cleanups(bool reports_errors)
{
    std::vector<std::string> errors;
    if (persistence_is_faulted()) {
        return errors;
    }

    for (std::vector<std::string> const &resume_ids : pending_resume_cleanup_id_groups()) {
        ResumeSaveResult completed = complete_pending_resume_cleanup(resume_ids);
        if (!completed) {
            errors.push_back(completed.error());
        }
    }

    if (reports_errors) {
        for (std::string const &error : errors) {
            queue_alert_error_threadsafe("Pending resume cleanup retry failed: " + error + ".");
        }
    }
    return errors;
}

void TTorrentClient::remember_pending_tombstone_clear_locked(std::vector<std::string> const &ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized || normalized->empty()) {
        return;
    }

    for (std::string const &id : *normalized) {
        pending_tombstone_clear_ids_by_id[id] = *normalized;
    }
}

void TTorrentClient::forget_pending_tombstone_clear_locked(std::vector<std::string> const &ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized) {
        return;
    }

    for (std::string const &id : *normalized) {
        pending_tombstone_clear_ids_by_id.erase(id);
    }
}

std::vector<std::vector<std::string>> TTorrentClient::pending_tombstone_clear_id_groups()
{
    std::vector<std::vector<std::string>> groups;
    std::scoped_lock io_guard(resume_io_lock);
    for (auto const &entry : pending_tombstone_clear_ids_by_id) {
        if (std::ranges::find(groups, entry.second) == groups.end()) {
            groups.push_back(entry.second);
        }
    }
    return groups;
}

std::vector<std::string> TTorrentClient::retry_pending_tombstone_clears(bool reports_errors)
{
    std::vector<std::string> errors;
    if (persistence_is_faulted()) {
        return errors;
    }

    for (std::vector<std::string> const &ids : pending_tombstone_clear_id_groups()) {
        ResumeSaveResult cleared = clear_removal_tombstones(ids);
        if (!cleared) {
            errors.push_back(cleared.error());
        }
    }

    if (reports_errors) {
        for (std::string const &error : errors) {
            queue_alert_error_threadsafe("Removal marker cleanup retry failed: " + error + ".");
        }
    }
    return errors;
}

std::vector<std::string> TTorrentClient::promote_pending_delete_to_terminal_cleanup(lt::info_hash_t const &hashes)
{
    std::vector<std::string> resume_ids;
    std::vector<std::string> const ids = hash_keys(hashes);
    std::scoped_lock io_guard(resume_io_lock);
    for (std::string const &id : ids) {
        auto const pending = awaiting_delete_resume_ids_by_id.find(id);
        if (pending == awaiting_delete_resume_ids_by_id.end()) {
            continue;
        }
        for (std::string const &resume_id : pending->second) {
            append_unique(resume_ids, resume_id);
        }
    }
    if (resume_ids.empty()) {
        return resume_ids;
    }

    for (std::string const &id : ids) {
        awaiting_delete_resume_ids_by_id.erase(id);
        terminal_delete_cleanup_ids_by_id[id] = resume_ids;
    }
    return resume_ids;
}

std::vector<std::vector<std::string>> TTorrentClient::terminal_delete_cleanup_id_groups()
{
    std::vector<std::vector<std::string>> groups;
    std::scoped_lock io_guard(resume_io_lock);
    for (auto const &entry : terminal_delete_cleanup_ids_by_id) {
        if (std::ranges::find(groups, entry.second) == groups.end()) {
            groups.push_back(entry.second);
        }
    }
    return groups;
}

void TTorrentClient::forget_pending_delete_resume_ids(std::vector<std::string> const &resume_ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(resume_ids);
    if (!normalized || normalized->empty()) {
        return;
    }

    std::scoped_lock io_guard(resume_io_lock);
    std::erase_if(terminal_delete_cleanup_ids_by_id,
                  [&normalized](auto const &entry) { return entry.second == *normalized; });
}

ResumeSaveResult TTorrentClient::complete_pending_delete_cleanup(std::vector<std::string> const &resume_ids)
{
    ResumeSaveResult completed = complete_pending_resume_cleanup(resume_ids);
    if (!completed) {
        return completed;
    }
    forget_pending_delete_resume_ids(resume_ids);
    return {};
}

DirtyMask TTorrentClient::complete_pending_delete(lt::info_hash_t const &hashes, std::string const &failure_message)
{
    DirtyMask changes = 0;
    std::vector<std::string> const resume_ids = promote_pending_delete_to_terminal_cleanup(hashes);
    if (resume_ids.empty()) {
        if (!failure_message.empty()) {
            changes |= queue_alert_error(failure_message);
        }
        return changes;
    }

    if (!failure_message.empty()) {
        changes |= queue_alert_error(failure_message);
    }
    ResumeSaveResult completed = complete_pending_delete_cleanup(resume_ids);
    if (!completed) {
        changes |= queue_alert_error("Torrent was removed, but " + completed.error() + ".");
        return changes;
    }
    return changes;
}

std::vector<std::string> TTorrentClient::retry_pending_delete_cleanups(bool reports_errors)
{
    std::vector<std::string> errors;
    if (persistence_is_faulted()) {
        return errors;
    }

    for (std::vector<std::string> const &resume_ids : terminal_delete_cleanup_id_groups()) {
        ResumeSaveResult completed = complete_pending_delete_cleanup(resume_ids);
        if (!completed) {
            errors.push_back(completed.error());
        }
    }

    if (reports_errors) {
        for (std::string const &error : errors) {
            queue_alert_error_threadsafe("Pending deletion cleanup retry failed: " + error + ".");
        }
    }
    return errors;
}

bool TTorrentClient::remove_resume_file_locked(std::string_view const filename)
{
    if (filename.empty() || filename.contains('/') || filename.contains('\0')) {
        return false;
    }

    std::string const owned_filename(filename);
    return ::unlinkat(resume_directory_descriptor.get(), owned_filename.c_str(), 0) == 0;
}

ResumeRemoveResult TTorrentClient::remove_resume_file_checked_locked(std::string_view const filename)
{
    if (filename.empty() || filename.contains('/') || filename.contains('\0')) {
        return std::unexpected("Resume data filename is invalid.");
    }

    std::string const owned_filename(filename);
    if (::unlinkat(resume_directory_descriptor.get(), owned_filename.c_str(), 0) == 0) {
        return true;
    }
    if (errno == ENOENT) {
        return false;
    }
    return std::unexpected(system_error_message("Resume data file could not be removed", errno));
}

void TTorrentClient::sync_resume_directory_quietly()
{
    ResumeSaveResult result = sync_directory(resume_directory_descriptor.get());
    if (!result) {
        ignore_shutdown_failure();
    }
}

ResumeRemoveResult TTorrentClient::remove_resume_temp_files_for_id_checked_locked(std::string const &id)
{
    bool removed = false;
    std::string const prefix = id + std::string(kResumeExtension) + std::string(kTempExtension) + ".";
    DirectoryNamesResult const names = directory_entry_names(
        resume_directory_descriptor.get(),
        "Resume data directory could not be scanned"
    );
    if (!names) {
        return std::unexpected(names.error());
    }
    for (std::string const &name : *names) {
        RegularFileResult const regular = is_regular_file_at(
            resume_directory_descriptor.get(),
            name,
            "Resume data file could not be inspected"
        );
        if (!regular) {
            return std::unexpected(regular.error());
        }
        if (!*regular) {
            continue;
        }

        if (!name.starts_with(prefix)) {
            continue;
        }

        ResumeRemoveResult removed_file = remove_resume_file_checked_locked(name);
        if (!removed_file) {
            return removed_file;
        }
        removed = *removed_file || removed;
    }

    return removed;
}

ResumeRemoveResult TTorrentClient::remove_resume_files_for_id_checked_locked(std::string const &id)
{
    std::string const final_filename = id + std::string(kResumeExtension);
    std::string const temp_filename = final_filename + std::string(kTempExtension);

    bool removed = false;
    ResumeRemoveResult removed_final = remove_resume_file_checked_locked(final_filename);
    if (!removed_final) {
        return removed_final;
    }
    removed = *removed_final || removed;

    ResumeRemoveResult removed_temp = remove_resume_file_checked_locked(temp_filename);
    if (!removed_temp) {
        return removed_temp;
    }
    removed = *removed_temp || removed;

    ResumeRemoveResult removed_temps = remove_resume_temp_files_for_id_checked_locked(id);
    if (!removed_temps) {
        return removed_temps;
    }
    removed = *removed_temps || removed;
    return removed;
}

TombstoneEntriesResult TTorrentClient::scan_removal_tombstone_entries_locked(
    RemovalTombstoneIndexLimits const limits
)
{
#if defined(TORRENT_BRIDGE_TESTING)
    ++removal_tombstone_directory_scan_count;
#endif
    std::vector<RemovalTombstoneEntry> entries;
    DirectoryNamesResult const names = directory_entry_names(
        resume_directory_descriptor.get(),
        "Removal tombstones could not be scanned"
    );
    if (!names) {
        return std::unexpected(names.error());
    }
    std::size_t materialized_id_count = 0;
    for (std::string const &name : *names) {
        if (!is_removal_tombstone_path(fs::path(name))) {
            continue;
        }

        RegularFileResult const regular = is_regular_file_at(
            resume_directory_descriptor.get(),
            name,
            "Removal tombstone could not be inspected"
        );
        if (!regular) {
            return std::unexpected(regular.error());
        }
        if (!*regular) {
            return std::unexpected("Removal tombstone is not a regular file.");
        }

        if (entries.size() >= limits.entry_count) {
            return std::unexpected("Removal tombstone index contains too many entries.");
        }

        FileReadResult const buffer = read_file_at(
            resume_directory_descriptor.get(),
            name,
            kMaxRemovalTombstoneBytes
        );
        if (!buffer) {
            return std::unexpected(tombstone_read_error(buffer.error()));
        }

        TombstonePayloadResult payload = tombstone_payload_from_bytes(*buffer);
        if (!payload) {
            return std::unexpected(payload.error());
        }
        if (materialized_id_count > limits.id_membership_count
            || payload->ids.size() > limits.id_membership_count - materialized_id_count) {
            return std::unexpected("Removal tombstone index contains too many identifier references.");
        }
        materialized_id_count += payload->ids.size();
        entries.push_back(RemovalTombstoneEntry{
            .filename = name,
            .ids = std::move(payload->ids),
            .state = payload->state,
            .delete_files = payload->delete_files,
            .delete_partfile = payload->delete_partfile
        });
    }
    return entries;
}

ResumeSaveResult TTorrentClient::load_removal_tombstone_index_locked(
    RemovalTombstoneIndexLimits const limits
)
{
    TombstoneEntriesResult entries = scan_removal_tombstone_entries_locked(limits);
    if (!entries) {
        return std::unexpected(entries.error());
    }
    if (entries->size() > limits.entry_count) {
        return std::unexpected("Removal tombstone index contains too many entries.");
    }

    RemovalTombstoneEntryMap indexed_entries;
    RemovalTombstoneIDIndex indexed_ids;
    std::size_t membership_count = 0;
    for (RemovalTombstoneEntry &entry : *entries) {
        if (membership_count > limits.id_membership_count
            || entry.ids.size() > limits.id_membership_count - membership_count) {
            return std::unexpected("Removal tombstone index contains too many identifier references.");
        }

        auto owned_entry = std::make_unique<RemovalTombstoneEntry>(std::move(entry));
        RemovalTombstoneEntry *const raw_entry = owned_entry.get();
        auto const [position, inserted] = indexed_entries.emplace(
            raw_entry->filename,
            std::move(owned_entry)
        );
        static_cast<void>(position);
        if (!inserted) {
            return std::unexpected("Removal tombstone index contains a duplicate filename.");
        }
        for (std::string const &id : raw_entry->ids) {
            indexed_ids[id].insert(raw_entry);
        }
        membership_count += raw_entry->ids.size();
    }

    removal_tombstones_by_filename.swap(indexed_entries);
    removal_tombstones_by_id.swap(indexed_ids);
    removal_tombstone_id_membership_count = membership_count;
    return {};
}

void TTorrentClient::unindex_removal_tombstone_locked(RemovalTombstoneEntry const *const entry) noexcept
{
    if (entry == nullptr) {
        return;
    }

    auto const indexed_entry = removal_tombstones_by_filename.find(entry->filename);
    if (indexed_entry == removal_tombstones_by_filename.end()
        || indexed_entry->second.get() != entry) {
        return;
    }
    for (std::string const &id : entry->ids) {
        auto indexed = removal_tombstones_by_id.find(id);
        if (indexed == removal_tombstones_by_id.end()) {
            continue;
        }
        if (indexed->second.erase(entry) > 0U && removal_tombstone_id_membership_count > 0U) {
            --removal_tombstone_id_membership_count;
        }
        if (indexed->second.empty()) {
            removal_tombstones_by_id.erase(indexed);
        }
    }
    removal_tombstones_by_filename.erase(indexed_entry);
}

TombstoneEntriesResult TTorrentClient::removal_tombstone_entries_locked()
{
    std::vector<RemovalTombstoneEntry> entries;
    entries.reserve(removal_tombstones_by_filename.size());
    for (auto const &[filename, entry] : removal_tombstones_by_filename) {
        static_cast<void>(filename);
        if (entry != nullptr) {
            entries.push_back(*entry);
        }
    }
    return entries;
}

TombstoneIDResult TTorrentClient::removal_tombstone_ids_locked()
{
    std::set<std::string> ids;
    for (auto const &[id, entries] : removal_tombstones_by_id) {
        if (!entries.empty()) {
            ids.insert(id);
        }
    }
    return ids;
}

ResumeIDListResult TTorrentClient::tombstone_ids_overlapping_locked(std::vector<std::string> const &ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized) {
        return std::unexpected(normalized.error());
    }
    if (normalized->empty()) {
        return std::vector<std::string>{};
    }

    std::set<RemovalTombstoneEntry const *> matched_entries;
    for (std::string const &id : *normalized) {
        auto const indexed = removal_tombstones_by_id.find(id);
        if (indexed != removal_tombstones_by_id.end()) {
            matched_entries.insert(indexed->second.begin(), indexed->second.end());
        }
    }

    std::vector<std::string> matched_ids;
    for (RemovalTombstoneEntry const *entry : matched_entries) {
        if (entry == nullptr) {
            continue;
        }
        for (std::string const &id : entry->ids) {
            append_unique(matched_ids, id);
        }
    }
    return matched_ids;
}

TombstoneCommitResult TTorrentClient::persist_removal_tombstones_locked(std::vector<std::string> const &ids,
                                                        RemovalTombstoneState state, bool delete_files,
                                                        bool delete_partfile)
{
    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized) {
        return std::unexpected(normalized.error());
    }
    if (normalized->empty()) {
        return TombstoneCommitStatus{};
    }

    std::string const payload = tombstone_payload(*normalized, state, delete_files, delete_partfile);
    if (payload.empty() || payload.size() > kMaxRemovalTombstoneBytes) {
        return std::unexpected("Removal tombstone payload is too large.");
    }

    if (removal_tombstones_by_filename.size() >= kMaxRemovalTombstoneEntryCount) {
        return std::unexpected("Removal tombstone index contains too many entries.");
    }
    if (removal_tombstone_id_membership_count > kMaxRemovalTombstoneIDMembershipCount
        || normalized->size()
            > kMaxRemovalTombstoneIDMembershipCount - removal_tombstone_id_membership_count) {
        return std::unexpected("Removal tombstone index contains too many identifier references.");
    }

    std::string tombstone_filename;
    constexpr std::size_t kMaxFilenameAttempts = 16U;
    for (std::size_t attempt = 0; attempt < kMaxFilenameAttempts; ++attempt) {
        tombstone_filename = make_removal_tombstone_filename();
        if (!removal_tombstones_by_filename.contains(tombstone_filename)) {
            break;
        }
        tombstone_filename.clear();
    }
    if (tombstone_filename.empty()) {
        return std::unexpected("A unique removal tombstone filename could not be created.");
    }

    RemovalTombstoneEntryMap staged_entries;
    auto staged_entry = std::make_unique<RemovalTombstoneEntry>(RemovalTombstoneEntry{
        .filename = tombstone_filename,
        .ids = *normalized,
        .state = state,
        .delete_files = delete_files,
        .delete_partfile = delete_partfile
    });
    RemovalTombstoneEntry *const raw_staged_entry = staged_entry.get();
    staged_entries.emplace(tombstone_filename, std::move(staged_entry));

    struct ExistingIDMembership {
        std::set<RemovalTombstoneEntry const *> *destination = nullptr;
        std::set<RemovalTombstoneEntry const *>::node_type node;
    };
    RemovalTombstoneIDIndex staged_new_ids;
    std::vector<ExistingIDMembership> staged_existing_ids;
    staged_existing_ids.reserve(normalized->size());
    for (std::string const &id : *normalized) {
        auto const existing = removal_tombstones_by_id.find(id);
        if (existing == removal_tombstones_by_id.end()) {
            staged_new_ids[id].insert(raw_staged_entry);
            continue;
        }

        std::set<RemovalTombstoneEntry const *> staged_membership{raw_staged_entry};
        staged_existing_ids.push_back(ExistingIDMembership{
            .destination = &existing->second,
            .node = staged_membership.extract(raw_staged_entry)
        });
    }

    ResumeSaveResult written = write_owner_only_file_at_checked(
        resume_directory_descriptor.get(),
        tombstone_filename,
        payload
    );
    if (!written) {
        return std::unexpected("Removal tombstone could not be saved: " + written.error());
    }

    ResumeSaveResult synced = sync_directory(resume_directory_descriptor.get());
    if (!synced) {
        return TombstoneCommitStatus{
            .directory_synced = false
        };
    }

    auto entry_node = staged_entries.extract(tombstone_filename);
    auto const inserted_entry = removal_tombstones_by_filename.insert(std::move(entry_node));
    if (!inserted_entry.inserted) {
        std::terminate();
    }
    while (!staged_new_ids.empty()) {
        auto id_node = staged_new_ids.extract(staged_new_ids.begin());
        auto const inserted_id = removal_tombstones_by_id.insert(std::move(id_node));
        if (!inserted_id.inserted) {
            std::terminate();
        }
    }
    for (ExistingIDMembership &membership : staged_existing_ids) {
        if (membership.destination == nullptr) {
            std::terminate();
        }
        auto const inserted_membership = membership.destination->insert(std::move(membership.node));
        if (!inserted_membership.inserted) {
            std::terminate();
        }
    }
    removal_tombstone_id_membership_count += normalized->size();
    return TombstoneCommitStatus{};
}

ResumeSaveResult TTorrentClient::clear_removal_tombstones_locked(std::vector<std::string> const &ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized) {
        return std::unexpected(normalized.error());
    }
    if (normalized->empty()) {
        return {};
    }

    std::set<RemovalTombstoneEntry const *> candidates;
    for (std::string const &id : *normalized) {
        auto const indexed = removal_tombstones_by_id.find(id);
        if (indexed != removal_tombstones_by_id.end()) {
            candidates.insert(indexed->second.begin(), indexed->second.end());
        }
    }

    std::vector<RemovalTombstoneEntry const *> cleared_entries;
    cleared_entries.reserve(candidates.size());
    for (RemovalTombstoneEntry const *entry : candidates) {
        if (entry == nullptr) {
            continue;
        }
        bool const covers_entry = std::ranges::all_of(entry->ids, [&normalized](std::string const &id) {
            return std::ranges::find(*normalized, id) != normalized->end();
        });
        if (!covers_entry) {
            continue;
        }

        ResumeRemoveResult removed_tombstone = remove_resume_file_checked_locked(entry->filename);
        if (!removed_tombstone) {
            return std::unexpected("Removal tombstone could not be cleared: " + removed_tombstone.error());
        }
        cleared_entries.push_back(entry);
    }

    ResumeSaveResult synced = sync_directory(resume_directory_descriptor.get());
    if (!synced) {
        return synced;
    }
    for (RemovalTombstoneEntry const *entry : cleared_entries) {
        unindex_removal_tombstone_locked(entry);
    }
    return {};
}

ResumeSaveResult TTorrentClient::complete_pending_removals()
{
    std::scoped_lock io_guard(resume_io_lock);
    TombstoneEntriesResult entries = removal_tombstone_entries_locked();
    if (!entries) {
        return std::unexpected(entries.error());
    }

    for (RemovalTombstoneEntry const &entry : *entries) {
        bool const payload_delete_abandoned = entry.state == RemovalTombstoneState::awaiting_payload_delete;
        bool removed_any = false;
        for (std::string const &id : entry.ids) {
            ResumeRemoveResult removed = remove_resume_files_for_id_checked_locked(id);
            if (!removed) {
                return std::unexpected("Pending resume cleanup failed: " + removed.error());
            }
            removed_any = *removed || removed_any;
        }

        if (removed_any) {
            ResumeSaveResult synced_resume_removal = sync_directory(resume_directory_descriptor.get());
            if (!synced_resume_removal) {
                return std::unexpected("Pending resume cleanup could not be synced: " +
                                       synced_resume_removal.error());
            }
        }
        ResumeRemoveResult removed_tombstone = remove_resume_file_checked_locked(entry.filename);
        if (!removed_tombstone) {
            return std::unexpected("Removal tombstone could not be cleared: " + removed_tombstone.error());
        }
        if (!*removed_tombstone) {
            return std::unexpected("Removal tombstone disappeared before it could be cleared.");
        }

        ResumeSaveResult synced_tombstone_removal = sync_directory(resume_directory_descriptor.get());
        if (!synced_tombstone_removal) {
            return std::unexpected("Removal tombstone cleanup could not be synced: " +
                                   synced_tombstone_removal.error());
        }
        auto const indexed_entry = removal_tombstones_by_filename.find(entry.filename);
        if (indexed_entry != removal_tombstones_by_filename.end()) {
            unindex_removal_tombstone_locked(indexed_entry->second.get());
        }
        if (payload_delete_abandoned) {
            static_cast<void>(queue_alert_error(
                "A previous data deletion did not finish before shutdown. Some downloaded files may remain on disk."
            ));
        }
    }
    return {};
}

void TTorrentClient::remove_orphan_resume_temp_files()
{
    std::scoped_lock io_guard(resume_io_lock);
    bool removed = false;
    try {
        std::string const marker = std::string(kResumeExtension) + std::string(kTempExtension) + ".";
        std::string const tombstone_marker = removal_tombstone_suffix() + std::string(kTempExtension) + ".";
        DirectoryNamesResult const names = directory_entry_names(
            resume_directory_descriptor.get(),
            "Resume data directory could not be scanned"
        );
        if (!names) {
            return;
        }
        for (std::string const &name : *names) {
            RegularFileResult const regular = is_regular_file_at(
                resume_directory_descriptor.get(),
                name,
                "Resume data file could not be inspected"
            );
            if (!regular || !*regular) {
                continue;
            }

            if (name.contains(marker) || name.contains(tombstone_marker)) {
                removed = remove_resume_file_locked(name) || removed;
            }
        }
    } catch (...) {
        ignore_shutdown_failure();
    }

    if (removed) {
        sync_resume_directory_quietly();
    }
}

void TTorrentClient::load_resume_data()
{
    std::set<std::string> tombstoned_ids;
    {
        std::scoped_lock io_guard(resume_io_lock);
        TombstoneIDResult tombstones = removal_tombstone_ids_locked();
        if (!tombstones) {
            throw std::runtime_error(tombstones.error());
        }
        tombstoned_ids = std::move(*tombstones);
    }

    DirectoryNamesResult const names = directory_entry_names(
        resume_directory_descriptor.get(),
        "Resume data directory could not be scanned"
    );
    if (!names) {
        throw std::runtime_error(names.error());
    }

    std::uint64_t unauthorized_resume_count = 0U;
    std::size_t restore_add_attempt_count = 0U;
    auto const record_unauthorized_resume = [&unauthorized_resume_count] {
        if (unauthorized_resume_count != std::numeric_limits<std::uint64_t>::max()) {
            ++unauthorized_resume_count;
        }
    };
    auto const drain_restore_alerts_if_needed = [this, &restore_add_attempt_count] {
        ++restore_add_attempt_count;
        if (restore_add_attempt_count % kSynchronousAddAlertDrainInterval == 0U) {
            pump_alerts();
        }
    };

    for (std::string const &name : *names) {
        RegularFileResult const regular = is_regular_file_at(
            resume_directory_descriptor.get(),
            name,
            "Resume data file could not be inspected"
        );
        if (!regular || !*regular) {
            continue;
        }
        std::optional<std::string> const resume_id = resume_id_from_resume_path(fs::path(name));
        if (!resume_id) {
            continue;
        }
        if (tombstoned_ids.contains(*resume_id)) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
        BridgeResult const admission = ensure_torrent_admission_available(3);
        if (!admission) {
            static_cast<void>(publish_changes_locked(queue_alert_error(
                "Resume restore stopped: " + admission.error().message
                + " Remaining resume data was preserved."
            )));
            break;
        }

        FileReadResult const buffer = read_file_at(
            resume_directory_descriptor.get(),
            name,
            kMaxResumeFileBytes
        );
        if (!buffer) {
            if (resume_read_failure_is_definitively_invalid(buffer.error())) {
                remove_resume_file_locked(name);
                sync_resume_directory_quietly();
            }
            continue;
        }

        lt::error_code read_error;
        lt::add_torrent_params params = lt::read_resume_data(
            lt::span<char const>(buffer->data(), static_cast<int>(buffer->size())),
            read_error
        );
        if (read_error) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }

        std::optional<std::string> const authorized_save_path = normalize_authorized_save_path(
            params.save_path
        );
        auto const authorized_root = authorized_save_path
            ? authorized_save_roots.find(*authorized_save_path)
            : authorized_save_roots.end();
        if (!authorized_save_path || authorized_root == authorized_save_roots.end()) {
            record_unauthorized_resume();
            continue;
        }
        params.save_path = *authorized_save_path;
        params.storage_root = authorized_root->second;

        if (!resume_filename_matches_identity(*resume_id, params)) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
        std::string canonical_id = canonical_id_from_resume_data(*buffer);
        if (canonical_id.empty()) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
        if (params.ti) {
            BridgeResult const valid_info = validate_torrent_info(params);
            if (!valid_info) {
                remove_resume_file_locked(name);
                sync_resume_directory_quietly();
                continue;
            }
        }
        bool const metadata_pending = !params.ti;
        bool const persisted_metadata_pending =
            metadata_validation_pending_from_resume_data(*buffer);
        bool const allow_pre_metadata_dht = metadata_pending
            && persisted_metadata_pending
            && allow_pre_metadata_dht_from_resume_data(*buffer);
        bool const intended_default_dont_download = metadata_pending
            && static_cast<bool>(params.flags & lt::torrent_flags::default_dont_download);
        std::vector<lt::download_priority_t> intended_file_priorities = metadata_pending
            ? params.file_priorities
            : std::vector<lt::download_priority_t>{};
        if (metadata_pending) {
            sanitize_magnet_endpoint_hints(params);
        } else {
            sanitize_resume_endpoint_hints(params);
        }
        lt::add_torrent_params const source_params = params;
        bool const allows_non_https_trackers =
            allow_non_https_trackers_from_resume_data(*buffer);
        bool const allows_non_https_web_seeds =
            allow_non_https_web_seeds_from_resume_data(*buffer);
        bool const requires_https_trackers =
            require_https_trackers_from_resume_data(*buffer);
        bool const requires_https_web_seeds =
            require_https_web_seeds_from_resume_data(*buffer);
        int32_t const queue_priority =
            queue_priority_from_resume_data(*buffer);
        int32_t const queue_rank =
            queue_rank_from_resume_data(*buffer);
        bool const dht_enabled_by_user =
            enable_dht_from_resume_data(*buffer);
        bool const dht_disabled_by_user =
            disable_dht_from_resume_data(*buffer);
        bool const app_disabled_dht =
            app_disabled_dht_from_resume_data(*buffer) && !dht_enabled_by_user && !dht_disabled_by_user;
        bool const peer_exchange_enabled_by_user =
            enable_peer_exchange_from_resume_data(*buffer);
        bool const peer_exchange_disabled_by_user =
            disable_peer_exchange_from_resume_data(*buffer);
        bool const lsd_enabled_by_user =
            enable_lsd_from_resume_data(*buffer);
        bool const lsd_disabled_by_user =
            disable_lsd_from_resume_data(*buffer);
        bool const app_disabled_lsd =
            app_disabled_lsd_from_resume_data(*buffer) && !lsd_enabled_by_user && !lsd_disabled_by_user;
        bool const has_private_metadata = params.ti && params.ti->priv();
        // A metadata-less app resume can only contain temporary discovery
        // guards or explicit app policy. Source locks are established only
        // after the torrent metadata itself has been validated.
        bool const dht_locked_by_source = has_private_metadata
            || (!metadata_pending
                && static_cast<bool>(params.flags & lt::torrent_flags::disable_dht)
                && !dht_enabled_by_user
                && !dht_disabled_by_user);
        bool const peer_exchange_locked_by_source = has_private_metadata
            || (!metadata_pending
                && static_cast<bool>(params.flags & lt::torrent_flags::disable_pex)
                && !peer_exchange_enabled_by_user
                && !peer_exchange_disabled_by_user);
        bool const lsd_locked_by_source = has_private_metadata
            || (!metadata_pending
                && static_cast<bool>(params.flags & lt::torrent_flags::disable_lsd)
                && !lsd_enabled_by_user
                && !lsd_disabled_by_user);
        if (requires_https_trackers || requires_https_web_seeds) {
            static_cast<void>(filter_non_https_sources(params, requires_https_trackers, requires_https_web_seeds));
        }
        BridgeResult const valid_sources = validate_torrent_sources(params);
        if (!valid_sources) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
        if (dht_locked_by_source || dht_disabled_by_user
            || (app_disabled_dht && !(metadata_pending && allow_pre_metadata_dht))
            || (metadata_pending && !allow_pre_metadata_dht)) {
            params.flags |= lt::torrent_flags::disable_dht;
        } else if (dht_enabled_by_user || allow_pre_metadata_dht) {
            params.flags &= ~lt::torrent_flags::disable_dht;
        }
        if (peer_exchange_locked_by_source || peer_exchange_disabled_by_user || metadata_pending) {
            params.flags |= lt::torrent_flags::disable_pex;
        } else if (peer_exchange_enabled_by_user) {
            params.flags &= ~lt::torrent_flags::disable_pex;
        }
        if (lsd_locked_by_source || lsd_disabled_by_user || app_disabled_lsd || metadata_pending) {
            params.flags |= lt::torrent_flags::disable_lsd;
        } else if (lsd_enabled_by_user) {
            params.flags &= ~lt::torrent_flags::disable_lsd;
        }
        if (metadata_pending) {
            params.file_priorities.clear();
            params.flags |= lt::torrent_flags::default_dont_download;
            params.flags |= lt::torrent_flags::block_non_global_peers;
        }
        if (!metadata_pending && should_strip_resume_peer_cache(params, nullptr, app_disabled_dht)) {
            strip_resume_peer_cache(params);
        }

        bool const manually_paused = (params.flags & lt::torrent_flags::paused)
            && !(params.flags & lt::torrent_flags::auto_managed);
        if (manually_paused) {
            params.flags &= ~lt::torrent_flags::auto_managed;
        } else {
            params.flags |= lt::torrent_flags::auto_managed;
            params.flags |= lt::torrent_flags::paused;
        }
        params.flags |= lt::torrent_flags::duplicate_is_error;
        params.flags |= lt::torrent_flags::update_subscribe;

        TorrentIdentity *identity = attach_identity(params, std::move(canonical_id));
        identity->allows_non_https_trackers = allows_non_https_trackers;
        identity->allows_non_https_web_seeds = allows_non_https_web_seeds;
        identity->requires_https_trackers = requires_https_trackers;
        identity->requires_https_web_seeds = requires_https_web_seeds;
        identity->queue_priority = queue_priority;
        identity->queue_rank = queue_rank;
        identity->dht_locked_by_source = dht_locked_by_source;
        identity->peer_exchange_locked_by_source = peer_exchange_locked_by_source;
        identity->lsd_locked_by_source = lsd_locked_by_source;
        identity->allow_pre_metadata_dht = allow_pre_metadata_dht;
        identity->intended_default_dont_download = intended_default_dont_download;
        identity->intended_file_priorities = std::move(intended_file_priorities);
        identity->dht_enabled_by_user = dht_enabled_by_user && !dht_disabled_by_user && !dht_locked_by_source;
        identity->dht_disabled_by_user = dht_disabled_by_user && !dht_locked_by_source;
        identity->peer_exchange_enabled_by_user =
            peer_exchange_enabled_by_user && !peer_exchange_disabled_by_user && !peer_exchange_locked_by_source;
        identity->peer_exchange_disabled_by_user = peer_exchange_disabled_by_user && !peer_exchange_locked_by_source;
        identity->lsd_enabled_by_user = lsd_enabled_by_user && !lsd_disabled_by_user && !lsd_locked_by_source;
        identity->lsd_disabled_by_user = lsd_disabled_by_user && !lsd_locked_by_source;
        remember_source_policy_sources(*identity, source_params);
        lt::error_code add_error;
        lt::torrent_handle handle = session.add_torrent(std::move(params), add_error);
        if (add_error) {
            discard_unpublished_identity(identity);
            drain_restore_alerts_if_needed();
            continue;
        }
        mark_active(handle, identity);
        if (app_disabled_dht && !dht_locked_by_source) {
            dht_disabled_by_app.insert(identity);
        }
        if (app_disabled_lsd && !lsd_locked_by_source) {
            lsd_disabled_by_app.insert(identity);
        }
        if (metadata_pending) {
            metadata_validation_pending.insert(identity);
        }
        drain_restore_alerts_if_needed();
    }

    // Process the final partial batch before rebuilding the externally visible
    // cache. This also surfaces restore-time storage and fast-resume errors.
    pump_alerts();

    if (unauthorized_resume_count != 0U) {
        std::string const noun = unauthorized_resume_count == 1U ? "torrent" : "torrents";
        static_cast<void>(publish_changes_locked(queue_alert_error(
            "Skipped restoring " + std::to_string(unauthorized_resume_count) + " saved " + noun
            + " because download folder access is not authorized. Resume data was preserved."
        )));
    }
    static_cast<void>(apply_queue_priority_order_locked());
}

} // namespace torrent_bridge::internal
