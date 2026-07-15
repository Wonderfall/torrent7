#ifndef TORRENT_BRIDGE_INTERNAL_HPP
#define TORRENT_BRIDGE_INTERNAL_HPP

#include "TorrentBridge.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/client_data.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_handle.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <arpa/inet.h>
#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstddef>
#include <condition_variable>
#include <ctime>
#include <exception>
#include <expected>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <ranges>
#include <set>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>
#include <fcntl.h>
#include <cstdlib>
#include <sys/cdefs.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>


namespace fs = std::filesystem;
namespace lt = libtorrent;

constexpr std::string_view kResumeExtension = ".fastresume";
constexpr std::string_view kTempExtension = ".tmp";
constexpr std::string_view kRemovalTombstoneExtension = ".remove";
constexpr std::string_view kRemovalTombstonePrefix = "removal-";
constexpr std::string_view kCanonicalIDResumeKey = "torrent-app-id";
constexpr std::string_view kMetadataValidationPendingResumeKey = "torrent-app-metadata-validation-pending";
constexpr std::string_view kAllowPreMetadataDHTResumeKey = "torrent-app-allow-pre-metadata-dht";
constexpr std::string_view kAllowNonHTTPSTrackersResumeKey = "torrent-app-allow-non-https-trackers";
constexpr std::string_view kAllowNonHTTPSWebSeedsResumeKey = "torrent-app-allow-non-https-web-seeds";
constexpr std::string_view kRequireHTTPSTrackersResumeKey = "torrent-app-require-https-trackers";
constexpr std::string_view kRequireHTTPSWebSeedsResumeKey = "torrent-app-require-https-web-seeds";
constexpr std::string_view kEnableDHTResumeKey = "torrent-app-enable-dht";
constexpr std::string_view kDisableDHTResumeKey = "torrent-app-disable-dht";
constexpr std::string_view kAppDisabledDHTResumeKey = "torrent-app-policy-disable-dht";
constexpr std::string_view kEnablePeerExchangeResumeKey = "torrent-app-enable-pex";
constexpr std::string_view kDisablePeerExchangeResumeKey = "torrent-app-disable-pex";
constexpr std::string_view kEnableLSDResumeKey = "torrent-app-enable-lsd";
constexpr std::string_view kDisableLSDResumeKey = "torrent-app-disable-lsd";
constexpr std::string_view kAppDisabledLSDResumeKey = "torrent-app-policy-disable-lsd";
constexpr std::string_view kQueuePriorityResumeKey = "torrent-app-queue-priority";
constexpr std::string_view kQueueRankResumeKey = "torrent-app-queue-rank";
constexpr std::string_view kCanonicalIDPrefix = "t:";
constexpr std::string_view kNetworkClientIdentity = "libtorrent/2.1";
constexpr int32_t kUnsetQueueRank = -1;
constexpr std::size_t kOneKilobyte = 1024U;
constexpr std::uintmax_t kOneMegabyte = static_cast<std::uintmax_t>(1024U) * 1024U;
constexpr std::size_t kRemovalTombstoneNonceBytes = 16U;
constexpr std::size_t kMaxMagnetURIBytes = 64U * kOneKilobyte;
constexpr std::uintmax_t kMaxTorrentFileBytes = 64U * kOneMegabyte;
constexpr std::uintmax_t kMaxResumeFileBytes = 64U * kOneMegabyte;
constexpr std::uintmax_t kMaxRemovalTombstoneBytes = 16U * kOneKilobyte;
constexpr std::array<unsigned char, 3> kUTF8ReplacementCharacter{0xefU, 0xbfU, 0xbdU};
constexpr auto kAlertWaitInterval = std::chrono::milliseconds(250);
constexpr auto kSnapshotUpdateInterval = std::chrono::milliseconds(500);
constexpr std::size_t kMaxPendingAlertErrors = 16U;
constexpr auto kPeriodicResumeSaveInterval = std::chrono::minutes(2);
constexpr auto kResumeRetryInterval = std::chrono::seconds(30);
constexpr auto kSnapshotStatusFlags = lt::torrent_handle::query_name
    | lt::torrent_handle::query_save_path
    | lt::torrent_handle::query_torrent_file
    | lt::torrent_handle::query_accurate_download_counters;
constexpr auto kRoutineResumeSaveFlags = lt::torrent_handle::only_if_modified | lt::torrent_handle::save_info_dict;
constexpr auto kPolicyResumeSaveFlags = lt::torrent_handle::save_info_dict;
constexpr auto kFullResumeSaveFlags = lt::torrent_handle::flush_disk_cache | lt::torrent_handle::save_info_dict;

static_assert(kMaxTorrentFileBytes <= static_cast<std::uintmax_t>(std::numeric_limits<int>::max()));
static_assert(kMaxResumeFileBytes <= static_cast<std::uintmax_t>(std::numeric_limits<int>::max()));
static_assert(TTORRENT_MAX_FILE_COUNT > 0);
static_assert(TTORRENT_MAX_TRACKER_COUNT > 0);
static_assert(TTORRENT_MAX_WEB_SEED_COUNT > 0);
static_assert(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT > 0);
static_assert(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT > 0);
static_assert(TTORRENT_BRIDGE_ABI_VERSION == 29U);
#if defined(TORRENT_USE_ASSERTS) && TORRENT_USE_ASSERTS
static_assert(sizeof(lt::add_torrent_params) == 760U);
#else
static_assert(sizeof(lt::add_torrent_params) == 744U);
#endif
static_assert(TTORRENT_FILE_PRIORITY_SKIP == static_cast<int32_t>(static_cast<std::uint8_t>(lt::dont_download)));
static_assert(TTORRENT_FILE_PRIORITY_LOW == static_cast<int32_t>(static_cast<std::uint8_t>(lt::low_priority)));
static_assert(TTORRENT_FILE_PRIORITY_NORMAL == static_cast<int32_t>(static_cast<std::uint8_t>(lt::default_priority)));
static_assert(TTORRENT_FILE_PRIORITY_HIGH == static_cast<int32_t>(static_cast<std::uint8_t>(lt::top_priority)));
static_assert(TTORRENT_ID_CAPACITY == 68);
static_assert(TTORRENT_TRACKER_HOST_CAPACITY == 256);
static_assert(sizeof(TTorrentSnapshot::id) == TTORRENT_ID_CAPACITY);
static_assert(sizeof(TTorrentSnapshot::info_hash) == 68U);
static_assert(sizeof(TTorrentSnapshot::name) == 512U);
static_assert(sizeof(TTorrentSnapshot::save_path) == 1024U);
static_assert(sizeof(TTorrentSnapshot::error) == 512U);
static_assert(sizeof(TTorrentSnapshot::comment) == 1024U);
static_assert(sizeof(TTorrentTrackerSnapshot::url) == 1024U);
static_assert(sizeof(TTorrentTrackerSnapshot::message) == 512U);
static_assert(sizeof(TTorrentTrackerHostSnapshot::torrent_id) == TTORRENT_ID_CAPACITY);
static_assert(sizeof(TTorrentTrackerHostSnapshot::host) == TTORRENT_TRACKER_HOST_CAPACITY);
static_assert(sizeof(TTorrentWebSeedSnapshot::url) == 1024U);
static_assert(sizeof(TTorrentFileSnapshot::path) == 1024U);
static_assert(sizeof(TTorrentFilePreview::name) == 512U);
static_assert(sizeof(TTorrentFilePreview::id) == TTORRENT_ID_CAPACITY);
static_assert(sizeof(std::uint8_t) == 1U);
static_assert(sizeof(std::int32_t) == 4U);
static_assert(sizeof(std::int64_t) == 8U);
static_assert(std::is_standard_layout_v<TTorrentSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentTrackerSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentTrackerSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentTrackerHostSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentTrackerHostSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentWebSeedSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentWebSeedSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentWebSeedActivitySnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentWebSeedActivitySnapshot>);
static_assert(std::is_standard_layout_v<TTorrentPeerSourceSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentPeerSourceSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentFileSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentFileSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentFilePriorityEntry>);
static_assert(std::is_trivially_copyable_v<TTorrentFilePriorityEntry>);
static_assert(std::is_standard_layout_v<TTorrentRemovalResult>);
static_assert(std::is_trivially_copyable_v<TTorrentRemovalResult>);
static_assert(std::is_standard_layout_v<TTorrentPieceMapSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentPieceMapSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentFilePreview>);
static_assert(std::is_trivially_copyable_v<TTorrentFilePreview>);
static_assert(std::is_standard_layout_v<TTorrentSessionSettings>);
static_assert(std::is_trivially_copyable_v<TTorrentSessionSettings>);
static_assert(std::is_standard_layout_v<TTorrentNetworkStatus>);
static_assert(std::is_trivially_copyable_v<TTorrentNetworkStatus>);
static_assert(std::is_standard_layout_v<TTorrentSourcePolicy>);
static_assert(std::is_trivially_copyable_v<TTorrentSourcePolicy>);
static_assert(std::is_standard_layout_v<TTorrentAddOptions>);
static_assert(std::is_trivially_copyable_v<TTorrentAddOptions>);
static_assert(std::is_standard_layout_v<TTorrentOptions>);
static_assert(std::is_trivially_copyable_v<TTorrentOptions>);
static_assert(sizeof(TTorrentSnapshot) == 3360U);
static_assert(alignof(TTorrentSnapshot) == 8U);
static_assert(sizeof(TTorrentTrackerSnapshot) == 1560U);
static_assert(alignof(TTorrentTrackerSnapshot) == 4U);
static_assert(sizeof(TTorrentTrackerHostSnapshot) == 324U);
static_assert(alignof(TTorrentTrackerHostSnapshot) == 1U);
static_assert(sizeof(TTorrentWebSeedSnapshot) == 1024U);
static_assert(alignof(TTorrentWebSeedSnapshot) == 1U);
static_assert(sizeof(TTorrentWebSeedActivitySnapshot) == 16U);
static_assert(alignof(TTorrentWebSeedActivitySnapshot) == 8U);
static_assert(sizeof(TTorrentPeerSourceSnapshot) == 36U);
static_assert(alignof(TTorrentPeerSourceSnapshot) == 4U);
static_assert(sizeof(TTorrentFileSnapshot) == 1064U);
static_assert(alignof(TTorrentFileSnapshot) == 8U);
static_assert(sizeof(TTorrentFilePriorityEntry) == 8U);
static_assert(alignof(TTorrentFilePriorityEntry) == 4U);
static_assert(sizeof(TTorrentRemovalResult) == 516U);
static_assert(alignof(TTorrentRemovalResult) == 4U);
static_assert(sizeof(TTorrentPieceMapSnapshot) == 16U);
static_assert(alignof(TTorrentPieceMapSnapshot) == 4U);
static_assert(sizeof(TTorrentFilePreview) == 616U);
static_assert(alignof(TTorrentFilePreview) == 8U);
static_assert(sizeof(TTorrentSessionSettings) == 72U);
static_assert(alignof(TTorrentSessionSettings) == 8U);
static_assert(sizeof(TTorrentNetworkStatus) == 664U);
static_assert(alignof(TTorrentNetworkStatus) == 8U);
static_assert(sizeof(TTorrentSourcePolicy) == 10U);
static_assert(alignof(TTorrentSourcePolicy) == 1U);
static_assert(sizeof(TTorrentAddOptions) == 6U);
static_assert(alignof(TTorrentAddOptions) == 1U);
static_assert(sizeof(TTorrentOptions) == 20U);
static_assert(alignof(TTorrentOptions) == 4U);

enum class FileSystemNodeKind : std::uint8_t {
    file,
    directory
};

enum class NetworkBindingKind : std::uint8_t {
    any,
    name,
    ipv4,
    ipv6
};

enum class FileReadFailure : std::uint8_t {
    unreadable,
    empty,
    too_large
};

enum class RemovalTombstoneState : std::uint8_t {
    resume_cleanup,
    awaiting_payload_delete
};

struct BridgeError {
    int32_t code;
    std::string message;
};

using BridgeResult = std::expected<void, BridgeError>;
using FileReadResult = std::expected<std::vector<char>, FileReadFailure>;
using ResumeRemoveResult = std::expected<bool, std::string>;
using ResumeSaveResult = std::expected<void, std::string>;
using ResumeIDListResult = std::expected<std::vector<std::string>, std::string>;
using TombstoneIDResult = std::expected<std::set<std::string>, std::string>;
using TorrentLoadResult = std::expected<lt::add_torrent_params, BridgeError>;

struct TombstoneCommitStatus {
    bool directory_synced = true;
};

struct TorrentIdentity;

struct PendingResumeCleanup {
    std::uint64_t after_generation = 0;
    std::vector<std::string> resume_ids;
};

struct PendingEncodedResumeWrite {
    lt::info_hash_t hashes;
    TorrentIdentity *identity = nullptr;
    std::uint64_t generation = 0;
    std::vector<char> encoded;
    std::vector<PendingResumeCleanup> cleanups;
};

struct ResumeSaveState {
    std::uint64_t next_generation = 1;
    std::uint64_t installed_generation = 0;
    std::uint64_t committed_generation = 0;
    std::optional<std::uint64_t> async_in_flight;
    bool save_again = false;
    lt::resume_data_flags_t save_again_flags = kRoutineResumeSaveFlags;
    std::optional<PendingEncodedResumeWrite> retry;
    std::vector<PendingResumeCleanup> pending_cleanups;
    std::vector<PendingResumeCleanup> cleanup_retry;
};

struct PendingResumeRequest {
    lt::torrent_handle handle;
    lt::resume_data_flags_t flags = kRoutineResumeSaveFlags;
};

struct TorrentIdentity {
    std::uint64_t generation = 0;
    std::string canonical_id;
    std::string comment;
    std::time_t creation_date = 0;
    ResumeSaveState resume_save;
    bool allows_non_https_trackers = false;
    bool allows_non_https_web_seeds = false;
    bool requires_https_trackers = false;
    bool requires_https_web_seeds = false;
    bool dht_enabled_by_user = false;
    bool dht_disabled_by_user = false;
    bool peer_exchange_enabled_by_user = false;
    bool peer_exchange_disabled_by_user = false;
    bool lsd_enabled_by_user = false;
    bool lsd_disabled_by_user = false;
    bool dht_locked_by_source = false;
    bool peer_exchange_locked_by_source = false;
    bool lsd_locked_by_source = false;
    bool allow_pre_metadata_dht = false;
    bool intended_default_dont_download = false;
    int32_t queue_priority = TTORRENT_QUEUE_PRIORITY_NORMAL;
    int32_t queue_rank = kUnsetQueueRank;
    std::vector<lt::announce_entry> source_trackers;
    std::vector<std::string> source_web_seeds;
    std::vector<lt::download_priority_t> intended_file_priorities;
    std::chrono::steady_clock::time_point metadata_validation_retry_after{};
};

struct ResumePolicySnapshot {
    bool has_identity = false;
    std::string canonical_id;
    bool allows_non_https_trackers = false;
    bool allows_non_https_web_seeds = false;
    bool requires_https_trackers = false;
    bool requires_https_web_seeds = false;
    bool dht_enabled_by_user = false;
    bool dht_disabled_by_user = false;
    bool peer_exchange_enabled_by_user = false;
    bool peer_exchange_disabled_by_user = false;
    bool lsd_enabled_by_user = false;
    bool lsd_disabled_by_user = false;
    bool dht_locked_by_source = false;
    bool peer_exchange_locked_by_source = false;
    bool lsd_locked_by_source = false;
    bool metadata_validation_pending = false;
    bool allow_pre_metadata_dht = false;
    bool intended_default_dont_download = false;
    bool app_disabled_dht = false;
    bool app_disabled_lsd = false;
    bool app_disabled_peer_exchange = false;
    int32_t queue_priority = TTORRENT_QUEUE_PRIORITY_NORMAL;
    int32_t queue_rank = kUnsetQueueRank;
    std::vector<lt::announce_entry> source_trackers;
    std::vector<std::string> source_web_seeds;
    std::vector<lt::download_priority_t> intended_file_priorities;
};

struct PendingResumeWrite {
    lt::add_torrent_params params;
    lt::torrent_handle handle;
    TorrentIdentity *identity = nullptr;
    ResumePolicySnapshot policy;
    std::uint64_t generation = 0;
    bool async = false;
    std::vector<PendingResumeCleanup> cleanups;
};

struct PendingResumeHandle {
    lt::torrent_handle handle;
    TorrentIdentity *identity = nullptr;
    ResumePolicySnapshot policy;
    std::vector<PendingResumeCleanup> cleanups;
};

struct RemovalTombstoneEntry {
    fs::path path;
    std::vector<std::string> ids;
    RemovalTombstoneState state = RemovalTombstoneState::resume_cleanup;
    bool delete_files = false;
    bool delete_partfile = false;
};

struct RemovalTombstonePayload {
    std::vector<std::string> ids;
    RemovalTombstoneState state = RemovalTombstoneState::resume_cleanup;
    bool delete_files = false;
    bool delete_partfile = false;
};

struct TrackerCacheEntry {
    std::uint64_t revision = 0;
    std::vector<TTorrentTrackerSnapshot> trackers;
};

struct WebSeedCacheEntry {
    std::uint64_t revision = 0;
    std::vector<TTorrentWebSeedSnapshot> web_seeds;
    TTorrentWebSeedActivitySnapshot activity{};
};

struct PeerSourceCacheEntry {
    std::uint64_t revision = 0;
    TTorrentPeerSourceSnapshot sources{};
};

struct FileCacheEntry {
    std::uint64_t revision = 0;
    std::vector<TTorrentFileSnapshot> files;
};

struct PieceMapCacheEntry {
    std::uint64_t revision = 0;
    TTorrentPieceMapSnapshot snapshot{};
    std::vector<std::uint8_t> pieces;
};

struct RemovalRequestEntry {
    std::uint64_t request_token = 0;
    lt::info_hash_t hashes;
    int32_t state = TTORRENT_REMOVAL_PENDING;
    std::array<char, 512> error{};
};

struct TorrentSourceCounts {
    int32_t tracker_count = 0;
    int32_t https_tracker_count = 0;
    int32_t web_seed_count = 0;
    int32_t https_web_seed_count = 0;
};

using TombstoneEntriesResult = std::expected<std::vector<RemovalTombstoneEntry>, std::string>;
using TombstoneCommitResult = std::expected<TombstoneCommitStatus, std::string>;
using TombstonePayloadResult = std::expected<RemovalTombstonePayload, std::string>;
using DirtyMask = std::uint32_t;

struct WakeCallbackInvocation {
    TTorrentWakeCallback callback = nullptr;
    void *context = nullptr;
};

[[nodiscard]] constexpr bool has_dirty_changes(DirtyMask changes) noexcept
{
    return changes != 0U;
}

struct ResumeDataReport {
    std::vector<PendingResumeWrite> writes;
    std::vector<std::string> errors;
};

struct ResumeHandleReport {
    std::vector<PendingResumeHandle> handles;
    std::vector<std::string> errors;
};

enum class TorrentIdentityState : std::uint8_t {
    current,
    stale,
    absent
};

void ignore_shutdown_failure() noexcept;

class UniqueFileDescriptor {
public:
    explicit UniqueFileDescriptor(int descriptor = -1) noexcept
        : descriptor_(descriptor)
    {
    }

    UniqueFileDescriptor(UniqueFileDescriptor const &) = delete;
    UniqueFileDescriptor &operator=(UniqueFileDescriptor const &) = delete;

    UniqueFileDescriptor(UniqueFileDescriptor &&other) noexcept
        : descriptor_(std::exchange(other.descriptor_, -1))
    {
    }

    UniqueFileDescriptor &operator=(UniqueFileDescriptor &&other) noexcept
    {
        if (this != &other) {
            reset();
            descriptor_ = std::exchange(other.descriptor_, -1);
        }
        return *this;
    }

    ~UniqueFileDescriptor()
    {
        reset();
    }

    [[nodiscard]] int get() const noexcept
    {
        return descriptor_;
    }

    [[nodiscard]] bool is_valid() const noexcept
    {
        return descriptor_ >= 0;
    }

    [[nodiscard]] std::error_code close() noexcept
    {
        if (!is_valid()) {
            return {};
        }

        int const descriptor = std::exchange(descriptor_, -1);
        if (::close(descriptor) == 0) {
            return {};
        }
        return {errno, std::generic_category()};
    }

private:
    void reset() noexcept
    {
        if (!is_valid()) {
            return;
        }

        int const descriptor = std::exchange(descriptor_, -1);
        (void)::close(descriptor);
    }

    int descriptor_;
};

struct DeferredSessionShutdown {
    UniqueFileDescriptor state_lock;
    lt::session_proxy proxy;
};

class DeferredSessionProxy {
public:
    DeferredSessionProxy() = default;
    DeferredSessionProxy(DeferredSessionProxy const &) = delete;
    DeferredSessionProxy &operator=(DeferredSessionProxy const &) = delete;
    DeferredSessionProxy(DeferredSessionProxy &&) = delete;
    DeferredSessionProxy &operator=(DeferredSessionProxy &&) = delete;

    ~DeferredSessionProxy()
    {
        if (!shutdown_) {
            return;
        }

        if (destroy_asynchronously_) {
            try {
                std::thread([shutdown = std::move(*shutdown_)]() mutable {}).detach();
            } catch (...) {
                ignore_shutdown_failure();
            }
        }
    }

    void capture(lt::session_proxy proxy, UniqueFileDescriptor state_lock)
    {
        shutdown_.emplace(DeferredSessionShutdown{
            .state_lock = std::move(state_lock),
            .proxy = std::move(proxy)
        });
    }

    void set_destroy_asynchronously(bool value) noexcept
    {
        destroy_asynchronously_ = value;
    }

private:
    std::optional<DeferredSessionShutdown> shutdown_;
    bool destroy_asynchronously_ = true;
};

struct ResumeTempFile {
    fs::path path;
    UniqueFileDescriptor descriptor;
};

using ResumeTempFileResult = std::expected<ResumeTempFile, std::string>;

struct UTF8Sequence {
    std::size_t length;
    bool valid;
};

std::string_view c_string_view(char const *value);

bool is_continuation_byte(unsigned char value) noexcept;

bool is_c_string_control_byte(unsigned char value) noexcept;

unsigned char byte_at(std::string_view source, std::size_t offset) noexcept;

UTF8Sequence utf8_sequence(std::string_view source, std::size_t offset) noexcept;

void copy_string_dynamic(std::span<char> destination, std::string_view source) noexcept;

template <std::size_t Extent>
void copy_string(std::span<char, Extent> destination, std::string_view source) noexcept
{
    static_assert(Extent != std::dynamic_extent);
    static_assert(Extent > 0);
    copy_string_dynamic(std::span<char>{destination.data(), destination.size()}, source);
}

template <typename Element>
std::span<Element> output_span_from_c_buffer(Element *destination, int32_t capacity) noexcept
{
    if (destination == nullptr || capacity <= 0) {
        return {};
    }

    // C ABI callers pass raw pointer + capacity pairs. Keep the trusted span
    // construction isolated here after validating the pointer and signed count.
    __unsafe_buffer_usage_begin
    auto output = std::span<Element>(destination, static_cast<std::size_t>(capacity));
    __unsafe_buffer_usage_end
    return output;
}

template <typename Element>
std::span<Element const> input_span_from_c_buffer(Element const *source, int32_t count) noexcept
{
    if (source == nullptr || count <= 0) {
        return {};
    }

    __unsafe_buffer_usage_begin
    auto input = std::span<Element const>(source, static_cast<std::size_t>(count));
    __unsafe_buffer_usage_end
    return input;
}

std::span<char> output_buffer(char *destination, int32_t capacity) noexcept;

void copy_error(std::span<char> destination, std::string_view message) noexcept;

BridgeResult bridge_error(int32_t code, std::string message);

std::uint8_t bridge_bool(bool value) noexcept;

bool bridge_bool(std::uint8_t value) noexcept;

int32_t bridge_torrent_state(lt::torrent_status::state_t state) noexcept;

void ignore_shutdown_failure() noexcept;

std::string system_error_message(std::string_view action, int error_number);

char hex_digit(unsigned char value) noexcept;

std::string hex_string(std::string_view bytes);

std::uint32_t random_u32() noexcept;

bool is_hex_character(char value) noexcept;

bool is_canonical_torrent_id(std::string_view id) noexcept;

bool is_prefixed_hex_id(std::string_view id, std::string_view prefix, std::size_t hex_length) noexcept;

bool is_resume_data_id(std::string_view id) noexcept;

std::string make_canonical_torrent_id();

std::string resume_temp_extension(std::uint32_t attempt);

void remove_file_quietly(fs::path const &path) noexcept;

ResumeTempFileResult open_resume_temp_file(fs::path const &final_path);

ResumeSaveResult write_all(int descriptor, std::span<char const> bytes);

ResumeSaveResult close_resume_temp_file(UniqueFileDescriptor &file);

ResumeSaveResult sync_file(int descriptor);

ResumeSaveResult sync_directory(fs::path const &directory);

ResumeSaveResult write_owner_only_file_checked(fs::path const &path, std::string_view bytes);

template <typename Operation>
int32_t run_bridge_operation(std::span<char> error_out, int32_t exception_code, Operation operation) noexcept
{
    copy_error(error_out, "");

    try {
        BridgeResult result = operation();
        if (result) {
            return 0;
        }

        copy_error(error_out, result.error().message);
        return result.error().code;
    } catch (std::exception const &exception) {
        copy_error(error_out, exception.what());
        return exception_code;
    } catch (...) {
        copy_error(error_out, "Unexpected libtorrent error.");
        return exception_code;
    }
}

void clear_count_outputs(std::uint64_t *revision_out, int32_t *required_count_out) noexcept;

std::string safe_c_string(char const *value);

std::string operation_label(lt::operation_t operation);

std::string alert_label(lt::alert const *alert);

std::string address_string(lt::address const &address);

std::string endpoint_string(lt::address const &address, int port);

std::vector<std::string> hash_keys(lt::info_hash_t const &hashes);

std::vector<std::string> hash_keys_with_requested(lt::info_hash_t const &hashes, std::string_view requested_id);

void append_unique(std::vector<std::string> &values, std::string value);

bool collections_overlap(std::vector<std::string> const &left, std::vector<std::string> const &right);

std::string removal_tombstone_suffix();

std::string make_removal_tombstone_filename();

fs::path removal_tombstone_path(fs::path const &resume_directory);

bool is_removal_tombstone_path(fs::path const &path);

std::optional<std::string> resume_id_from_resume_path(fs::path const &path);

ResumeIDListResult normalized_resume_ids(std::vector<std::string> const &ids);

TombstonePayloadResult tombstone_payload_from_bytes(std::vector<char> const &buffer);

std::string tombstone_read_error(FileReadFailure failure);

std::string tombstone_state_name(RemovalTombstoneState state);

std::string tombstone_payload(
    std::vector<std::string> const &ids,
    RemovalTombstoneState state,
    bool delete_files,
    bool delete_partfile
);

std::string joined_error_messages(std::vector<std::string> const &errors);

std::string primary_hash_key(lt::info_hash_t const &hashes);

bool resume_filename_matches_identity(std::string_view resume_id, lt::add_torrent_params const &params);

std::string torrent_alert_id(lt::torrent_alert const &alert);

std::string torrent_context(lt::torrent_alert const &alert);

ResumePolicySnapshot resume_policy_snapshot(
    TorrentIdentity const *identity,
    bool metadata_validation_pending,
    bool app_disabled_dht,
    bool app_disabled_lsd,
    bool app_disabled_peer_exchange
);

std::vector<char> encoded_resume_data(
    lt::add_torrent_params const &params,
    TorrentIdentity const *identity,
    bool metadata_validation_pending = false,
    bool app_disabled_dht = false,
    bool app_disabled_lsd = false
);

std::vector<char> encoded_resume_data(
    lt::add_torrent_params const &params,
    ResumePolicySnapshot const &policy
);

std::string canonical_id_from_resume_data(std::vector<char> const &buffer);

bool metadata_validation_pending_from_resume_data(std::vector<char> const &buffer);

bool allow_pre_metadata_dht_from_resume_data(std::vector<char> const &buffer);

void sanitize_magnet_endpoint_hints(lt::add_torrent_params &params);

void sanitize_resume_endpoint_hints(lt::add_torrent_params &params) noexcept;

bool allow_non_https_trackers_from_resume_data(std::vector<char> const &buffer);

bool allow_non_https_web_seeds_from_resume_data(std::vector<char> const &buffer);

bool require_https_trackers_from_resume_data(std::vector<char> const &buffer);

bool require_https_web_seeds_from_resume_data(std::vector<char> const &buffer);

bool enable_dht_from_resume_data(std::vector<char> const &buffer);

bool disable_dht_from_resume_data(std::vector<char> const &buffer);

bool app_disabled_dht_from_resume_data(std::vector<char> const &buffer);

bool enable_peer_exchange_from_resume_data(std::vector<char> const &buffer);

bool disable_peer_exchange_from_resume_data(std::vector<char> const &buffer);

bool enable_lsd_from_resume_data(std::vector<char> const &buffer);

bool disable_lsd_from_resume_data(std::vector<char> const &buffer);

bool app_disabled_lsd_from_resume_data(std::vector<char> const &buffer);

bool is_valid_queue_priority(int32_t value) noexcept;

bool is_valid_queue_rank(int32_t value) noexcept;

int32_t queue_priority_from_resume_data(std::vector<char> const &buffer);

int32_t queue_rank_from_resume_data(std::vector<char> const &buffer);

template <typename Hash>
void copy_hash_key(std::span<char> destination, std::string_view prefix, Hash const &hash) noexcept
{
    if (destination.empty()) {
        return;
    }

    std::size_t offset = 0;
    auto append = [&](char character) noexcept {
        if (offset + 1U < destination.size()) {
            *std::next(destination.begin(), static_cast<std::ptrdiff_t>(offset)) = character;
            ++offset;
        }
    };

    for (char const character : prefix) {
        append(character);
    }

    for (unsigned char const value : hash) {
        append(hex_digit(value >> 4U));
        append(hex_digit(value));
    }

    *std::next(destination.begin(), static_cast<std::ptrdiff_t>(offset)) = '\0';
}

void copy_primary_hash_key(std::span<char> destination, lt::info_hash_t const &hashes) noexcept;

TorrentIdentity *identity_from_client_data(lt::client_data_t const &userdata) noexcept;

TorrentIdentity *identity_from_handle(lt::torrent_handle const &handle) noexcept;

TorrentIdentity *identity_from_resume_alert(lt::save_resume_data_alert const &alert) noexcept;

std::string identity_snapshot_id(TorrentIdentity const *identity, lt::info_hash_t const &hashes);

bool hash_matches(lt::info_hash_t const &hashes, std::string_view id);

double download_progress(lt::torrent_status const &status);

TTorrentSnapshot snapshot_from_status(
    lt::torrent_status const &status,
    TorrentIdentity const *identity = nullptr
);

struct TrackerEndpointAggregate {
    int32_t relevant_count = 0;
    int32_t failed_count = 0;
    int32_t max_fail_count = 0;
    std::string first_failure_message;
};

bool tracker_info_failed(lt::announce_infohash const &info);

void merge_tracker_info(
    TTorrentTrackerSnapshot &snapshot,
    lt::announce_infohash const &info,
    std::string &message,
    TrackerEndpointAggregate &aggregate
);

TTorrentTrackerSnapshot tracker_snapshot_from_entry(lt::announce_entry const &entry, lt::info_hash_t const &hashes);

std::optional<std::string> normalized_tracker_host(std::string const &url);

TTorrentWebSeedSnapshot web_seed_snapshot(std::string const &url);

void append_web_seed_snapshots(
    std::vector<TTorrentWebSeedSnapshot> &snapshots,
    std::set<std::string> const &urls,
    std::size_t limit
);

TTorrentFileSnapshot file_snapshot_from_files(
    lt::filenames const &files,
    lt::file_index_t file,
    int32_t priority
);

bool is_web_seed_peer(lt::peer_info const &peer) noexcept;

TTorrentPeerSourceSnapshot peer_source_snapshot(std::vector<lt::peer_info> const &peers) noexcept;

lt::settings_pack make_settings();

lt::session_params make_session_params(bool enable_peer_exchange_plugin);

void prepare_add_params(
    lt::add_torrent_params &params,
    std::string_view save_path,
    bool starts_paused,
    bool enable_peer_exchange
);

bool is_https_url(std::string_view url) noexcept;

TorrentSourceCounts torrent_source_counts(lt::add_torrent_params const &params);

BridgeResult validate_torrent_sources(lt::add_torrent_params const &params);

bool filter_non_https_sources(
    lt::add_torrent_params &params,
    bool require_https_trackers = true,
    bool require_https_web_seeds = true
);

void remember_source_policy_sources(TorrentIdentity &identity, lt::add_torrent_params const &params);

void restore_source_policy_sources(lt::add_torrent_params &params, TorrentIdentity const *identity);

void restore_source_policy_sources(lt::add_torrent_params &params, ResumePolicySnapshot const &policy);

[[nodiscard]] bool should_strip_resume_peer_cache(
    lt::add_torrent_params const &params,
    TorrentIdentity const *identity,
    bool app_disabled_dht
) noexcept;

[[nodiscard]] bool should_strip_resume_peer_cache(
    lt::add_torrent_params const &params,
    ResumePolicySnapshot const &policy
) noexcept;

void strip_resume_peer_cache(lt::add_torrent_params &params) noexcept;

BridgeResult validate_save_path(std::string_view save_path);

std::string trimmed(std::string_view value);

bool contains_invalid_interface_character(std::string_view value);

bool is_ipv4_address(std::string const &value);

bool is_ipv6_address(std::string const &value);

struct TTorrentClient;

struct NetworkBinding {
    NetworkBindingKind kind = NetworkBindingKind::any;
    std::string value;
};

NetworkBinding network_binding(std::string_view network_interface);

std::string listen_interfaces(int32_t incoming_port, std::string_view network_interface, bool network_blocked);

std::string outgoing_interfaces(std::string_view network_interface, bool network_blocked);

int encryption_policy(int32_t value);

bool is_valid_encryption_policy(int32_t value) noexcept;

FileReadResult read_file(fs::path const &path, std::uintmax_t max_size);

UniqueFileDescriptor open_directory_no_follow(fs::path const &path, std::string_view description);

void restrict_permissions(fs::path const &path, FileSystemNodeKind kind);

void restrict_permissions(int descriptor, std::string_view description, FileSystemNodeKind kind);

UniqueFileDescriptor acquire_state_directory_lock(int state_directory_descriptor);

TorrentLoadResult load_torrent_data(std::span<char const> torrent_data);

BridgeResult validate_torrent_info(lt::torrent_info const &info);

BridgeResult validate_torrent_info(
    lt::torrent_info const &info,
    std::map<lt::file_index_t, std::string> const &renamed_files
);

BridgeResult validate_torrent_info(lt::add_torrent_params const &params);

void copy_torrent_preview(lt::add_torrent_params const &params, TTorrentFilePreview *preview) noexcept;

void copy_torrent_preview_files(
    lt::add_torrent_params const &params,
    std::span<TTorrentFileSnapshot> output
);

bool is_valid_file_priority(int32_t priority) noexcept;

lt::download_priority_t file_priority_from_bridge(int32_t priority) noexcept;

BridgeResult apply_file_priorities(
    lt::add_torrent_params &params,
    std::optional<std::span<TTorrentFilePriorityEntry const>> file_priorities
);


struct TTorrentClient {
    explicit TTorrentClient(std::string_view state_path, bool enable_peer_exchange_plugin = true);

    ~TTorrentClient() noexcept;

    TTorrentClient(TTorrentClient const &) = delete;
    TTorrentClient &operator=(TTorrentClient const &) = delete;
    TTorrentClient(TTorrentClient &&) = delete;
    TTorrentClient &operator=(TTorrentClient &&) = delete;

    void set_session_shutdown_asynchronous(bool value) noexcept;

    std::mutex lock;
    fs::path state_directory;
    fs::path resume_directory;
    UniqueFileDescriptor state_lock;
    mutable std::mutex resume_io_lock;
    std::mutex resume_capture_lock;
    std::uint64_t next_identity_generation = 1;
    std::vector<std::unique_ptr<TorrentIdentity>> torrent_identities;
    std::vector<std::unique_ptr<TorrentIdentity>> retired_torrent_identities;
    std::unordered_map<std::string, TorrentIdentity *> active_identity_by_id;
    std::unordered_map<std::string, TorrentIdentity *> removing_identity_by_id;
    std::unordered_map<std::string, lt::torrent_handle> handle_by_id;
    std::set<TorrentIdentity *> dht_disabled_by_app;
    std::set<TorrentIdentity *> peer_exchange_disabled_by_app;
    std::set<TorrentIdentity const *> metadata_validation_pending;
    std::set<TorrentIdentity *> lsd_disabled_by_app;
    std::unordered_map<std::string, std::vector<std::string>> awaiting_delete_resume_ids_by_id;
    std::unordered_map<std::string, std::vector<std::string>> pending_resume_cleanup_ids_by_id;
    std::unordered_map<std::string, std::vector<std::string>> terminal_delete_cleanup_ids_by_id;
    std::unordered_map<std::string, std::vector<std::string>> pending_tombstone_clear_ids_by_id;
    std::set<TorrentIdentity *> unidentified_removing_identities;
    bool persistence_faulted = false;
    std::string persistence_fault_message;
    DeferredSessionProxy deferred_session_shutdown;
    lt::session session;
    std::jthread alert_thread;
    std::vector<TTorrentSnapshot> snapshot_cache;
    std::unordered_map<std::string, std::size_t> snapshot_indices;
    std::uint64_t snapshot_revision = 0;
    std::unordered_map<std::string, std::vector<std::string>> tracker_host_cache;
    std::uint64_t tracker_host_revision = 0;
    std::unordered_map<std::string, TrackerCacheEntry> tracker_cache;
    std::uint64_t tracker_revision = 0;
    std::unordered_map<std::string, WebSeedCacheEntry> web_seed_cache;
    std::uint64_t web_seed_revision = 0;
    std::unordered_map<std::string, PeerSourceCacheEntry> peer_source_cache;
    std::uint64_t peer_source_revision = 0;
    std::unordered_map<std::string, FileCacheEntry> file_cache;
    std::uint64_t file_revision = 0;
    std::unordered_map<std::string, PieceMapCacheEntry> piece_map_cache;
    std::uint64_t piece_map_revision = 0;
    std::uint64_t next_removal_request_token = 1;
    std::optional<RemovalRequestEntry> removal_request;
    std::uint64_t requested_network_revision = 0;
    std::uint64_t submitted_network_revision = 0;
    bool requested_network_blocked = true;
    bool dht_node_enabled = true;
    bool dht_enabled_by_default = true;
    bool lsd_service_enabled = false;
    bool lsd_enabled_by_default = true;
    bool peer_exchange_plugin_enabled = true;
    bool peer_exchange_enabled_by_default = true;
    bool require_https_trackers = false;
    bool require_https_web_seeds = false;
    bool has_listener = false;
    int32_t listen_port = 0;
    std::string listen_endpoint;
    std::string last_network_error;
    std::vector<std::string> pending_alert_errors;
    std::uint64_t publication_epoch = 0;
    DirtyMask pending_changes = 0;
    bool wake_pending = false;
    TTorrentWakeCallback wake_callback = nullptr;
    void *wake_callback_context = nullptr;
    int32_t wake_callbacks_in_flight = 0;
    std::condition_variable wake_callback_quiesced;

    void start_alert_worker();

    void stop_alert_worker() noexcept;

    void alert_loop(std::stop_token const &stop_token);

    void set_wake_callback(TTorrentWakeCallback callback, void *context);

    void clear_wake_callback() noexcept;

    [[nodiscard]] std::uint64_t take_changes(DirtyMask *changes_out) noexcept;

    [[nodiscard]] WakeCallbackInvocation publish_changes_locked(DirtyMask changes) noexcept;

    void complete_wake_callback() noexcept;

    void invoke_wake_callback(WakeCallbackInvocation wake) noexcept;

    [[nodiscard]] bool canonical_id_in_collection_locked(
        std::vector<std::unique_ptr<TorrentIdentity>> const &identities,
        std::string_view canonical_id
    ) const;

    [[nodiscard]] bool canonical_id_in_use_locked(std::string_view canonical_id) const;

    [[nodiscard]] std::string make_unique_canonical_torrent_id_locked() const;

    TorrentIdentity *make_identity(std::string canonical_id = {});

    TorrentIdentity *attach_identity(lt::add_torrent_params &params, std::string canonical_id = {});

    std::uint64_t allocate_resume_generation_locked(TorrentIdentity *identity);

    std::uint64_t allocate_resume_generation(TorrentIdentity *identity);

    std::optional<std::uint64_t> begin_async_resume_save(TorrentIdentity *identity, lt::resume_data_flags_t flags);

    void cancel_async_resume_save(TorrentIdentity *identity, std::uint64_t generation);

    std::optional<std::uint64_t> async_resume_generation(TorrentIdentity *identity);

    std::optional<lt::resume_data_flags_t> complete_async_resume_save(TorrentIdentity *identity,
                                                                      std::uint64_t generation);

    void queue_alert_error_threadsafe(std::string message);

    [[nodiscard]] bool resume_write_is_installable_locked(PendingEncodedResumeWrite const &write) const;

    std::vector<PendingEncodedResumeWrite> claim_resume_retries();

    std::vector<std::string> retry_resume_cleanups(bool reports_errors);

    void discard_pending_resume_saves_locked(TorrentIdentity *identity) noexcept;

    void discard_unpublished_identity(TorrentIdentity *identity) noexcept;

    void append_cleanup_ids_locked(std::vector<PendingResumeCleanup> &destination, PendingResumeCleanup cleanup);

    void remember_pending_cleanups_locked(TorrentIdentity *identity, std::vector<PendingResumeCleanup> cleanups);

    void remember_pending_cleanups(TorrentIdentity *identity, std::vector<PendingResumeCleanup> cleanups);

    std::vector<PendingResumeCleanup>
    cleanups_for_write(TorrentIdentity *identity, std::uint64_t generation,
                       std::vector<PendingResumeCleanup> const &explicit_cleanups = {});

    void remove_cleanup_ids_locked(std::vector<PendingResumeCleanup> &target,
                                   std::vector<PendingResumeCleanup> const &completed);

    void mark_resume_cleanups_completed_locked(TorrentIdentity *identity,
                                               std::vector<PendingResumeCleanup> const &cleanups);

    void remember_resume_cleanup_failure_locked(TorrentIdentity *identity, std::vector<PendingResumeCleanup> cleanups);

    std::vector<std::string> removal_ids_for_identity(lt::info_hash_t const &hashes, std::string_view requested_id,
                                                      TorrentIdentity *identity);

    bool delete_pending_for_hashes(lt::info_hash_t const &hashes);

    void remember_pending_delete(lt::info_hash_t const &hashes, std::vector<std::string> const &resume_ids);

    void remember_pending_resume_cleanup_locked(std::vector<std::string> const &ids);

    void remember_pending_resume_cleanup(std::vector<std::string> const &ids);

    void forget_pending_resume_cleanup_locked(std::vector<std::string> const &ids);

    std::vector<std::vector<std::string>> pending_resume_cleanup_id_groups();

    ResumeSaveResult complete_pending_resume_cleanup(std::vector<std::string> const &resume_ids);

    std::vector<std::string> retry_pending_resume_cleanups(bool reports_errors);

    void remember_pending_tombstone_clear_locked(std::vector<std::string> const &ids);

    void forget_pending_tombstone_clear_locked(std::vector<std::string> const &ids);

    std::vector<std::vector<std::string>> pending_tombstone_clear_id_groups();

    std::vector<std::string> retry_pending_tombstone_clears(bool reports_errors);

    std::vector<std::string> promote_pending_delete_to_terminal_cleanup(lt::info_hash_t const &hashes);

    std::vector<std::vector<std::string>> terminal_delete_cleanup_id_groups();

    void forget_pending_delete_resume_ids(std::vector<std::string> const &resume_ids);

    ResumeSaveResult complete_pending_delete_cleanup(std::vector<std::string> const &resume_ids);

    [[nodiscard]] DirtyMask complete_pending_delete(lt::info_hash_t const &hashes, std::string const &failure_message);

    std::vector<std::string> retry_pending_delete_cleanups(bool reports_errors);

    bool remove_resume_file_locked(fs::path const &path);

    ResumeRemoveResult remove_resume_file_checked_locked(fs::path const &path);

    void sync_resume_directory_quietly();

    ResumeRemoveResult remove_resume_temp_files_for_id_checked_locked(std::string const &id);

    ResumeRemoveResult remove_resume_files_for_id_checked_locked(std::string const &id);

    TombstoneEntriesResult removal_tombstone_entries_locked();

    TombstoneIDResult removal_tombstone_ids_locked();

    ResumeIDListResult tombstone_ids_overlapping_locked(std::vector<std::string> const &ids);

    TombstoneCommitResult persist_removal_tombstones_locked(std::vector<std::string> const &ids,
                                                            RemovalTombstoneState state, bool delete_files,
                                                            bool delete_partfile);

    ResumeSaveResult clear_removal_tombstones_locked(std::vector<std::string> const &ids);

    ResumeSaveResult complete_pending_removals();

    void remove_orphan_resume_temp_files();

    void load_resume_data();

    [[nodiscard]] DirtyMask rebuild_snapshot_cache();

    [[nodiscard]] DirtyMask mark_snapshot_cache_changed() noexcept;

    void request_snapshot_update();

    void request_snapshot_update_locked();

    [[nodiscard]] DirtyMask cache_snapshot(lt::torrent_status const &status);

    [[nodiscard]] DirtyMask cache_snapshot(lt::torrent_handle const &handle);

    [[nodiscard]] DirtyMask cache_resume_metadata(
        TorrentIdentity *identity,
        lt::add_torrent_params const &params
    );

    std::vector<lt::torrent_handle> apply_queue_priority_order_locked();

    [[nodiscard]] DirtyMask update_snapshot_cache(std::vector<lt::torrent_status> const &statuses);

    [[nodiscard]] DirtyMask remove_snapshot(std::string_view id);

    [[nodiscard]] DirtyMask mark_tracker_host_cache_changed() noexcept;

    [[nodiscard]] DirtyMask cache_tracker_hosts(std::string const &id, std::vector<lt::announce_entry> const &trackers);

    [[nodiscard]] DirtyMask cache_tracker_hosts(lt::torrent_handle const &handle, std::string const &id);

    [[nodiscard]] DirtyMask remove_tracker_hosts(std::string_view id);

    [[nodiscard]] DirtyMask mark_tracker_cache_changed() noexcept;

    [[nodiscard]] DirtyMask remove_trackers(std::string_view id);

    [[nodiscard]] DirtyMask mark_web_seed_cache_changed() noexcept;

    [[nodiscard]] DirtyMask remove_web_seeds(std::string_view id);

    void remove_peer_sources(std::string_view id);

    [[nodiscard]] DirtyMask mark_file_cache_changed() noexcept;

    [[nodiscard]] DirtyMask remove_files(std::string_view id);

    [[nodiscard]] DirtyMask mark_piece_map_cache_changed() noexcept;

    [[nodiscard]] DirtyMask remove_piece_map(std::string_view id);

    [[nodiscard]] DirtyMask invalidate_detail_caches_locked();

    [[nodiscard]] DirtyMask cache_trackers(lt::torrent_handle const &handle, std::vector<lt::announce_entry> const &trackers);

    std::optional<std::string> cache_id_for_handle(lt::torrent_handle const &handle);

    [[nodiscard]] BridgeResult cache_web_seeds(lt::torrent_handle const &handle, DirtyMask &changes);

    [[nodiscard]] DirtyMask cache_web_seeds(
        std::string_view id,
        std::set<std::string> const &url_seeds
    );

    [[nodiscard]] BridgeResult cache_file_metadata(lt::torrent_handle const &handle, DirtyMask &changes);

    [[nodiscard]] DirtyMask cache_file_progress(lt::torrent_handle const &handle, lt::aux::vector<std::int64_t, lt::file_index_t> const &progress);

    [[nodiscard]] DirtyMask cache_piece_map(lt::torrent_status const &status);

    [[nodiscard]] DirtyMask cache_web_seed_activity(lt::torrent_handle const &handle, std::vector<lt::peer_info> const &peers);

    void cache_peer_sources(lt::torrent_handle const &handle, std::vector<lt::peer_info> const &peers);

    [[nodiscard]] BridgeResult request_sources(std::string const &id, DirtyMask &changes);

    [[nodiscard]] DirtyMask remove_torrent_with_invalid_metadata(lt::torrent_handle const &handle, std::string const &reason);

    [[nodiscard]] DirtyMask apply_https_source_policy_locked();

    [[nodiscard]] DirtyMask enforce_https_source_policy(lt::torrent_handle const &handle, TorrentIdentity *identity);

    [[nodiscard]] DirtyMask restore_metadata_source_policy(lt::torrent_handle const &handle, TorrentIdentity const *identity);

    [[nodiscard]] DirtyMask clear_peer_cache_if_restricted(
        lt::torrent_handle handle,
        TorrentIdentity *identity
    );

    [[nodiscard]] bool requires_https_trackers(TorrentIdentity const *identity) const noexcept;

    [[nodiscard]] bool requires_https_web_seeds(TorrentIdentity const *identity) const noexcept;

    [[nodiscard]] TTorrentSourcePolicy source_policy(lt::torrent_handle const &handle, TorrentIdentity const *identity) const;

    [[nodiscard]] DirtyMask set_source_policy(lt::torrent_handle const &handle, TorrentIdentity *identity, TTorrentSourcePolicy const &policy);

    static bool conflict_participant_is_preferred(TorrentIdentity const *candidate, TorrentIdentity const *other) noexcept;

    [[nodiscard]] DirtyMask resolve_torrent_conflict(
        lt::torrent_conflict_alert const &conflict,
        std::vector<PendingResumeHandle> &forced_resume_handles
    );

    [[nodiscard]] BridgeResult validate_or_remove_loaded_metadata(lt::torrent_handle const &handle, DirtyMask &changes);

    void validate_pending_metadata(DirtyMask &changes);

    [[nodiscard]] BridgeResult request_files(std::string const &id, DirtyMask &changes);

    [[nodiscard]] BridgeResult request_piece_map(std::string const &id, DirtyMask &changes);

    int32_t copy_trackers(
        std::string const &id,
        std::span<TTorrentTrackerSnapshot> output,
        std::uint64_t *revision_out,
        int32_t *required_count_out
    );

    int32_t copy_web_seeds(
        std::string const &id,
        std::span<TTorrentWebSeedSnapshot> output,
        std::uint64_t *revision_out,
        int32_t *required_count_out
    );

    bool copy_web_seed_activity(
        std::string const &id,
        TTorrentWebSeedActivitySnapshot *activity_out,
        std::uint64_t *revision_out
    );

    bool copy_peer_sources(
        std::string const &id,
        TTorrentPeerSourceSnapshot *sources_out,
        std::uint64_t *revision_out
    );

    int32_t copy_files(
        std::string const &id,
        std::span<TTorrentFileSnapshot> output,
        std::uint64_t *revision_out,
        int32_t *required_count_out
    );

    int32_t copy_piece_map(
        std::string const &id,
        TTorrentPieceMapSnapshot *snapshot,
        std::span<std::uint8_t> output,
        std::uint64_t *revision_out,
        int32_t *required_count_out
    );

    [[nodiscard]] DirtyMask remove_snapshot(lt::info_hash_t const &hashes, std::string_view requested_id);

    int32_t copy_snapshots(std::span<TTorrentSnapshot> output, std::uint64_t *revision_out, int32_t *required_count_out);

    int32_t copy_tracker_hosts(
        std::span<TTorrentTrackerHostSnapshot> output,
        std::uint64_t *revision_out,
        int32_t *required_count_out
    );

    [[nodiscard]] DirtyMask queue_alert_error(std::string message);

    [[nodiscard]] DirtyMask record_listen_failed(lt::listen_failed_alert const &alert);

    [[nodiscard]] DirtyMask record_listen_succeeded(lt::listen_succeeded_alert const &alert);

    [[nodiscard]] DirtyMask record_network_requested(bool blocked);

    [[nodiscard]] DirtyMask record_network_blocked();

    [[nodiscard]] TTorrentNetworkStatus network_status() const;

    bool take_alert_error(std::span<char> output);

    [[nodiscard]] BridgeResult ensure_persistence_available(int32_t code) const;

    [[nodiscard]] BridgeResult ensure_persistence_available_locked(int32_t code) const;

    [[nodiscard]] bool persistence_is_faulted() const;

    [[nodiscard]] bool persistence_is_faulted_locked() const noexcept;

    [[nodiscard]] BridgeResult fault_persistence_locked(int32_t code, std::string message);

    void pause_session_for_persistence_fault();

    [[nodiscard]] BridgeResult fault_persistence(int32_t code, std::string message);

    [[nodiscard]] BridgeResult fault_persistence_and_pause_locked(int32_t code, std::string message);

    [[nodiscard]] BridgeResult cancel_tombstoned_operation_or_fault(
        std::vector<std::string> const &ids,
        int32_t code,
        std::string operation_error
    );

    bool identity_is_referenced_locked(TorrentIdentity const *identity) const;

    void retire_identity_if_unreferenced_locked(TorrentIdentity *identity);

    TorrentIdentityState reconcile_identity_for_hashes_locked(std::vector<std::string> const &ids, TorrentIdentity *identity);

    TorrentIdentityState identity_state_for_status(std::vector<std::string> const &ids, TorrentIdentity *identity);

    bool reconcile_current_for_write_locked(lt::info_hash_t const &hashes, TorrentIdentity *identity);

    void mark_active(lt::torrent_handle const &handle, TorrentIdentity *identity);

    void mark_active(lt::info_hash_t const &hashes, lt::torrent_handle const &handle, TorrentIdentity *identity);

    void remember_canonical_handle(lt::torrent_handle const &handle, TorrentIdentity *identity);

    void mark_unidentified_remove_requested(TorrentIdentity *identity);

    [[nodiscard]] bool rollback_added_torrent_without_hashes(
        lt::torrent_handle const &handle,
        TorrentIdentity *identity,
        DirtyMask &changes
    );

    [[nodiscard]] bool rollback_added_torrent(
        lt::torrent_handle const &handle,
        lt::info_hash_t const &hashes,
        TorrentIdentity *identity,
        std::vector<std::string> const &resume_ids,
        bool publish_tombstone,
        DirtyMask &changes
    );

    void mark_remove_requested(lt::info_hash_t const &hashes, std::string_view requested_id, TorrentIdentity *identity);

    void forget_removed_identity_aliases(lt::info_hash_t const &hashes, TorrentIdentity *identity);

    bool accepts_removed_alert(lt::info_hash_t const &hashes, TorrentIdentity *identity);

    void finalize_removed(lt::info_hash_t const &hashes, TorrentIdentity *identity);

    std::uint64_t begin_delete_request(lt::info_hash_t const &hashes);

    void abandon_removal_request(std::uint64_t request_token) noexcept;

    void complete_delete_request(
        lt::info_hash_t const &hashes,
        int32_t terminal_state,
        std::string_view error = {}
    ) noexcept;

    [[nodiscard]] DirtyMask fail_dropped_delete_request(lt::alerts_dropped_alert const &alert);

    [[nodiscard]] BridgeResult take_removal_result(
        std::uint64_t request_token,
        TTorrentRemovalResult *result
    );

    bool resume_write_is_current(lt::info_hash_t const &hashes, TorrentIdentity *identity);

    ResumePolicySnapshot resume_policy_snapshot_locked(TorrentIdentity *identity) const;

    ResumeSaveResult remember_resume_write_failure_locked(PendingEncodedResumeWrite write, std::string message);

    void mark_resume_write_installed_locked(PendingEncodedResumeWrite const &write);

    void mark_resume_write_committed_locked(PendingEncodedResumeWrite const &write);

    [[nodiscard]] bool resume_cleanups_are_eligible_locked(PendingEncodedResumeWrite const &write) const;

    ResumeSaveResult perform_resume_cleanups_locked(std::vector<PendingResumeCleanup> const &cleanups);

    ResumeSaveResult complete_resume_cleanups_locked(PendingEncodedResumeWrite const &write);

    ResumeSaveResult commit_encoded_resume_data_checked(PendingEncodedResumeWrite write);

    ResumeSaveResult write_resume_data_checked(lt::add_torrent_params const &params, TorrentIdentity *identity,
                                               ResumePolicySnapshot const &policy,
                                               std::uint64_t generation, std::vector<PendingResumeCleanup> cleanups);

    ResumeSaveResult write_resume_data(PendingResumeWrite const &write);

    ResumeSaveResult save_added_torrent_resume_data(lt::add_torrent_params params, lt::info_hash_t const &hashes,
                                                    TorrentIdentity *identity);

    ResumeSaveResult remove_obsolete_tombstoned_resume_data_for_readd(std::vector<std::string> const &resume_ids);

    std::vector<std::string> retry_terminal_cleanups(bool reports_errors);

    std::vector<std::string> retry_resume_writes(bool reports_errors);

    void request_save(lt::torrent_handle const &handle,
                      lt::resume_data_flags_t flags = kRoutineResumeSaveFlags);

    std::vector<lt::torrent_handle> collect_torrent_handles();

    void request_periodic_resume_saves();

    std::vector<PendingResumeHandle> collect_resume_handles();

    ResumeHandleReport collect_resume_handles_report();

    std::vector<PendingResumeWrite> collect_resume_data(
        std::span<PendingResumeHandle const> handles,
        lt::resume_data_flags_t flags
    );

    ResumeDataReport collect_resume_data_report(
        std::span<PendingResumeHandle const> handles,
        lt::resume_data_flags_t flags
    );

    void save_all();

    BridgeResult save_all_checked();

    std::optional<PendingResumeRequest> release_async_resume_state_for_alert(lt::alert const *alert);

    void enqueue_repeat_resume_save(
        std::vector<PendingResumeRequest> &repeat_resume_requests,
        PendingResumeRequest const &request
    );

    void complete_async_resume_write(
        PendingResumeWrite const &write,
        std::vector<PendingResumeRequest> &repeat_resume_requests
    );

    void pump_alerts();

    std::optional<lt::torrent_handle> find(std::string const &id);

    ResumeSaveResult remove_resume_files_for_ids_checked(std::vector<std::string> const &ids);

    BridgeResult persist_removal_tombstones(std::vector<std::string> const &ids,
                                            RemovalTombstoneState state = RemovalTombstoneState::resume_cleanup,
                                            bool delete_files = false, bool delete_partfile = false);

    ResumeIDListResult tombstone_ids_overlapping(std::vector<std::string> const &ids);

    ResumeSaveResult clear_removal_tombstones(std::vector<std::string> const &ids);
};

[[nodiscard]] DirtyMask block_network_locked(TTorrentClient &client);

struct LockedChangePublisher {
    TTorrentClient &client;
    WakeCallbackInvocation &wake;
    DirtyMask changes = 0;

    LockedChangePublisher(TTorrentClient &client, WakeCallbackInvocation &wake) noexcept
        : client(client),
          wake(wake)
    {
    }

    LockedChangePublisher(LockedChangePublisher const &) = delete;
    LockedChangePublisher &operator=(LockedChangePublisher const &) = delete;
    LockedChangePublisher(LockedChangePublisher &&) = delete;
    LockedChangePublisher &operator=(LockedChangePublisher &&) = delete;

    ~LockedChangePublisher() noexcept
    {
        wake = client.publish_changes_locked(changes);
    }

    void add(DirtyMask next_changes) noexcept
    {
        changes |= next_changes;
    }
};

#endif
