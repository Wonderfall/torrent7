#ifndef TORRENT_BRIDGE_H
#define TORRENT_BRIDGE_H

#include <stdint.h>

// The public declarations carry ABI-neutral bounds and lifetime metadata for
// Swift's safe interop importer. Definitions use conventional C pointer types
// so the implementation can include third-party C++ headers without enabling
// their unrelated experimental bounds contracts.
#if defined(TORRENT_BRIDGE_IMPLEMENTATION)
#define TORRENT_BRIDGE_COUNTED_BY(count)
#define TORRENT_BRIDGE_NOESCAPE
#define TORRENT_BRIDGE_NONNULL
#define TORRENT_BRIDGE_NULLABLE
#define TORRENT_BRIDGE_NULL_TERMINATED
#else
#define TORRENT_BRIDGE_NONNULL _Nonnull
#define TORRENT_BRIDGE_NULLABLE _Nullable

#if __has_include(<lifetimebound.h>)
#include <lifetimebound.h>
#define TORRENT_BRIDGE_NOESCAPE __noescape
#elif __has_attribute(noescape)
#define TORRENT_BRIDGE_NOESCAPE __attribute__((noescape))
#else
#define TORRENT_BRIDGE_NOESCAPE
#endif

#if __has_include(<ptrcheck.h>)
#include <ptrcheck.h>
#define TORRENT_BRIDGE_COUNTED_BY(count) __counted_by(count)
#define TORRENT_BRIDGE_NULL_TERMINATED __null_terminated
#else
#define TORRENT_BRIDGE_COUNTED_BY(count)
#define TORRENT_BRIDGE_NULL_TERMINATED
#endif
#endif

#ifdef __cplusplus
#define TORRENT_BRIDGE_NOEXCEPT noexcept
inline constexpr int32_t TTORRENT_BRIDGE_STATE_UNKNOWN = -1;
inline constexpr int32_t TTORRENT_BRIDGE_STATE_CHECKING_FILES = 1;
inline constexpr int32_t TTORRENT_BRIDGE_STATE_DOWNLOADING_METADATA = 2;
inline constexpr int32_t TTORRENT_BRIDGE_STATE_DOWNLOADING = 3;
inline constexpr int32_t TTORRENT_BRIDGE_STATE_FINISHED = 4;
inline constexpr int32_t TTORRENT_BRIDGE_STATE_SEEDING = 5;
inline constexpr int32_t TTORRENT_BRIDGE_STATE_CHECKING_RESUME_DATA = 7;
inline constexpr int32_t TTORRENT_MAX_FILE_COUNT = 20000;
inline constexpr int32_t TTORRENT_MAX_TRACKER_COUNT = 2000;
inline constexpr int32_t TTORRENT_MAX_WEB_SEED_COUNT = 2000;
inline constexpr int32_t TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT = 20000;
inline constexpr int32_t TTORRENT_MAX_TRACKER_HOST_ROW_COUNT = 20000;
// Each live root authority holds several descriptors. Cap current and
// torrent-retained historical roots together so a standard 256-FD XPC process
// retains meaningful headroom for torrent files, sockets, and state.
inline constexpr int32_t TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT = 32;
inline constexpr int32_t TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES = 1023;
inline constexpr int32_t TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES = 32768;
inline constexpr int32_t TTORRENT_MAX_NETWORK_INTERFACE_BYTES = 64;
inline constexpr int32_t TTORRENT_ERROR_AUTHORIZED_SAVE_ROOT_CAPACITY = 4;
inline constexpr int32_t TTORRENT_ID_CAPACITY = 68;
inline constexpr int32_t TTORRENT_TRACKER_HOST_CAPACITY = 256;
inline constexpr uint32_t TTORRENT_DIRTY_TORRENTS = 1U << 0U;
inline constexpr uint32_t TTORRENT_DIRTY_TRACKERS = 1U << 1U;
inline constexpr uint32_t TTORRENT_DIRTY_WEB_SEEDS = 1U << 2U;
inline constexpr uint32_t TTORRENT_DIRTY_FILES = 1U << 3U;
inline constexpr uint32_t TTORRENT_DIRTY_NETWORK = 1U << 4U;
inline constexpr uint32_t TTORRENT_DIRTY_ERRORS = 1U << 5U;
inline constexpr uint32_t TTORRENT_DIRTY_PIECES = 1U << 6U;
inline constexpr uint32_t TTORRENT_DIRTY_TRACKER_HOSTS = 1U << 7U;
inline constexpr uint32_t TTORRENT_DIRTY_HEALTH = 1U << 8U;
inline constexpr int32_t TTORRENT_MAX_PIECE_MAP_COUNT = 0x200000;
inline constexpr int32_t TTORRENT_QUEUE_PRIORITY_LOW = 0;
inline constexpr int32_t TTORRENT_QUEUE_PRIORITY_NORMAL = 1;
inline constexpr int32_t TTORRENT_QUEUE_PRIORITY_HIGH = 2;
inline constexpr int32_t TTORRENT_FILE_PRIORITY_SKIP = 0;
inline constexpr int32_t TTORRENT_FILE_PRIORITY_LOW = 1;
inline constexpr int32_t TTORRENT_FILE_PRIORITY_NORMAL = 4;
inline constexpr int32_t TTORRENT_FILE_PRIORITY_HIGH = 7;
inline constexpr int32_t TTORRENT_QUEUE_MOVE_TOP = 0;
inline constexpr int32_t TTORRENT_QUEUE_MOVE_UP = 1;
inline constexpr int32_t TTORRENT_QUEUE_MOVE_DOWN = 2;
inline constexpr int32_t TTORRENT_QUEUE_MOVE_BOTTOM = 3;
inline constexpr int32_t TTORRENT_ADD_REJECTED = 0;
inline constexpr int32_t TTORRENT_ADD_COMMITTED = 1;
inline constexpr int32_t TTORRENT_ADD_OUTCOME_UNKNOWN = 2;
inline constexpr int32_t TTORRENT_REMOVAL_PENDING = 0;
inline constexpr int32_t TTORRENT_REMOVAL_SUCCEEDED = 1;
inline constexpr int32_t TTORRENT_REMOVAL_FAILED = 2;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_ENABLE_DHT = 0;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE = 1;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_ENABLE_LSD = 2;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY = 3;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY = 4;
inline constexpr int32_t TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT = 5;
inline constexpr uint8_t TTORRENT_HTTPS_POLICY_INHERIT = 0;
inline constexpr uint8_t TTORRENT_HTTPS_POLICY_ORIGINAL = 1;
inline constexpr uint8_t TTORRENT_HTTPS_POLICY_PREFER = 2;
inline constexpr uint8_t TTORRENT_HTTPS_POLICY_REQUIRE = 3;
inline constexpr uint8_t TTORRENT_DHT_DISCOVERY_ALONGSIDE_TRACKERS = 0;
inline constexpr uint8_t TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL = 1;
inline constexpr uint8_t TTORRENT_DHT_STATUS_DISABLED = 0;
inline constexpr uint8_t TTORRENT_DHT_STATUS_STARTING = 1;
inline constexpr uint8_t TTORRENT_DHT_STATUS_RUNNING = 2;
inline constexpr uint8_t TTORRENT_CONTENT_KIND_UNKNOWN = 0;
inline constexpr uint8_t TTORRENT_CONTENT_KIND_SINGLE_FILE = 1;
inline constexpr uint8_t TTORRENT_CONTENT_KIND_DIRECTORY = 2;
inline constexpr uint32_t TTORRENT_BRIDGE_ABI_VERSION = 44;
namespace torrent_bridge::internal {
struct TTorrentClient;
}
using TTorrentClient = torrent_bridge::internal::TTorrentClient;
extern "C" {
#else
#define TORRENT_BRIDGE_NOEXCEPT
enum {
    TTORRENT_BRIDGE_STATE_UNKNOWN = -1,
    TTORRENT_BRIDGE_STATE_CHECKING_FILES = 1,
    TTORRENT_BRIDGE_STATE_DOWNLOADING_METADATA = 2,
    TTORRENT_BRIDGE_STATE_DOWNLOADING = 3,
    TTORRENT_BRIDGE_STATE_FINISHED = 4,
    TTORRENT_BRIDGE_STATE_SEEDING = 5,
    TTORRENT_BRIDGE_STATE_CHECKING_RESUME_DATA = 7,
    TTORRENT_MAX_FILE_COUNT = 20000,
    TTORRENT_MAX_TRACKER_COUNT = 2000,
    TTORRENT_MAX_WEB_SEED_COUNT = 2000,
    TTORRENT_MAX_TORRENT_SNAPSHOT_COUNT = 20000,
    TTORRENT_MAX_TRACKER_HOST_ROW_COUNT = 20000,
    TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT = 32,
    TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES = 1023,
    TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES = 32768,
    TTORRENT_MAX_NETWORK_INTERFACE_BYTES = 64,
    TTORRENT_ERROR_AUTHORIZED_SAVE_ROOT_CAPACITY = 4,
    TTORRENT_ID_CAPACITY = 68,
    TTORRENT_TRACKER_HOST_CAPACITY = 256,
    TTORRENT_DIRTY_TORRENTS = 1U << 0U,
    TTORRENT_DIRTY_TRACKERS = 1U << 1U,
    TTORRENT_DIRTY_WEB_SEEDS = 1U << 2U,
    TTORRENT_DIRTY_FILES = 1U << 3U,
    TTORRENT_DIRTY_NETWORK = 1U << 4U,
    TTORRENT_DIRTY_ERRORS = 1U << 5U,
    TTORRENT_DIRTY_PIECES = 1U << 6U,
    TTORRENT_DIRTY_TRACKER_HOSTS = 1U << 7U,
    TTORRENT_DIRTY_HEALTH = 1U << 8U,
    TTORRENT_MAX_PIECE_MAP_COUNT = 0x200000,
    TTORRENT_QUEUE_PRIORITY_LOW = 0,
    TTORRENT_QUEUE_PRIORITY_NORMAL = 1,
    TTORRENT_QUEUE_PRIORITY_HIGH = 2,
    TTORRENT_FILE_PRIORITY_SKIP = 0,
    TTORRENT_FILE_PRIORITY_LOW = 1,
    TTORRENT_FILE_PRIORITY_NORMAL = 4,
    TTORRENT_FILE_PRIORITY_HIGH = 7,
    TTORRENT_QUEUE_MOVE_TOP = 0,
    TTORRENT_QUEUE_MOVE_UP = 1,
    TTORRENT_QUEUE_MOVE_DOWN = 2,
    TTORRENT_QUEUE_MOVE_BOTTOM = 3,
    TTORRENT_ADD_REJECTED = 0,
    TTORRENT_ADD_COMMITTED = 1,
    TTORRENT_ADD_OUTCOME_UNKNOWN = 2,
    TTORRENT_REMOVAL_PENDING = 0,
    TTORRENT_REMOVAL_SUCCEEDED = 1,
    TTORRENT_REMOVAL_FAILED = 2,
    TTORRENT_SOURCE_POLICY_ENABLE_DHT = 0,
    TTORRENT_SOURCE_POLICY_ENABLE_PEER_EXCHANGE = 1,
    TTORRENT_SOURCE_POLICY_ENABLE_LSD = 2,
    TTORRENT_SOURCE_POLICY_HTTPS_TRACKER_POLICY = 3,
    TTORRENT_SOURCE_POLICY_HTTPS_WEB_SEED_POLICY = 4,
    TTORRENT_SOURCE_POLICY_ALLOW_PRE_METADATA_DHT = 5,
    TTORRENT_HTTPS_POLICY_INHERIT = 0,
    TTORRENT_HTTPS_POLICY_ORIGINAL = 1,
    TTORRENT_HTTPS_POLICY_PREFER = 2,
    TTORRENT_HTTPS_POLICY_REQUIRE = 3,
    TTORRENT_DHT_DISCOVERY_ALONGSIDE_TRACKERS = 0,
    TTORRENT_DHT_DISCOVERY_AFTER_ALL_TRACKERS_FAIL = 1,
    TTORRENT_DHT_STATUS_DISABLED = 0,
    TTORRENT_DHT_STATUS_STARTING = 1,
    TTORRENT_DHT_STATUS_RUNNING = 2,
    TTORRENT_CONTENT_KIND_UNKNOWN = 0,
    TTORRENT_CONTENT_KIND_SINGLE_FILE = 1,
    TTORRENT_CONTENT_KIND_DIRECTORY = 2,
    TTORRENT_BRIDGE_ABI_VERSION = 44
};
#endif

#ifndef __cplusplus
typedef struct TTorrentClient TTorrentClient;
#endif
typedef void (* TORRENT_BRIDGE_NULLABLE TTorrentWakeCallback)(void * TORRENT_BRIDGE_NULLABLE context);

typedef struct TTorrentSnapshot {
    char id[68];
    char info_hash[68];
    char name[512];
    char save_path[1024];
    char error[512];
    char comment[1024];
    double progress;
    int64_t total_done;
    int64_t total_wanted;
    int64_t total_size;
    int64_t total_upload;
    int64_t total_download;
    int64_t total_payload_upload;
    int64_t total_payload_download;
    int64_t all_time_upload;
    int64_t all_time_download;
    int64_t added_time;
    int64_t created_time;
    int64_t completed_time;
    int32_t download_rate;
    int32_t upload_rate;
    int32_t download_payload_rate;
    int32_t upload_payload_rate;
    int32_t peers;
    int32_t known_peers;
    int32_t seeds;
    int32_t state;
    int32_t queue_position;
    int32_t queue_priority;
    uint8_t paused;
    uint8_t auto_managed;
    uint8_t seeding;
    uint8_t finished;
    uint8_t has_metadata;
    uint8_t private_torrent;
    uint8_t content_kind;
} TTorrentSnapshot;

typedef struct TTorrentTrackerSnapshot {
    char url[1024];
    char message[512];
    int32_t tier;
    int32_t fail_count;
    int32_t scrape_seeders;
    int32_t scrape_leechers;
    int32_t scrape_downloaded;
    uint8_t updating;
    uint8_t verified;
    uint8_t has_error;
    uint8_t enabled;
} TTorrentTrackerSnapshot;

typedef struct TTorrentTrackerHostSnapshot {
    char torrent_id[68];
    char host[256];
} TTorrentTrackerHostSnapshot;

typedef struct TTorrentWebSeedSnapshot {
    char url[1024];
} TTorrentWebSeedSnapshot;

typedef struct TTorrentWebSeedActivitySnapshot {
    int32_t active_count;
    int32_t download_rate;
    int64_t total_download;
} TTorrentWebSeedActivitySnapshot;

typedef struct TTorrentPeerSourceSnapshot {
    int32_t connected;
    int32_t tracker;
    int32_t dht;
    int32_t peer_exchange;
    int32_t local_service_discovery;
    int32_t resume_data;
    int32_t incoming;
    int32_t web_seed;
    int32_t other;
} TTorrentPeerSourceSnapshot;

typedef struct TTorrentFileSnapshot {
    char path[1024];
    int64_t size;
    int64_t downloaded;
    double progress;
    int32_t index;
    int32_t priority;
    uint8_t pad_file;
} TTorrentFileSnapshot;

typedef struct TTorrentFilePriorityEntry {
    int32_t index;
    int32_t priority;
} TTorrentFilePriorityEntry;

typedef struct TTorrentRemovalResult {
    int32_t state;
    char error[512];
} TTorrentRemovalResult;

typedef struct TTorrentPieceMapSnapshot {
    int32_t total_pieces;
    int32_t completed_pieces;
    int32_t available_pieces;
    uint8_t map_available;
    uint8_t map_truncated;
} TTorrentPieceMapSnapshot;

typedef struct TTorrentFilePreview {
    char name[512];
    char id[68];
    int64_t total_size;
    int32_t file_count;
    int32_t tracker_count;
    int32_t https_tracker_count;
    int32_t web_seed_count;
    int32_t https_web_seed_count;
} TTorrentFilePreview;

typedef struct TTorrentSourceSecurityInspection {
    int32_t tracker_count;
    int32_t https_tracker_count;
    int32_t web_seed_count;
    int32_t https_web_seed_count;
} TTorrentSourceSecurityInspection;

typedef struct TTorrentSessionSettings {
    int32_t download_rate_limit;
    int32_t upload_rate_limit;
    int32_t active_downloads;
    int32_t active_seeds;
    int32_t active_limit;
    int32_t share_ratio_limit;
    int32_t seed_time_limit;
    int32_t incoming_port;
    uint8_t accept_incoming_connections;
    uint8_t enable_port_forwarding;
    uint8_t enable_dht;
    uint8_t use_dht_by_default;
    uint8_t dht_read_only;
    uint8_t enable_lsd;
    uint8_t use_lsd_by_default;
    uint8_t use_pex_by_default;
    uint8_t https_tracker_policy;
    uint8_t https_web_seed_policy;
    int32_t encryption_policy;
    uint8_t anonymous_mode;
    uint8_t network_blocked;
    uint8_t dht_discovery_policy;
} TTorrentSessionSettings;

typedef struct TTorrentNetworkStatus {
    uint64_t requested_revision;
    uint64_t submitted_revision;
    int32_t listen_port;
    uint8_t network_blocked;
    uint8_t has_listener;
    char endpoint[128];
    char last_error[512];
    int32_t dht_routing_nodes;
    uint8_t dht_status;
} TTorrentNetworkStatus;

typedef struct TTorrentBridgeHealth {
    uint64_t total_alert_worker_failures;
    uint64_t consecutive_alert_worker_failures;
    uint8_t alert_worker_degraded;
    char last_alert_worker_error[512];
} TTorrentBridgeHealth;

typedef struct TTorrentSourcePolicy {
    uint8_t enable_dht;
    uint8_t enable_peer_exchange;
    uint8_t enable_lsd;
    uint8_t https_tracker_policy;
    uint8_t https_web_seed_policy;
    uint8_t effective_https_tracker_policy;
    uint8_t effective_https_web_seed_policy;
    uint8_t dht_locked;
    uint8_t peer_exchange_locked;
    uint8_t lsd_locked;
    uint8_t metadata_validation_pending;
    uint8_t allow_pre_metadata_dht;
} TTorrentSourcePolicy;

typedef struct TTorrentAddOptions {
    uint8_t starts_paused;
    uint8_t queue_priority;
    uint8_t enable_peer_exchange;
    uint8_t https_tracker_policy;
    uint8_t https_web_seed_policy;
    uint8_t allow_pre_metadata_dht;
} TTorrentAddOptions;

typedef struct TTorrentOptions {
    int32_t download_rate_limit;
    int32_t upload_rate_limit;
    int32_t max_uploads;
    int32_t max_connections;
    int32_t queue_priority;
} TTorrentOptions;

typedef struct TTorrentSourceSecurityInspectionResult {
    int32_t status;
    TTorrentSourceSecurityInspection inspection;
} TTorrentSourceSecurityInspectionResult;

typedef struct TTorrentSourcePolicyResult {
    int32_t status;
    TTorrentSourcePolicy policy;
} TTorrentSourcePolicyResult;

typedef struct TTorrentOptionsResult {
    int32_t status;
    TTorrentOptions options;
} TTorrentOptionsResult;

typedef struct TTorrentWebSeedActivityResult {
    int32_t status;
    uint64_t revision;
    TTorrentWebSeedActivitySnapshot activity;
} TTorrentWebSeedActivityResult;

typedef struct TTorrentPeerSourcesResult {
    int32_t status;
    uint64_t revision;
    TTorrentPeerSourceSnapshot sources;
} TTorrentPeerSourcesResult;

typedef struct TTorrentRemovalReadResult {
    int32_t status;
    TTorrentRemovalResult result;
} TTorrentRemovalReadResult;

typedef struct TTorrentNetworkStatusResult {
    int32_t status;
    TTorrentNetworkStatus network_status;
} TTorrentNetworkStatusResult;

typedef struct TTorrentBridgeHealthResult {
    int32_t status;
    TTorrentBridgeHealth health;
} TTorrentBridgeHealthResult;

typedef uint8_t (* TORRENT_BRIDGE_NULLABLE TTorrentAuthorizedRootLifetimeRetainCallback)(uint64_t token);
typedef void (* TORRENT_BRIDGE_NULLABLE TTorrentAuthorizedRootLifetimeReleaseCallback)(uint64_t token);

// A borrowed, descriptor-backed directory capability corresponding one-to-one
// with a path in the authorized-save-path blob. The bridge validates the
// descriptor, identity, and current canonical pathname, then duplicates the
// descriptor and validates and retains lifetime_token before returning. Input
// records must remain valid for the synchronous bridge call. Tokens must be
// unguessable, process-local capabilities owned by the callback registry.
// Callbacks must be thread-safe, non-throwing, and must not reenter
// TorrentBridge. The retain callback returns nonzero only for a live token.
// Every successful retain is balanced by one release; release may run on a
// libtorrent worker or detached-shutdown thread before blocking client
// destruction has completed.
typedef struct TTorrentAuthorizedSaveRoot {
    int32_t directory_descriptor;
    uint64_t device;
    uint64_t inode;
    uint64_t lifetime_token;
} TTorrentAuthorizedSaveRoot;

const char * TORRENT_BRIDGE_NONNULL TORRENT_BRIDGE_NULL_TERMINATED TorrentBridgeLibtorrentVersion(void)
    TORRENT_BRIDGE_NOEXCEPT;

// Parses and sanitizes the magnet with the same native path used by add.
// result.status is 0 only when all sources are valid and within the bridge
// limits; the inspection is zeroed on failure.
TTorrentSourceSecurityInspectionResult TorrentBridgeInspectMagnetSources(
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED magnet_uri TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

// Returns an owned client handle. Release it exactly once with TorrentClientDestroy.
// authorized_save_paths_blob is a bounded sequence of non-empty, absolute UTF-8
// paths, each terminated by NUL. authorized_save_roots contains one matching
// descriptor-backed capability per path in the same order. Pass NULL/0 for both
// collections to deny all resume restoration. Pointer/count mismatches,
// malformed records, and identity mismatches fail creation atomically.
TTorrentClient * TORRENT_BRIDGE_NULLABLE TorrentClientCreateWithError(
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED state_path TORRENT_BRIDGE_NOESCAPE,
    uint8_t enable_pex_plugin,
    const uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(authorized_save_paths_blob_size)
        authorized_save_paths_blob TORRENT_BRIDGE_NOESCAPE,
    int32_t authorized_save_paths_blob_size,
    const TTorrentAuthorizedSaveRoot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(authorized_save_root_count)
        authorized_save_roots TORRENT_BRIDGE_NOESCAPE,
    int32_t authorized_save_root_count,
    TTorrentAuthorizedRootLifetimeRetainCallback retain_authorized_root,
    TTorrentAuthorizedRootLifetimeReleaseCallback release_authorized_root,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Atomically replaces the exact normalized save paths accepted by subsequent
// live add operations. This does not alter already-active torrents or rerun
// startup resume restoration. The path and root collections have the same
// bounded format, ordering, and pointer/count rules as
// TorrentClientCreateWithError; pass NULL/0 for both collections to deny all
// subsequent live adds. Returns
// TTORRENT_ERROR_AUTHORIZED_SAVE_ROOT_CAPACITY without changing the current
// roots if active torrents retain too many historical root generations.
int32_t TorrentClientReplaceAuthorizedSavePaths(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(authorized_save_paths_blob_size)
        authorized_save_paths_blob TORRENT_BRIDGE_NOESCAPE,
    int32_t authorized_save_paths_blob_size,
    const TTorrentAuthorizedSaveRoot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(authorized_save_root_count)
        authorized_save_roots TORRENT_BRIDGE_NOESCAPE,
    int32_t authorized_save_root_count,
    TTorrentAuthorizedRootLifetimeRetainCallback retain_authorized_root,
    TTorrentAuthorizedRootLifetimeReleaseCallback release_authorized_root,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Consumes a client handle returned by TorrentClientCreateWithError. Passing NULL is allowed.
// No other bridge call may race with destruction of the same client.
void TorrentClientDestroy(TTorrentClient * TORRENT_BRIDGE_NULLABLE client) TORRENT_BRIDGE_NOEXCEPT;

// Like TorrentClientDestroy, but waits for libtorrent's shutdown proxy before returning.
void TorrentClientDestroyBlocking(TTorrentClient * TORRENT_BRIDGE_NULLABLE client) TORRENT_BRIDGE_NOEXCEPT;

// The wake callback is invoked outside the client lock and remains installed until
// client destruction. It must not destroy the client from inside the callback.
void TorrentClientSetWakeCallback(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentWakeCallback callback,
    void * TORRENT_BRIDGE_NULLABLE context
) TORRENT_BRIDGE_NOEXCEPT;

uint64_t TorrentClientTakeChanges(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint32_t * TORRENT_BRIDGE_NULLABLE dirty_mask_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

// add_outcome_out is mandatory. It reports REJECTED until the native add can
// have committed, OUTCOME_UNKNOWN while libtorrent acceptance or rollback is
// not yet proven, and COMMITTED only after every bridge invariant and durable
// bookkeeping step succeeds. A failed call may therefore be distinguished as
// a definite rejection or a commit-ambiguous failure without replaying it.
int32_t TorrentClientAddMagnet(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED magnet_uri TORRENT_BRIDGE_NOESCAPE,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED save_path TORRENT_BRIDGE_NOESCAPE,
    TTorrentAddOptions options,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(added_id_capacity) added_id_out TORRENT_BRIDGE_NOESCAPE,
    int32_t added_id_capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE add_outcome_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientAddTorrentFileData(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(torrent_data_size)
        torrent_data TORRENT_BRIDGE_NOESCAPE,
    int32_t torrent_data_size,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED save_path TORRENT_BRIDGE_NOESCAPE,
    TTorrentAddOptions options,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(added_id_capacity) added_id_out TORRENT_BRIDGE_NOESCAPE,
    int32_t added_id_capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE add_outcome_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientAddTorrentFileDataWithPriorities(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(torrent_data_size)
        torrent_data TORRENT_BRIDGE_NOESCAPE,
    int32_t torrent_data_size,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED save_path TORRENT_BRIDGE_NOESCAPE,
    TTorrentAddOptions options,
    const TTorrentFilePriorityEntry * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(file_priority_count)
        file_priorities TORRENT_BRIDGE_NOESCAPE,
    int32_t file_priority_count,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(added_id_capacity) added_id_out TORRENT_BRIDGE_NOESCAPE,
    int32_t added_id_capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE add_outcome_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientPreviewTorrentFileData(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(torrent_data_size)
        torrent_data TORRENT_BRIDGE_NOESCAPE,
    int32_t torrent_data_size,
    TTorrentFilePreview * TORRENT_BRIDGE_NULLABLE preview TORRENT_BRIDGE_NOESCAPE,
    TTorrentFileSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) files TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopySnapshotBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) snapshots TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE revision_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientRequestSources(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentSourcePolicyResult TorrentClientCopySourcePolicy(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Mutates one policy field against the current torrent state and commits the
// resulting policy to resume data before returning success.
int32_t TorrentClientSetSourcePolicyField(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    int32_t field,
    int32_t value,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentOptionsResult TorrentClientCopyTorrentOptions(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSetTorrentOptions(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    TTorrentOptions options,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientMoveTorrentInQueue(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    int32_t move,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyTrackerBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    TTorrentTrackerSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) trackers TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE revision_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE resident_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyTrackerHostBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentTrackerHostSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) hosts TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE revision_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyWebSeedBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    TTorrentWebSeedSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) web_seeds TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE revision_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE resident_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentWebSeedActivityResult TorrentClientCopyWebSeedActivity(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentPeerSourcesResult TorrentClientCopyPeerSources(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientRequestFiles(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyFileBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    TTorrentFileSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) files TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE revision_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE resident_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientRequestPieceMap(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyPieceMap(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    TTorrentPieceMapSnapshot * TORRENT_BRIDGE_NULLABLE snapshot TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) pieces TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE revision_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE resident_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSetFilePriority(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    int32_t file_index,
    int32_t priority,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientPause(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientResume(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientReannounce(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientForceRecheck(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// removal_committed_out becomes true immediately after libtorrent accepts any
// removal and remains authoritative even if later bridge bookkeeping fails. A
// nonzero request token additionally identifies an asynchronous payload
// deletion. After commit, the caller must either consume that token's terminal
// result when present or blocking-destroy the client before releasing access.
int32_t TorrentClientRemove(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED torrent_id TORRENT_BRIDGE_NOESCAPE,
    uint8_t delete_files,
    uint8_t delete_partfile,
    uint64_t * TORRENT_BRIDGE_NULLABLE request_token_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE removal_committed_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// A nonzero token is returned only when payload deletion needs an asynchronous
// terminal result. Pending results remain available; a terminal result is
// consumed when read. An accepted removal cannot be cancelled.
TTorrentRemovalReadResult TorrentClientTakeRemovalResult(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t request_token,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientApplySettings(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentSessionSettings requested,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(required_network_interface_size)
        required_network_interface TORRENT_BRIDGE_NOESCAPE,
    int32_t required_network_interface_size,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientBlockNetwork(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentNetworkStatusResult TorrentClientCopyNetworkStatus(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentBridgeHealthResult TorrentClientCopyHealth(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSaveAllChecked(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

void TorrentClientSaveAll(TTorrentClient * TORRENT_BRIDGE_NULLABLE client) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientTakeAlertError(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef TORRENT_BRIDGE_NOEXCEPT
#undef TORRENT_BRIDGE_COUNTED_BY
#undef TORRENT_BRIDGE_NOESCAPE
#undef TORRENT_BRIDGE_NONNULL
#undef TORRENT_BRIDGE_NULLABLE
#undef TORRENT_BRIDGE_NULL_TERMINATED

#endif
