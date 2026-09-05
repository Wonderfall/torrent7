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

void TTorrentClient::discard_unpublished_identity(TorrentIdentity *identity) noexcept
{
    std::scoped_lock io_guard(resume_io_lock);
    dht_disabled_by_app.erase(identity);
    lsd_disabled_by_app.erase(identity);
    peer_exchange_disabled_by_app.erase(identity);
    metadata_validation_pending.erase(identity);
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

std::vector<std::string> TTorrentClient::removal_ids_for_identity(lt::info_hash_t const &hashes, std::string_view requested_id,
                                                  TorrentIdentity *identity)
{
    std::vector<std::string> ids = hash_keys_with_requested(hashes, requested_id);
    std::scoped_lock io_guard(resume_io_lock);
    if (identity == nullptr) {
        return ids;
    }

    append_unique(ids, identity->canonical_id);
    return ids;
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
            .ids = std::move(payload->ids)
        });
    }
    return entries;
}

TombstoneEntriesResult TTorrentClient::removal_tombstone_entries_locked()
{
    return scan_removal_tombstone_entries_locked(RemovalTombstoneIndexLimits{
        .entry_count = kMaxRemovalTombstoneEntryCount,
        .id_membership_count = kMaxRemovalTombstoneIDMembershipCount,
    });
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

    TombstoneEntriesResult const entries = removal_tombstone_entries_locked();
    if (!entries) {
        return std::unexpected(entries.error());
    }
    std::vector<std::string> matched_ids;
    for (RemovalTombstoneEntry const &entry : *entries) {
        bool const overlaps = std::ranges::any_of(entry.ids, [&normalized](std::string const &id) {
            return std::ranges::find(*normalized, id) != normalized->end();
        });
        if (!overlaps) {
            continue;
        }
        for (std::string const &id : entry.ids) {
            append_unique(matched_ids, id);
        }
    }
    return matched_ids;
}

TombstoneCommitResult TTorrentClient::persist_removal_tombstones_locked(std::vector<std::string> const &ids)
{
    ResumeIDListResult normalized = normalized_resume_ids(ids);
    if (!normalized) {
        return std::unexpected(normalized.error());
    }
    if (normalized->empty()) {
        return TombstoneCommitStatus{};
    }

    std::string const payload = tombstone_payload(*normalized);
    if (payload.empty() || payload.size() > kMaxRemovalTombstoneBytes) {
        return std::unexpected("Removal tombstone payload is too large.");
    }

    TombstoneEntriesResult const entries = removal_tombstone_entries_locked();
    if (!entries) {
        return std::unexpected(entries.error());
    }
    if (entries->size() >= kMaxRemovalTombstoneEntryCount) {
        return std::unexpected("Removal tombstone index contains too many entries.");
    }
    std::size_t membership_count = 0;
    for (RemovalTombstoneEntry const &entry : *entries) {
        membership_count += entry.ids.size();
    }
    if (membership_count > kMaxRemovalTombstoneIDMembershipCount
        || normalized->size()
            > kMaxRemovalTombstoneIDMembershipCount - membership_count) {
        return std::unexpected("Removal tombstone index contains too many identifier references.");
    }

    std::set<std::string> existing_filenames;
    for (RemovalTombstoneEntry const &entry : *entries) {
        existing_filenames.insert(entry.filename);
    }

    std::string tombstone_filename;
    constexpr std::size_t kMaxFilenameAttempts = 16U;
    for (std::size_t attempt = 0; attempt < kMaxFilenameAttempts; ++attempt) {
        tombstone_filename = make_removal_tombstone_filename();
        if (!existing_filenames.contains(tombstone_filename)) {
            break;
        }
        tombstone_filename.clear();
    }
    if (tombstone_filename.empty()) {
        return std::unexpected("A unique removal tombstone filename could not be created.");
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
            .directory_synced = false,
            .filename = tombstone_filename,
        };
    }

    return TombstoneCommitStatus{
        .directory_synced = true,
        .filename = tombstone_filename,
    };
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

    TombstoneEntriesResult const entries = removal_tombstone_entries_locked();
    if (!entries) {
        return std::unexpected(entries.error());
    }
    bool removed_any = false;
    for (RemovalTombstoneEntry const &entry : *entries) {
        bool const covers_entry = std::ranges::all_of(entry.ids, [&normalized](std::string const &id) {
            return std::ranges::find(*normalized, id) != normalized->end();
        });
        if (!covers_entry) {
            continue;
        }

        ResumeRemoveResult removed_tombstone = remove_resume_file_checked_locked(entry.filename);
        if (!removed_tombstone) {
            return std::unexpected("Removal tombstone could not be cleared: " + removed_tombstone.error());
        }
        removed_any = *removed_tombstone || removed_any;
    }

    if (removed_any) {
        return sync_directory(resume_directory_descriptor.get());
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
    DirectoryNamesResult const names = directory_entry_names(
        resume_directory_descriptor.get(),
        "Resume data directory could not be scanned"
    );
    if (!names) {
        throw std::runtime_error(names.error());
    }

    std::uint64_t unclaimed_resume_count = 0U;
    std::uint64_t duplicate_identity_resume_count = 0U;
    std::size_t restore_add_attempt_count = 0U;
    auto const record_unclaimed_resume = [&unclaimed_resume_count] {
        if (unclaimed_resume_count != std::numeric_limits<std::uint64_t>::max()) {
            ++unclaimed_resume_count;
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

        ResumeInfoSectionResult persisted_info_result =
            preparsed_info_from_resume_data(*buffer);
        if (!persisted_info_result) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
        std::optional<std::vector<char>> persisted_info =
            std::move(*persisted_info_result);

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
        if (params.ti) {
            // preparsed_info_from_resume_data() rejects the legacy nested
            // representation before libtorrent can semantically import it.
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }

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
        {
            std::scoped_lock io_guard(resume_io_lock);
            if (canonical_ids_in_use.contains(canonical_id)) {
                if (duplicate_identity_resume_count != std::numeric_limits<std::uint64_t>::max()) {
                    ++duplicate_identity_resume_count;
                }
                continue;
            }
        }
        bool const persisted_metadata_pending =
            metadata_validation_pending_from_resume_data(*buffer);
        std::optional<TTorrentStorageActivation> const storage_activation =
            storage_activation_from_resume_data(*buffer);
        bool const metadata_pending = !persisted_info.has_value();
        auto const staged_metadata = staged_metadata_from_resume_data(*buffer);
        if (!staged_metadata || (*staged_metadata && (metadata_pending || persisted_metadata_pending))) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
        bool const staged = metadata_pending || *staged_metadata;
        if (metadata_pending) {
            if (storage_activation || !persisted_metadata_pending) {
                record_unclaimed_resume();
                continue;
            }
        } else {
            if (persisted_metadata_pending) {
                remove_resume_file_locked(name);
                sync_resume_directory_quietly();
                continue;
            }
            if (!swarm_metadata_parser) {
                if (!storage_activation) {
                    record_unclaimed_resume();
                    continue;
                }
                remove_resume_file_locked(name);
                sync_resume_directory_quietly();
                continue;
            }
            lt::error_code metadata_error;
            std::shared_ptr<lt::torrent_info> imported_info =
                swarm_metadata_parser->parse(
                    lt::span<char const>(
                        persisted_info->data(),
                        static_cast<int>(persisted_info->size())
                    ),
                    metadata_error
                );
            if (metadata_error || !imported_info
                || imported_info->info_hashes() != params.info_hashes) {
                remove_resume_file_locked(name);
                sync_resume_directory_quietly();
                continue;
            }
            params.ti = std::move(imported_info);
            BridgeResult const valid_info = validate_torrent_info(params);
            if (!valid_info) {
                remove_resume_file_locked(name);
                sync_resume_directory_quietly();
                continue;
            }
            BridgeResult const valid_merkle_state = validate_resume_merkle_state(params);
            if (!valid_merkle_state) {
                remove_resume_file_locked(name);
                sync_resume_directory_quietly();
                continue;
            }
            if (!storage_activation && !staged) {
                record_unclaimed_resume();
                continue;
            }
        }
        if (storage_activation) {
            BridgeResult const valid_activation = validate_storage_activation(
                params,
                *storage_activation
            );
            if (!valid_activation) {
                record_unclaimed_resume();
                continue;
            }
            params.save_path = part_file_path(*storage_activation);
            params.file_provider = make_payload_provider(*storage_activation);
        } else {
            params.save_path = staging_path(params.info_hashes);
            params.file_provider.reset();
        }
        bool const allow_pre_metadata_dht = metadata_pending
            && persisted_metadata_pending
            && allow_pre_metadata_dht_from_resume_data(*buffer);
        bool const intended_default_dont_download = staged
            && static_cast<bool>(params.flags & lt::torrent_flags::default_dont_download);
        std::vector<lt::download_priority_t> intended_file_priorities = staged
            ? params.file_priorities
            : std::vector<lt::download_priority_t>{};
        if (metadata_pending) {
            sanitize_magnet_endpoint_hints(params);
        } else {
            sanitize_resume_endpoint_hints(params);
        }
        lt::add_torrent_params const source_params = params;
        BridgeResult const valid_original_sources = validate_torrent_sources(source_params);
        if (!valid_original_sources) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
        HTTPSPolicy const persisted_https_tracker_policy =
            https_tracker_policy_from_resume_data(*buffer);
        HTTPSPolicy const persisted_https_web_seed_policy =
            https_web_seed_policy_from_resume_data(*buffer);
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
        static_cast<void>(apply_https_source_policy(
            params,
            HTTPSSourcePolicy{
                .trackers = persisted_https_tracker_policy == HTTPSPolicy::inherit
                    ? HTTPSPolicy::prefer
                    : persisted_https_tracker_policy,
                .web_seeds = persisted_https_web_seed_policy == HTTPSPolicy::inherit
                    ? HTTPSPolicy::require
                    : persisted_https_web_seed_policy,
            }
        ));
        BridgeResult const valid_sources = validate_torrent_sources(params);
        if (!valid_sources) {
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
        if (dht_locked_by_source || dht_disabled_by_user
            || (app_disabled_dht && !(metadata_pending && allow_pre_metadata_dht))
            || (staged && !allow_pre_metadata_dht)) {
            params.flags |= lt::torrent_flags::disable_dht;
        } else if (dht_enabled_by_user || allow_pre_metadata_dht) {
            params.flags &= ~lt::torrent_flags::disable_dht;
        }
        if (peer_exchange_locked_by_source || peer_exchange_disabled_by_user || staged) {
            params.flags |= lt::torrent_flags::disable_pex;
        } else if (peer_exchange_enabled_by_user) {
            params.flags &= ~lt::torrent_flags::disable_pex;
        }
        if (lsd_locked_by_source || lsd_disabled_by_user || app_disabled_lsd || staged) {
            params.flags |= lt::torrent_flags::disable_lsd;
        } else if (lsd_enabled_by_user) {
            params.flags &= ~lt::torrent_flags::disable_lsd;
        }
        params.flags |= lt::torrent_flags::block_non_global_peers;
        if (staged) {
            params.file_priorities.assign(
                params.ti ? static_cast<std::size_t>(params.ti->layout().num_files()) : 0U,
                lt::dont_download
            );
            params.piece_priorities.clear();
            params.flags |= lt::torrent_flags::default_dont_download;
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
        identity->storage_activation = storage_activation;
        identity->https_tracker_policy = persisted_https_tracker_policy;
        identity->https_web_seed_policy = persisted_https_web_seed_policy;
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
        BridgeResult const remembered_sources = remember_source_policy_sources(*identity, source_params);
        if (!remembered_sources) {
            discard_unpublished_identity(identity);
            remove_resume_file_locked(name);
            sync_resume_directory_quietly();
            continue;
        }
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

    // Process the final partial batch before refreshing externally visible
    // status. This also surfaces restore-time storage and fast-resume errors.
    pump_alerts();

    if (unclaimed_resume_count != 0U) {
        std::string const noun = unclaimed_resume_count == 1U ? "torrent" : "torrents";
        static_cast<void>(publish_changes_locked(queue_alert_error(
            "Skipped restoring " + std::to_string(unclaimed_resume_count) + " saved " + noun
            + " because brokered storage authority was missing or invalid. Resume data was preserved."
        )));
    }
    if (duplicate_identity_resume_count != 0U) {
        std::string const noun = duplicate_identity_resume_count == 1U ? "record" : "records";
        static_cast<void>(publish_changes_locked(queue_alert_error(
            "Skipped restoring " + std::to_string(duplicate_identity_resume_count)
            + " saved resume " + noun
            + " because its canonical Swift identity was duplicated. Resume data was preserved."
        )));
    }
}

} // namespace torrent_bridge::internal
