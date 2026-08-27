#include "TorrentBridgeInternal.hpp"

extern "C" {
__attribute__((visibility("hidden"), used, retain))
extern char const torrent7_native_deps_build_id[] = TORRENT7_NATIVE_DEPS_BUILD_ID;
}

#if __has_feature(address_sanitizer)
extern "C" __attribute__((visibility("default"), used, retain))
char const *__asan_default_options()
{
    // Enhanced Security helpers are launched by the system and may not inherit
    // the test runner's environment. Make every helper-side violation fail the lane.
    return "halt_on_error=1:abort_on_error=1";
}
#endif

#if __has_feature(thread_sanitizer)
extern "C" __attribute__((visibility("default"), used, retain))
char const *__tsan_default_options()
{
    // Enhanced Security helpers are launched by the system and may not inherit
    // the test runner's environment. Make every helper-side race fail the lane.
    return "halt_on_error=1:exitcode=66:print_full_thread_history=1";
}
#endif

namespace torrent_bridge::internal {

namespace {

constexpr int kUnlimitedTorrentCountLimit = static_cast<int>((1U << 24U) - 1U);

int normalized_torrent_count_limit(int limit)
{
    return limit >= kUnlimitedTorrentCountLimit ? -1 : limit;
}

bool is_valid_torrent_count_limit(int limit)
{
    return limit == -1 || limit >= 2;
}

struct ActiveTorrentEntry {
    lt::torrent_handle handle;
    TorrentIdentity *identity = nullptr;
};

ResumeIDListResult resume_ids_from_bridge(std::span<TTorrentResumeID const> const rows)
{
    if (rows.empty() || rows.size() > static_cast<std::size_t>(TTORRENT_MAX_RESUME_ID_COUNT)) {
        return std::unexpected("Invalid resume identifier count.");
    }

    std::vector<std::string> ids;
    ids.reserve(rows.size());
    for (TTorrentResumeID const &row : rows) {
        auto const terminator = std::ranges::find(row.value, '\0');
        if (terminator == std::ranges::end(row.value)) {
            return std::unexpected("Resume identifier is not terminated.");
        }
        std::string id(row.value, terminator);
        if (!is_resume_data_id(id)
            || std::ranges::find(ids, id) != ids.end()) {
            return std::unexpected("Resume identifier is invalid or duplicated.");
        }
        ids.push_back(std::move(id));
    }
    return ids;
}

std::vector<ActiveTorrentEntry> active_torrent_entries(TTorrentClient const &client)
{
    std::vector<ActiveTorrentEntry> entries;
    std::scoped_lock io_guard(client.resume_io_lock);
    entries.reserve(client.handle_by_native_token.size());
    for (auto const &owned_identity : client.torrent_identities) {
        TorrentIdentity *const identity = owned_identity.get();
        if (identity == nullptr || identity->token == nullptr) {
            continue;
        }
        auto const handle = client.handle_by_native_token.find(identity->token->value);
        if (handle != client.handle_by_native_token.end() && handle->second.is_valid()) {
            entries.push_back(ActiveTorrentEntry{
                .handle = handle->second,
                .identity = identity,
            });
        }
    }
    return entries;
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

void save_and_publish_policy_handles(TTorrentClient &client, std::span<lt::torrent_handle const> handles,
                                     LockedChangePublisher &publisher) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    for (lt::torrent_handle const &handle : handles) {
        client.request_save_locked(handle, kPolicyResumeSaveFlags);
        publisher.add(client.observe_torrent_handle(handle));
    }
}

struct ResolvedQueuePlacement {
    lt::torrent_handle handle;
    TorrentIdentity *identity = nullptr;
    int32_t priority = TTORRENT_QUEUE_PRIORITY_NORMAL;
    int32_t rank = 0;
    std::optional<int> previous_position;
    int32_t previous_priority = TTORRENT_QUEUE_PRIORITY_NORMAL;
    int32_t previous_rank = kUnsetQueueRank;
};

BridgeResult apply_queue_state_locked(
    TTorrentClient &client,
    std::span<TTorrentQueuePlacement const> placements,
    LockedChangePublisher &publisher
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    std::vector<ActiveTorrentEntry> const active_entries = active_torrent_entries(client);
    if (placements.size() != active_entries.size()) {
        return bridge_error(2, "The Swift queue state did not cover every active torrent.");
    }

    std::unordered_map<std::uint64_t, ActiveTorrentEntry const *> active_by_token;
    active_by_token.reserve(active_entries.size());
    for (ActiveTorrentEntry const &entry : active_entries) {
        if (entry.identity == nullptr
            || entry.identity->token == nullptr
            || entry.identity->token->value == 0U
            || !active_by_token.emplace(entry.identity->token->value, &entry).second) {
            return bridge_error(2, "The native queue identities were inconsistent.");
        }
    }

    std::array<int32_t, 3> next_rank{};
    std::set<TorrentIdentity *> seen;
    std::vector<ResolvedQueuePlacement> resolved;
    resolved.reserve(placements.size());
    for (TTorrentQueuePlacement const &placement : placements) {
        if (placement.native_token == 0U || !is_valid_queue_priority(placement.priority)) {
            return bridge_error(1, "The Swift queue state was invalid.");
        }
        auto const active = active_by_token.find(placement.native_token);
        if (active == active_by_token.end() || !seen.insert(active->second->identity).second) {
            return bridge_error(2, "The Swift queue state contained an unknown or duplicate torrent.");
        }

        int32_t const rank = next_rank.at(static_cast<std::size_t>(placement.priority))++;
        resolved.push_back(ResolvedQueuePlacement{
            .handle = active->second->handle,
            .identity = active->second->identity,
            .priority = placement.priority,
            .rank = rank,
            .previous_position = queue_position_value(active->second->handle),
            .previous_priority = active->second->identity->queue_priority,
            .previous_rank = active->second->identity->queue_rank,
        });
    }

    std::vector<std::pair<int, lt::torrent_handle>> previous_native_order;
    previous_native_order.reserve(resolved.size());
    for (ResolvedQueuePlacement const &entry : resolved) {
        if (entry.previous_position) {
            previous_native_order.emplace_back(*entry.previous_position, entry.handle);
        }
    }
    std::ranges::sort(previous_native_order, {}, &std::pair<int, lt::torrent_handle>::first);

    try {
        int next_position = 0;
        for (ResolvedQueuePlacement &entry : resolved) {
            entry.identity->queue_priority = entry.priority;
            entry.identity->queue_rank = entry.rank;
            if (entry.previous_position) {
                entry.handle.queue_position_set(lt::queue_position_t(next_position++));
            }
        }
    } catch (std::exception const &exception) {
        for (ResolvedQueuePlacement const &entry : resolved) {
            entry.identity->queue_priority = entry.previous_priority;
            entry.identity->queue_rank = entry.previous_rank;
        }
        int position = 0;
        for (auto const &[previous_position, handle] : previous_native_order) {
            static_cast<void>(previous_position);
            try {
                handle.queue_position_set(lt::queue_position_t(position++));
            } catch (...) {
                ignore_shutdown_failure();
            }
        }
        return bridge_error(2, std::string("The native queue state could not be applied: ") + exception.what());
    } catch (...) {
        for (ResolvedQueuePlacement const &entry : resolved) {
            entry.identity->queue_priority = entry.previous_priority;
            entry.identity->queue_rank = entry.previous_rank;
        }
        int position = 0;
        for (auto const &[previous_position, handle] : previous_native_order) {
            static_cast<void>(previous_position);
            try {
                handle.queue_position_set(lt::queue_position_t(position++));
            } catch (...) {
                ignore_shutdown_failure();
            }
        }
        return bridge_error(2, "The native queue state could not be applied.");
    }

    std::vector<lt::torrent_handle> handles;
    handles.reserve(resolved.size());
    for (ResolvedQueuePlacement const &entry : resolved) {
        handles.push_back(entry.handle);
    }
    save_and_publish_policy_handles(client, handles, publisher);
    client.request_snapshot_update_locked();
    return {};
}

} // namespace

namespace {

struct NativeNetworkStateExpectation {
    std::string_view listen_interfaces;
    std::string_view outgoing_interfaces;
    bool enable_upnp;
    bool enable_natpmp;
    bool enable_dht;
    bool enable_lsd;
    bool enable_outgoing_tcp;
    bool enable_incoming_tcp;
    bool enable_outgoing_utp;
    bool enable_incoming_utp;
    bool dht_privacy_lookups;
    std::optional<bool> dht_read_only;
    std::optional<bool> use_dht_as_fallback;
    bool session_paused;
};

BridgeResult acknowledge_network_state_locked(
    TTorrentClient &client,
    NativeNetworkStateExpectation const &expected,
    std::string_view failure_message
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    // get_settings() and is_paused() are synchronous libtorrent-context calls.
    // They cannot complete until the settings and pause/resume operations queued
    // before them have run on the session's single network executor.
    lt::settings_pack const current = client.session.get_settings();
    bool const session_paused = client.session.is_paused();
    if (current.get_str(lt::settings_pack::listen_interfaces) != expected.listen_interfaces
        || current.get_str(lt::settings_pack::outgoing_interfaces) != expected.outgoing_interfaces
        || current.get_bool(lt::settings_pack::enable_upnp) != expected.enable_upnp
        || current.get_bool(lt::settings_pack::enable_natpmp) != expected.enable_natpmp
        || current.get_bool(lt::settings_pack::enable_dht) != expected.enable_dht
        || current.get_bool(lt::settings_pack::enable_lsd) != expected.enable_lsd
        || current.get_bool(lt::settings_pack::enable_outgoing_tcp) != expected.enable_outgoing_tcp
        || current.get_bool(lt::settings_pack::enable_incoming_tcp) != expected.enable_incoming_tcp
        || current.get_bool(lt::settings_pack::enable_outgoing_utp) != expected.enable_outgoing_utp
        || current.get_bool(lt::settings_pack::enable_incoming_utp) != expected.enable_incoming_utp
        || current.get_bool(lt::settings_pack::dht_privacy_lookups) != expected.dht_privacy_lookups
        || (expected.dht_read_only
            && current.get_bool(lt::settings_pack::dht_read_only) != *expected.dht_read_only)
        || (expected.use_dht_as_fallback
            && current.get_bool(lt::settings_pack::use_dht_as_fallback) != *expected.use_dht_as_fallback)
        || session_paused != expected.session_paused) {
        return bridge_error(2, std::string(failure_message));
    }
    return {};
}

BridgeResult block_network_locked(
    TTorrentClient &client,
    DirtyMask &changes
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    changes = 0U;

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
    settings.set_bool(lt::settings_pack::dht_privacy_lookups, false);
    client.session.apply_settings(std::move(settings));
    client.session.pause();

    BridgeResult const acknowledged = acknowledge_network_state_locked(
        client,
        NativeNetworkStateExpectation{
            .listen_interfaces = "",
            .outgoing_interfaces = "",
            .enable_upnp = false,
            .enable_natpmp = false,
            .enable_dht = false,
            .enable_lsd = false,
            .enable_outgoing_tcp = false,
            .enable_incoming_tcp = false,
            .enable_outgoing_utp = false,
            .enable_incoming_utp = false,
            .dht_privacy_lookups = false,
            .dht_read_only = std::nullopt,
            .use_dht_as_fallback = std::nullopt,
            .session_paused = true,
        },
        "Native network containment could not be confirmed."
    );
    if (!acknowledged) {
        return acknowledged;
    }

    changes = client.record_network_blocked();
    client.request_snapshot_update_locked();
    return {};
}

[[nodiscard]] int callback_error_code(int32_t const code) noexcept
{
    return code > 0 ? code : EIO;
}

void assign_callback_error(lt::error_code &error, int32_t const code) noexcept
{
    error.assign(callback_error_code(code), lt::generic_category());
}

[[nodiscard]] bool all_zero(std::span<std::uint8_t const> const bytes) noexcept
{
    return std::ranges::all_of(bytes, [](std::uint8_t const byte) {
        return byte == 0U;
    });
}

void append_u64(std::vector<char> &bytes, std::uint64_t const value)
{
    for (unsigned int shift = 56U;; shift -= 8U) {
        bytes.push_back(static_cast<char>(static_cast<std::uint8_t>(value >> shift)));
        if (shift == 0U) {
            break;
        }
    }
}

void append_string(std::vector<char> &bytes, std::string_view const value)
{
    append_u64(bytes, value.size());
    bytes.insert(bytes.end(), value.begin(), value.end());
}

void append_optional_hash(
    std::vector<char> &bytes,
    bool const present,
    char const *value,
    std::size_t const size
)
{
    bytes.push_back(present ? '\x01' : '\0');
    if (!present) {
        return;
    }
    append_u64(bytes, size);
    bytes.insert(bytes.end(), value, std::next(value, static_cast<std::ptrdiff_t>(size)));
}

[[nodiscard]] std::vector<std::string> split_manifest_path(std::string_view path)
{
    std::vector<std::string> components;
    while (!path.empty()) {
        std::size_t const separator = path.find('/');
        std::string_view const component = path.substr(0U, separator);
        if (component.empty()) {
            throw std::invalid_argument("The torrent contains an invalid logical path.");
        }
        components.emplace_back(component);
        if (separator == std::string_view::npos) {
            break;
        }
        path.remove_prefix(separator + 1U);
    }
    return components;
}

[[nodiscard]] std::string rootless_manifest_name(lt::info_hash_t const &hashes)
{
    if (!hashes.has_v2()) {
        return {};
    }
    constexpr std::array<char, 16> alphabet{
        '0', '1', '2', '3', '4', '5', '6', '7',
        '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
    };
    std::string name = "Torrent-";
    std::string const digest = hashes.v2.to_string();
    for (std::size_t index = 0U; index < 6U; ++index) {
        auto const byte = static_cast<std::uint8_t>(digest.at(index));
        name.push_back(alphabet.at(byte >> 4U));
        name.push_back(alphabet.at(byte & 0x0fU));
    }
    return name;
}

[[nodiscard]] lt::sha256_hash logical_manifest_digest(lt::add_torrent_params const &params)
{
    if (!params.ti) {
        throw std::invalid_argument("The torrent metadata is unavailable.");
    }

    lt::torrent_info const &info = *params.ti;
    lt::file_storage const &files = info.layout();
    if (files.num_files() <= 0) {
        throw std::invalid_argument("The torrent has no files.");
    }

    lt::file_index_t first_payload{0};
    int payload_count = 0;
    for (lt::file_index_t const file : files.file_range()) {
        if (!files.pad_file_at(file)) {
            if (payload_count == 0) {
                first_payload = file;
            }
            ++payload_count;
        }
    }
    if (payload_count == 0) {
        throw std::invalid_argument("The torrent has no payload files.");
    }

    std::string name = files.name();
    if (name.empty()) {
        name = rootless_manifest_name(info.info_hashes());
    }
    if (name.empty()) {
        throw std::invalid_argument("The torrent has no logical name.");
    }

    bool const single_file = payload_count == 1
        && files.file_path(first_payload) == files.name();

    std::vector<char> input;
    static constexpr auto domain = std::to_array("Torrent7 logical storage manifest\0v1");
    auto const domain_bytes = std::span{domain}.first<domain.size() - 1U>();
    input.insert(input.end(), domain_bytes.begin(), domain_bytes.end());
    append_string(input, name);
    input.push_back(single_file ? '\0' : '\x01');

    lt::info_hash_t const hashes = info.info_hashes();
    append_optional_hash(
        input,
        hashes.has_v1(),
        hashes.v1.data(),
        static_cast<std::size_t>(lt::sha1_hash::size())
    );
    append_optional_hash(
        input,
        hashes.has_v2(),
        hashes.v2.data(),
        static_cast<std::size_t>(lt::sha256_hash::size())
    );
    append_u64(input, static_cast<std::uint64_t>(info.piece_length()));
    append_u64(input, static_cast<std::uint64_t>(files.num_files()));

    for (lt::file_index_t const file : files.file_range()) {
        int const index = static_cast<int>(file);
        bool const padding = files.pad_file_at(file);
        append_u64(input, static_cast<std::uint64_t>(index));

        std::vector<std::string> components;
        if (padding) {
            components.emplace_back(".pad");
            components.push_back(
                std::to_string(files.file_size(file)) + "-" + std::to_string(index)
            );
        } else if (single_file) {
            components.push_back(name);
        } else {
            components = split_manifest_path(files.file_path(file));
            if (!files.name().empty() && !components.empty()
                && components.front() == files.name()) {
                components.erase(components.begin());
            }
            if (components.empty()) {
                throw std::invalid_argument("The torrent contains an empty logical path.");
            }
        }

        append_u64(input, components.size());
        for (std::string const &component : components) {
            append_string(input, component);
        }
        append_u64(input, static_cast<std::uint64_t>(files.file_size(file)));
        input.push_back(padding ? '\x01' : '\0');
    }

    return lt::hasher256(lt::span<char const>(input.data(), static_cast<int>(input.size()))).final();
}

[[nodiscard]] bool digest_matches(
    lt::sha256_hash const &digest,
    TTorrentStorageActivation const &activation
)
{
    std::uint8_t difference = 0U;
    std::string const actual = digest.to_string();
    std::array<std::uint8_t, 32> expected{};
    std::ranges::copy(activation.source_manifest_digest, expected.begin());
    for (std::size_t index = 0U; index < 32U; ++index) {
        auto const mismatch = static_cast<std::uint8_t>(
            static_cast<std::uint8_t>(actual.at(index)) ^ expected.at(index)
        );
        difference = static_cast<std::uint8_t>(difference | mismatch);
    }
    return difference == 0U;
}

} // namespace

BridgeResult TTorrentClient::contain_network_for_critical_fault_locked(
    DirtyMask &changes
)
{
    return block_network_locked(*this, changes);
}

#if defined(TORRENT_BRIDGE_TESTING)
lt::sha256_hash testing_logical_manifest_digest(lt::add_torrent_params const &params)
{
    return logical_manifest_digest(params);
}
#endif

BridgeSwarmMetadataParser::BridgeSwarmMetadataParser(
    TTorrentSwarmMetainfoParserCallbacks const callbacks
)
    : callbacks_{
        .context = callbacks.context,
        .retain_context = callbacks.retain_context,
        .release_context = callbacks.release_context,
        .parse_info = callbacks.parse_info,
        .release_capsule = callbacks.release_capsule,
    }
{
    if (callbacks_.context == nullptr
        || callbacks_.retain_context == nullptr
        || callbacks_.release_context == nullptr
        || callbacks_.parse_info == nullptr
        || callbacks_.release_capsule == nullptr) {
        throw std::invalid_argument("The swarm metainfo parser callback table is incomplete.");
    }
    retained_ = callbacks_.retain_context(callbacks_.context) != 0U;
    if (!retained_) {
        throw std::invalid_argument("The swarm metainfo parser context is unavailable.");
    }
}

BridgeSwarmMetadataParser::~BridgeSwarmMetadataParser()
{
    if (retained_) {
        callbacks_.release_context(callbacks_.context);
    }
}

std::shared_ptr<lt::torrent_info> BridgeSwarmMetadataParser::parse(
    lt::span<char const> const info,
    lt::error_code &error
) noexcept
{
    TTorrentOwnedMetainfoCapsule capsule{};
    struct CapsuleReleaseGuard final {
        CapsuleReleaseGuard(
            SwarmMetainfoParserCallbacks const *stored_callbacks,
            TTorrentOwnedMetainfoCapsule *stored_capsule
        ) noexcept
            : callbacks(stored_callbacks), capsule(stored_capsule)
        {
        }

        CapsuleReleaseGuard(CapsuleReleaseGuard const &) = delete;
        CapsuleReleaseGuard &operator=(CapsuleReleaseGuard const &) = delete;
        CapsuleReleaseGuard(CapsuleReleaseGuard &&) = delete;
        CapsuleReleaseGuard &operator=(CapsuleReleaseGuard &&) = delete;

        ~CapsuleReleaseGuard() noexcept
        {
            if (capsule->bytes != nullptr) {
                try {
                    callbacks->release_capsule(callbacks->context, *capsule);
                } catch (...) {
                    ignore_shutdown_failure();
                }
            }
        }

        SwarmMetainfoParserCallbacks const *callbacks;
        TTorrentOwnedMetainfoCapsule *capsule;
    } release_guard(&callbacks_, &capsule);

    try {
        if (info.empty()
            || std::cmp_greater(info.size(), std::numeric_limits<int32_t>::max())) {
            error = lt::errors::invalid_swarm_metadata;
            return nullptr;
        }
        int32_t const result = callbacks_.parse_info(
            callbacks_.context,
            info.data(),
            static_cast<int32_t>(info.size()),
            &capsule
        );
        if (result != 0
            || capsule.bytes == nullptr
            || capsule.size <= 0
            || capsule.size > TTORRENT_METAINFO_CAPSULE_MAX_BYTES) {
            error = lt::errors::invalid_swarm_metadata;
            return nullptr;
        }

        TorrentInfoLoadResult imported = import_preparsed_info_capsule(
            input_span_from_c_buffer(capsule.bytes, capsule.size)
        );
        if (!imported) {
            error = lt::errors::invalid_swarm_metadata;
            return nullptr;
        }
        error.clear();
        return std::move(*imported);
    } catch (...) {
        error = lt::errors::invalid_swarm_metadata;
        return nullptr;
    }
}

namespace {

[[nodiscard]] bool valid_extension_id(int32_t const value) noexcept
{
    return value >= -1 && value <= 255;
}

[[nodiscard]] bool valid_extension_ids(
    std::array<int32_t, 5U> const &identifiers
)
{
    for (std::size_t index = 0U; index < identifiers.size(); ++index) {
        int32_t const identifier = identifiers.at(index);
        if (!valid_extension_id(identifier)) {
            return false;
        }
        if (identifier <= 0) {
            continue;
        }
        for (std::size_t previous = 0U; previous < index; ++previous) {
            if (identifiers.at(previous) == identifier) {
                return false;
            }
        }
    }
    return true;
}

struct PeerAddressBits {
    std::uint64_t high = 0U;
    std::uint64_t low = 0U;
    std::uint8_t family = 0U;
};

[[nodiscard]] std::optional<lt::address> peer_address(PeerAddressBits const bits)
{
    if (bits.family == TTORRENT_PEER_ADDRESS_IPV4) {
        if (bits.high != 0U || bits.low == 0U
            || bits.low > static_cast<std::uint64_t>(std::numeric_limits<std::uint32_t>::max())) {
            return std::nullopt;
        }
        lt::address_v4::bytes_type bytes{};
        auto const value = static_cast<std::uint32_t>(bits.low);
        for (std::size_t index = 0U; index < bytes.size(); ++index) {
            auto const shift = static_cast<unsigned int>((bytes.size() - index - 1U) * 8U);
            bytes.at(index) = static_cast<std::uint8_t>(value >> shift);
        }
        if (bytes.front() >= 224U || value == std::numeric_limits<std::uint32_t>::max()) {
            return std::nullopt;
        }
        return lt::address_v4(bytes);
    }
    if (bits.family == TTORRENT_PEER_ADDRESS_IPV6) {
        if ((bits.high == 0U && bits.low == 0U)
            || static_cast<std::uint8_t>(bits.high >> 56U) == 0xffU
            || (bits.high == 0U && (bits.low >> 32U) == 0xffffU)) {
            return std::nullopt;
        }
        lt::address_v6::bytes_type bytes{};
        for (std::size_t index = 0U; index < 8U; ++index) {
            auto const shift = static_cast<unsigned int>((7U - index) * 8U);
            bytes.at(index) = static_cast<std::uint8_t>(bits.high >> shift);
            bytes.at(index + 8U) = static_cast<std::uint8_t>(bits.low >> shift);
        }
        return lt::address_v6(bytes);
    }
    return std::nullopt;
}

} // namespace

BridgePeerMessageParser::BridgePeerMessageParser(
    TTorrentPeerProtocolParserCallbacks const callbacks
)
    : callbacks_{
        .context = callbacks.context,
        .retain_context = callbacks.retain_context,
        .release_context = callbacks.release_context,
        .parse_extension_handshake = callbacks.parse_extension_handshake,
        .parse_metadata_message = callbacks.parse_metadata_message,
        .parse_peer_exchange = callbacks.parse_peer_exchange,
    }
{
    if (callbacks_.context == nullptr
        || callbacks_.retain_context == nullptr
        || callbacks_.release_context == nullptr
        || callbacks_.parse_extension_handshake == nullptr
        || callbacks_.parse_metadata_message == nullptr
        || callbacks_.parse_peer_exchange == nullptr) {
        throw std::invalid_argument("The peer protocol parser callback table is incomplete.");
    }
    retained_ = callbacks_.retain_context(callbacks_.context) != 0U;
    if (!retained_) {
        throw std::invalid_argument("The peer protocol parser context is unavailable.");
    }
}

BridgePeerMessageParser::~BridgePeerMessageParser()
{
    if (retained_) {
        callbacks_.release_context(callbacks_.context);
    }
}

bool BridgePeerMessageParser::parse_extension_handshake(
    lt::span<char const> const message,
    lt::aux::extension_handshake &result,
    lt::error_code &error
) noexcept
{
    try {
        if (message.empty()
            || std::cmp_greater(message.size(), TTORRENT_MAX_EXTENSION_HANDSHAKE_BYTES)) {
            error = lt::errors::invalid_extended;
            return false;
        }
        std::array<std::uint8_t, TTORRENT_MAX_PEER_CLIENT_VERSION_BYTES> client_version{};
        TTorrentExtensionHandshakeResult parsed{};
        parsed.ut_metadata_id = -1;
        parsed.ut_pex_id = -1;
        parsed.upload_only_id = -1;
        parsed.holepunch_id = -1;
        parsed.dont_have_id = -1;
        int32_t const status = callbacks_.parse_extension_handshake(
            callbacks_.context,
            message.data(),
            static_cast<int32_t>(message.size()),
            client_version.data(),
            static_cast<int32_t>(client_version.size()),
            &parsed
        );
        constexpr std::uint32_t known_fields =
            TTORRENT_HANDSHAKE_HAS_METADATA_SIZE
            | TTORRENT_HANDSHAKE_HAS_LISTEN_PORT
            | TTORRENT_HANDSHAKE_HAS_LAST_SEEN_COMPLETE
            | TTORRENT_HANDSHAKE_HAS_REQUEST_QUEUE
            | TTORRENT_HANDSHAKE_HAS_CLIENT_VERSION
            | TTORRENT_HANDSHAKE_HAS_EXTERNAL_ADDRESS
            | TTORRENT_HANDSHAKE_HAS_UPLOAD_ONLY;
        if (status != 0
            || parsed.reserved != 0U
            || (parsed.present_fields & ~known_fields) != 0U
            || !valid_extension_ids({
                parsed.ut_metadata_id,
                parsed.ut_pex_id,
                parsed.upload_only_id,
                parsed.holepunch_id,
                parsed.dont_have_id,
            })) {
            error = lt::errors::invalid_extended;
            return false;
        }

        lt::aux::extension_handshake imported;
        imported.ut_metadata_id = parsed.ut_metadata_id;
        imported.ut_pex_id = parsed.ut_pex_id;
        imported.upload_only_id = parsed.upload_only_id;
        imported.holepunch_id = parsed.holepunch_id;
        imported.dont_have_id = parsed.dont_have_id;

        auto const has = [&](std::uint32_t const field) {
            return (parsed.present_fields & field) != 0U;
        };
        if (has(TTORRENT_HANDSHAKE_HAS_METADATA_SIZE)) {
            if (parsed.metadata_size < 0 || parsed.metadata_size > 4 * 1024 * 1024) {
                error = lt::errors::invalid_extended;
                return false;
            }
            imported.metadata_size = parsed.metadata_size;
        } else if (parsed.metadata_size != 0) {
            error = lt::errors::invalid_extended;
            return false;
        }
        if (has(TTORRENT_HANDSHAKE_HAS_LISTEN_PORT)) {
            if (parsed.listen_port <= 0
                || parsed.listen_port > 65'535) {
                error = lt::errors::invalid_extended;
                return false;
            }
            imported.listen_port = parsed.listen_port;
        } else if (parsed.listen_port != 0) {
            error = lt::errors::invalid_extended;
            return false;
        }
        if (has(TTORRENT_HANDSHAKE_HAS_LAST_SEEN_COMPLETE)) {
            if (parsed.last_seen_complete < 0) {
                error = lt::errors::invalid_extended;
                return false;
            }
            imported.last_seen_complete = parsed.last_seen_complete;
        } else if (parsed.last_seen_complete != 0) {
            error = lt::errors::invalid_extended;
            return false;
        }
        if (has(TTORRENT_HANDSHAKE_HAS_REQUEST_QUEUE)) {
            if (parsed.request_queue_limit < 0
                || parsed.request_queue_limit > 65'535) {
                error = lt::errors::invalid_extended;
                return false;
            }
            imported.request_queue_limit = parsed.request_queue_limit;
        } else if (parsed.request_queue_limit != 0) {
            error = lt::errors::invalid_extended;
            return false;
        }
        if (has(TTORRENT_HANDSHAKE_HAS_CLIENT_VERSION)) {
            if (parsed.client_version_size <= 0
                || std::cmp_greater(parsed.client_version_size, client_version.size())) {
                error = lt::errors::invalid_extended;
                return false;
            }
            std::string version;
            version.reserve(static_cast<std::size_t>(parsed.client_version_size));
            for (std::uint8_t const byte : std::span(client_version).first(
                static_cast<std::size_t>(parsed.client_version_size)
            )) {
                version.push_back(static_cast<char>(byte));
            }
            imported.client_version = std::move(version);
        } else if (parsed.client_version_size != 0) {
            error = lt::errors::invalid_extended;
            return false;
        }
        if (has(TTORRENT_HANDSHAKE_HAS_EXTERNAL_ADDRESS)) {
            imported.external_address = peer_address(PeerAddressBits{
                .high = parsed.address_high,
                .low = parsed.address_low,
                .family = parsed.address_family,
            });
            if (!imported.external_address) {
                error = lt::errors::invalid_extended;
                return false;
            }
        } else if (parsed.address_family != 0U
            || parsed.address_high != 0U || parsed.address_low != 0U) {
            error = lt::errors::invalid_extended;
            return false;
        }
        if (has(TTORRENT_HANDSHAKE_HAS_UPLOAD_ONLY)) {
            if (parsed.upload_only > 1U) {
                error = lt::errors::invalid_extended;
                return false;
            }
            imported.upload_only = parsed.upload_only != 0U;
        } else if (parsed.upload_only != 0U) {
            error = lt::errors::invalid_extended;
            return false;
        }

        result = std::move(imported);
        error.clear();
        return true;
    } catch (...) {
        error = lt::errors::invalid_extended;
        return false;
    }
}

bool BridgePeerMessageParser::parse_ut_metadata(
    lt::span<char const> const message,
    lt::aux::ut_metadata_message &result,
    lt::error_code &error
) noexcept
{
    try {
        if (message.empty()
            || std::cmp_greater(message.size(), TTORRENT_MAX_METADATA_MESSAGE_BYTES)) {
            error = lt::errors::invalid_metadata_message;
            return false;
        }
        TTorrentMetadataMessageResult parsed{};
        int32_t const status = callbacks_.parse_metadata_message(
            callbacks_.context,
            message.data(),
            static_cast<int32_t>(message.size()),
            &parsed
        );
        if (status != 0 || parsed.reserved0 != 0U || parsed.reserved1 != 0U
            || parsed.piece < 0 || parsed.has_total_size > 1U
            || parsed.payload_offset <= 0 || parsed.payload_size < 0
            || parsed.payload_offset > static_cast<int32_t>(message.size())
            || parsed.payload_size
                != static_cast<int32_t>(message.size()) - parsed.payload_offset
            || (parsed.has_total_size == 0U && parsed.total_size != 0)
            || (parsed.has_total_size != 0U
                && (parsed.total_size < 0 || parsed.total_size > 4 * 1024 * 1024))) {
            error = lt::errors::invalid_metadata_message;
            return false;
        }

        lt::aux::ut_metadata_message imported;
        imported.raw_type = parsed.raw_message_type;
        imported.piece = parsed.piece;
        imported.total_size = parsed.has_total_size != 0U ? parsed.total_size : 0;
        imported.payload_offset = parsed.payload_offset;
        imported.payload_size = parsed.payload_size;
        switch (parsed.kind) {
        case TTORRENT_METADATA_MESSAGE_REQUEST:
            if (parsed.raw_message_type != 0 || parsed.payload_size != 0) {
                error = lt::errors::invalid_metadata_message;
                return false;
            }
            imported.type = lt::aux::ut_metadata_message_type::request;
            break;
        case TTORRENT_METADATA_MESSAGE_DATA:
            if (parsed.raw_message_type != 1 || parsed.has_total_size == 0U
                || parsed.total_size <= 0 || parsed.payload_size <= 0
                || parsed.payload_size > 16 * 1024) {
                error = lt::errors::invalid_metadata_message;
                return false;
            }
            imported.type = lt::aux::ut_metadata_message_type::piece;
            break;
        case TTORRENT_METADATA_MESSAGE_REJECT:
            if (parsed.raw_message_type != 2 || parsed.payload_size != 0) {
                error = lt::errors::invalid_metadata_message;
                return false;
            }
            imported.type = lt::aux::ut_metadata_message_type::dont_have;
            break;
        case TTORRENT_METADATA_MESSAGE_UNKNOWN:
            if (parsed.raw_message_type >= 0 && parsed.raw_message_type <= 2) {
                error = lt::errors::invalid_metadata_message;
                return false;
            }
            imported.type = lt::aux::ut_metadata_message_type::unknown;
            break;
        default:
            error = lt::errors::invalid_metadata_message;
            return false;
        }
        result = imported;
        error.clear();
        return true;
    } catch (...) {
        error = lt::errors::invalid_metadata_message;
        return false;
    }
}

bool BridgePeerMessageParser::parse_ut_pex(
    lt::span<char const> const message,
    lt::aux::peer_exchange_message &result,
    lt::error_code &error
) noexcept
{
    try {
        if (message.empty()
            || std::cmp_greater(message.size(), TTORRENT_MAX_PEX_MESSAGE_BYTES)) {
            error = lt::errors::invalid_pex_message;
            return false;
        }
        std::array<TTorrentPeerExchangeRecord, TTORRENT_MAX_PEX_MESSAGE_CONTACTS> records{};
        TTorrentPeerExchangeResult parsed{};
        int32_t const status = callbacks_.parse_peer_exchange(
            callbacks_.context,
            message.data(),
            static_cast<int32_t>(message.size()),
            records.data(),
            static_cast<int32_t>(records.size()),
            &parsed
        );
        if (status != 0 || parsed.reserved != 0U
            || parsed.record_count <= 0
            || std::cmp_greater(parsed.record_count, records.size())
            || parsed.added_count < 0 || parsed.dropped_count < 0
            || parsed.added_count > 100 || parsed.dropped_count > 100
            || parsed.record_count != parsed.added_count + parsed.dropped_count) {
            error = lt::errors::invalid_pex_message;
            return false;
        }

        lt::aux::peer_exchange_message imported;
        imported.contacts.reserve(static_cast<std::size_t>(parsed.record_count));
        std::set<std::tuple<std::uint8_t, std::uint64_t, std::uint64_t>> seen_addresses;
        int32_t added_count = 0;
        int32_t dropped_count = 0;
        for (int32_t index = 0; index < parsed.record_count; ++index) {
            TTorrentPeerExchangeRecord const &record = records.at(
                static_cast<std::size_t>(index)
            );
            if (record.reserved0 != 0U || record.reserved1 != 0U
                || record.port == 0U || (record.flags & 0xe0U) != 0U
                || (record.action != TTORRENT_PEX_CONTACT_ADD
                    && record.action != TTORRENT_PEX_CONTACT_DROP)
                || !seen_addresses.emplace(
                    record.address_family, record.address_high, record.address_low
                ).second) {
                error = lt::errors::invalid_pex_message;
                return false;
            }
            std::optional<lt::address> address = peer_address(PeerAddressBits{
                .high = record.address_high,
                .low = record.address_low,
                .family = record.address_family,
            });
            if (!address) {
                error = lt::errors::invalid_pex_message;
                return false;
            }
            lt::aux::peer_exchange_action action = lt::aux::peer_exchange_action::add;
            if (record.action == TTORRENT_PEX_CONTACT_ADD) {
                action = lt::aux::peer_exchange_action::add;
                ++added_count;
            } else {
                action = lt::aux::peer_exchange_action::drop;
                ++dropped_count;
            }
            imported.contacts.push_back(lt::aux::peer_exchange_contact{
                .endpoint = lt::tcp::endpoint(*address, record.port),
                .action = action,
                .flags = lt::pex_flags_t(record.flags),
            });
        }
        if (added_count != parsed.added_count || dropped_count != parsed.dropped_count) {
            error = lt::errors::invalid_pex_message;
            return false;
        }
        imported.added_count = added_count;
        imported.dropped_count = dropped_count;
        result = std::move(imported);
        error.clear();
        return true;
    } catch (...) {
        error = lt::errors::invalid_pex_message;
        return false;
    }
}

namespace {

struct TrackerAddressBits {
    std::uint64_t high = 0U;
    std::uint64_t low = 0U;
    std::uint8_t family = 0U;
};

[[nodiscard]] std::optional<lt::address> tracker_address(TrackerAddressBits const bits)
{
    if (bits.family == TTORRENT_PEER_ADDRESS_IPV4) {
        if (bits.high != 0U
            || bits.low > static_cast<std::uint64_t>(std::numeric_limits<std::uint32_t>::max())) {
            return std::nullopt;
        }
        lt::address_v4::bytes_type bytes{};
        auto const value = static_cast<std::uint32_t>(bits.low);
        for (std::size_t index = 0U; index < bytes.size(); ++index) {
            auto const shift = static_cast<unsigned int>((bytes.size() - index - 1U) * 8U);
            bytes.at(index) = static_cast<std::uint8_t>(value >> shift);
        }
        return lt::address_v4(bytes);
    }
    if (bits.family == TTORRENT_PEER_ADDRESS_IPV6) {
        lt::address_v6::bytes_type bytes{};
        for (std::size_t index = 0U; index < 8U; ++index) {
            auto const shift = static_cast<unsigned int>((7U - index) * 8U);
            bytes.at(index) = static_cast<std::uint8_t>(bits.high >> shift);
            bytes.at(index + 8U) = static_cast<std::uint8_t>(bits.low >> shift);
        }
        return lt::address_v6(bytes);
    }
    return std::nullopt;
}

[[nodiscard]] std::optional<lt::span<char const>> tracker_body_range(
    lt::span<char const> const body,
    int32_t const offset,
    int32_t const size,
    int32_t const maximum_size,
    bool const allow_empty
)
{
    auto const span_offset = static_cast<std::ptrdiff_t>(offset);
    auto const span_size = static_cast<std::ptrdiff_t>(size);
    if (offset < 0 || size < 0 || size > maximum_size
        || (!allow_empty && size == 0)
        || span_offset > body.size()
        || span_size > body.size() - span_offset) {
        return std::nullopt;
    }
    return body.subspan(span_offset, span_size);
}

[[nodiscard]] bool safe_tracker_hostname(lt::span<char const> const hostname)
{
    return !hostname.empty() && std::ranges::all_of(hostname, [](char const character) {
        auto const byte = static_cast<unsigned char>(character);
        return (byte >= static_cast<unsigned char>('0') && byte <= static_cast<unsigned char>('9'))
            || (byte >= static_cast<unsigned char>('A') && byte <= static_cast<unsigned char>('Z'))
            || (byte >= static_cast<unsigned char>('a') && byte <= static_cast<unsigned char>('z'))
            || byte == static_cast<unsigned char>('.')
            || byte == static_cast<unsigned char>('-')
            || byte == static_cast<unsigned char>('_')
            || byte == static_cast<unsigned char>(':');
    });
}

[[nodiscard]] bool valid_tracker_statistic(int32_t const value)
{
    return value >= -1;
}

[[nodiscard]] bool valid_tracker_message(lt::span<char const> const value)
{
    std::string const owned(value.begin(), value.end());
    if (owned.find('\0') != std::string::npos) {
        return false;
    }
    std::size_t offset = 0U;
    while (offset < owned.size()) {
        UTF8Sequence const sequence = utf8_sequence(owned, offset);
        if (!sequence.valid) {
            return false;
        }
        offset += sequence.length;
    }
    return true;
}

} // namespace

BridgeTrackerResponseParser::BridgeTrackerResponseParser(
    TTorrentTrackerResponseParserCallbacks const callbacks
)
    : callbacks_{
        .context = callbacks.context,
        .retain_context = callbacks.retain_context,
        .release_context = callbacks.release_context,
        .parse_http_response = callbacks.parse_http_response,
    }
{
    if (callbacks_.context == nullptr
        || callbacks_.retain_context == nullptr
        || callbacks_.release_context == nullptr
        || callbacks_.parse_http_response == nullptr) {
        throw std::invalid_argument("The tracker response parser callback table is incomplete.");
    }
    retained_ = callbacks_.retain_context(callbacks_.context) != 0U;
    if (!retained_) {
        throw std::invalid_argument("The tracker response parser context is unavailable.");
    }
}

BridgeTrackerResponseParser::~BridgeTrackerResponseParser()
{
    if (retained_) {
        callbacks_.release_context(callbacks_.context);
    }
}

bool BridgeTrackerResponseParser::parse_http_response(
    lt::span<char const> const body,
    bool const is_scrape,
    lt::sha1_hash const &scrape_info_hash,
    lt::aux::tracker_response &result,
    lt::error_code &error
) noexcept
{
    try {
        if (body.empty()
            || std::cmp_greater(body.size(), TTORRENT_MAX_HTTP_TRACKER_RESPONSE_BYTES)) {
            error = lt::errors::invalid_tracker_response;
            return false;
        }
        auto const body_size = static_cast<std::size_t>(body.size());
        std::size_t const peer_capacity = std::clamp<std::size_t>(
            (body_size + 5U) / 6U,
            1U,
            static_cast<std::size_t>(TTORRENT_MAX_TRACKER_RESPONSE_PEERS)
        );
        std::vector<TTorrentTrackerPeerRecord> peers(peer_capacity);
        TTorrentHTTPTrackerResponseResult parsed{};
        std::array<std::uint8_t, 20U> scrape_hash_bytes{};
        if (is_scrape) {
            std::ranges::copy(scrape_info_hash, scrape_hash_bytes.begin());
        }
        auto const *scrape_hash = is_scrape
            ? scrape_hash_bytes.data()
            : nullptr;
        int32_t const status = callbacks_.parse_http_response(
            callbacks_.context,
            body.data(),
            static_cast<int32_t>(body.size()),
            is_scrape ? 1U : 0U,
            scrape_hash,
            is_scrape ? 20 : 0,
            peers.data(),
            static_cast<int32_t>(peers.size()),
            &parsed
        );
        constexpr std::uint32_t known_fields =
            TTORRENT_TRACKER_HAS_ID
            | TTORRENT_TRACKER_HAS_FAILURE_REASON
            | TTORRENT_TRACKER_HAS_WARNING_MESSAGE
            | TTORRENT_TRACKER_HAS_EXTERNAL_ADDRESS;
        if (status != 0 || parsed.reserved0 != 0U || parsed.reserved1 != 0U
            || (parsed.present_fields & ~known_fields) != 0U
            || parsed.interval < 0 || parsed.minimum_interval < 0
            || !valid_tracker_statistic(parsed.complete)
            || !valid_tracker_statistic(parsed.incomplete)
            || !valid_tracker_statistic(parsed.downloaded)
            || !valid_tracker_statistic(parsed.downloaders)
            || parsed.peer_count < 0
            || std::cmp_greater(parsed.peer_count, peers.size())
            || parsed.peer_count > TTORRENT_MAX_TRACKER_RESPONSE_PEERS) {
            error = lt::errors::invalid_tracker_response;
            return false;
        }

        auto const has = [&](std::uint32_t const field) {
            return (parsed.present_fields & field) != 0U;
        };
        struct OptionalRangeSpecification {
            std::uint32_t field;
            int32_t offset;
            int32_t size;
            int32_t maximum_size;
            bool allow_empty;
        };
        auto const optional_range = [&](OptionalRangeSpecification const specification)
            -> std::optional<lt::span<char const>> {
            if (!has(specification.field)) {
                if (specification.offset != 0 || specification.size != 0) {
                    return std::nullopt;
                }
                return lt::span<char const>{};
            }
            return tracker_body_range(
                body,
                specification.offset,
                specification.size,
                specification.maximum_size,
                specification.allow_empty
            );
        };

        auto const tracker_id = optional_range(OptionalRangeSpecification{
            .field = TTORRENT_TRACKER_HAS_ID,
            .offset = parsed.tracker_id_offset,
            .size = parsed.tracker_id_size,
            .maximum_size = TTORRENT_MAX_TRACKER_ID_BYTES,
            .allow_empty = true,
        });
        auto const failure_reason = optional_range(OptionalRangeSpecification{
            .field = TTORRENT_TRACKER_HAS_FAILURE_REASON,
            .offset = parsed.failure_reason_offset,
            .size = parsed.failure_reason_size,
            .maximum_size = TTORRENT_MAX_TRACKER_MESSAGE_BYTES,
            .allow_empty = true,
        });
        auto const warning_message = optional_range(OptionalRangeSpecification{
            .field = TTORRENT_TRACKER_HAS_WARNING_MESSAGE,
            .offset = parsed.warning_message_offset,
            .size = parsed.warning_message_size,
            .maximum_size = TTORRENT_MAX_TRACKER_MESSAGE_BYTES,
            .allow_empty = true,
        });
        if (!tracker_id || !failure_reason || !warning_message) {
            error = lt::errors::invalid_tracker_response;
            return false;
        }
        if ((has(TTORRENT_TRACKER_HAS_FAILURE_REASON)
                && !valid_tracker_message(*failure_reason))
            || (has(TTORRENT_TRACKER_HAS_WARNING_MESSAGE)
                && !valid_tracker_message(*warning_message))) {
            error = lt::errors::invalid_tracker_response;
            return false;
        }

        lt::aux::tracker_response imported;
        imported.interval = lt::seconds32(parsed.interval);
        imported.min_interval = lt::seconds32(parsed.minimum_interval);
        imported.complete = parsed.complete;
        imported.incomplete = parsed.incomplete;
        imported.downloaded = parsed.downloaded;
        imported.downloaders = parsed.downloaders;
        if (has(TTORRENT_TRACKER_HAS_ID)) {
            imported.trackerid.assign(tracker_id->begin(), tracker_id->end());
        }
        if (has(TTORRENT_TRACKER_HAS_FAILURE_REASON)) {
            if (parsed.peer_count != 0
                || has(TTORRENT_TRACKER_HAS_WARNING_MESSAGE)
                || has(TTORRENT_TRACKER_HAS_EXTERNAL_ADDRESS)
                || parsed.complete != -1 || parsed.incomplete != -1
                || parsed.downloaded != -1 || parsed.downloaders != -1) {
                error = lt::errors::invalid_tracker_response;
                return false;
            }
            imported.failure_reason.assign(failure_reason->begin(), failure_reason->end());
            result = std::move(imported);
            error = lt::errors::tracker_failure;
            return true;
        }
        if (has(TTORRENT_TRACKER_HAS_WARNING_MESSAGE)) {
            imported.warning_message.assign(warning_message->begin(), warning_message->end());
        }

        if (has(TTORRENT_TRACKER_HAS_EXTERNAL_ADDRESS)) {
            std::optional<lt::address> const address = tracker_address(TrackerAddressBits{
                .high = parsed.address_high,
                .low = parsed.address_low,
                .family = parsed.address_family,
            });
            if (!address) {
                error = lt::errors::invalid_tracker_response;
                return false;
            }
            imported.external_ip = *address;
        } else if (parsed.address_family != 0U
            || parsed.address_high != 0U || parsed.address_low != 0U) {
            error = lt::errors::invalid_tracker_response;
            return false;
        }

        if (is_scrape) {
            if (parsed.peer_count != 0
                || has(TTORRENT_TRACKER_HAS_EXTERNAL_ADDRESS)) {
                error = lt::errors::invalid_tracker_response;
                return false;
            }
        } else if (parsed.downloaders != -1) {
            error = lt::errors::invalid_tracker_response;
            return false;
        }

        imported.peers.reserve(static_cast<std::size_t>(parsed.peer_count));
        imported.peers4.reserve(static_cast<std::size_t>(parsed.peer_count));
        imported.peers6.reserve(static_cast<std::size_t>(parsed.peer_count));
        for (int32_t index = 0; index < parsed.peer_count; ++index) {
            TTorrentTrackerPeerRecord const &peer = peers.at(static_cast<std::size_t>(index));
            if (peer.reserved != 0U || peer.has_peer_id > 1U) {
                error = lt::errors::invalid_tracker_response;
                return false;
            }
            if (peer.kind == TTORRENT_TRACKER_PEER_HOSTNAME) {
                if (peer.address_high != 0U || peer.address_low != 0U) {
                    error = lt::errors::invalid_tracker_response;
                    return false;
                }
                auto const hostname = tracker_body_range(
                    body,
                    peer.hostname_offset,
                    peer.hostname_size,
                    TTORRENT_MAX_TRACKER_HOSTNAME_BYTES,
                    false
                );
                if (!hostname || !safe_tracker_hostname(*hostname)) {
                    error = lt::errors::invalid_tracker_response;
                    return false;
                }
                lt::aux::peer_entry imported_peer;
                imported_peer.hostname.assign(hostname->begin(), hostname->end());
                imported_peer.port = peer.port;
                if (peer.has_peer_id != 0U) {
                    auto const peer_id = tracker_body_range(
                        body,
                        peer.peer_id_offset,
                        20,
                        20,
                        false
                    );
                    if (!peer_id) {
                        error = lt::errors::invalid_tracker_response;
                        return false;
                    }
                    std::copy(peer_id->begin(), peer_id->end(), imported_peer.pid.begin());
                } else {
                    if (peer.peer_id_offset != 0) {
                        error = lt::errors::invalid_tracker_response;
                        return false;
                    }
                    imported_peer.pid.clear();
                }
                imported.peers.push_back(std::move(imported_peer));
                continue;
            }
            if (peer.hostname_offset != 0 || peer.hostname_size != 0
                || peer.peer_id_offset != 0 || peer.has_peer_id != 0U) {
                error = lt::errors::invalid_tracker_response;
                return false;
            }
            std::optional<lt::address> const address = tracker_address(TrackerAddressBits{
                .high = peer.address_high,
                .low = peer.address_low,
                .family = peer.kind,
            });
            if (!address) {
                error = lt::errors::invalid_tracker_response;
                return false;
            }
            if (peer.kind == TTORRENT_PEER_ADDRESS_IPV4) {
                imported.peers4.push_back(lt::aux::ipv4_peer_entry{
                    .ip = address->to_v4().to_bytes(),
                    .port = peer.port,
                });
            } else if (peer.kind == TTORRENT_PEER_ADDRESS_IPV6) {
                imported.peers6.push_back(lt::aux::ipv6_peer_entry{
                    .ip = address->to_v6().to_bytes(),
                    .port = peer.port,
                });
            } else {
                error = lt::errors::invalid_tracker_response;
                return false;
            }
        }

        result = std::move(imported);
        error.clear();
        return true;
    } catch (...) {
        error = lt::errors::invalid_tracker_response;
        return false;
    }
}

PayloadBrokerContext::PayloadBrokerContext(TTorrentPayloadBrokerCallbacks const callbacks)
    : callbacks_{
        .context = callbacks.context,
        .retain_context = callbacks.retain_context,
        .release_context = callbacks.release_context,
        .open_payload = callbacks.open_payload,
        .payload_size = callbacks.payload_size,
    }
{
    if (callbacks_.context == nullptr
        || callbacks_.retain_context == nullptr
        || callbacks_.release_context == nullptr
        || callbacks_.open_payload == nullptr
        || callbacks_.payload_size == nullptr) {
        throw std::invalid_argument("The payload broker callback table is incomplete.");
    }
    retained_ = callbacks_.retain_context(callbacks_.context) != 0U;
    if (!retained_) {
        throw std::invalid_argument("The payload broker context is unavailable.");
    }
}

PayloadBrokerContext::~PayloadBrokerContext()
{
    if (retained_) {
        callbacks_.release_context(callbacks_.context);
    }
}

int PayloadBrokerContext::open_payload(
    TTorrentStorageActivation const &activation,
    lt::file_index_t const file,
    bool const writable,
    lt::error_code &error
) const noexcept
{
    int32_t descriptor = -1;
    try {
        int32_t const result = callbacks_.open_payload(
            callbacks_.context,
            activation.claim_id,
            activation.claim_generation,
            static_cast<int32_t>(static_cast<int>(file)),
            writable ? 1U : 0U,
            &descriptor
        );
        if (result != 0 || descriptor < 0) {
            if (descriptor >= 0) {
                static_cast<void>(::close(descriptor));
            }
            assign_callback_error(error, result == 0 ? EBADF : result);
            return -1;
        }

        int const descriptor_flags = ::fcntl(descriptor, F_GETFD);
        auto const cloexec_flags = static_cast<int>(
            static_cast<unsigned int>(descriptor_flags)
                | static_cast<unsigned int>(FD_CLOEXEC)
        );
        if (descriptor_flags < 0
            || ::fcntl(descriptor, F_SETFD, cloexec_flags) != 0) {
            int const error_number = errno;
            static_cast<void>(::close(descriptor));
            assign_callback_error(error, error_number);
            return -1;
        }

        struct ::stat metadata {};
        if (::fstat(descriptor, &metadata) != 0) {
            int const error_number = errno;
            static_cast<void>(::close(descriptor));
            assign_callback_error(error, error_number);
            return -1;
        }
        if (!S_ISREG(metadata.st_mode)) {
            static_cast<void>(::close(descriptor));
            assign_callback_error(error, EFTYPE);
            return -1;
        }
        int const access_mode = ::fcntl(descriptor, F_GETFL);
        auto const access_bits = static_cast<unsigned int>(access_mode)
            & static_cast<unsigned int>(O_ACCMODE);
        if (access_mode < 0
            || (writable && access_bits == static_cast<unsigned int>(O_RDONLY))) {
            int const error_number = access_mode < 0 ? errno : EACCES;
            static_cast<void>(::close(descriptor));
            assign_callback_error(error, error_number);
            return -1;
        }

        error.clear();
        return descriptor;
    } catch (...) {
        if (descriptor >= 0) {
            static_cast<void>(::close(descriptor));
        }
        assign_callback_error(error, EIO);
        return -1;
    }
}

std::int64_t PayloadBrokerContext::payload_size(
    TTorrentStorageActivation const &activation,
    lt::file_index_t const file,
    lt::error_code &error
) const noexcept
{
    std::int64_t size = -1;
    try {
        int32_t const result = callbacks_.payload_size(
            callbacks_.context,
            activation.claim_id,
            activation.claim_generation,
            static_cast<int32_t>(static_cast<int>(file)),
            &size
        );
        if (result != 0 || size < 0) {
            assign_callback_error(error, result == 0 ? EIO : result);
            return -1;
        }
        error.clear();
        return size;
    } catch (...) {
        assign_callback_error(error, EIO);
        return -1;
    }
}

BridgePayloadFileProvider::BridgePayloadFileProvider(
    std::shared_ptr<PayloadBrokerContext> broker,
    TTorrentStorageActivation activation
)
    : broker_(std::move(broker)), activation_(activation)
{
    if (!broker_) {
        throw std::invalid_argument("The payload broker is unavailable.");
    }
}

int BridgePayloadFileProvider::open_payload(
    lt::file_index_t const file,
    bool const writable,
    lt::error_code &error
)
{
    return broker_->open_payload(activation_, file, writable, error);
}

std::int64_t BridgePayloadFileProvider::payload_size(
    lt::file_index_t const file,
    lt::error_code &error
)
{
    return broker_->payload_size(activation_, file, error);
}

static std::string storage_preserved_torrent_id(
    TTorrentStorageActivation const &activation
)
{
    std::span<std::uint8_t const> const bytes{activation.preserved_torrent_id};
    if (all_zero(bytes)) {
        return {};
    }
    std::string result;
    result.reserve(bytes.size());
    std::ranges::transform(
        bytes,
        std::back_inserter(result),
        [](std::uint8_t const byte) { return static_cast<char>(byte); }
    );
    return result;
}

static std::optional<std::string> requested_torrent_id(
    TTorrentAddOptions const &options
)
{
    std::span<char const> const bytes{options.canonical_id};
    auto const terminator = std::ranges::find(bytes, '\0');
    if (terminator == bytes.end()) {
        return std::nullopt;
    }
    std::string id(bytes.begin(), terminator);
    if (!is_canonical_torrent_id(id)) {
        return std::nullopt;
    }
    return id;
}

BridgeResult validate_storage_activation(
    lt::add_torrent_params const &params,
    TTorrentStorageActivation const &activation
)
{
    std::span<std::uint8_t const> const claim_id{activation.claim_id};
    std::span<std::uint8_t const> const expected_digest{activation.source_manifest_digest};
    std::string const preserved_id = storage_preserved_torrent_id(activation);
    if (activation.claim_generation == 0U
        || activation.claim_generation > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())
        || all_zero(claim_id)
        || all_zero(expected_digest)
        || (!preserved_id.empty() && !is_canonical_torrent_id(preserved_id))) {
        return bridge_error(2, "The storage claim activation is invalid.");
    }
    try {
        lt::sha256_hash const actual_digest = logical_manifest_digest(params);
        if (!digest_matches(actual_digest, activation)) {
            return bridge_error(
                2,
                "The storage claim does not match libtorrent's logical manifest."
            );
        }
    } catch (std::exception const &exception) {
        return bridge_error(2, exception.what());
    } catch (...) {
        return bridge_error(2, "The logical manifest could not be validated.");
    }
    return {};
}

std::string storage_claim_key(TTorrentStorageActivation const &activation)
{
    constexpr std::array<char, 16> alphabet{
        '0', '1', '2', '3', '4', '5', '6', '7',
        '8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
    };
    std::string key;
    key.reserve(32U);
    for (std::uint8_t const byte : activation.claim_id) {
        key.push_back(alphabet.at(byte >> 4U));
        key.push_back(alphabet.at(byte & 0x0fU));
    }
    return key;
}

namespace {

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

using TrackerTopologyEntry = std::pair<std::string_view, std::uint8_t>;

std::vector<TrackerTopologyEntry> tracker_topology(std::vector<lt::announce_entry> const &trackers)
{
    std::vector<TrackerTopologyEntry> topology;
    topology.reserve(trackers.size());
    for (lt::announce_entry const &tracker : trackers) {
        topology.emplace_back(tracker.url, tracker.tier);
    }
    std::ranges::sort(topology);
    return topology;
}

bool same_tracker_topology(
    std::vector<lt::announce_entry> const &left,
    std::vector<lt::announce_entry> const &right
)
{
    return tracker_topology(left) == tracker_topology(right);
}

void preserve_runtime_tracker_state(
    std::vector<lt::announce_entry> &desired,
    std::vector<lt::announce_entry> const &current
)
{
    std::map<std::string_view, lt::announce_entry const *> current_by_url;
    for (lt::announce_entry const &tracker : current) {
        current_by_url.emplace(tracker.url, &tracker);
    }

    for (lt::announce_entry &tracker : desired) {
        auto const current_tracker = current_by_url.find(tracker.url);
        if (current_tracker == current_by_url.end()) {
            continue;
        }
        std::uint8_t const desired_tier = tracker.tier;
        tracker = *current_tracker->second;
        tracker.tier = desired_tier;
    }
}

} // namespace

DirtyMask TTorrentClient::enforce_https_source_policy(
    lt::torrent_handle const &handle,
    TorrentIdentity *identity,
    HTTPSSourcePolicyScope const scope,
    HTTPSSourcePolicy const policy
)
{
    if (!handle.is_valid()) {
        return {};
    }

    DirtyMask changes = 0;
    bool changed = false;
    bool trackers_changed = false;
    bool web_seeds_changed = false;

    if (updates_https_trackers(scope)) {
        std::vector<lt::announce_entry> const trackers = handle.trackers();
        std::vector<lt::announce_entry> const effective_trackers = trackers_for_https_policy(
            trackers,
            policy.trackers
        );
        trackers_changed = !same_tracker_topology(trackers, effective_trackers);
        if (trackers_changed) {
            handle.replace_trackers(effective_trackers);
            handle.force_reannounce();
            changes |= observe_trackers(handle);
            changed = true;
        }
    }

    bool const require_web_seeds = policy.web_seeds == HTTPSPolicy::require;
    if (updates_https_web_seeds(scope) && require_web_seeds) {
        for (std::string const &url : handle.url_seeds()) {
            if (!is_https_url(url)) {
                handle.remove_url_seed(url);
                changed = true;
                web_seeds_changed = true;
            }
        }
    }

    if (web_seeds_changed) {
        changes |= mark_web_seeds_changed();
    }
    if (trackers_changed) {
        changes |= clear_peer_cache_if_restricted(handle, identity);
    }
    if (changed) {
        request_save_locked(handle);
    }

    return changes;
}

DirtyMask TTorrentClient::restore_metadata_source_policy(
    lt::torrent_handle const &handle,
    TorrentIdentity *identity,
    HTTPSSourcePolicyScope const scope,
    HTTPSSourcePolicy const policy
)
{
    if (!handle.is_valid()) {
        return {};
    }

    if (identity == nullptr
        || ((!updates_https_trackers(scope) || identity->source_trackers.empty())
            && (!updates_https_web_seeds(scope) || identity->source_web_seeds.empty()))) {
        return {};
    }

    DirtyMask changes = 0;
    bool changed = false;

    std::vector<lt::announce_entry> const current_trackers = handle.trackers();
    std::vector<lt::announce_entry> restored_trackers = current_trackers;
    bool trackers_changed = false;
    if (updates_https_trackers(scope)) {
        restored_trackers.clear();
        restored_trackers.reserve(identity->source_trackers.size() + current_trackers.size());
        std::set<std::string> tracker_urls;
        for (lt::announce_entry const &tracker : identity->source_trackers) {
            if (tracker_urls.insert(tracker.url).second) {
                restored_trackers.push_back(tracker);
            }
        }
        for (lt::announce_entry const &tracker : current_trackers) {
            if (tracker_urls.insert(tracker.url).second) {
                restored_trackers.push_back(tracker);
            }
        }
        restored_trackers = trackers_for_https_policy(
            std::move(restored_trackers),
            policy.trackers
        );
        preserve_runtime_tracker_state(restored_trackers, current_trackers);
        trackers_changed = !same_tracker_topology(restored_trackers, current_trackers);
    }

    std::set<std::string> const existing_url_seeds = handle.url_seeds();
    std::set<std::string> restored_url_seeds = existing_url_seeds;
    bool web_seeds_changed = false;
    if (updates_https_web_seeds(scope)) {
        bool const require_web_seeds = policy.web_seeds == HTTPSPolicy::require;
        auto web_seed_allowed = [require_web_seeds](std::string const &web_seed) noexcept {
            return !require_web_seeds || is_https_url(web_seed);
        };
        std::erase_if(restored_url_seeds, [&](std::string const &web_seed) {
            return !web_seed_allowed(web_seed);
        });
        for (std::string const &web_seed : identity->source_web_seeds) {
            if (web_seed_allowed(web_seed)) {
                restored_url_seeds.insert(web_seed);
            }
        }
        web_seeds_changed = restored_url_seeds != existing_url_seeds;
    }

    lt::add_torrent_params restored_sources;
    for (lt::announce_entry const &tracker : restored_trackers) {
        restored_sources.trackers.push_back(tracker.url);
        restored_sources.tracker_tiers.push_back(tracker.tier);
    }
    restored_sources.url_seeds.assign(restored_url_seeds.begin(), restored_url_seeds.end());
    BridgeResult const valid_sources = validate_torrent_sources(restored_sources);
    if (!valid_sources) {
        changes |= remove_torrent_with_invalid_metadata(handle, valid_sources.error().message);
        return changes;
    }

    if (trackers_changed) {
        handle.replace_trackers(restored_trackers);
        handle.force_reannounce();
        changes |= observe_trackers(handle);
        changes |= clear_peer_cache_if_restricted(handle, identity);
        changed = true;
    }

    if (web_seeds_changed) {
        changed = true;
        for (std::string const &url : existing_url_seeds) {
            if (!restored_url_seeds.contains(url)) {
                handle.remove_url_seed(url);
            }
        }
        for (std::string const &url : restored_url_seeds) {
            if (!existing_url_seeds.contains(url)) {
                handle.add_url_seed(url);
            }
        }
        changes |= mark_web_seeds_changed();
    }

    if (changed) {
        request_save_locked(handle);
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
    request_save_locked(handle);
    request_snapshot_update_locked();
    return kChangeTorrents;
}

namespace {

bool is_valid_boolean_policy(std::uint8_t const value) noexcept
{
    return value == TTORRENT_BOOLEAN_POLICY_INHERIT
        || value == TTORRENT_BOOLEAN_POLICY_DISABLED
        || value == TTORRENT_BOOLEAN_POLICY_ENABLED;
}

std::uint8_t boolean_policy(bool const enabled, bool const disabled) noexcept
{
    if (enabled != disabled) {
        return enabled ? TTORRENT_BOOLEAN_POLICY_ENABLED : TTORRENT_BOOLEAN_POLICY_DISABLED;
    }
    return TTORRENT_BOOLEAN_POLICY_INHERIT;
}

TTorrentSourcePolicyState source_policy_state(
    TTorrentClient const &client,
    ActiveTorrentEntry const &entry
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    TTorrentSourcePolicyState state{};
    TorrentIdentity const *identity = entry.identity;
    state.native_token = identity->token == nullptr ? 0U : identity->token->value;
    state.dht_policy = boolean_policy(identity->dht_enabled_by_user, identity->dht_disabled_by_user);
    state.peer_exchange_policy = boolean_policy(
        identity->peer_exchange_enabled_by_user,
        identity->peer_exchange_disabled_by_user
    );
    state.lsd_policy = boolean_policy(identity->lsd_enabled_by_user, identity->lsd_disabled_by_user);
    state.https_tracker_policy = static_cast<std::uint8_t>(identity->https_tracker_policy);
    state.https_web_seed_policy = static_cast<std::uint8_t>(identity->https_web_seed_policy);

    std::shared_ptr<lt::torrent_info const> const torrent_file = entry.handle.torrent_file();
    bool const private_torrent = torrent_file && torrent_file->is_valid() && torrent_file->priv();
    bool const metadata_pending = client.metadata_validation_pending.contains(identity);
    state.dht_locked = bridge_bool(private_torrent || identity->dht_locked_by_source);
    state.peer_exchange_locked = bridge_bool(private_torrent || identity->peer_exchange_locked_by_source);
    state.lsd_locked = bridge_bool(private_torrent || identity->lsd_locked_by_source);
    state.metadata_validation_pending = bridge_bool(metadata_pending);
    state.allow_pre_metadata_dht = bridge_bool(
        metadata_pending && !bridge_bool(state.dht_locked) && identity->allow_pre_metadata_dht
    );
    return state;
}

struct ResolvedSourcePolicyApplication {
    TTorrentSourcePolicyApplication application{};
    lt::torrent_handle handle;
    TorrentIdentity *identity = nullptr;
    lt::torrent_flags_t previous_flags;
    HTTPSPolicy previous_tracker_policy = HTTPSPolicy::inherit;
    HTTPSPolicy previous_web_seed_policy = HTTPSPolicy::inherit;
    bool previous_dht_enabled_by_user = false;
    bool previous_dht_disabled_by_user = false;
    bool previous_peer_exchange_enabled_by_user = false;
    bool previous_peer_exchange_disabled_by_user = false;
    bool previous_lsd_enabled_by_user = false;
    bool previous_lsd_disabled_by_user = false;
    bool previous_allow_pre_metadata_dht = false;
    bool previous_app_disabled_dht = false;
    bool previous_app_disabled_peer_exchange = false;
    bool previous_app_disabled_lsd = false;
    std::vector<lt::announce_entry> previous_trackers;
    std::set<std::string> previous_web_seeds;
};

struct BooleanPolicyMirror {
    bool enabled = false;
    bool disabled = false;
};

BooleanPolicyMirror policy_mirror(std::uint8_t const policy) noexcept
{
    return BooleanPolicyMirror{
        .enabled = policy == TTORRENT_BOOLEAN_POLICY_ENABLED,
        .disabled = policy == TTORRENT_BOOLEAN_POLICY_DISABLED,
    };
}

void set_membership(std::set<TorrentIdentity *> &set, TorrentIdentity *identity, bool const contained)
{
    if (contained) {
        set.insert(identity);
    } else {
        set.erase(identity);
    }
}

bool restore_membership(
    std::set<TorrentIdentity *> &set,
    TorrentIdentity *identity,
    bool const contained
) noexcept
{
    try {
        set_membership(set, identity, contained);
        return true;
    } catch (...) {
        return false;
    }
}

bool restore_source_application(TTorrentClient &client, ResolvedSourcePolicyApplication const &entry) noexcept
    TORRENT_BRIDGE_REQUIRES(client.lock)
{
#if defined(TORRENT_BRIDGE_TESTING)
    if (client.fail_next_source_policy_rollback) {
        client.fail_next_source_policy_rollback = false;
        return false;
    }
#endif
    TorrentIdentity *identity = entry.identity;
    identity->https_tracker_policy = entry.previous_tracker_policy;
    identity->https_web_seed_policy = entry.previous_web_seed_policy;
    identity->dht_enabled_by_user = entry.previous_dht_enabled_by_user;
    identity->dht_disabled_by_user = entry.previous_dht_disabled_by_user;
    identity->peer_exchange_enabled_by_user = entry.previous_peer_exchange_enabled_by_user;
    identity->peer_exchange_disabled_by_user = entry.previous_peer_exchange_disabled_by_user;
    identity->lsd_enabled_by_user = entry.previous_lsd_enabled_by_user;
    identity->lsd_disabled_by_user = entry.previous_lsd_disabled_by_user;
    identity->allow_pre_metadata_dht = entry.previous_allow_pre_metadata_dht;
    bool mirrors_restored = restore_membership(
        client.dht_disabled_by_app,
        identity,
        entry.previous_app_disabled_dht
    );
    mirrors_restored = restore_membership(
        client.peer_exchange_disabled_by_app,
        identity,
        entry.previous_app_disabled_peer_exchange
    ) && mirrors_restored;
    mirrors_restored = restore_membership(
        client.lsd_disabled_by_app,
        identity,
        entry.previous_app_disabled_lsd
    ) && mirrors_restored;
    try {
        auto restore_flag = [&](lt::torrent_flags_t const flag) {
            if (static_cast<bool>(entry.previous_flags & flag)) {
                entry.handle.set_flags(flag);
            } else {
                entry.handle.unset_flags(flag);
            }
        };
        restore_flag(lt::torrent_flags::disable_dht);
        restore_flag(lt::torrent_flags::disable_pex);
        restore_flag(lt::torrent_flags::disable_lsd);
        entry.handle.replace_trackers(entry.previous_trackers);
        std::set<std::string> const current_web_seeds = entry.handle.url_seeds();
        for (std::string const &url : current_web_seeds) {
            if (!entry.previous_web_seeds.contains(url)) {
                entry.handle.remove_url_seed(url);
            }
        }
        for (std::string const &url : entry.previous_web_seeds) {
            if (!current_web_seeds.contains(url)) {
                entry.handle.add_url_seed(url);
            }
        }
    } catch (...) {
        return false;
    }
    return mirrors_restored;
}

BridgeResult rollback_source_applications_or_contain(
    TTorrentClient &client,
    std::span<ResolvedSourcePolicyApplication const> applications,
    LockedChangePublisher &publisher,
    std::string message
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    bool rollback_complete = true;
    for (ResolvedSourcePolicyApplication const &entry : applications) {
        bool const entry_restored = restore_source_application(client, entry);
        rollback_complete = entry_restored && rollback_complete;
    }
    if (rollback_complete) {
        return bridge_error(2, std::move(message));
    }

    client.source_policy_reconciled = false;
    DirtyMask containment_changes = 0U;
    BridgeResult const containment = block_network_locked(client, containment_changes);
    publisher.add(containment_changes);
    if (!containment) {
        message += " Source-policy rollback was incomplete, and network containment could not be confirmed: ";
        message += containment.error().message;
        return bridge_error(2, std::move(message));
    }
    message += " Source-policy rollback was incomplete; networking was blocked.";
    return bridge_error(2, std::move(message));
}

BridgeResult apply_source_policy_state_locked(
    TTorrentClient &client,
    std::span<TTorrentSourcePolicyApplication const> applications,
    LockedChangePublisher &publisher
) TORRENT_BRIDGE_REQUIRES(client.lock)
{
    std::vector<ActiveTorrentEntry> const active_entries = active_torrent_entries(client);
    if (applications.size() != active_entries.size()) {
        return bridge_error(2, "The Swift source policy did not cover every active torrent.");
    }

    std::unordered_map<std::uint64_t, ActiveTorrentEntry const *> active_by_token;
    active_by_token.reserve(active_entries.size());
    for (ActiveTorrentEntry const &entry : active_entries) {
        if (entry.identity == nullptr
            || entry.identity->token == nullptr
            || entry.identity->token->value == 0U
            || !active_by_token.emplace(entry.identity->token->value, &entry).second) {
            return bridge_error(2, "The native source-policy identities were inconsistent.");
        }
    }

    std::set<TorrentIdentity *> seen;
    std::vector<ResolvedSourcePolicyApplication> resolved;
    resolved.reserve(applications.size());
    for (TTorrentSourcePolicyApplication const &application : applications) {
        auto const active = active_by_token.find(application.native_token);
        if (application.native_token == 0U
            || active == active_by_token.end()
            || !seen.insert(active->second->identity).second) {
            return bridge_error(2, "The Swift source policy contained an unknown or duplicate torrent.");
        }
        if (!is_valid_boolean_policy(application.dht_policy)
            || !is_valid_boolean_policy(application.peer_exchange_policy)
            || !is_valid_boolean_policy(application.lsd_policy)
            || !is_valid_https_tracker_policy(application.https_tracker_policy, true)
            || !is_valid_https_web_seed_policy(application.https_web_seed_policy, true)
            || !is_valid_https_tracker_policy(application.effective_https_tracker_policy, false)
            || !is_valid_https_web_seed_policy(application.effective_https_web_seed_policy, false)
            || application.enable_dht > 1U
            || application.enable_peer_exchange > 1U
            || application.enable_lsd > 1U
            || application.allow_pre_metadata_dht > 1U) {
            return bridge_error(1, "The Swift source policy contained an invalid value.");
        }

        ActiveTorrentEntry const &entry = *active->second;
        TorrentIdentity *identity = entry.identity;
        std::shared_ptr<lt::torrent_info const> const torrent_file = entry.handle.torrent_file();
        bool const private_torrent = torrent_file && torrent_file->is_valid() && torrent_file->priv();
        bool const dht_locked = private_torrent || identity->dht_locked_by_source;
        bool const pex_locked = private_torrent || identity->peer_exchange_locked_by_source;
        bool const lsd_locked = private_torrent || identity->lsd_locked_by_source;
        bool const metadata_pending = client.metadata_validation_pending.contains(identity);
        bool const enable_dht = bridge_bool(application.enable_dht);
        bool const enable_pex = bridge_bool(application.enable_peer_exchange);
        bool const enable_lsd = bridge_bool(application.enable_lsd);
        bool const allow_pre_metadata_dht = bridge_bool(application.allow_pre_metadata_dht);
        if ((dht_locked && (enable_dht || application.dht_policy != TTORRENT_BOOLEAN_POLICY_INHERIT))
            || (pex_locked && (enable_pex || application.peer_exchange_policy != TTORRENT_BOOLEAN_POLICY_INHERIT))
            || (lsd_locked && (enable_lsd || application.lsd_policy != TTORRENT_BOOLEAN_POLICY_INHERIT))
            || (metadata_pending && (enable_pex || enable_lsd))
            || (!metadata_pending && allow_pre_metadata_dht)
            || (metadata_pending && enable_dht != allow_pre_metadata_dht)
            || (allow_pre_metadata_dht && dht_locked)
            || (enable_pex && !client.peer_exchange_plugin_enabled)) {
            return bridge_error(2, "The Swift source policy violated a native source constraint.");
        }

        resolved.push_back(ResolvedSourcePolicyApplication{
            .application = application,
            .handle = entry.handle,
            .identity = identity,
            .previous_flags = entry.handle.flags(),
            .previous_tracker_policy = identity->https_tracker_policy,
            .previous_web_seed_policy = identity->https_web_seed_policy,
            .previous_dht_enabled_by_user = identity->dht_enabled_by_user,
            .previous_dht_disabled_by_user = identity->dht_disabled_by_user,
            .previous_peer_exchange_enabled_by_user = identity->peer_exchange_enabled_by_user,
            .previous_peer_exchange_disabled_by_user = identity->peer_exchange_disabled_by_user,
            .previous_lsd_enabled_by_user = identity->lsd_enabled_by_user,
            .previous_lsd_disabled_by_user = identity->lsd_disabled_by_user,
            .previous_allow_pre_metadata_dht = identity->allow_pre_metadata_dht,
            .previous_app_disabled_dht = client.dht_disabled_by_app.contains(identity),
            .previous_app_disabled_peer_exchange = client.peer_exchange_disabled_by_app.contains(identity),
            .previous_app_disabled_lsd = client.lsd_disabled_by_app.contains(identity),
            .previous_trackers = entry.handle.trackers(),
            .previous_web_seeds = entry.handle.url_seeds(),
        });
    }

    DirtyMask changes = 0;
    try {
        for (ResolvedSourcePolicyApplication &entry : resolved) {
            TTorrentSourcePolicyApplication const &application = entry.application;
            TorrentIdentity *identity = entry.identity;
            bool const enable_dht = bridge_bool(application.enable_dht);
            bool const enable_pex = bridge_bool(application.enable_peer_exchange);
            bool const enable_lsd = bridge_bool(application.enable_lsd);
            bool const dht_was_disabled = static_cast<bool>(entry.previous_flags & lt::torrent_flags::disable_dht);
            bool const pex_was_disabled = static_cast<bool>(entry.previous_flags & lt::torrent_flags::disable_pex);
            bool const lsd_was_disabled = static_cast<bool>(entry.previous_flags & lt::torrent_flags::disable_lsd);

            identity->https_tracker_policy = https_policy_from_value(application.https_tracker_policy);
            identity->https_web_seed_policy = https_policy_from_value(application.https_web_seed_policy);
            BooleanPolicyMirror const dht_mirror = policy_mirror(application.dht_policy);
            identity->dht_enabled_by_user = dht_mirror.enabled;
            identity->dht_disabled_by_user = dht_mirror.disabled;
            BooleanPolicyMirror const peer_exchange_mirror = policy_mirror(
                application.peer_exchange_policy
            );
            identity->peer_exchange_enabled_by_user = peer_exchange_mirror.enabled;
            identity->peer_exchange_disabled_by_user = peer_exchange_mirror.disabled;
            BooleanPolicyMirror const lsd_mirror = policy_mirror(application.lsd_policy);
            identity->lsd_enabled_by_user = lsd_mirror.enabled;
            identity->lsd_disabled_by_user = lsd_mirror.disabled;
            identity->allow_pre_metadata_dht = bridge_bool(application.allow_pre_metadata_dht);
            set_membership(
                client.dht_disabled_by_app,
                identity,
                application.dht_policy == TTORRENT_BOOLEAN_POLICY_INHERIT && !enable_dht
            );
            set_membership(
                client.peer_exchange_disabled_by_app,
                identity,
                application.peer_exchange_policy == TTORRENT_BOOLEAN_POLICY_INHERIT && !enable_pex
            );
            set_membership(
                client.lsd_disabled_by_app,
                identity,
                application.lsd_policy == TTORRENT_BOOLEAN_POLICY_INHERIT && !enable_lsd
            );

            bool changed = enable_dht
                ? unset_torrent_flag_if_needed(entry.handle, lt::torrent_flags::disable_dht)
                : set_torrent_flag_if_needed(entry.handle, lt::torrent_flags::disable_dht);
            changed = (enable_pex
                ? unset_torrent_flag_if_needed(entry.handle, lt::torrent_flags::disable_pex)
                : set_torrent_flag_if_needed(entry.handle, lt::torrent_flags::disable_pex)) || changed;
            changed = (enable_lsd
                ? unset_torrent_flag_if_needed(entry.handle, lt::torrent_flags::disable_lsd)
                : set_torrent_flag_if_needed(entry.handle, lt::torrent_flags::disable_lsd)) || changed;

            HTTPSSourcePolicy const https_policy{
                .trackers = https_policy_from_value(application.effective_https_tracker_policy),
                .web_seeds = https_policy_from_value(application.effective_https_web_seed_policy),
            };
            changes |= client.restore_metadata_source_policy(
                entry.handle,
                identity,
                HTTPSSourcePolicyScope::all,
                https_policy
            );
            changes |= client.enforce_https_source_policy(
                entry.handle,
                identity,
                HTTPSSourcePolicyScope::all,
                https_policy
            );
            if (!enable_dht || !enable_pex || https_policy.trackers == HTTPSPolicy::require) {
                changes |= client.clear_peer_cache_if_restricted(entry.handle, identity);
            }
            if (enable_lsd
                && lsd_was_disabled
                && client.lsd_service_enabled
                && !client.requested_network_blocked
                && !static_cast<bool>(entry.previous_flags & lt::torrent_flags::paused)) {
                entry.handle.force_lsd_announce();
            }
            if (changed || dht_was_disabled != !enable_dht || pex_was_disabled != !enable_pex) {
                changes |= kChangeTorrents;
            }
#if defined(TORRENT_BRIDGE_TESTING)
            if (client.fail_next_source_policy_application) {
                client.fail_next_source_policy_application = false;
                throw std::runtime_error("Synthetic source-policy application failure.");
            }
#endif
        }
    } catch (std::exception const &exception) {
        return rollback_source_applications_or_contain(
            client,
            resolved,
            publisher,
            exception.what()
        );
    } catch (...) {
        return rollback_source_applications_or_contain(
            client,
            resolved,
            publisher,
            "The native source policy could not be applied."
        );
    }

    std::vector<lt::torrent_handle> handles;
    handles.reserve(resolved.size());
    for (ResolvedSourcePolicyApplication const &entry : resolved) {
        handles.push_back(entry.handle);
    }
    save_and_publish_policy_handles(client, handles, publisher);
    client.source_policy_reconciled = true;
    publisher.add(changes);
    client.request_snapshot_update_locked();
    return {};
}

} // namespace

extern "C" const char *TorrentBridgeLibtorrentVersion(void) noexcept
{
    return LIBTORRENT_VERSION;
}

extern "C" TTorrentClient *TorrentClientCreateWithError(
    const char *state_path,
    uint8_t enable_pex_plugin,
    TTorrentPayloadBrokerCallbacks payload_broker,
    TTorrentSwarmMetainfoParserCallbacks swarm_metainfo_parser,
    TTorrentPeerProtocolParserCallbacks peer_protocol_parser,
    TTorrentTrackerResponseParserCallbacks tracker_response_parser,
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
        fs::path const state_directory_path{std::string(requested_state_path)};
        if (!state_directory_path.is_absolute()) {
            copy_error(error_buffer, "The state path must be absolute.");
            return nullptr;
        }
        std::string normalized_state_path = state_directory_path.lexically_normal().native();
        auto broker = std::make_shared<PayloadBrokerContext>(payload_broker);
        auto parser = std::make_shared<BridgeSwarmMetadataParser>(swarm_metainfo_parser);
        auto peer_parser = std::make_shared<BridgePeerMessageParser>(peer_protocol_parser);
        auto tracker_parser = std::make_shared<BridgeTrackerResponseParser>(
            tracker_response_parser
        );

        return std::make_unique<TTorrentClient>(
            normalized_state_path,
            bridge_bool(enable_pex_plugin),
            std::move(broker),
            std::move(parser),
            std::move(peer_parser),
            std::move(tracker_parser)
        ).release();
    } catch (std::exception const &exception) {
        copy_error(error_buffer, exception.what());
        return nullptr;
    } catch (...) {
        copy_error(error_buffer, "Unexpected libtorrent error.");
        return nullptr;
    }
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

extern "C" int32_t TorrentClientDrainEvents(
    TTorrentClient *client,
    TTorrentEvent *events,
    int32_t capacity,
    int32_t *required_count_out,
    uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentEvent> output = output_span_from_c_buffer(events, capacity);
        return client->drain_events(output, required_count_out, available_out);
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientDrainPresentationMetadata(
    TTorrentClient *client,
    TTorrentPresentationMetadata *metadata,
    int32_t capacity,
    int32_t *required_count_out,
    uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentPresentationMetadata> output = output_span_from_c_buffer(
            metadata,
            capacity
        );
        return client->drain_presentation_metadata(
            output,
            required_count_out,
            available_out
        );
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientAddParsedMagnet(
    TTorrentClient *client,
    TTorrentMagnetImport magnet,
    std::uint8_t const *blob,
    int32_t blob_size,
    TTorrentMagnetTracker const *trackers,
    int32_t tracker_count,
    TTorrentByteRange const *web_seeds,
    int32_t web_seed_count,
    TTorrentFileSelectionRange const *file_selections,
    int32_t file_selection_count,
    TTorrentAddOptions options,
    char *added_id_out,
    int32_t added_id_capacity,
    std::uint64_t *native_token_out,
    int32_t *add_outcome_out,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    if (add_outcome_out != nullptr) {
        *add_outcome_out = TTORRENT_ADD_REJECTED;
    }
    if (native_token_out != nullptr) {
        *native_token_out = 0U;
    }
    WakeCallbackInvocation wake;
    std::span<char> const added_id_buffer = output_buffer(added_id_out, added_id_capacity);
    copy_string_dynamic(added_id_buffer, "");
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 4, [&]() -> BridgeResult {
        if (client == nullptr || native_token_out == nullptr || add_outcome_out == nullptr) {
            return bridge_error(1, "Missing torrent client, native token, or add outcome output.");
        }
        TTorrentAddOptions const &add_options = options;
        if (blob_size < 0
            || tracker_count < 0
            || web_seed_count < 0
            || file_selection_count < 0
            || (blob_size > 0 && blob == nullptr)
            || (tracker_count > 0 && trackers == nullptr)
            || (web_seed_count > 0 && web_seeds == nullptr)
            || (file_selection_count > 0 && file_selections == nullptr)) {
            return bridge_error(1, "Invalid parsed magnet buffers.");
        }
        if (!is_valid_queue_priority(add_options.queue_priority)) {
            return bridge_error(1, "Invalid queue priority.");
        }
        std::optional<std::string> const canonical_id = requested_torrent_id(add_options);
        if (!canonical_id) {
            return bridge_error(1, "Invalid Swift torrent identifier.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
        BridgeResult const admission = client->ensure_torrent_admission_available(3);
        if (!admission) {
            return admission;
        }
        TorrentLoadResult parsed = import_parsed_magnet(
            magnet,
            input_span_from_c_buffer(blob, blob_size),
            input_span_from_c_buffer(trackers, tracker_count),
            input_span_from_c_buffer(web_seeds, web_seed_count),
            input_span_from_c_buffer(file_selections, file_selection_count)
        );
        if (!parsed) {
            return std::unexpected(parsed.error());
        }
        lt::add_torrent_params params = std::move(*parsed);
        lt::add_torrent_params const source_params = params;
        BridgeResult const valid_original_sources = validate_torrent_sources(source_params);
        if (!valid_original_sources) {
            return valid_original_sources;
        }

        if (add_options.enable_dht > 1U
            || add_options.enable_peer_exchange > 1U
            || add_options.enable_lsd > 1U
            || add_options.allow_pre_metadata_dht > 1U
            || !is_valid_https_tracker_policy(add_options.https_tracker_policy, true)
            || !is_valid_https_web_seed_policy(add_options.https_web_seed_policy, true)
            || !is_valid_https_tracker_policy(add_options.effective_https_tracker_policy, false)
            || !is_valid_https_web_seed_policy(add_options.effective_https_web_seed_policy, false)) {
            return bridge_error(1, "Invalid HTTPS source policy.");
        }
        HTTPSPolicy const requested_tracker_policy = https_policy_from_value(add_options.https_tracker_policy);
        HTTPSPolicy const requested_web_seed_policy = https_policy_from_value(add_options.https_web_seed_policy);
        HTTPSPolicy const effective_tracker_policy = https_policy_from_value(
            add_options.effective_https_tracker_policy
        );
        HTTPSPolicy const effective_web_seed_policy = https_policy_from_value(
            add_options.effective_https_web_seed_policy
        );
        static_cast<void>(apply_https_source_policy(
            params,
            HTTPSSourcePolicy{.trackers = effective_tracker_policy, .web_seeds = effective_web_seed_policy}
        ));
        BridgeResult const valid_effective_sources = validate_torrent_sources(params);
        if (!valid_effective_sources) {
            return valid_effective_sources;
        }
        bool const enable_dht_value = bridge_bool(add_options.enable_dht);
        bool const enable_peer_exchange_value = bridge_bool(add_options.enable_peer_exchange)
            && client->peer_exchange_plugin_enabled;
        bool const enable_lsd_value = bridge_bool(add_options.enable_lsd);
        bool const metadata_pending = !params.ti;
        bool const allow_pre_metadata_dht =
            metadata_pending && bridge_bool(add_options.allow_pre_metadata_dht);
        bool const intended_default_dont_download =
            static_cast<bool>(params.flags & lt::torrent_flags::default_dont_download);
        std::vector<lt::download_priority_t> intended_file_priorities = params.file_priorities;
        bool const private_torrent = params.ti && params.ti->priv();
        bool const dht_locked_by_source =
            private_torrent || static_cast<bool>(params.flags & lt::torrent_flags::disable_dht);
        bool const dht_disabled_by_app = !enable_dht_value && !dht_locked_by_source;
        bool const lsd_locked_by_source =
            private_torrent || static_cast<bool>(params.flags & lt::torrent_flags::disable_lsd);
        bool const lsd_disabled_by_app = !enable_lsd_value && !lsd_locked_by_source;
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
        }
        prepare_add_params(
            params,
            client->staging_path(params.info_hashes),
            bridge_bool(add_options.starts_paused),
            enable_peer_exchange_value && !metadata_pending
        );
        bool const peer_exchange_disabled_by_app =
            !enable_peer_exchange_value && !peer_exchange_was_disabled && !peer_exchange_locked_by_source;
        TorrentIdentity *identity = client->attach_identity(params, *canonical_id, true);
        UnpublishedIdentityGuard identity_guard(*client, identity);
        identity->https_tracker_policy = requested_tracker_policy;
        identity->https_web_seed_policy = requested_web_seed_policy;
        identity->queue_priority = add_options.queue_priority;
        identity->dht_locked_by_source = dht_locked_by_source;
        identity->lsd_locked_by_source = lsd_locked_by_source;
        identity->peer_exchange_locked_by_source = peer_exchange_locked_by_source;
        identity->peer_exchange_enabled_by_user = enable_peer_exchange_value
            && !peer_exchange_locked_by_source;
        identity->peer_exchange_disabled_by_user = !enable_peer_exchange_value
            && !peer_exchange_locked_by_source;
        identity->allow_pre_metadata_dht = allow_pre_metadata_dht;
        identity->intended_default_dont_download = intended_default_dont_download;
        identity->intended_file_priorities = std::move(intended_file_priorities);
        BridgeResult const remembered_sources = remember_source_policy_sources(*identity, source_params);
        if (!remembered_sources) {
            return remembered_sources;
        }
        lt::add_torrent_params resume_params = params;
        lt::error_code add_error;
        *add_outcome_out = TTORRENT_ADD_OUTCOME_UNKNOWN;
        identity_guard.release();
        lt::torrent_handle handle = client->session.add_torrent(std::move(params), add_error);
        client->record_synchronous_add_alert_locked();
        if (add_error) {
            *add_outcome_out = TTORRENT_ADD_REJECTED;
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
        publisher.add(client->observe_torrent_handle(handle));
        client->request_snapshot_update_locked();
        copy_string_dynamic(added_id_buffer, identity->canonical_id);
        *native_token_out = identity->token->value;
        *add_outcome_out = TTORRENT_ADD_COMMITTED;
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
        client->drain_synchronous_add_alerts_if_needed();
    }
    return result;
}

namespace {

TorrentLoadResult load_metainfo_capsule_from_c_buffer(
    std::uint8_t const *capsule,
    int32_t capsule_size
)
{
    if (capsule == nullptr) {
        return std::unexpected(BridgeError{.code = 1, .message = "Missing metainfo capsule."});
    }
    if (capsule_size < 0) {
        return std::unexpected(BridgeError{.code = 1, .message = "Invalid metainfo capsule size."});
    }

    return import_preparsed_metainfo_capsule(
        input_span_from_c_buffer(capsule, capsule_size)
    );
}

template <typename LoadTorrent>
int32_t add_torrent_with_loader(
    TTorrentClient *client,
    TTorrentStorageActivation const activation,
    TTorrentAddOptions const &options,
    bool apply_file_priority_overrides,
    const TTorrentFilePriorityEntry *file_priorities,
    int32_t file_priority_count,
    char *added_id_out,
    int32_t added_id_capacity,
    std::uint64_t *native_token_out,
    int32_t *add_outcome_out,
    char *error_out,
    int32_t error_capacity,
    LoadTorrent load_torrent
) noexcept
{
    if (add_outcome_out != nullptr) {
        *add_outcome_out = TTORRENT_ADD_REJECTED;
    }
    if (native_token_out != nullptr) {
        *native_token_out = 0U;
    }
    WakeCallbackInvocation wake;
    std::span<char> const added_id_buffer = output_buffer(added_id_out, added_id_capacity);
    copy_string_dynamic(added_id_buffer, "");
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || native_token_out == nullptr || add_outcome_out == nullptr) {
            return bridge_error(1, "Missing torrent client, native token, or add outcome output.");
        }
        TTorrentAddOptions const &add_options = options;
        if (file_priority_count < 0) {
            return bridge_error(1, "Invalid file priority count.");
        }
        if (file_priority_count > TTORRENT_MAX_FILE_COUNT) {
            return bridge_error(1, "Invalid file priority count.");
        }
        if (file_priority_count > 0 && file_priorities == nullptr) {
            return bridge_error(1, "Missing file priorities.");
        }
        if (!is_valid_queue_priority(add_options.queue_priority)) {
            return bridge_error(1, "Invalid queue priority.");
        }
        std::optional<std::string> const canonical_id = requested_torrent_id(add_options);
        if (!canonical_id) {
            return bridge_error(1, "Invalid Swift torrent identifier.");
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
        BridgeResult const valid_activation = validate_storage_activation(params, activation);
        if (!valid_activation) {
            return valid_activation;
        }
        sanitize_resume_endpoint_hints(params);
        lt::add_torrent_params const source_params = params;
        BridgeResult const valid_original_sources = validate_torrent_sources(source_params);
        if (!valid_original_sources) {
            return valid_original_sources;
        }
        if (apply_file_priority_overrides
            && file_priority_count > params.ti->layout().num_files()) {
            return bridge_error(2, "The file priorities are invalid.");
        }

        std::optional<std::span<TTorrentFilePriorityEntry const>> priority_entries;
        if (apply_file_priority_overrides) {
            priority_entries = input_span_from_c_buffer(file_priorities, file_priority_count);
        }
        BridgeResult const valid_file_policy = apply_file_priorities(params, priority_entries);
        if (!valid_file_policy) {
            return valid_file_policy;
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence =
            client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }
        BridgeResult const admission = client->ensure_torrent_admission_available(2);
        if (!admission) {
            return admission;
        }
        if (add_options.enable_dht > 1U
            || add_options.enable_peer_exchange > 1U
            || add_options.enable_lsd > 1U
            || add_options.allow_pre_metadata_dht > 1U
            || !is_valid_https_tracker_policy(add_options.https_tracker_policy, true)
            || !is_valid_https_web_seed_policy(add_options.https_web_seed_policy, true)
            || !is_valid_https_tracker_policy(add_options.effective_https_tracker_policy, false)
            || !is_valid_https_web_seed_policy(add_options.effective_https_web_seed_policy, false)) {
            return bridge_error(1, "Invalid HTTPS source policy.");
        }
        HTTPSPolicy const requested_tracker_policy = https_policy_from_value(add_options.https_tracker_policy);
        HTTPSPolicy const requested_web_seed_policy = https_policy_from_value(add_options.https_web_seed_policy);
        HTTPSPolicy const effective_tracker_policy = https_policy_from_value(
            add_options.effective_https_tracker_policy
        );
        HTTPSPolicy const effective_web_seed_policy = https_policy_from_value(
            add_options.effective_https_web_seed_policy
        );
        static_cast<void>(apply_https_source_policy(
            params,
            HTTPSSourcePolicy{.trackers = effective_tracker_policy, .web_seeds = effective_web_seed_policy}
        ));
        BridgeResult const valid_effective_sources = validate_torrent_sources(params);
        if (!valid_effective_sources) {
            return valid_effective_sources;
        }
        bool const enable_dht_value = bridge_bool(add_options.enable_dht);
        bool const enable_peer_exchange_value = bridge_bool(add_options.enable_peer_exchange)
            && client->peer_exchange_plugin_enabled;
        bool const enable_lsd_value = bridge_bool(add_options.enable_lsd);
        bool const private_torrent = params.ti && params.ti->priv();
        bool const dht_locked_by_source =
            private_torrent || static_cast<bool>(params.flags & lt::torrent_flags::disable_dht);
        bool const dht_disabled_by_app = !enable_dht_value && !dht_locked_by_source;
        bool const lsd_locked_by_source =
            private_torrent || static_cast<bool>(params.flags & lt::torrent_flags::disable_lsd);
        bool const lsd_disabled_by_app = !enable_lsd_value && !lsd_locked_by_source;
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
            client->part_file_path(activation),
            bridge_bool(add_options.starts_paused),
            enable_peer_exchange_value
        );
        params.file_provider = client->make_payload_provider(activation);
        bool const peer_exchange_disabled_by_app =
            !enable_peer_exchange_value && !peer_exchange_was_disabled && !peer_exchange_locked_by_source;
        std::string const preserved_id = storage_preserved_torrent_id(activation);
        if (!preserved_id.empty() && preserved_id != *canonical_id) {
            return bridge_error(2, "The Swift torrent identifier does not match the preserved storage identity.");
        }
        TorrentIdentity *identity = client->attach_identity(
            params,
            *canonical_id,
            true
        );
        UnpublishedIdentityGuard identity_guard(*client, identity);
        identity->storage_activation = activation;
        identity->https_tracker_policy = requested_tracker_policy;
        identity->https_web_seed_policy = requested_web_seed_policy;
        identity->queue_priority = add_options.queue_priority;
        identity->dht_locked_by_source = dht_locked_by_source;
        identity->lsd_locked_by_source = lsd_locked_by_source;
        identity->peer_exchange_locked_by_source = peer_exchange_locked_by_source;
        identity->peer_exchange_enabled_by_user = enable_peer_exchange_value
            && !peer_exchange_locked_by_source;
        identity->peer_exchange_disabled_by_user = !enable_peer_exchange_value
            && !peer_exchange_locked_by_source;
        BridgeResult const remembered_sources = remember_source_policy_sources(*identity, source_params);
        if (!remembered_sources) {
            return remembered_sources;
        }
        lt::add_torrent_params resume_params = params;
        lt::error_code add_error;
        *add_outcome_out = TTORRENT_ADD_OUTCOME_UNKNOWN;
        identity_guard.release();
        lt::torrent_handle handle = client->session.add_torrent(std::move(params), add_error);
        client->record_synchronous_add_alert_locked();
        if (add_error) {
            *add_outcome_out = TTORRENT_ADD_REJECTED;
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
        publisher.add(client->observe_torrent_handle(handle));
        client->request_snapshot_update_locked();
        copy_string_dynamic(added_id_buffer, identity->canonical_id);
        *native_token_out = identity->token->value;
        *add_outcome_out = TTORRENT_ADD_COMMITTED;
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
        client->drain_synchronous_add_alerts_if_needed();
    }
    return result;
}

} // namespace

#ifdef TORRENT_BRIDGE_TESTING
int32_t add_torrent_params_for_testing(
    TTorrentClient *client,
    lt::add_torrent_params params,
    TTorrentStorageActivation activation,
    TTorrentAddOptions const &options,
    char *added_id_out,
    int32_t added_id_capacity,
    std::uint64_t *native_token_out,
    int32_t *add_outcome_out,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return add_torrent_with_loader(
        client,
        activation,
        options,
        false,
        nullptr,
        0,
        added_id_out,
        added_id_capacity,
        native_token_out,
        add_outcome_out,
        error_out,
        error_capacity,
        [params = std::move(params)]() mutable -> TorrentLoadResult {
            return std::move(params);
        }
    );
}
#endif

extern "C" int32_t TorrentClientAddMetainfoCapsule(
    TTorrentClient *client,
    std::uint8_t const *capsule,
    int32_t capsule_size,
    TTorrentStorageActivation activation,
    TTorrentAddOptions options,
    char *added_id_out,
    int32_t added_id_capacity,
    std::uint64_t *native_token_out,
    int32_t *add_outcome_out,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return add_torrent_with_loader(
        client,
        activation,
        options,
        false,
        nullptr,
        0,
        added_id_out,
        added_id_capacity,
        native_token_out,
        add_outcome_out,
        error_out,
        error_capacity,
        [capsule, capsule_size]() {
            return load_metainfo_capsule_from_c_buffer(capsule, capsule_size);
        }
    );
}

extern "C" int32_t TorrentClientAddMetainfoCapsuleWithPriorities(
    TTorrentClient *client,
    std::uint8_t const *capsule,
    int32_t capsule_size,
    TTorrentStorageActivation activation,
    TTorrentAddOptions options,
    const TTorrentFilePriorityEntry *file_priorities,
    int32_t file_priority_count,
    char *added_id_out,
    int32_t added_id_capacity,
    std::uint64_t *native_token_out,
    int32_t *add_outcome_out,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    return add_torrent_with_loader(
        client,
        activation,
        options,
        true,
        file_priorities,
        file_priority_count,
        added_id_out,
        added_id_capacity,
        native_token_out,
        add_outcome_out,
        error_out,
        error_capacity,
        [capsule, capsule_size]() {
            return load_metainfo_capsule_from_c_buffer(capsule, capsule_size);
        }
    );
}

extern "C" int32_t TorrentClientCopySnapshotBatch(
    TTorrentClient *client,
    TTorrentSnapshot *snapshots,
    int32_t capacity,
    int32_t *required_count_out,
    uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = 0;
    }
    if (client == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentSnapshot> output = output_span_from_c_buffer(snapshots, capacity);
        int32_t const copied = client->copy_snapshots(output, required_count_out);
        if (available_out != nullptr) {
            *available_out = 1;
        }
        return copied;
    } catch (...) {
        return 0;
    }
}

extern "C" int32_t TorrentClientCopySourcePolicyStateBatch(
    TTorrentClient *client,
    TTorrentSourcePolicyState *states,
    int32_t capacity,
    int32_t *required_count_out,
    uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentSourcePolicyState> output = output_span_from_c_buffer(states, capacity);
        std::scoped_lock guard(client->lock);
        std::vector<ActiveTorrentEntry> const active_entries = active_torrent_entries(*client);
        if (active_entries.size() > static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT)) {
            return 0;
        }
        auto const required = static_cast<int32_t>(active_entries.size());
        if (required_count_out != nullptr) {
            *required_count_out = required;
        }
        if (output.size() < active_entries.size()) {
            if (available_out != nullptr) {
                *available_out = bridge_bool(true);
            }
            return 0;
        }
        auto destination = output.begin();
        for (ActiveTorrentEntry const &entry : active_entries) {
            *destination = source_policy_state(*client, entry);
            ++destination;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(true);
        }
        return required;
    } catch (...) {
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(false);
        }
        return 0;
    }
}

extern "C" int32_t TorrentClientApplySourcePolicyState(
    TTorrentClient *client,
    TTorrentSourcePolicyApplication const *applications,
    int32_t application_count,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }
        if (application_count < 0 || application_count > TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT) {
            return bridge_error(1, "Invalid Swift source-policy count.");
        }
        if (application_count > 0 && applications == nullptr) {
            return bridge_error(1, "Missing Swift source policy.");
        }
        std::span<TTorrentSourcePolicyApplication const> const source_policy = input_span_from_c_buffer(
            applications,
            application_count
        );
        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(2);
        return persistence
            ? apply_source_policy_state_locked(*client, source_policy, publisher)
            : persistence;
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" TTorrentOptionsResult TorrentClientCopyTorrentOptions(
    TTorrentClient *client,
    std::uint64_t const native_token,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    TTorrentOptionsResult output{};
    output.status = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || native_token == 0U) {
            return bridge_error(1, "Missing torrent client or native token.");
        }

        std::scoped_lock guard(client->lock);
        auto handle = client->find(native_token);
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        TorrentIdentity const *identity = identity_from_handle(*handle);
        output.options.download_rate_limit = handle->download_limit();
        output.options.upload_rate_limit = handle->upload_limit();
        output.options.max_uploads = normalized_torrent_count_limit(handle->max_uploads());
        output.options.max_connections = normalized_torrent_count_limit(handle->max_connections());
        output.options.queue_priority = identity == nullptr ? TTORRENT_QUEUE_PRIORITY_NORMAL : identity->queue_priority;
        return {};
    });
    return output;
}

extern "C" int32_t TorrentClientSetTorrentOptions(
    TTorrentClient *client,
    std::uint64_t const native_token,
    TTorrentOptions options,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || native_token == 0U) {
            return bridge_error(1, "Missing torrent client or native token.");
        }
        if (options.download_rate_limit < -1 || options.upload_rate_limit < -1) {
            return bridge_error(1, "Torrent rate limits must be unlimited or nonnegative.");
        }
        if (!is_valid_torrent_count_limit(options.max_uploads)
            || !is_valid_torrent_count_limit(options.max_connections)) {
            return bridge_error(1, "Torrent count limits must be unlimited or at least 2.");
        }
        if (!is_valid_queue_priority(options.queue_priority)) {
            return bridge_error(1, "Invalid queue priority.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }
        auto handle = client->find(native_token);
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        TorrentIdentity *identity = identity_from_handle(*handle);
        if (identity == nullptr) {
            return bridge_error(2, "Torrent identity not found.");
        }

        if (handle->download_limit() != options.download_rate_limit) {
            handle->set_download_limit(options.download_rate_limit);
        }
        if (handle->upload_limit() != options.upload_rate_limit) {
            handle->set_upload_limit(options.upload_rate_limit);
        }
        if (normalized_torrent_count_limit(handle->max_uploads()) != options.max_uploads) {
            handle->set_max_uploads(options.max_uploads);
        }
        if (normalized_torrent_count_limit(handle->max_connections()) != options.max_connections) {
            handle->set_max_connections(options.max_connections);
        }
        client->request_save_locked(*handle);
        publisher.add(client->observe_torrent_handle(*handle));
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientApplyQueueState(
    TTorrentClient *client,
    TTorrentQueuePlacement const *placements,
    int32_t placement_count,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }
        if (placement_count < 0 || placement_count > TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT) {
            return bridge_error(1, "Invalid Swift queue state count.");
        }
        if (placement_count > 0 && placements == nullptr) {
            return bridge_error(1, "Missing Swift queue state.");
        }
        std::span<TTorrentQueuePlacement const> const queue_state = input_span_from_c_buffer(
            placements,
            placement_count
        );

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }
        return apply_queue_state_locked(*client, queue_state, publisher);
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientCopyTrackerBatch(
    TTorrentClient *client,
    std::uint64_t const native_token,
    TTorrentTrackerSnapshot *trackers,
    int32_t capacity,
    int32_t *required_count_out,
    uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr || native_token == 0U) {
        return 0;
    }

    try {
        std::span<TTorrentTrackerSnapshot> output = output_span_from_c_buffer(trackers, capacity);
        return client->copy_trackers(
            native_token,
            output,
            required_count_out,
            available_out
        );
    } catch (...) {
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(false);
        }
        return 0;
    }
}

extern "C" int32_t TorrentClientCopyTrackerHostBatch(
    TTorrentClient *client,
    TTorrentTrackerHostSnapshot *hosts,
    int32_t capacity,
    int32_t *required_count_out,
    uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr) {
        return 0;
    }

    try {
        std::span<TTorrentTrackerHostSnapshot> output = output_span_from_c_buffer(hosts, capacity);
        return client->copy_tracker_hosts(output, required_count_out, available_out);
    } catch (...) {
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(false);
        }
        return 0;
    }
}

extern "C" int32_t TorrentClientCopyWebSeedBatch(TTorrentClient *client, std::uint64_t const native_token,
                                                 TTorrentWebSeedSnapshot *web_seeds, int32_t capacity,
                                                 int32_t *required_count_out,
                                                 uint8_t *available_out) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr || native_token == 0U) {
        return 0;
    }

    try {
        std::span<TTorrentWebSeedSnapshot> output = output_span_from_c_buffer(web_seeds, capacity);
        return client->copy_web_seeds(
            native_token,
            output,
            required_count_out,
            available_out
        );
    } catch (...) {
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(false);
        }
        return 0;
    }
}

extern "C" TTorrentWebSeedActivityResult TorrentClientCopyWebSeedActivity(
    TTorrentClient *client,
    std::uint64_t const native_token
) noexcept
{
    TTorrentWebSeedActivityResult output{};
    if (client == nullptr || native_token == 0U) {
        return output;
    }

    try {
        output.status = client->copy_web_seed_activity(
            native_token,
            &output.activity
        ) ? 1 : 0;
    } catch (...) {
        output = {};
    }
    return output;
}

extern "C" TTorrentPeerSourcesResult TorrentClientCopyPeerSources(
    TTorrentClient *client,
    std::uint64_t const native_token
) noexcept
{
    TTorrentPeerSourcesResult output{};
    if (client == nullptr || native_token == 0U) {
        return output;
    }

    try {
        output.status = client->copy_peer_sources(
            native_token,
            &output.sources
        ) ? 1 : 0;
    } catch (...) {
        output = {};
    }
    return output;
}

extern "C" int32_t TorrentClientCopyFileBatch(TTorrentClient *client, std::uint64_t const native_token,
                                              TTorrentFileSnapshot *files, int32_t capacity,
                                              int32_t *required_count_out, uint8_t *available_out) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr || native_token == 0U) {
        return 0;
    }

    try {
        std::span<TTorrentFileSnapshot> output = output_span_from_c_buffer(files, capacity);
        return client->copy_files(
            native_token,
            output,
            required_count_out,
            available_out
        );
    } catch (...) {
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(false);
        }
        return 0;
    }
}

extern "C" int32_t TorrentClientCopyPieceMap(
    TTorrentClient *client,
    std::uint64_t const native_token,
    TTorrentPieceMapSnapshot *snapshot,
    uint8_t *pieces,
    int32_t capacity,
    int32_t *required_count_out,
    uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (snapshot != nullptr) {
        *snapshot = TTorrentPieceMapSnapshot{};
    }
    if (client == nullptr || native_token == 0U) {
        return 0;
    }

    try {
        std::span<std::uint8_t> output = output_span_from_c_buffer(pieces, capacity);
        return client->copy_piece_map(
            native_token,
            snapshot,
            output,
            required_count_out,
            available_out
        );
    } catch (...) {
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(false);
        }
        if (snapshot != nullptr) {
            *snapshot = TTorrentPieceMapSnapshot{};
        }
        return 0;
    }
}

extern "C" int32_t TorrentClientCopyTorrentMetadata(
    TTorrentClient *client,
    std::uint64_t const native_token,
    std::uint8_t *metadata,
    int32_t capacity,
    int32_t *required_count_out,
    std::uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr || native_token == 0U
        || required_count_out == nullptr || available_out == nullptr) {
        return 0;
    }

    try {
        std::span<std::uint8_t> output = output_span_from_c_buffer(metadata, capacity);
        std::scoped_lock guard(client->lock);
        auto const handle = client->find(native_token);
        if (!handle) {
            return 0;
        }
        std::shared_ptr<lt::torrent_info const> const torrent_file = handle->torrent_file();
        if (!torrent_file || !torrent_file->is_valid()) {
            return 0;
        }
        lt::span<char const> const info = torrent_file->info_section();
        if (info.empty()
            || info.size() > static_cast<decltype(info.size())>(kMaxTorrentFileBytes)) {
            return 0;
        }

        *required_count_out = static_cast<int32_t>(info.size());
        *available_out = bridge_bool(true);
        std::size_t const copied = std::min(output.size(), static_cast<std::size_t>(info.size()));
        std::ranges::transform(
            info.first(static_cast<int>(copied)),
            output.begin(),
            [](char const byte) { return static_cast<std::uint8_t>(byte); }
        );
        return static_cast<int32_t>(copied);
    } catch (...) {
        *required_count_out = 0;
        *available_out = bridge_bool(false);
        return 0;
    }
}

extern "C" int32_t TorrentClientSetFilePriority(
    TTorrentClient *client,
    std::uint64_t const native_token,
    int32_t file_index,
    int32_t priority,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr || native_token == 0U) {
            return bridge_error(1, "Missing torrent client or native token.");
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

        auto handle = client->find(native_token);
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

        TorrentIdentity *const identity = identity_from_handle(*handle);
        if (identity != nullptr && !identity->storage_activation) {
            identity->intended_file_priorities.resize(
                static_cast<std::size_t>(torrent_file->layout().num_files()),
                identity->intended_default_dont_download
                    ? lt::dont_download
                    : lt::default_priority
            );
            identity->intended_file_priorities.at(
                static_cast<std::size_t>(file_index)
            ) = file_priority_from_bridge(priority);
            handle->file_priority(
                lt::file_index_t(file_index),
                lt::dont_download
            );
        } else {
            handle->file_priority(
                lt::file_index_t(file_index),
                file_priority_from_bridge(priority)
            );
        }
        client->request_save_locked(*handle);
        publisher.add(client->mark_files_changed());
        publisher.add(client->observe_torrent_handle(*handle));
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientPause(TTorrentClient *client, std::uint64_t const native_token, char *error_out,
                                      int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || native_token == 0U) {
            return bridge_error(1, "Missing torrent client or native token.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
        auto handle = client->find(native_token);
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        handle->set_flags(lt::torrent_flags::paused, lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
        client->request_save_locked(*handle);
        publisher.add(client->observe_torrent_handle(*handle));
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientResume(TTorrentClient *client, std::uint64_t const native_token, char *error_out,
                                       int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || native_token == 0U) {
            return bridge_error(1, "Missing torrent client or native token.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        BridgeResult const persistence = client->ensure_persistence_available(3);
        if (!persistence) {
            return persistence;
        }
        auto handle = client->find(native_token);
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        handle->set_flags(lt::torrent_flags::auto_managed, lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
        client->request_save_locked(*handle);
        publisher.add(client->observe_torrent_handle(*handle));
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientReannounce(TTorrentClient *client, std::uint64_t const native_token, char *error_out,
                                           int32_t error_capacity) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || native_token == 0U) {
            return bridge_error(1, "Missing torrent client or native token.");
        }

        std::scoped_lock guard(client->lock);
        auto handle = client->find(native_token);
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        handle->force_reannounce();
        return {};
    });
}

extern "C" int32_t TorrentClientForceRecheck(TTorrentClient *client, std::uint64_t const native_token, char *error_out,
                                             int32_t error_capacity) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || native_token == 0U) {
            return bridge_error(1, "Missing torrent client or native token.");
        }

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        auto handle = client->find(native_token);
        if (!handle) {
            return bridge_error(2, "Torrent not found.");
        }

        handle->force_recheck();
        publisher.add(client->observe_torrent_handle(*handle));
        client->request_snapshot_update_locked();
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientRemove(TTorrentClient *client, std::uint64_t const native_token,
                                       uint8_t *removal_committed_out, char *error_out, int32_t error_capacity) noexcept
{
    if (removal_committed_out != nullptr) {
        *removal_committed_out = bridge_bool(false);
    }
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || native_token == 0U || removal_committed_out == nullptr) {
            return bridge_error(1, "Missing torrent client, native token, or removal operation output.");
        }

        TorrentIdentityToken *removal_token = nullptr;
        {
            std::scoped_lock guard(client->lock);
            LockedChangePublisher publisher(*client, wake);
            auto handle = client->find(native_token);
            if (!handle) {
                return bridge_error(2, "Torrent not found.");
            }

            lt::info_hash_t const hashes = handle->info_hashes();
            TorrentIdentity *identity = identity_from_handle(*handle);
            if (identity == nullptr || identity->token == nullptr) {
                return bridge_error(3, "Torrent removal identity is unavailable.");
            }
            std::string const &id = identity->canonical_id;
            removal_token = identity->token;

            try {
                client->session.remove_torrent(*handle);
            } catch (std::exception const &exception) {
                return bridge_error(3, exception.what());
            } catch (...) {
                return bridge_error(3, "Torrent could not be removed.");
            }
            *removal_committed_out = bridge_bool(true);
            client->mark_remove_requested(hashes, identity);
            publisher.add(client->mark_torrent_removed(hashes, id));
            client->request_snapshot_update_locked();
        }

        if (!client->wait_for_torrent_removal(
                removal_token,
                kTorrentRemovalQuiescenceTimeout
            )) {
            return bridge_error(
                3,
                "Torrent removal did not release its disk activity before the deadline."
            );
        }
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" int32_t TorrentClientCopyResumeIDs(
    TTorrentClient *client,
    std::uint64_t const native_token,
    TTorrentResumeID *ids,
    int32_t const capacity,
    int32_t *required_count_out,
    std::uint8_t *available_out
) noexcept
{
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
    if (available_out != nullptr) {
        *available_out = bridge_bool(false);
    }
    if (client == nullptr || native_token == 0U) {
        return 0;
    }

    try {
        std::span<TTorrentResumeID> const output = output_span_from_c_buffer(ids, capacity);
        std::scoped_lock guard(client->lock);
        std::optional<lt::torrent_handle> const handle = client->find(native_token);
        if (!handle) {
            return 0;
        }
        TorrentIdentity *const identity = identity_from_handle(*handle);
        if (identity == nullptr) {
            return 0;
        }
        std::vector<std::string> const resume_ids = client->removal_ids_for_identity(
            handle->info_hashes(),
            identity->canonical_id,
            identity
        );
        if (resume_ids.empty()
            || resume_ids.size() > static_cast<std::size_t>(TTORRENT_MAX_RESUME_ID_COUNT)) {
            return 0;
        }
        auto const required = static_cast<int32_t>(resume_ids.size());
        if (required_count_out != nullptr) {
            *required_count_out = required;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(true);
        }
        if (output.size() < resume_ids.size()) {
            return 0;
        }
        auto destination = output.begin();
        for (std::string const &resume_id : resume_ids) {
            *destination = {};
            copy_string(std::span{destination->value}, resume_id);
            ++destination;
        }
        return required;
    } catch (...) {
        if (required_count_out != nullptr) {
            *required_count_out = 0;
        }
        if (available_out != nullptr) {
            *available_out = bridge_bool(false);
        }
        return 0;
    }
}

extern "C" int32_t TorrentClientPersistRemovalTombstone(
    TTorrentClient *client,
    TTorrentResumeID const *ids,
    int32_t const id_count,
    char *filename_out,
    int32_t const filename_capacity,
    char *error_out,
    int32_t const error_capacity
) noexcept
{
    std::span<char> const filename_buffer = output_buffer(filename_out, filename_capacity);
    copy_error(filename_buffer, "");
    return run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || id_count <= 0 || ids == nullptr || filename_buffer.empty()) {
            return bridge_error(1, "Missing removal tombstone input or output.");
        }
        ResumeIDListResult const resume_ids = resume_ids_from_bridge(
            input_span_from_c_buffer(ids, id_count)
        );
        if (!resume_ids) {
            return bridge_error(1, resume_ids.error());
        }

        std::scoped_lock io_guard(client->resume_io_lock);
        BridgeResult const persistence = client->ensure_persistence_available_locked(3);
        if (!persistence) {
            return persistence;
        }
        TombstoneCommitResult const saved = client->persist_removal_tombstones_locked(*resume_ids);
        if (!saved) {
            return bridge_error(3, saved.error());
        }
        if (!saved->directory_synced) {
            return client->fault_persistence_and_pause_locked(
                3,
                "Removal tombstone commit outcome is uncertain."
            );
        }
        if (saved->filename.empty()
            || saved->filename.size() + 1U > filename_buffer.size()) {
            return client->fault_persistence_and_pause_locked(
                3,
                "Removal tombstone filename could not be returned."
            );
        }
        copy_string_dynamic(filename_buffer, saved->filename);
        return {};
    });
}

extern "C" int32_t TorrentClientRemoveResumeData(
    TTorrentClient *client,
    TTorrentResumeID const *ids,
    int32_t const id_count,
    char *error_out,
    int32_t const error_capacity
) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || id_count <= 0 || ids == nullptr) {
            return bridge_error(1, "Missing resume cleanup input.");
        }
        ResumeIDListResult const resume_ids = resume_ids_from_bridge(
            input_span_from_c_buffer(ids, id_count)
        );
        if (!resume_ids) {
            return bridge_error(1, resume_ids.error());
        }
        ResumeSaveResult const removed = client->remove_resume_files_for_ids_checked(*resume_ids);
        return removed ? BridgeResult{} : bridge_error(3, removed.error());
    });
}

extern "C" int32_t TorrentClientClearRemovalTombstone(
    TTorrentClient *client,
    char const *filename,
    char *error_out,
    int32_t const error_capacity
) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr || filename == nullptr) {
            return bridge_error(1, "Missing removal tombstone filename.");
        }
        ResumeSaveResult const cleared = client->clear_removal_tombstone_file(
            c_string_view(filename)
        );
        return cleared ? BridgeResult{} : bridge_error(3, cleared.error());
    });
}

extern "C" int32_t TorrentClientApplySettings(
    TTorrentClient *client,
    TTorrentSessionSettings requested,
    char const *required_network_interface,
    int32_t required_network_interface_size,
    char *error_out,
    int32_t error_capacity
) noexcept
{
    WakeCallbackInvocation wake;
    int32_t const result = run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }
        bool const has_network_interface = required_network_interface != nullptr;
        bool const has_network_interface_bytes = required_network_interface_size != 0;
        if (required_network_interface_size < 0
            || required_network_interface_size > TTORRENT_MAX_NETWORK_INTERFACE_BYTES
            || has_network_interface != has_network_interface_bytes) {
            return bridge_error(1, "Invalid required network interface buffer.");
        }

        std::span<char const> const network_interface_bytes = input_span_from_c_buffer(
            required_network_interface,
            required_network_interface_size
        );
        std::string const network_interface(
            network_interface_bytes.begin(),
            network_interface_bytes.end()
        );
        bool const accept_incoming_connections = bridge_bool(requested.accept_incoming_connections);
        bool const enable_port_forwarding = bridge_bool(requested.enable_port_forwarding);
        bool const enable_dht = bridge_bool(requested.enable_dht);
        bool const dht_read_only = bridge_bool(requested.dht_read_only);
        if (!is_valid_dht_discovery_policy(requested.dht_discovery_policy)) {
            return bridge_error(1, "Invalid DHT discovery policy.");
        }
        bool const use_dht_as_fallback = requested.dht_discovery_policy
            == TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL;
        bool const enable_lsd = bridge_bool(requested.enable_lsd);
        bool const anonymous_mode = bridge_bool(requested.anonymous_mode);
        bool const network_blocked = bridge_bool(requested.network_blocked);
        if (!is_valid_encryption_policy(requested.encryption_policy)) {
            return bridge_error(1, "Invalid encryption policy.");
        }
        if (!network_blocked) {
            static_cast<void>(network_binding(network_interface));
        }
        std::string const listen_interface_settings =
            listen_interfaces(requested.incoming_port, network_interface, network_blocked);
        std::string const outgoing_interface_settings =
            outgoing_interfaces(network_interface, network_blocked);

        std::scoped_lock guard(client->lock);
        LockedChangePublisher publisher(*client, wake);
        if (!network_blocked && !client->source_policy_reconciled) {
            return bridge_error(
                2,
                "Networking cannot resume until source policy has been fully reconciled."
            );
        }
        if (network_blocked) {
            DirtyMask containment_changes = 0U;
            BridgeResult const containment = block_network_locked(
                *client,
                containment_changes
            );
            if (!containment) {
                return containment;
            }
            publisher.add(containment_changes);
        }

        BridgeResult const persistence = client->ensure_persistence_available(2);
        if (!persistence) {
            return persistence;
        }

        bool const should_resume_session = client->requested_network_blocked && !network_blocked;
        bool const expected_session_paused = network_blocked
            || (!should_resume_session && client->session.is_paused());
        client->lsd_service_enabled = enable_lsd;

        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces, listen_interface_settings);
        settings.set_str(lt::settings_pack::outgoing_interfaces, outgoing_interface_settings);
        settings.set_int(lt::settings_pack::download_rate_limit, requested.download_rate_limit);
        settings.set_int(lt::settings_pack::upload_rate_limit, requested.upload_rate_limit);
        settings.set_int(lt::settings_pack::active_downloads, requested.active_downloads);
        settings.set_int(lt::settings_pack::active_seeds, requested.active_seeds);
        settings.set_int(lt::settings_pack::active_limit, requested.active_limit);
        settings.set_bool(lt::settings_pack::dont_count_slow_torrents, false);
        settings.set_int(lt::settings_pack::share_ratio_limit, requested.share_ratio_limit);
        settings.set_int(lt::settings_pack::seed_time_limit, requested.seed_time_limit);
        settings.set_bool(lt::settings_pack::enable_upnp, !network_blocked && enable_port_forwarding);
        settings.set_bool(lt::settings_pack::enable_natpmp, !network_blocked && enable_port_forwarding);
        settings.set_bool(lt::settings_pack::enable_dht, !network_blocked && enable_dht);
        settings.set_bool(lt::settings_pack::dht_read_only, dht_read_only);
        settings.set_bool(lt::settings_pack::use_dht_as_fallback, use_dht_as_fallback);
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
        settings.set_int(lt::settings_pack::out_enc_policy, encryption_policy(requested.encryption_policy));
        settings.set_int(lt::settings_pack::in_enc_policy, encryption_policy(requested.encryption_policy));
        settings.set_int(lt::settings_pack::allowed_enc_level, static_cast<int>(lt::settings_pack::pe_both));
        settings.set_bool(lt::settings_pack::prefer_rc4, false);
        client->session.apply_settings(std::move(settings));

        if (network_blocked) {
            client->session.pause();
        } else if (should_resume_session) {
            client->session.resume();
        }

        BridgeResult const acknowledged = acknowledge_network_state_locked(
            *client,
            NativeNetworkStateExpectation{
                .listen_interfaces = listen_interface_settings,
                .outgoing_interfaces = outgoing_interface_settings,
                .enable_upnp = !network_blocked && enable_port_forwarding,
                .enable_natpmp = !network_blocked && enable_port_forwarding,
                .enable_dht = !network_blocked && enable_dht,
                .enable_lsd = !network_blocked && enable_lsd,
                .enable_outgoing_tcp = !network_blocked,
                .enable_incoming_tcp = !network_blocked && accept_incoming_connections,
                .enable_outgoing_utp = !network_blocked,
                .enable_incoming_utp = !network_blocked && accept_incoming_connections,
                .dht_privacy_lookups = !network_blocked && enable_dht,
                .dht_read_only = dht_read_only,
                .use_dht_as_fallback = use_dht_as_fallback,
                .session_paused = expected_session_paused,
            },
            network_blocked
                ? "Native network containment could not be confirmed."
                : "Native network binding could not be confirmed."
        );
        if (!acknowledged) {
            return acknowledged;
        }

        if (network_blocked) {
            publisher.add(client->record_network_blocked());
        } else {
            publisher.add(client->record_network_requested(false));
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
        DirtyMask changes = 0U;
        BridgeResult const containment = block_network_locked(*client, changes);
        if (!containment) {
            return containment;
        }
        publisher.add(changes);
        return {};
    });
    if (client != nullptr) {
        client->invoke_wake_callback(wake);
    }
    return result;
}

extern "C" TTorrentNetworkStatusResult TorrentClientCopyNetworkStatus(TTorrentClient *client) noexcept
{
    TTorrentNetworkStatusResult output{};
    if (client == nullptr) {
        return output;
    }

    try {
        std::scoped_lock guard(client->lock);
        output.network_status = client->network_status();
        output.status = 1;
    } catch (...) {
        output = {};
    }
    return output;
}

extern "C" TTorrentBridgeHealthResult TorrentClientCopyHealth(TTorrentClient *client) noexcept
{
    TTorrentBridgeHealthResult output{};
    if (client == nullptr) {
        return output;
    }

    try {
        std::scoped_lock guard(client->lock);
        output.health = client->health_status();
        output.status = 1;
    } catch (...) {
        output = {};
    }
    return output;
}

extern "C" int32_t TorrentClientSaveResumeDataChecked(
    TTorrentClient *client,
    std::uint64_t const native_token,
    std::uint8_t const save_mode,
    char *error_out,
    int32_t const error_capacity
) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 3, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }
        return client->save_resume_data_checked(
            native_token,
            static_cast<ResumeSaveMode>(save_mode)
        );
    });
}

extern "C" int32_t TorrentClientRecoverPendingRemovalsChecked(
    TTorrentClient *client,
    char *error_out,
    int32_t const error_capacity
) noexcept
{
    return run_bridge_operation(output_buffer(error_out, error_capacity), 2, [&]() -> BridgeResult {
        if (client == nullptr) {
            return bridge_error(1, "Missing torrent client.");
        }

        std::scoped_lock guard(client->lock);
        ResumeSaveResult const recovered = client->complete_pending_removals();
        if (!recovered) {
            return bridge_error(3, recovered.error());
        }
        return {};
    });
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

} // namespace torrent_bridge::internal
