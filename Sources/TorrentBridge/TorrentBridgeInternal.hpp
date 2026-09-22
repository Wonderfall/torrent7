#ifndef TORRENT_BRIDGE_INTERNAL_HPP
#define TORRENT_BRIDGE_INTERNAL_HPP

#define TORRENT_BRIDGE_IMPLEMENTATION
#include "TorrentBridge.h"

#undef TORRENT_BRIDGE_IMPLEMENTATION

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/aux_/path.hpp>
#include <libtorrent/aux_/dht_message_parser.hpp>
#include <libtorrent/aux_/payload_file_provider.hpp>
#include <libtorrent/aux_/peer_message_parser.hpp>
#include <libtorrent/aux_/preparsed_metainfo.hpp>
#include <libtorrent/aux_/swarm_metadata_parser.hpp>
#include <libtorrent/aux_/tracker_response_parser.hpp>
#include <libtorrent/aux_/tracker_manager.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/client_data.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/hasher.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_handle.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <arpa/inet.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <bit>
#include <cerrno>
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
#include <stop_token>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>
#include <fcntl.h>
#include <cstdlib>
#include <ptrauth.h>
#include <sys/cdefs.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define TORRENT_BRIDGE_GUARDED_BY(mutex) __attribute__((guarded_by(mutex)))
#define TORRENT_BRIDGE_REQUIRES(...) __attribute__((requires_capability(__VA_ARGS__)))
#define TORRENT_BRIDGE_REQUIRES_NOT(mutex) __attribute__((requires_capability(!(mutex))))
#define TORRENT_BRIDGE_ACQUIRED_AFTER(...) __attribute__((acquired_after(__VA_ARGS__)))
#define TORRENT_BRIDGE_SCOPED_CAPABILITY __attribute__((scoped_lockable))
#define TORRENT_BRIDGE_ACQUIRE(...) __attribute__((acquire_capability(__VA_ARGS__)))
#define TORRENT_BRIDGE_RELEASE(...) __attribute__((release_capability(__VA_ARGS__)))
#define TORRENT_BRIDGE_NO_THREAD_SAFETY_ANALYSIS __attribute__((no_thread_safety_analysis))

namespace torrent_bridge::internal {

namespace fs = std::filesystem;
namespace lt = libtorrent;

// std::mutex is already a Clang capability in libc++, but it does not provide
// the unary operator required to spell negative capability contracts.
class AnalyzedMutex final : public std::mutex {
public:
    [[nodiscard]] AnalyzedMutex const &operator!() const noexcept { return *this; }
};

// libc++ annotates mutex, lock_guard, and the single-mutex scoped_lock, but not
// unique_lock. This adapter preserves unique_lock's condition-variable API
// while making its ownership visible to Clang's thread-safety analysis.
class TORRENT_BRIDGE_SCOPED_CAPABILITY AnalyzedUniqueLock {
public:
    explicit AnalyzedUniqueLock(std::mutex &mutex) TORRENT_BRIDGE_ACQUIRE(mutex)
        : lock_(mutex)
    {
    }

    ~AnalyzedUniqueLock() TORRENT_BRIDGE_RELEASE() = default;

    AnalyzedUniqueLock(AnalyzedUniqueLock const &) = delete;
    AnalyzedUniqueLock &operator=(AnalyzedUniqueLock const &) = delete;
    AnalyzedUniqueLock(AnalyzedUniqueLock &&) = delete;
    AnalyzedUniqueLock &operator=(AnalyzedUniqueLock &&) = delete;

    [[nodiscard]] std::unique_lock<std::mutex> &native() noexcept { return lock_; }

private:
    std::unique_lock<std::mutex> lock_;
};

constexpr std::string_view kResumeExtension = ".fastresume";
constexpr std::string_view kTempExtension = ".tmp";
constexpr std::string_view kRemovalTombstoneExtension = ".remove";
constexpr std::string_view kRemovalTombstonePrefix = "removal-";
constexpr std::string_view kCanonicalIDResumeKey = "torrent-app-id";
// Exact, already validated info-dictionary bytes are persisted as an opaque
// string. They must return through the Swift InfoCore parser on restore rather
// than becoming libtorrent's conventional nested `info` dictionary.
constexpr std::string_view kPreparsedInfoResumeKey = "torrent-app-preparsed-info";
constexpr std::string_view kStorageClaimIDResumeKey = "torrent-app-storage-claim-id";
constexpr std::string_view kStorageClaimGenerationResumeKey = "torrent-app-storage-claim-generation";
constexpr std::string_view kStorageManifestDigestResumeKey = "torrent-app-storage-manifest-digest";
constexpr std::string_view kMetadataValidationPendingResumeKey = "torrent-app-metadata-validation-pending";
constexpr std::string_view kStagedMetadataResumeKey = "torrent-app-staged-metadata";
constexpr std::string_view kAllowPreMetadataDHTResumeKey = "torrent-app-allow-pre-metadata-dht";
constexpr std::string_view kHTTPSTrackerPolicyResumeKey = "torrent-app-https-tracker-policy";
constexpr std::string_view kHTTPSWebSeedPolicyResumeKey = "torrent-app-https-web-seed-policy";
// Retired encodings are rejected rather than silently changing security policy.
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
// Keep the BitTorrent peer ID coarse and stable across the 2.1.x series, just
// like the HTTP user agent and extension handshake identity above.
constexpr std::string_view kCoarsePeerFingerprint = "-LT2100-";

enum class HTTPSPolicy : std::uint8_t {
    inherit = TTORRENT_HTTPS_POLICY_INHERIT,
    original = TTORRENT_HTTPS_POLICY_ORIGINAL,
    prefer = TTORRENT_HTTPS_POLICY_PREFER,
    require = TTORRENT_HTTPS_POLICY_REQUIRE,
};

enum class DHTDiscoveryPolicy : std::uint8_t {
    alongside_trackers = TTORRENT_DHT_DISCOVERY_ALONGSIDE_TRACKERS,
    after_all_trackers_fail = TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL,
};

constexpr bool is_valid_dht_discovery_policy(std::uint8_t const value) noexcept
{
    return value == TTORRENT_DHT_DISCOVERY_ALONGSIDE_TRACKERS
        || value == TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL;
}

struct HTTPSSourcePolicy {
    HTTPSPolicy trackers;
    HTTPSPolicy web_seeds;
};

enum class HTTPSSourcePolicyScope : std::uint8_t {
    none,
    trackers,
    web_seeds,
    all,
};

constexpr bool updates_https_trackers(HTTPSSourcePolicyScope const scope) noexcept
{
    return scope == HTTPSSourcePolicyScope::trackers || scope == HTTPSSourcePolicyScope::all;
}

constexpr bool updates_https_web_seeds(HTTPSSourcePolicyScope const scope) noexcept
{
    return scope == HTTPSSourcePolicyScope::web_seeds || scope == HTTPSSourcePolicyScope::all;
}

constexpr HTTPSSourcePolicyScope changed_https_policy_scope(
    HTTPSSourcePolicy const previous,
    HTTPSSourcePolicy const current
) noexcept
{
    bool const trackers_changed = previous.trackers != current.trackers;
    bool const web_seeds_changed = previous.web_seeds != current.web_seeds;
    if (trackers_changed && web_seeds_changed) {
        return HTTPSSourcePolicyScope::all;
    }
    if (trackers_changed) {
        return HTTPSSourcePolicyScope::trackers;
    }
    if (web_seeds_changed) {
        return HTTPSSourcePolicyScope::web_seeds;
    }
    return HTTPSSourcePolicyScope::none;
}

constexpr bool is_valid_https_tracker_policy(std::int64_t const value, bool const allow_inherit) noexcept
{
    switch (value) {
    case TTORRENT_HTTPS_POLICY_INHERIT:
        return allow_inherit;
    case TTORRENT_HTTPS_POLICY_ORIGINAL:
    case TTORRENT_HTTPS_POLICY_PREFER:
    case TTORRENT_HTTPS_POLICY_REQUIRE:
        return true;
    default:
        return false;
    }
}

constexpr bool is_valid_https_web_seed_policy(std::int64_t const value, bool const allow_inherit) noexcept
{
    switch (value) {
    case TTORRENT_HTTPS_POLICY_INHERIT:
        return allow_inherit;
    case TTORRENT_HTTPS_POLICY_ORIGINAL:
    case TTORRENT_HTTPS_POLICY_REQUIRE:
        return true;
    default:
        return false;
    }
}

constexpr HTTPSPolicy https_policy_from_value(int32_t const value) noexcept
{
    return static_cast<HTTPSPolicy>(static_cast<std::uint8_t>(value));
}
constexpr int32_t kUnsetQueueRank = -1;
constexpr std::size_t kOneKilobyte = 1024U;
constexpr std::uintmax_t kOneMegabyte = static_cast<std::uintmax_t>(1024U) * 1024U;
constexpr std::size_t kRemovalTombstoneNonceBytes = 16U;
constexpr std::size_t kMaxMagnetURIBytes = 64U * kOneKilobyte;
constexpr std::uintmax_t kMaxTorrentFileBytes = 64U * kOneMegabyte;
constexpr std::uintmax_t kMaxResumeFileBytes = 64U * kOneMegabyte;
constexpr std::uintmax_t kMaxRemovalTombstoneBytes = 16U * kOneKilobyte;
// Outstanding cleanup failures must not grow persistent recovery state beyond
// one complete live-torrent population. A marker normally carries the v1, v2,
// and app IDs; four memberships per live slot leaves one additional cleanup ID
// on average while still failing closed under pathological churn.
constexpr std::size_t kMaxRemovalTombstoneEntryCount =
    static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT);
constexpr std::size_t kMaxRemovalTombstoneIDMembershipCount =
    4U * static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT);
constexpr std::array<unsigned char, 3> kUTF8ReplacementCharacter{0xefU, 0xbfU, 0xbdU};
constexpr auto kAlertWaitInterval = std::chrono::milliseconds(250);
// A public remove request has a 60-second IPC deadline. Leave enough headroom
// for the fail-closed engine shutdown and reply if libtorrent never confirms
// that its disk pipeline has quiesced.
constexpr auto kTorrentRemovalQuiescenceTimeout = std::chrono::seconds(30);
// Synchronous adds post critical and high-priority alerts. The worker normally
// drains them immediately; this bounded queue extends burst tolerance when it
// is temporarily starved on the client lock. Explicit cadence drains below are
// the guarantee that a product-sized add burst cannot fill it.
constexpr int kLibtorrentAlertQueueSize = 8192;
// Construction deliberately remains single-threaded, and live adds can
// repeatedly reacquire the client lock before the worker. Drain both paths at
// a fixed cadence without exposing partially initialized restore indexes.
constexpr std::size_t kSynchronousAddAlertDrainInterval = 256U;
constexpr auto kAlertWorkerInitialFailureBackoff = std::chrono::milliseconds(100);
constexpr auto kAlertWorkerMaximumFailureBackoff = std::chrono::seconds(5);
constexpr auto kSnapshotUpdateInterval = std::chrono::milliseconds(500);
constexpr auto kDHTDiagnosticsRefreshInterval = std::chrono::seconds(2);
constexpr std::size_t kMaxPendingAlertErrors = 16U;
// Userdata tokens cannot be reused safely because late libtorrent alerts may
// still contain them. Bound their session-lifetime footprint while allowing
// several complete replacements of the maximum live torrent set.
constexpr std::size_t kMaxTorrentIdentityTokenCount =
    4U * static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT);
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
static_assert(kCoarsePeerFingerprint.size() == 8U);
static_assert(TTORRENT_MAX_FILE_COUNT > 0);
static_assert(TTORRENT_MAX_TRACKER_COUNT > 0);
static_assert(TTORRENT_MAX_WEB_SEED_COUNT > 0);
static_assert(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT > 0);
static_assert(kLibtorrentAlertQueueSize > 0);
static_assert(kSynchronousAddAlertDrainInterval > 0U);
static_assert(
    kSynchronousAddAlertDrainInterval
    < static_cast<std::size_t>(kLibtorrentAlertQueueSize)
);
static_assert(kMaxTorrentIdentityTokenCount > static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT));
static_assert(TTORRENT_MAX_TRACKER_HOST_ROW_COUNT > 0);
static_assert(TTORRENT_BRIDGE_ABI_VERSION == 64U);
static_assert(
    TORRENT_ABI_VERSION > 1,
    "Deprecated libtorrent ABIs can parse add_torrent_params.url as a raw magnet."
);
static_assert(sizeof(TTorrentEvent) == 16U);
static_assert(offsetof(TTorrentEvent, critical_faults) == 12U);
static_assert(TTORRENT_DHT_DISCOVERY_ALONGSIDE_TRACKERS == 0U);
static_assert(TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL == 1U);
static_assert(TTORRENT_DHT_STATUS_DISABLED == 0U);
static_assert(TTORRENT_DHT_STATUS_STARTING == 1U);
static_assert(TTORRENT_DHT_STATUS_RUNNING == 2U);
static_assert(TTORRENT_ADD_REJECTED == 0);
static_assert(TTORRENT_ADD_COMMITTED == 1);
static_assert(TTORRENT_ADD_OUTCOME_UNKNOWN == 2);
static_assert(TTORRENT_CONTENT_KIND_UNKNOWN == 0U);
static_assert(TTORRENT_CONTENT_KIND_SINGLE_FILE == 1U);
static_assert(TTORRENT_CONTENT_KIND_DIRECTORY == 2U);
#if defined(TORRENT_USE_ASSERTS) && TORRENT_USE_ASSERTS
static_assert(sizeof(lt::add_torrent_params) == 824U);
#else
static_assert(sizeof(lt::add_torrent_params) == 808U);
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
static_assert(sizeof(TTorrentPresentationMetadata::comment) == 1024U);
static_assert(sizeof(TTorrentTrackerSnapshot::url) == 1024U);
static_assert(sizeof(TTorrentTrackerSnapshot::message) == 512U);
static_assert(sizeof(TTorrentTrackerHostSnapshot::host) == TTORRENT_TRACKER_HOST_CAPACITY);
static_assert(sizeof(TTorrentWebSeedSnapshot::url) == 1024U);
static_assert(sizeof(TTorrentFileSnapshot::path) == 1024U);
static_assert(sizeof(std::uint8_t) == 1U);
static_assert(sizeof(std::int32_t) == 4U);
static_assert(sizeof(std::int64_t) == 8U);
static_assert(std::is_standard_layout_v<TTorrentSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentPresentationMetadata>);
static_assert(std::is_trivially_copyable_v<TTorrentPresentationMetadata>);
static_assert(std::is_standard_layout_v<TTorrentQueuePlacement>);
static_assert(std::is_trivially_copyable_v<TTorrentQueuePlacement>);
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
static_assert(std::is_standard_layout_v<TTorrentPieceMapSnapshot>);
static_assert(std::is_trivially_copyable_v<TTorrentPieceMapSnapshot>);
static_assert(std::is_standard_layout_v<TTorrentMagnetImport>);
static_assert(std::is_trivially_copyable_v<TTorrentMagnetImport>);
static_assert(std::is_standard_layout_v<TTorrentMagnetTracker>);
static_assert(std::is_trivially_copyable_v<TTorrentMagnetTracker>);
static_assert(std::is_standard_layout_v<TTorrentByteRange>);
static_assert(std::is_trivially_copyable_v<TTorrentByteRange>);
static_assert(std::is_standard_layout_v<TTorrentFileSelectionRange>);
static_assert(std::is_trivially_copyable_v<TTorrentFileSelectionRange>);
static_assert(std::is_standard_layout_v<TTorrentSessionSettings>);
static_assert(std::is_trivially_copyable_v<TTorrentSessionSettings>);
static_assert(std::is_standard_layout_v<TTorrentNetworkStatus>);
static_assert(std::is_trivially_copyable_v<TTorrentNetworkStatus>);
static_assert(std::is_standard_layout_v<TTorrentBridgeHealth>);
static_assert(std::is_trivially_copyable_v<TTorrentBridgeHealth>);
static_assert(std::is_standard_layout_v<TTorrentSourcePolicyState>);
static_assert(std::is_trivially_copyable_v<TTorrentSourcePolicyState>);
static_assert(std::is_standard_layout_v<TTorrentSourcePolicyApplication>);
static_assert(std::is_trivially_copyable_v<TTorrentSourcePolicyApplication>);
static_assert(std::is_standard_layout_v<TTorrentAddOptions>);
static_assert(std::is_trivially_copyable_v<TTorrentAddOptions>);
static_assert(std::is_standard_layout_v<TTorrentOptions>);
static_assert(std::is_trivially_copyable_v<TTorrentOptions>);
static_assert(std::is_standard_layout_v<TTorrentOptionsResult>);
static_assert(std::is_trivially_copyable_v<TTorrentOptionsResult>);
static_assert(std::is_standard_layout_v<TTorrentWebSeedActivityResult>);
static_assert(std::is_trivially_copyable_v<TTorrentWebSeedActivityResult>);
static_assert(std::is_standard_layout_v<TTorrentPeerSourcesResult>);
static_assert(std::is_trivially_copyable_v<TTorrentPeerSourcesResult>);
static_assert(std::is_standard_layout_v<TTorrentNetworkStatusResult>);
static_assert(std::is_trivially_copyable_v<TTorrentNetworkStatusResult>);
static_assert(std::is_standard_layout_v<TTorrentBridgeHealthResult>);
static_assert(std::is_trivially_copyable_v<TTorrentBridgeHealthResult>);
static_assert(std::is_standard_layout_v<TTorrentPayloadBrokerCallbacks>);
static_assert(std::is_standard_layout_v<TTorrentOwnedMetainfoCapsule>);
static_assert(std::is_trivially_copyable_v<TTorrentOwnedMetainfoCapsule>);
static_assert(std::is_standard_layout_v<TTorrentSwarmMetainfoParserCallbacks>);
static_assert(std::is_standard_layout_v<TTorrentExtensionHandshakeResult>);
static_assert(std::is_trivially_copyable_v<TTorrentExtensionHandshakeResult>);
static_assert(std::is_standard_layout_v<TTorrentMetadataMessageResult>);
static_assert(std::is_trivially_copyable_v<TTorrentMetadataMessageResult>);
static_assert(std::is_standard_layout_v<TTorrentPeerExchangeRecord>);
static_assert(std::is_trivially_copyable_v<TTorrentPeerExchangeRecord>);
static_assert(std::is_standard_layout_v<TTorrentPeerExchangeResult>);
static_assert(std::is_trivially_copyable_v<TTorrentPeerExchangeResult>);
static_assert(std::is_standard_layout_v<TTorrentPeerProtocolParserCallbacks>);
static_assert(std::is_standard_layout_v<TTorrentTrackerPeerRecord>);
static_assert(std::is_trivially_copyable_v<TTorrentTrackerPeerRecord>);
static_assert(std::is_standard_layout_v<TTorrentHTTPTrackerResponseResult>);
static_assert(std::is_trivially_copyable_v<TTorrentHTTPTrackerResponseResult>);
static_assert(std::is_standard_layout_v<TTorrentTrackerResponseParserCallbacks>);
static_assert(std::is_standard_layout_v<TTorrentDHTNodeRecord>);
static_assert(std::is_trivially_copyable_v<TTorrentDHTNodeRecord>);
static_assert(std::is_standard_layout_v<TTorrentDHTPeerRecord>);
static_assert(std::is_trivially_copyable_v<TTorrentDHTPeerRecord>);
static_assert(std::is_standard_layout_v<TTorrentDHTMessageResult>);
static_assert(std::is_trivially_copyable_v<TTorrentDHTMessageResult>);
static_assert(std::is_standard_layout_v<TTorrentDHTMessageParserCallbacks>);
static_assert(std::is_standard_layout_v<TTorrentStorageActivation>);
static_assert(std::is_trivially_copyable_v<TTorrentStorageActivation>);
static_assert(sizeof(TTorrentSnapshot) == 2336U);
static_assert(alignof(TTorrentSnapshot) == 8U);
static_assert(offsetof(TTorrentSnapshot, content_kind) == 2334U);
static_assert(sizeof(TTorrentPresentationMetadata) == 1040U);
static_assert(alignof(TTorrentPresentationMetadata) == 8U);
static_assert(offsetof(TTorrentPresentationMetadata, comment) == 16U);
static_assert(sizeof(TTorrentQueuePlacement) == 16U);
static_assert(alignof(TTorrentQueuePlacement) == 8U);
static_assert(offsetof(TTorrentQueuePlacement, priority) == 8U);
static_assert(sizeof(TTorrentTrackerSnapshot) == 1560U);
static_assert(alignof(TTorrentTrackerSnapshot) == 4U);
static_assert(sizeof(TTorrentTrackerHostSnapshot) == 264U);
static_assert(alignof(TTorrentTrackerHostSnapshot) == 8U);
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
static_assert(sizeof(TTorrentPieceMapSnapshot) == 16U);
static_assert(alignof(TTorrentPieceMapSnapshot) == 4U);
static_assert(sizeof(TTorrentMagnetImport) == 68U);
static_assert(alignof(TTorrentMagnetImport) == 4U);
static_assert(sizeof(TTorrentMagnetTracker) == 12U);
static_assert(alignof(TTorrentMagnetTracker) == 4U);
static_assert(sizeof(TTorrentByteRange) == 8U);
static_assert(alignof(TTorrentByteRange) == 4U);
static_assert(sizeof(TTorrentFileSelectionRange) == 8U);
static_assert(alignof(TTorrentFileSelectionRange) == 4U);
static_assert(sizeof(TTorrentSessionSettings) == 48U);
static_assert(offsetof(TTorrentSessionSettings, dht_discovery_policy) == 46U);
static_assert(alignof(TTorrentSessionSettings) == 4U);
static_assert(sizeof(TTorrentNetworkStatus) == 656U);
static_assert(alignof(TTorrentNetworkStatus) == 4U);
static_assert(offsetof(TTorrentNetworkStatus, dht_routing_nodes) == 648U);
static_assert(offsetof(TTorrentNetworkStatus, dht_status) == 652U);
static_assert(sizeof(TTorrentBridgeHealth) == 536U);
static_assert(alignof(TTorrentBridgeHealth) == 8U);
static_assert(sizeof(TTorrentSourcePolicyState) == 24U);
static_assert(alignof(TTorrentSourcePolicyState) == 8U);
static_assert(sizeof(TTorrentSourcePolicyApplication) == 24U);
static_assert(alignof(TTorrentSourcePolicyApplication) == 8U);
static_assert(sizeof(TTorrentAddOptions) == 78U);
static_assert(alignof(TTorrentAddOptions) == 1U);
static_assert(sizeof(TTorrentOptions) == 20U);
static_assert(alignof(TTorrentOptions) == 4U);
static_assert(sizeof(TTorrentOptionsResult) == 24U);
static_assert(alignof(TTorrentOptionsResult) == 4U);
static_assert(offsetof(TTorrentOptionsResult, options) == 4U);
static_assert(sizeof(TTorrentWebSeedActivityResult) == 24U);
static_assert(alignof(TTorrentWebSeedActivityResult) == 8U);
static_assert(offsetof(TTorrentWebSeedActivityResult, activity) == 8U);
static_assert(sizeof(TTorrentPeerSourcesResult) == 40U);
static_assert(alignof(TTorrentPeerSourcesResult) == 4U);
static_assert(offsetof(TTorrentPeerSourcesResult, sources) == 4U);
static_assert(sizeof(TTorrentNetworkStatusResult) == 660U);
static_assert(alignof(TTorrentNetworkStatusResult) == 4U);
static_assert(offsetof(TTorrentNetworkStatusResult, network_status) == 4U);
static_assert(sizeof(TTorrentBridgeHealthResult) == 544U);
static_assert(alignof(TTorrentBridgeHealthResult) == 8U);
static_assert(offsetof(TTorrentBridgeHealthResult, health) == 8U);
static_assert(sizeof(TTorrentPayloadBrokerCallbacks) == 40U);
static_assert(alignof(TTorrentPayloadBrokerCallbacks) == 8U);
static_assert(sizeof(TTorrentOwnedMetainfoCapsule) == 16U);
static_assert(alignof(TTorrentOwnedMetainfoCapsule) == 8U);
static_assert(sizeof(TTorrentSwarmMetainfoParserCallbacks) == 40U);
static_assert(alignof(TTorrentSwarmMetainfoParserCallbacks) == 8U);
static_assert(sizeof(TTorrentExtensionHandshakeResult) == 64U);
static_assert(alignof(TTorrentExtensionHandshakeResult) == 8U);
static_assert(sizeof(TTorrentMetadataMessageResult) == 32U);
static_assert(alignof(TTorrentMetadataMessageResult) == 8U);
static_assert(sizeof(TTorrentPeerExchangeRecord) == 24U);
static_assert(alignof(TTorrentPeerExchangeRecord) == 8U);
static_assert(sizeof(TTorrentPeerExchangeResult) == 16U);
static_assert(alignof(TTorrentPeerExchangeResult) == 4U);
static_assert(sizeof(TTorrentPeerProtocolParserCallbacks) == 48U);
static_assert(alignof(TTorrentPeerProtocolParserCallbacks) == 8U);
static_assert(sizeof(TTorrentTrackerPeerRecord) == 40U);
static_assert(alignof(TTorrentTrackerPeerRecord) == 8U);
static_assert(sizeof(TTorrentHTTPTrackerResponseResult) == 80U);
static_assert(alignof(TTorrentHTTPTrackerResponseResult) == 8U);
static_assert(sizeof(TTorrentTrackerResponseParserCallbacks) == 32U);
static_assert(alignof(TTorrentTrackerResponseParserCallbacks) == 8U);
static_assert(sizeof(TTorrentDHTNodeRecord) == 32U);
static_assert(alignof(TTorrentDHTNodeRecord) == 8U);
static_assert(sizeof(TTorrentDHTPeerRecord) == 24U);
static_assert(alignof(TTorrentDHTPeerRecord) == 8U);
static_assert(sizeof(TTorrentDHTMessageResult) == 112U);
static_assert(alignof(TTorrentDHTMessageResult) == 8U);
static_assert(sizeof(TTorrentDHTMessageParserCallbacks) == 32U);
static_assert(alignof(TTorrentDHTMessageParserCallbacks) == 8U);
static_assert(sizeof(TTorrentStorageActivation) == 96U);
static_assert(alignof(TTorrentStorageActivation) == 8U);
static_assert(offsetof(TTorrentStorageActivation, preserved_torrent_id) == 56U);

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

struct BridgeError {
    int32_t code;
    std::string message;
};

using BridgeResult = std::expected<void, BridgeError>;
using FileReadResult = std::expected<std::vector<char>, FileReadFailure>;
using ResumeRemoveResult = std::expected<bool, std::string>;
using ResumeSaveResult = std::expected<void, std::string>;
using ResumeIDListResult = std::expected<std::vector<std::string>, std::string>;
using ResumeInfoSectionResult =
    std::expected<std::optional<std::vector<char>>, std::string>;
using TorrentLoadResult = std::expected<lt::add_torrent_params, BridgeError>;
using TorrentInfoLoadResult = std::expected<std::shared_ptr<lt::torrent_info>, BridgeError>;

[[nodiscard]] constexpr bool torrent_count_allows_admission(std::size_t count) noexcept
{
    return count < static_cast<std::size_t>(TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT);
}

[[nodiscard]] constexpr bool torrent_identity_token_count_allows_admission(std::size_t count) noexcept
{
    return count < kMaxTorrentIdentityTokenCount;
}

[[nodiscard]] constexpr bool resume_read_failure_is_definitively_invalid(FileReadFailure failure) noexcept
{
    return failure == FileReadFailure::empty || failure == FileReadFailure::too_large;
}

struct TombstoneCommitStatus {
    bool directory_synced = true;
    std::string filename;
};

struct TorrentIdentity;

struct PendingResumeCleanup {
    std::vector<std::string> resume_ids;
};

struct PendingEncodedResumeWrite {
    lt::info_hash_t hashes;
    TorrentIdentity *identity = nullptr;
    std::vector<char> encoded;
    std::vector<PendingResumeCleanup> cleanups;
};

enum class ResumeSaveMode : std::uint8_t {
    routine = TTORRENT_RESUME_SAVE_ROUTINE,
    policy = TTORRENT_RESUME_SAVE_POLICY,
    full = TTORRENT_RESUME_SAVE_FULL,
};

// Libtorrent may retain userdata after the app has stopped considering a
// torrent active. Keep only this compact token alive for the session lifetime;
// the heavyweight identity it resolves to can be reclaimed safely.
struct TorrentIdentityToken {
    std::uint64_t value = 0;
    std::atomic<TorrentIdentity *> active_identity = nullptr;
};

static_assert(sizeof(TorrentIdentityToken) <= 2U * sizeof(std::uintptr_t));

struct TorrentIdentity {
    TorrentIdentityToken *token = nullptr;
    std::string canonical_id;
    std::optional<TTorrentStorageActivation> storage_activation;
    std::unique_ptr<TTorrentPresentationMetadata> pending_presentation_metadata;
    bool presentation_metadata_refresh_requested = false;
    HTTPSPolicy https_tracker_policy = HTTPSPolicy::inherit;
    HTTPSPolicy https_web_seed_policy = HTTPSPolicy::inherit;
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
    std::chrono::steady_clock::time_point metadata_validation_retry_after;
};

struct ResumePolicySnapshot {
    bool has_identity = false;
    std::string canonical_id;
    std::optional<TTorrentStorageActivation> storage_activation;
    HTTPSPolicy https_tracker_policy = HTTPSPolicy::inherit;
    HTTPSPolicy https_web_seed_policy = HTTPSPolicy::inherit;
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
    TorrentIdentity *identity = nullptr;
    ResumePolicySnapshot policy;
    std::vector<PendingResumeCleanup> cleanups;
};

struct PendingResumeHandle {
    lt::torrent_handle handle;
    TorrentIdentity *identity = nullptr;
    ResumePolicySnapshot policy;
    std::vector<PendingResumeCleanup> cleanups;
};

struct RemovalTombstoneEntry {
    std::string filename;
    std::vector<std::string> ids;
};

struct RemovalTombstoneIndexLimits {
    std::size_t entry_count = 0;
    std::size_t id_membership_count = 0;
};

struct RemovalTombstonePayload {
    std::vector<std::string> ids;
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
inline constexpr DirtyMask kChangeTorrents = 1U << 0U;
inline constexpr DirtyMask kChangeTrackers = 1U << 1U;
inline constexpr DirtyMask kChangeWebSeeds = 1U << 2U;
inline constexpr DirtyMask kChangeFiles = 1U << 3U;
inline constexpr DirtyMask kChangeNetwork = 1U << 4U;
inline constexpr DirtyMask kChangeErrors = 1U << 5U;
inline constexpr DirtyMask kChangePieces = 1U << 6U;
inline constexpr DirtyMask kChangeTrackerHosts = 1U << 7U;
inline constexpr DirtyMask kChangeHealth = 1U << 8U;

// Preserve the standard C callback ABI at the exported boundary. PAC targets
// keep each callback capability in role- and address-diversified authenticated
// storage; the plain-arm64 libFuzzer build retains the same source-level types.
#if defined(__PTRAUTH__)
inline constexpr ptrauth_extra_data_t kPayloadRetainCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.payload.retain");
inline constexpr ptrauth_extra_data_t kPayloadReleaseCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.payload.release");
inline constexpr ptrauth_extra_data_t kPayloadOpenCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.payload.open");
inline constexpr ptrauth_extra_data_t kPayloadSizeCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.payload.size");
inline constexpr ptrauth_extra_data_t kPayloadContextDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.payload.context");
inline constexpr ptrauth_extra_data_t kSwarmMetainfoRetainCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.swarm-metainfo.retain");
inline constexpr ptrauth_extra_data_t kSwarmMetainfoReleaseCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.swarm-metainfo.release");
inline constexpr ptrauth_extra_data_t kSwarmMetainfoParseCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.swarm-metainfo.parse");
inline constexpr ptrauth_extra_data_t kSwarmMetainfoCapsuleReleaseCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.swarm-metainfo.capsule-release");
inline constexpr ptrauth_extra_data_t kSwarmMetainfoContextDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.swarm-metainfo.context");
inline constexpr ptrauth_extra_data_t kPeerProtocolRetainCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.peer-protocol.retain");
inline constexpr ptrauth_extra_data_t kPeerProtocolReleaseCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.peer-protocol.release");
inline constexpr ptrauth_extra_data_t kPeerProtocolHandshakeCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.peer-protocol.handshake");
inline constexpr ptrauth_extra_data_t kPeerProtocolMetadataCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.peer-protocol.metadata");
inline constexpr ptrauth_extra_data_t kPeerProtocolPEXCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.peer-protocol.pex");
inline constexpr ptrauth_extra_data_t kPeerProtocolContextDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.peer-protocol.context");
inline constexpr ptrauth_extra_data_t kTrackerParserRetainCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.tracker-parser.retain");
inline constexpr ptrauth_extra_data_t kTrackerParserReleaseCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.tracker-parser.release");
inline constexpr ptrauth_extra_data_t kTrackerParserHTTPCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.tracker-parser.http");
inline constexpr ptrauth_extra_data_t kTrackerParserContextDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.tracker-parser.context");
inline constexpr ptrauth_extra_data_t kDHTParserRetainCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.dht-parser.retain");
inline constexpr ptrauth_extra_data_t kDHTParserReleaseCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.dht-parser.release");
inline constexpr ptrauth_extra_data_t kDHTParserMessageCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.dht-parser.message");
inline constexpr ptrauth_extra_data_t kDHTParserContextDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.dht-parser.context");
inline constexpr ptrauth_extra_data_t kWakeCallbackDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.wake");
inline constexpr ptrauth_extra_data_t kWakeContextDiscriminator =
    ptrauth_string_discriminator("torrent.bridge.wake.context");
using StoredWakeCallback = TTorrentWakeCallback __ptrauth(
    ptrauth_key_function_pointer,
    1,
    kWakeCallbackDiscriminator
);
using StoredWakeContext = void * __ptrauth(
    ptrauth_key_process_dependent_data,
    1,
    kWakeContextDiscriminator
);
using StoredPayloadRetainCallback = TTorrentPayloadContextRetainCallback __ptrauth(
    ptrauth_key_function_pointer,
    1,
    kPayloadRetainCallbackDiscriminator
);
using StoredPayloadReleaseCallback = TTorrentPayloadContextReleaseCallback __ptrauth(
    ptrauth_key_function_pointer,
    1,
    kPayloadReleaseCallbackDiscriminator
);
using StoredPayloadOpenCallback = TTorrentPayloadOpenCallback __ptrauth(
    ptrauth_key_function_pointer,
    1,
    kPayloadOpenCallbackDiscriminator
);
using StoredPayloadSizeCallback = TTorrentPayloadSizeCallback __ptrauth(
    ptrauth_key_function_pointer,
    1,
    kPayloadSizeCallbackDiscriminator
);
using StoredPayloadContext = void * __ptrauth(
    ptrauth_key_process_dependent_data,
    1,
    kPayloadContextDiscriminator
);
using StoredSwarmMetainfoRetainCallback =
    TTorrentSwarmMetainfoContextRetainCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kSwarmMetainfoRetainCallbackDiscriminator
    );
using StoredSwarmMetainfoReleaseCallback =
    TTorrentSwarmMetainfoContextReleaseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kSwarmMetainfoReleaseCallbackDiscriminator
    );
using StoredSwarmMetainfoParseCallback =
    TTorrentSwarmMetainfoParseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kSwarmMetainfoParseCallbackDiscriminator
    );
using StoredSwarmMetainfoCapsuleReleaseCallback =
    TTorrentSwarmMetainfoCapsuleReleaseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kSwarmMetainfoCapsuleReleaseCallbackDiscriminator
    );
using StoredSwarmMetainfoContext = void * __ptrauth(
    ptrauth_key_process_dependent_data,
    1,
    kSwarmMetainfoContextDiscriminator
);
using StoredPeerProtocolRetainCallback =
    TTorrentPeerProtocolContextRetainCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kPeerProtocolRetainCallbackDiscriminator
    );
using StoredPeerProtocolReleaseCallback =
    TTorrentPeerProtocolContextReleaseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kPeerProtocolReleaseCallbackDiscriminator
    );
using StoredPeerProtocolHandshakeCallback =
    TTorrentExtensionHandshakeParseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kPeerProtocolHandshakeCallbackDiscriminator
    );
using StoredPeerProtocolMetadataCallback =
    TTorrentMetadataMessageParseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kPeerProtocolMetadataCallbackDiscriminator
    );
using StoredPeerProtocolPEXCallback =
    TTorrentPeerExchangeParseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kPeerProtocolPEXCallbackDiscriminator
    );
using StoredPeerProtocolContext = void * __ptrauth(
    ptrauth_key_process_dependent_data,
    1,
    kPeerProtocolContextDiscriminator
);
using StoredTrackerParserRetainCallback =
    TTorrentTrackerParserContextRetainCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kTrackerParserRetainCallbackDiscriminator
    );
using StoredTrackerParserReleaseCallback =
    TTorrentTrackerParserContextReleaseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kTrackerParserReleaseCallbackDiscriminator
    );
using StoredTrackerParserHTTPCallback =
    TTorrentHTTPTrackerResponseParseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kTrackerParserHTTPCallbackDiscriminator
    );
using StoredTrackerParserContext = void * __ptrauth(
    ptrauth_key_process_dependent_data,
    1,
    kTrackerParserContextDiscriminator
);
using StoredDHTParserRetainCallback =
    TTorrentDHTParserContextRetainCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kDHTParserRetainCallbackDiscriminator
    );
using StoredDHTParserReleaseCallback =
    TTorrentDHTParserContextReleaseCallback __ptrauth(
        ptrauth_key_function_pointer,
        1,
        kDHTParserReleaseCallbackDiscriminator
    );
using StoredDHTParserMessageCallback = TTorrentDHTMessageParseCallback __ptrauth(
    ptrauth_key_function_pointer,
    1,
    kDHTParserMessageCallbackDiscriminator
);
using StoredDHTParserContext = void * __ptrauth(
    ptrauth_key_process_dependent_data,
    1,
    kDHTParserContextDiscriminator
);
#else
using StoredWakeCallback = TTorrentWakeCallback;
using StoredWakeContext = void *;
using StoredPayloadRetainCallback = TTorrentPayloadContextRetainCallback;
using StoredPayloadReleaseCallback = TTorrentPayloadContextReleaseCallback;
using StoredPayloadOpenCallback = TTorrentPayloadOpenCallback;
using StoredPayloadSizeCallback = TTorrentPayloadSizeCallback;
using StoredPayloadContext = void *;
using StoredSwarmMetainfoRetainCallback = TTorrentSwarmMetainfoContextRetainCallback;
using StoredSwarmMetainfoReleaseCallback = TTorrentSwarmMetainfoContextReleaseCallback;
using StoredSwarmMetainfoParseCallback = TTorrentSwarmMetainfoParseCallback;
using StoredSwarmMetainfoCapsuleReleaseCallback =
    TTorrentSwarmMetainfoCapsuleReleaseCallback;
using StoredSwarmMetainfoContext = void *;
using StoredPeerProtocolRetainCallback = TTorrentPeerProtocolContextRetainCallback;
using StoredPeerProtocolReleaseCallback = TTorrentPeerProtocolContextReleaseCallback;
using StoredPeerProtocolHandshakeCallback = TTorrentExtensionHandshakeParseCallback;
using StoredPeerProtocolMetadataCallback = TTorrentMetadataMessageParseCallback;
using StoredPeerProtocolPEXCallback = TTorrentPeerExchangeParseCallback;
using StoredPeerProtocolContext = void *;
using StoredTrackerParserRetainCallback = TTorrentTrackerParserContextRetainCallback;
using StoredTrackerParserReleaseCallback = TTorrentTrackerParserContextReleaseCallback;
using StoredTrackerParserHTTPCallback = TTorrentHTTPTrackerResponseParseCallback;
using StoredTrackerParserContext = void *;
using StoredDHTParserRetainCallback = TTorrentDHTParserContextRetainCallback;
using StoredDHTParserReleaseCallback = TTorrentDHTParserContextReleaseCallback;
using StoredDHTParserMessageCallback = TTorrentDHTMessageParseCallback;
using StoredDHTParserContext = void *;
#endif

struct PayloadBrokerCallbacks {
    StoredPayloadContext context = nullptr;
    StoredPayloadRetainCallback retain_context = nullptr;
    StoredPayloadReleaseCallback release_context = nullptr;
    StoredPayloadOpenCallback open_payload = nullptr;
    StoredPayloadSizeCallback payload_size = nullptr;
};

struct SwarmMetainfoParserCallbacks {
    StoredSwarmMetainfoContext context = nullptr;
    StoredSwarmMetainfoRetainCallback retain_context = nullptr;
    StoredSwarmMetainfoReleaseCallback release_context = nullptr;
    StoredSwarmMetainfoParseCallback parse_info = nullptr;
    StoredSwarmMetainfoCapsuleReleaseCallback release_capsule = nullptr;
};

struct PeerProtocolParserCallbacks {
    StoredPeerProtocolContext context = nullptr;
    StoredPeerProtocolRetainCallback retain_context = nullptr;
    StoredPeerProtocolReleaseCallback release_context = nullptr;
    StoredPeerProtocolHandshakeCallback parse_extension_handshake = nullptr;
    StoredPeerProtocolMetadataCallback parse_metadata_message = nullptr;
    StoredPeerProtocolPEXCallback parse_peer_exchange = nullptr;
};

struct TrackerResponseParserCallbacks {
    StoredTrackerParserContext context = nullptr;
    StoredTrackerParserRetainCallback retain_context = nullptr;
    StoredTrackerParserReleaseCallback release_context = nullptr;
    StoredTrackerParserHTTPCallback parse_http_response = nullptr;
};

struct DHTMessageParserCallbacks {
    StoredDHTParserContext context = nullptr;
    StoredDHTParserRetainCallback retain_context = nullptr;
    StoredDHTParserReleaseCallback release_context = nullptr;
    StoredDHTParserMessageCallback parse_message = nullptr;
};

class BridgeDHTMessageParser final : public lt::aux::dht_message_parser {
public:
    explicit BridgeDHTMessageParser(TTorrentDHTMessageParserCallbacks callbacks);
    __attribute__((noinline)) ~BridgeDHTMessageParser() override;

    BridgeDHTMessageParser(BridgeDHTMessageParser const &) = delete;
    BridgeDHTMessageParser &operator=(BridgeDHTMessageParser const &) = delete;
    BridgeDHTMessageParser(BridgeDHTMessageParser &&) = delete;
    BridgeDHTMessageParser &operator=(BridgeDHTMessageParser &&) = delete;

    [[nodiscard]] bool parse_message(
        lt::span<char const> body,
        bool source_is_ipv6,
        lt::dht::krpc_message &result
    ) noexcept override;

private:
    DHTMessageParserCallbacks callbacks_;
    bool retained_ = false;
};

class BridgeTrackerResponseParser final : public lt::aux::tracker_response_parser {
public:
    explicit BridgeTrackerResponseParser(TTorrentTrackerResponseParserCallbacks callbacks);
    __attribute__((noinline)) ~BridgeTrackerResponseParser() override;

    BridgeTrackerResponseParser(BridgeTrackerResponseParser const &) = delete;
    BridgeTrackerResponseParser &operator=(BridgeTrackerResponseParser const &) = delete;
    BridgeTrackerResponseParser(BridgeTrackerResponseParser &&) = delete;
    BridgeTrackerResponseParser &operator=(BridgeTrackerResponseParser &&) = delete;

    [[nodiscard]] bool parse_http_response(
        lt::span<char const> body,
        bool is_scrape,
        lt::sha1_hash const &scrape_info_hash,
        lt::aux::tracker_response &result,
        lt::error_code &error
    ) noexcept override;

private:
    TrackerResponseParserCallbacks callbacks_;
    bool retained_ = false;
};

class BridgePeerMessageParser final : public lt::aux::peer_message_parser {
public:
    explicit BridgePeerMessageParser(TTorrentPeerProtocolParserCallbacks callbacks);
    __attribute__((noinline)) ~BridgePeerMessageParser() override;

    BridgePeerMessageParser(BridgePeerMessageParser const &) = delete;
    BridgePeerMessageParser &operator=(BridgePeerMessageParser const &) = delete;
    BridgePeerMessageParser(BridgePeerMessageParser &&) = delete;
    BridgePeerMessageParser &operator=(BridgePeerMessageParser &&) = delete;

    [[nodiscard]] bool parse_extension_handshake(
        lt::span<char const> message,
        lt::aux::extension_handshake &result,
        lt::error_code &error
    ) noexcept override;

    [[nodiscard]] bool parse_ut_metadata(
        lt::span<char const> message,
        lt::aux::ut_metadata_message &result,
        lt::error_code &error
    ) noexcept override;

    [[nodiscard]] bool parse_ut_pex(
        lt::span<char const> message,
        lt::aux::peer_exchange_message &result,
        lt::error_code &error
    ) noexcept override;

private:
    PeerProtocolParserCallbacks callbacks_;
    bool retained_ = false;
};

class BridgeSwarmMetadataParser final : public lt::aux::swarm_metadata_parser {
public:
    explicit BridgeSwarmMetadataParser(TTorrentSwarmMetainfoParserCallbacks callbacks);
    __attribute__((noinline)) ~BridgeSwarmMetadataParser() override;

    BridgeSwarmMetadataParser(BridgeSwarmMetadataParser const &) = delete;
    BridgeSwarmMetadataParser &operator=(BridgeSwarmMetadataParser const &) = delete;
    BridgeSwarmMetadataParser(BridgeSwarmMetadataParser &&) = delete;
    BridgeSwarmMetadataParser &operator=(BridgeSwarmMetadataParser &&) = delete;

    [[nodiscard]] std::shared_ptr<lt::torrent_info> parse(
        lt::span<char const> info,
        lt::error_code &error
    ) noexcept override;

private:
    SwarmMetainfoParserCallbacks callbacks_;
    bool retained_ = false;
};

class PayloadBrokerContext final {
public:
    explicit PayloadBrokerContext(TTorrentPayloadBrokerCallbacks callbacks);
    __attribute__((noinline)) ~PayloadBrokerContext();

    PayloadBrokerContext(PayloadBrokerContext const &) = delete;
    PayloadBrokerContext &operator=(PayloadBrokerContext const &) = delete;
    PayloadBrokerContext(PayloadBrokerContext &&) = delete;
    PayloadBrokerContext &operator=(PayloadBrokerContext &&) = delete;

    [[nodiscard]] int open_payload(
        TTorrentStorageActivation const &activation,
        lt::file_index_t file,
        bool writable,
        lt::error_code &error
    ) const noexcept;

    [[nodiscard]] std::int64_t payload_size(
        TTorrentStorageActivation const &activation,
        lt::file_index_t file,
        lt::error_code &error
    ) const noexcept;

private:
    PayloadBrokerCallbacks callbacks_;
    bool retained_ = false;
};

class BridgePayloadFileProvider final : public lt::aux::payload_file_provider {
public:
    BridgePayloadFileProvider(
        std::shared_ptr<PayloadBrokerContext> broker,
        TTorrentStorageActivation activation
    );

    int open_payload(lt::file_index_t file, bool writable, lt::error_code &error) override;
    std::int64_t payload_size(lt::file_index_t file, lt::error_code &error) override;

private:
    std::shared_ptr<PayloadBrokerContext> broker_;
    TTorrentStorageActivation activation_{};
};

[[nodiscard]] BridgeResult validate_storage_activation(
    lt::add_torrent_params const &params,
    TTorrentStorageActivation const &activation
);

#if defined(TORRENT_BRIDGE_TESTING)
[[nodiscard]] lt::sha256_hash testing_logical_manifest_digest(
    lt::add_torrent_params const &params
);
#endif

[[nodiscard]] std::string storage_claim_key(TTorrentStorageActivation const &activation);

[[nodiscard]] std::optional<TTorrentStorageActivation> storage_activation_from_resume_data(
    std::vector<char> const &buffer
);

struct WakeCallbackInvocation {
    StoredWakeCallback callback = nullptr;
    StoredWakeContext context = nullptr;
};

#if defined(__PTRAUTH__)
static_assert(!std::is_trivially_copyable_v<WakeCallbackInvocation>);
#endif

[[nodiscard]] constexpr bool has_dirty_changes(DirtyMask changes) noexcept
{
    return changes != 0U;
}

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

template <typename Cleanup>
void detach_terminal_cleanup(Cleanup cleanup)
{
    // Cleanup must own every resource it needs and must not refer back to its
    // caller; the detached thread exists only to run that terminal destruction.
    std::thread([cleanup = std::move(cleanup)]() mutable {}).detach();
}

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
                // After client-owned work is quiescent, the ordinary C ABI destroy
                // path must not also wait for session_proxy to join libtorrent's
                // internal threads. The helper's thread takes sole ownership of the
                // proxy and state lock and never accesses the former TTorrentClient; a
                // local std::jthread would join here and restore that final blocking
                // wait.
                detach_terminal_cleanup(std::move(*shutdown_));
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

std::string system_error_message(std::string_view action, int error_number);

char hex_digit(unsigned char value) noexcept;

std::string hex_string(std::string_view bytes);

std::uint32_t random_u32() noexcept;

bool is_hex_character(char value) noexcept;

bool is_canonical_torrent_id(std::string_view id) noexcept;

bool is_prefixed_hex_id(std::string_view id, std::string_view prefix, std::size_t hex_length) noexcept;

bool is_resume_data_id(std::string_view id) noexcept;

std::string resume_temp_extension(std::uint32_t attempt);

void remove_file_quietly(fs::path const &path) noexcept;

ResumeTempFileResult open_resume_temp_file(fs::path const &final_path);

void remove_file_at_quietly(int directory_descriptor, std::string const &filename) noexcept;

ResumeTempFileResult open_resume_temp_file_at(
    int directory_descriptor,
    std::string const &final_filename
);

ResumeSaveResult write_all(int descriptor, std::span<char const> bytes);

ResumeSaveResult close_resume_temp_file(UniqueFileDescriptor &file);

ResumeSaveResult sync_file(int descriptor);

ResumeSaveResult sync_directory(fs::path const &directory);

ResumeSaveResult sync_directory(int directory_descriptor);

ResumeSaveResult write_owner_only_file_checked(fs::path const &path, std::string_view bytes);

ResumeSaveResult write_owner_only_file_at_checked(
    int directory_descriptor,
    std::string const &filename,
    std::string_view bytes
);

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

bool is_removal_tombstone_path(fs::path const &path);

std::optional<std::string> resume_id_from_resume_path(fs::path const &path);

ResumeIDListResult normalized_resume_ids(std::vector<std::string> const &ids);

TombstonePayloadResult tombstone_payload_from_bytes(std::vector<char> const &buffer);

std::string_view tombstone_read_error(FileReadFailure failure) noexcept;

std::string tombstone_payload(std::vector<std::string> const &ids);

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

ResumeInfoSectionResult preparsed_info_from_resume_data(
    std::vector<char> const &buffer
);

bool metadata_validation_pending_from_resume_data(std::vector<char> const &buffer);

[[nodiscard]] std::expected<bool, std::string> staged_metadata_from_resume_data(std::vector<char> const &buffer);

bool allow_pre_metadata_dht_from_resume_data(std::vector<char> const &buffer);

void sanitize_magnet_endpoint_hints(lt::add_torrent_params &params);

TorrentLoadResult import_parsed_magnet(
    TTorrentMagnetImport const &magnet,
    std::span<std::uint8_t const> blob,
    std::span<TTorrentMagnetTracker const> trackers,
    std::span<TTorrentByteRange const> web_seeds,
    std::span<TTorrentFileSelectionRange const> file_selections
);

TorrentLoadResult import_preparsed_metainfo_capsule(
    std::span<std::uint8_t const> capsule
);

TorrentInfoLoadResult import_preparsed_info_capsule(
    std::span<std::uint8_t const> capsule
);

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
) noexcept;
#endif

void sanitize_resume_endpoint_hints(lt::add_torrent_params &params) noexcept;

[[nodiscard]] std::expected<HTTPSSourcePolicy, std::string> https_source_policy_from_resume_data(
    std::vector<char> const &buffer
);

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

std::string identity_snapshot_id(TorrentIdentity const *identity);

void stage_presentation_metadata(
    TorrentIdentity &identity,
    lt::add_torrent_params const &params
);

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

lt::session_params make_session_params(
    bool enable_peer_exchange_plugin,
    std::shared_ptr<lt::aux::dht_message_parser> const &dht_message_parser = nullptr
);

void prepare_add_params(
    lt::add_torrent_params &params,
    std::string_view save_path,
    bool starts_paused,
    bool enable_peer_exchange
);

bool is_https_url(std::string_view url) noexcept;

TorrentSourceCounts torrent_source_counts(lt::add_torrent_params const &params);

BridgeResult validate_torrent_sources(lt::add_torrent_params const &params);

bool apply_https_source_policy(
    lt::add_torrent_params &params,
    HTTPSSourcePolicy policy
);

[[nodiscard]] std::vector<lt::announce_entry> trackers_for_https_policy(
    std::vector<lt::announce_entry> trackers,
    HTTPSPolicy policy
);

[[nodiscard]] BridgeResult remember_source_policy_sources(
    TorrentIdentity &identity,
    lt::add_torrent_params const &params
);

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

std::string trimmed(std::string_view value);

bool contains_invalid_interface_character(std::string_view value);

bool is_ipv4_address(std::string const &value);

bool is_ipv6_address(std::string const &value);

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

FileReadResult read_file_at(
    int directory_descriptor,
    std::string const &filename,
    std::uintmax_t max_size
);

UniqueFileDescriptor open_directory_no_follow(fs::path const &path, std::string_view description);

UniqueFileDescriptor open_directory_at_no_follow(
    int parent_directory_descriptor,
    char const *filename,
    std::string_view description
);

void restrict_permissions(fs::path const &path, FileSystemNodeKind kind);

void restrict_permissions(int descriptor, std::string_view description, FileSystemNodeKind kind);

UniqueFileDescriptor acquire_state_directory_lock(int state_directory_descriptor);

BridgeResult validate_torrent_info(lt::torrent_info const &info);

BridgeResult validate_torrent_info(
    lt::torrent_info const &info,
    std::map<lt::file_index_t, std::string> const &renamed_files
);

BridgeResult validate_torrent_info(lt::add_torrent_params const &params);

BridgeResult validate_resume_merkle_state(lt::add_torrent_params const &params);

bool is_valid_file_priority(int32_t priority) noexcept;

lt::download_priority_t file_priority_from_bridge(int32_t priority) noexcept;

BridgeResult apply_file_priorities(
    lt::add_torrent_params &params,
    std::optional<std::span<TTorrentFilePriorityEntry const>> file_priorities
);

[[nodiscard]] std::chrono::milliseconds alert_worker_failure_backoff(
    std::uint64_t consecutive_failures
) noexcept;

[[nodiscard]] bool wait_for_alert_worker_backoff(
    std::stop_token const &stop_token,
    std::chrono::milliseconds duration
) noexcept;

struct TTorrentClient {
    explicit TTorrentClient(std::string_view state_path, bool enable_peer_exchange_plugin = true);

    TTorrentClient(
        std::string_view state_path,
        bool enable_peer_exchange_plugin,
        std::shared_ptr<PayloadBrokerContext> payload_broker,
        std::shared_ptr<lt::aux::swarm_metadata_parser> swarm_parser = nullptr,
        std::shared_ptr<lt::aux::peer_message_parser> peer_parser = nullptr,
        std::shared_ptr<lt::aux::tracker_response_parser> tracker_parser = nullptr,
        std::shared_ptr<lt::aux::dht_message_parser> dht_parser = nullptr
    );

    ~TTorrentClient() noexcept;

    TTorrentClient(TTorrentClient const &) = delete;
    TTorrentClient &operator=(TTorrentClient const &) = delete;
    TTorrentClient(TTorrentClient &&) = delete;
    TTorrentClient &operator=(TTorrentClient &&) = delete;

    void set_session_shutdown_asynchronous(bool value) noexcept;

    [[nodiscard]] std::shared_ptr<lt::aux::payload_file_provider> make_payload_provider(
        TTorrentStorageActivation const &activation
    ) const;

    [[nodiscard]] std::string part_file_path(TTorrentStorageActivation const &activation) const;

    [[nodiscard]] std::string staging_path(lt::info_hash_t const &hashes) const;

    AnalyzedMutex lock;
    AnalyzedMutex resume_capture_lock TORRENT_BRIDGE_ACQUIRED_AFTER(lock);
    mutable AnalyzedMutex resume_io_lock TORRENT_BRIDGE_ACQUIRED_AFTER(resume_capture_lock);
    fs::path part_files_directory;
    fs::path staging_directory;
    std::shared_ptr<PayloadBrokerContext> payload_broker;
    std::shared_ptr<lt::aux::swarm_metadata_parser> swarm_metadata_parser;
    std::shared_ptr<lt::aux::peer_message_parser> peer_message_parser;
    std::shared_ptr<lt::aux::tracker_response_parser> tracker_response_parser;
    std::shared_ptr<lt::aux::dht_message_parser> dht_message_parser;
    UniqueFileDescriptor state_directory_descriptor;
    UniqueFileDescriptor resume_directory_descriptor;
    UniqueFileDescriptor part_files_directory_descriptor;
    UniqueFileDescriptor staging_directory_descriptor;
    UniqueFileDescriptor state_lock;
    std::uint64_t next_native_token TORRENT_BRIDGE_GUARDED_BY(resume_io_lock) = 1;
    std::vector<std::unique_ptr<TorrentIdentityToken>> identity_tokens TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    std::vector<std::unique_ptr<TorrentIdentity>> torrent_identities TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    std::vector<std::unique_ptr<TorrentIdentity>> retiring_torrent_identities TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    std::unordered_set<std::string> canonical_ids_in_use TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    std::atomic<std::size_t> identity_reclamation_blockers = 0;
    // Protected by resume_io_lock. Code that also needs client state acquires
    // lock before resume_io_lock.
    std::unordered_map<std::string, TorrentIdentity *> active_identity_by_id TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    std::unordered_map<std::string, TorrentIdentity *> removing_identity_by_id TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    std::unordered_map<std::uint64_t, lt::torrent_handle> handle_by_native_token TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    std::set<TorrentIdentity *> dht_disabled_by_app TORRENT_BRIDGE_GUARDED_BY(lock);
    std::set<TorrentIdentity *> peer_exchange_disabled_by_app TORRENT_BRIDGE_GUARDED_BY(lock);
    std::set<TorrentIdentity const *> metadata_validation_pending TORRENT_BRIDGE_GUARDED_BY(lock);
    std::set<TorrentIdentity *> lsd_disabled_by_app TORRENT_BRIDGE_GUARDED_BY(lock);
#if defined(TORRENT_BRIDGE_TESTING)
    std::size_t removal_tombstone_directory_scan_count TORRENT_BRIDGE_GUARDED_BY(resume_io_lock) = 0;
#endif
    std::set<TorrentIdentity *> unidentified_removing_identities TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    std::string persistence_fault_message TORRENT_BRIDGE_GUARDED_BY(resume_io_lock);
    DeferredSessionProxy deferred_session_shutdown;
    lt::session session;
    std::jthread alert_thread;
#if defined(TORRENT_BRIDGE_TESTING)
    bool fail_next_dht_diagnostics_poll TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    bool fail_next_source_policy_application TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    bool fail_next_source_policy_rollback TORRENT_BRIDGE_GUARDED_BY(lock) = false;
#endif
    bool persistence_faulted TORRENT_BRIDGE_GUARDED_BY(resume_io_lock) = false;
    bool requested_network_blocked TORRENT_BRIDGE_GUARDED_BY(lock) = true;
    bool source_policy_reconciled TORRENT_BRIDGE_GUARDED_BY(lock) = true;
    bool lsd_service_enabled TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    bool peer_exchange_plugin_enabled TORRENT_BRIDGE_GUARDED_BY(lock) = true;
    bool has_listener TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    int32_t listen_port TORRENT_BRIDGE_GUARDED_BY(lock) = 0;
    std::string listen_endpoint TORRENT_BRIDGE_GUARDED_BY(lock);
    std::string last_network_error TORRENT_BRIDGE_GUARDED_BY(lock);
    std::chrono::steady_clock::time_point last_dht_diagnostics_request TORRENT_BRIDGE_GUARDED_BY(lock);
    int32_t dht_routing_nodes TORRENT_BRIDGE_GUARDED_BY(lock) = 0;
    bool dht_diagnostics_request_pending TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    bool dht_routing_nodes_available TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    bool observed_dht_enabled TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    bool observed_dht_running TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    TTorrentBridgeHealth bridge_health TORRENT_BRIDGE_GUARDED_BY(lock){};
    std::vector<std::string> pending_alert_errors TORRENT_BRIDGE_GUARDED_BY(lock);
    std::size_t synchronous_adds_since_alert_drain TORRENT_BRIDGE_GUARDED_BY(lock) = 0U;
    // Owned, bounded handoff records between the native alert worker and the
    // Swift actor. Swift performs semantic coalescing and owns dirty state.
    std::vector<TTorrentEvent> pending_events TORRENT_BRIDGE_GUARDED_BY(lock);
    // Transient typed handoff only. Swift clears this by draining the event and
    // owns the durable fault latch, diagnostics, and recovery decision.
    std::uint32_t pending_critical_faults TORRENT_BRIDGE_GUARDED_BY(lock) = 0U;
    StoredWakeCallback wake_callback TORRENT_BRIDGE_GUARDED_BY(lock) = nullptr;
    StoredWakeContext wake_callback_context TORRENT_BRIDGE_GUARDED_BY(lock) = nullptr;
    int32_t wake_callbacks_in_flight TORRENT_BRIDGE_GUARDED_BY(lock) = 0;
    bool wake_pending TORRENT_BRIDGE_GUARDED_BY(lock) = false;
    std::condition_variable wake_callback_quiesced TORRENT_BRIDGE_GUARDED_BY(lock);
    std::condition_variable torrent_removal_quiesced TORRENT_BRIDGE_GUARDED_BY(lock);

    void start_alert_worker();

    void stop_alert_worker() noexcept;

    void record_synchronous_add_alert_locked() noexcept TORRENT_BRIDGE_REQUIRES(lock);

    void drain_synchronous_add_alerts_if_needed() noexcept
        TORRENT_BRIDGE_REQUIRES_NOT(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void alert_loop(std::stop_token const &stop_token)
        TORRENT_BRIDGE_REQUIRES_NOT(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] std::uint64_t record_alert_worker_failure(std::string_view error) noexcept
        TORRENT_BRIDGE_REQUIRES_NOT(lock);

    void record_alert_worker_recovery() noexcept TORRENT_BRIDGE_REQUIRES_NOT(lock);

    void set_wake_callback(TTorrentWakeCallback callback, void *context) TORRENT_BRIDGE_REQUIRES_NOT(lock);

    void clear_wake_callback() noexcept TORRENT_BRIDGE_REQUIRES_NOT(lock);

    int32_t drain_events(
        std::span<TTorrentEvent> output,
        int32_t *required_count_out,
        std::uint8_t *available_out
    ) noexcept TORRENT_BRIDGE_REQUIRES_NOT(lock);

    int32_t drain_presentation_metadata(
        std::span<TTorrentPresentationMetadata> output,
        int32_t *required_count_out,
        std::uint8_t *available_out
    ) noexcept TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] WakeCallbackInvocation publish_changes_locked(DirtyMask changes) noexcept
        TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] BridgeResult contain_network_for_critical_fault_locked(
        DirtyMask &changes
    ) TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask record_critical_fault_locked(std::uint32_t faults) noexcept
        TORRENT_BRIDGE_REQUIRES(lock);

    void complete_wake_callback() noexcept TORRENT_BRIDGE_REQUIRES_NOT(lock);

    void invoke_wake_callback(WakeCallbackInvocation const &wake) noexcept TORRENT_BRIDGE_REQUIRES_NOT(lock);

    [[nodiscard]] std::string reserve_canonical_torrent_id_locked(
        std::string canonical_id,
        bool allow_reuse_from_removing,
        int32_t *preserved_queue_rank_out = nullptr
    )
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    TorrentIdentity *make_identity(
        std::string canonical_id,
        bool allow_reuse_from_removing = false
    ) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    TorrentIdentity *attach_identity(
        lt::add_torrent_params &params,
        std::string canonical_id,
        bool allow_reuse_from_removing = false
    )
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] BridgeResult ensure_torrent_admission_available(int32_t code) const
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void queue_alert_error_threadsafe(std::string message) TORRENT_BRIDGE_REQUIRES_NOT(lock);

    void discard_unpublished_identity(TorrentIdentity *identity) noexcept
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    std::vector<std::string> removal_ids_for_identity(lt::info_hash_t const &hashes, std::string_view requested_id,
                                                      TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    bool remove_resume_file_locked(std::string_view filename) TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    ResumeRemoveResult remove_resume_file_checked_locked(std::string_view filename)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    void sync_resume_directory_quietly();

    ResumeRemoveResult remove_resume_temp_files_for_id_checked_locked(std::string const &id)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    ResumeRemoveResult remove_resume_files_for_id_checked_locked(std::string const &id)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    TombstoneEntriesResult scan_removal_tombstone_entries_locked(RemovalTombstoneIndexLimits limits)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    TombstoneEntriesResult removal_tombstone_entries_locked() TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    ResumeIDListResult tombstone_ids_overlapping_locked(std::vector<std::string> const &ids)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    TombstoneCommitResult persist_removal_tombstones_locked(std::vector<std::string> const &ids)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    ResumeSaveResult clear_removal_tombstones_locked(std::vector<std::string> const &ids)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    ResumeSaveResult complete_pending_removals()
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void remove_orphan_resume_temp_files() TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    // Called only while the client is being constructed, before the alert
    // worker or any external caller can observe the object.
    void load_resume_data() TORRENT_BRIDGE_NO_THREAD_SAFETY_ANALYSIS;

    [[nodiscard]] DirtyMask refresh_torrent_statuses()
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask mark_torrents_changed() noexcept;

    void request_snapshot_update() TORRENT_BRIDGE_REQUIRES_NOT(lock);

    void request_snapshot_update_locked() TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask observe_torrent_status(lt::torrent_status const &status)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask observe_torrent_handle(lt::torrent_handle const &handle)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask capture_requested_presentation_metadata(
        TorrentIdentity *identity,
        lt::add_torrent_params const &params
    ) TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask observe_torrent_statuses(std::vector<lt::torrent_status> const &statuses)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask mark_tracker_hosts_changed() noexcept;

    [[nodiscard]] DirtyMask mark_trackers_changed() noexcept;

    [[nodiscard]] DirtyMask mark_web_seeds_changed() noexcept;

    [[nodiscard]] DirtyMask mark_files_changed() noexcept;

    [[nodiscard]] DirtyMask mark_piece_map_changed() noexcept;

    [[nodiscard]] DirtyMask observe_trackers(lt::torrent_handle const &handle)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask remove_torrent_with_invalid_metadata(lt::torrent_handle const &handle, std::string const &reason)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask enforce_https_source_policy(
        lt::torrent_handle const &handle,
        TorrentIdentity *identity,
        HTTPSSourcePolicyScope scope,
        HTTPSSourcePolicy policy
    )
        TORRENT_BRIDGE_REQUIRES(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask restore_metadata_source_policy(
        lt::torrent_handle const &handle,
        TorrentIdentity *identity,
        HTTPSSourcePolicyScope scope,
        HTTPSSourcePolicy policy
    )
        TORRENT_BRIDGE_REQUIRES(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask clear_peer_cache_if_restricted(
        lt::torrent_handle handle,
        TorrentIdentity *identity
    ) TORRENT_BRIDGE_REQUIRES(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    static bool conflict_participant_is_preferred(TorrentIdentity const *candidate, TorrentIdentity const *other) noexcept;

    [[nodiscard]] DirtyMask resolve_torrent_conflict(
        lt::torrent_conflict_alert const &conflict,
        std::vector<PendingResumeHandle> &forced_resume_handles
    ) TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] BridgeResult validate_or_remove_loaded_metadata(lt::torrent_handle const &handle, DirtyMask &changes)
        TORRENT_BRIDGE_REQUIRES(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void validate_pending_metadata(DirtyMask &changes)
        TORRENT_BRIDGE_REQUIRES(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    int32_t copy_trackers(
        std::uint64_t native_token,
        std::span<TTorrentTrackerSnapshot> output,
        int32_t *required_count_out,
        std::uint8_t *available_out
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    int32_t copy_web_seeds(
        std::uint64_t native_token,
        std::span<TTorrentWebSeedSnapshot> output,
        int32_t *required_count_out,
        std::uint8_t *available_out
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    bool copy_web_seed_activity(
        std::uint64_t native_token,
        TTorrentWebSeedActivitySnapshot *activity_out
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    bool copy_peer_sources(
        std::uint64_t native_token,
        TTorrentPeerSourceSnapshot *sources_out
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    int32_t copy_files(
        std::uint64_t native_token,
        std::span<TTorrentFileSnapshot> output,
        int32_t *required_count_out,
        std::uint8_t *available_out
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    int32_t copy_piece_map(
        std::uint64_t native_token,
        TTorrentPieceMapSnapshot *snapshot,
        std::span<std::uint8_t> output,
        int32_t *required_count_out,
        std::uint8_t *available_out
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask mark_torrent_removed(lt::info_hash_t const &hashes, std::string_view requested_id)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    int32_t copy_snapshots(std::span<TTorrentSnapshot> output, int32_t *required_count_out)
        TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    int32_t copy_tracker_hosts(
        std::span<TTorrentTrackerHostSnapshot> output,
        int32_t *required_count_out,
        std::uint8_t *available_out
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] DirtyMask queue_alert_error(std::string message) TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask record_listen_failed(lt::listen_failed_alert const &alert) TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask record_listen_succeeded(lt::listen_succeeded_alert const &alert) TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask record_network_requested(bool blocked) TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask record_network_blocked() TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask cache_dht_diagnostics(lt::session_stats_alert const &alert)
        TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] DirtyMask invalidate_dht_diagnostics() noexcept TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] TTorrentNetworkStatus network_status() noexcept TORRENT_BRIDGE_REQUIRES(lock);

    [[nodiscard]] TTorrentBridgeHealth health_status() const noexcept TORRENT_BRIDGE_REQUIRES(lock);

    bool take_alert_error(std::span<char> output) TORRENT_BRIDGE_REQUIRES_NOT(lock);

    [[nodiscard]] BridgeResult ensure_persistence_available(int32_t code) const
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] BridgeResult ensure_persistence_available_locked(int32_t code) const
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    [[nodiscard]] bool persistence_is_faulted() const TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] bool persistence_is_faulted_locked() const noexcept TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    [[nodiscard]] BridgeResult fault_persistence_locked(int32_t code, std::string message)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    void pause_session_for_persistence_fault();

    [[nodiscard]] BridgeResult fault_persistence(int32_t code, std::string message)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] BridgeResult fault_persistence_and_pause_locked(int32_t code, std::string message)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    [[nodiscard]] BridgeResult cancel_tombstoned_operation_or_fault(
        std::vector<std::string> const &ids,
        int32_t code,
        std::string operation_error
    ) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    bool identity_is_referenced_locked(TorrentIdentity const *identity) const
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    void retire_identity_if_unreferenced_locked(TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES(lock, resume_io_lock);

    void reclaim_retired_identities() noexcept TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    TorrentIdentityState reconcile_identity_for_hashes_locked(std::vector<std::string> const &ids, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    TorrentIdentityState identity_state_for_status(std::vector<std::string> const &ids, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    bool reconcile_current_for_write_locked(lt::info_hash_t const &hashes, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    void mark_active(lt::torrent_handle const &handle, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void mark_active(lt::info_hash_t const &hashes, lt::torrent_handle const &handle, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void remember_native_handle(lt::torrent_handle const &handle, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void mark_unidentified_remove_requested(TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] bool rollback_added_torrent_without_hashes(
        lt::torrent_handle const &handle,
        TorrentIdentity *identity,
        DirtyMask &changes
    ) TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] bool rollback_added_torrent(
        lt::torrent_handle const &handle,
        lt::info_hash_t const &hashes,
        TorrentIdentity *identity,
        std::vector<std::string> const &resume_ids,
        bool publish_tombstone,
        DirtyMask &changes
    ) TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void mark_remove_requested(lt::info_hash_t const &hashes, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void mark_conflict_remove_requested(lt::info_hash_t const &hashes, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    bool accepts_removed_alert(lt::info_hash_t const &hashes, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void finalize_removed(lt::info_hash_t const &hashes, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    [[nodiscard]] bool wait_for_torrent_removal(
        TorrentIdentityToken const *token,
        std::chrono::milliseconds timeout
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    bool resume_write_is_current(lt::info_hash_t const &hashes, TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumePolicySnapshot resume_policy_snapshot_locked(TorrentIdentity *identity) const
        TORRENT_BRIDGE_REQUIRES(lock);

    ResumeSaveResult perform_resume_cleanups_locked(std::vector<PendingResumeCleanup> const &cleanups)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    ResumeSaveResult complete_resume_cleanups_locked(PendingEncodedResumeWrite const &write)
        TORRENT_BRIDGE_REQUIRES(resume_io_lock);

    ResumeSaveResult commit_encoded_resume_data_checked(PendingEncodedResumeWrite write)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumeSaveResult write_resume_data_checked(lt::add_torrent_params const &params, TorrentIdentity *identity,
                                               ResumePolicySnapshot const &policy,
                                               std::vector<PendingResumeCleanup> cleanups)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumeSaveResult write_resume_data(PendingResumeWrite const &write)
        TORRENT_BRIDGE_REQUIRES_NOT(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumeSaveResult save_added_torrent_resume_data(lt::add_torrent_params params, lt::info_hash_t const &hashes,
                                                    TorrentIdentity *identity)
        TORRENT_BRIDGE_REQUIRES(lock) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumeSaveResult remove_obsolete_tombstoned_resume_data_for_readd(std::vector<std::string> const &resume_ids)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void request_save_locked(lt::torrent_handle const &handle,
                             lt::resume_data_flags_t flags = kRoutineResumeSaveFlags)
        TORRENT_BRIDGE_REQUIRES(lock);

    void request_save(lt::torrent_handle const &handle,
                      lt::resume_data_flags_t flags = kRoutineResumeSaveFlags)
        TORRENT_BRIDGE_REQUIRES_NOT(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void request_resume_retry()
        TORRENT_BRIDGE_REQUIRES_NOT(lock);

    BridgeResult save_resume_data_checked(
        std::uint64_t native_token,
        ResumeSaveMode save_mode
    ) TORRENT_BRIDGE_REQUIRES_NOT(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    std::vector<lt::torrent_handle> collect_torrent_handles();

    void request_periodic_resume_saves()
        TORRENT_BRIDGE_REQUIRES_NOT(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    std::vector<PendingResumeHandle> collect_resume_handles() TORRENT_BRIDGE_REQUIRES(lock);

    std::vector<PendingResumeWrite> collect_resume_data(
        std::span<PendingResumeHandle const> handles,
        lt::resume_data_flags_t flags
    ) TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void save_all()
        TORRENT_BRIDGE_REQUIRES_NOT(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    void pump_alerts()
        TORRENT_BRIDGE_REQUIRES_NOT(lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_capture_lock)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    std::optional<lt::torrent_handle> find(std::uint64_t native_token) TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumeSaveResult remove_resume_files_for_ids_checked(std::vector<std::string> const &ids)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    BridgeResult persist_removal_tombstones(std::vector<std::string> const &ids)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumeIDListResult tombstone_ids_overlapping(std::vector<std::string> const &ids)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumeSaveResult clear_removal_tombstones(std::vector<std::string> const &ids)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);

    ResumeSaveResult clear_removal_tombstone_file(std::string_view filename)
        TORRENT_BRIDGE_REQUIRES_NOT(resume_io_lock);
};

class UnpublishedIdentityGuard final {
public:
    UnpublishedIdentityGuard(TTorrentClient &client, TorrentIdentity *identity) noexcept
        : client_(client)
        , identity_(identity)
    {
    }

    ~UnpublishedIdentityGuard() noexcept
    {
        if (identity_ != nullptr) {
            client_.discard_unpublished_identity(identity_);
        }
    }

    UnpublishedIdentityGuard(UnpublishedIdentityGuard const &) = delete;
    UnpublishedIdentityGuard &operator=(UnpublishedIdentityGuard const &) = delete;
    UnpublishedIdentityGuard(UnpublishedIdentityGuard &&) = delete;
    UnpublishedIdentityGuard &operator=(UnpublishedIdentityGuard &&) = delete;

    void release() noexcept
    {
        identity_ = nullptr;
    }

private:
    TTorrentClient &client_;
    TorrentIdentity *identity_;
};

class IdentityReclamationBlock final {
public:
    explicit IdentityReclamationBlock(TTorrentClient &client) noexcept
        : client_(client)
    {
        client_.identity_reclamation_blockers.fetch_add(1U, std::memory_order_acq_rel);
    }

    ~IdentityReclamationBlock() noexcept
    {
        if (client_.identity_reclamation_blockers.fetch_sub(1U, std::memory_order_acq_rel) == 1U) {
            client_.reclaim_retired_identities();
        }
    }

    IdentityReclamationBlock(IdentityReclamationBlock const &) = delete;
    IdentityReclamationBlock &operator=(IdentityReclamationBlock const &) = delete;
    IdentityReclamationBlock(IdentityReclamationBlock &&) = delete;
    IdentityReclamationBlock &operator=(IdentityReclamationBlock &&) = delete;

private:
    TTorrentClient &client_;
};

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

} // namespace torrent_bridge::internal

#endif
