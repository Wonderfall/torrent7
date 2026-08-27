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
inline constexpr int32_t TTORRENT_MAX_NETWORK_INTERFACE_BYTES = 64;
inline constexpr int32_t TTORRENT_ID_CAPACITY = 68;
inline constexpr int32_t TTORRENT_TRACKER_HOST_CAPACITY = 256;
inline constexpr int32_t TTORRENT_MAX_EVENT_COUNT = 1024;
inline constexpr int32_t TTORRENT_MAX_RESUME_ID_COUNT = 8;
inline constexpr int32_t TTORRENT_REMOVAL_TOMBSTONE_FILENAME_CAPACITY = 96;
inline constexpr uint8_t TTORRENT_EVENT_TORRENTS_CHANGED = 1;
inline constexpr uint8_t TTORRENT_EVENT_TRACKERS_CHANGED = 2;
inline constexpr uint8_t TTORRENT_EVENT_WEB_SEEDS_CHANGED = 3;
inline constexpr uint8_t TTORRENT_EVENT_FILES_CHANGED = 4;
inline constexpr uint8_t TTORRENT_EVENT_NETWORK_CHANGED = 5;
inline constexpr uint8_t TTORRENT_EVENT_ERRORS_AVAILABLE = 6;
inline constexpr uint8_t TTORRENT_EVENT_PIECES_CHANGED = 7;
inline constexpr uint8_t TTORRENT_EVENT_TRACKER_HOSTS_CHANGED = 8;
inline constexpr uint8_t TTORRENT_EVENT_HEALTH_CHANGED = 9;
inline constexpr uint8_t TTORRENT_EVENT_RESYNC_REQUIRED = 10;
inline constexpr uint8_t TTORRENT_EVENT_RESUME_SAVE_REQUESTED = 11;
inline constexpr uint8_t TTORRENT_EVENT_RESUME_RETRY_REQUESTED = 12;
inline constexpr uint8_t TTORRENT_EVENT_CRITICAL_FAULT = 13;
inline constexpr uint32_t TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY = 1U << 0U;
inline constexpr uint32_t TTORRENT_CRITICAL_FAULT_NETWORK_CONTAINMENT_UNCONFIRMED = 1U << 1U;
inline constexpr uint8_t TTORRENT_RESUME_SAVE_ROUTINE = 0;
inline constexpr uint8_t TTORRENT_RESUME_SAVE_POLICY = 1;
inline constexpr uint8_t TTORRENT_RESUME_SAVE_FULL = 2;
inline constexpr int32_t TTORRENT_MAX_PIECE_MAP_COUNT = 0x200000;
inline constexpr int32_t TTORRENT_QUEUE_PRIORITY_LOW = 0;
inline constexpr int32_t TTORRENT_QUEUE_PRIORITY_NORMAL = 1;
inline constexpr int32_t TTORRENT_QUEUE_PRIORITY_HIGH = 2;
inline constexpr int32_t TTORRENT_FILE_PRIORITY_SKIP = 0;
inline constexpr int32_t TTORRENT_FILE_PRIORITY_LOW = 1;
inline constexpr int32_t TTORRENT_FILE_PRIORITY_NORMAL = 4;
inline constexpr int32_t TTORRENT_FILE_PRIORITY_HIGH = 7;
inline constexpr int32_t TTORRENT_ADD_REJECTED = 0;
inline constexpr int32_t TTORRENT_ADD_COMMITTED = 1;
inline constexpr int32_t TTORRENT_ADD_OUTCOME_UNKNOWN = 2;
inline constexpr uint8_t TTORRENT_BOOLEAN_POLICY_INHERIT = 0;
inline constexpr uint8_t TTORRENT_BOOLEAN_POLICY_DISABLED = 1;
inline constexpr uint8_t TTORRENT_BOOLEAN_POLICY_ENABLED = 2;
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
inline constexpr uint32_t TTORRENT_MAGNET_IMPORT_SCHEMA_VERSION = 1;
inline constexpr uint32_t TTORRENT_MAGNET_HAS_V1 = 1U << 0U;
inline constexpr uint32_t TTORRENT_MAGNET_HAS_V2 = 1U << 1U;
inline constexpr uint32_t TTORRENT_MAGNET_HAS_FILE_SELECTION = 1U << 2U;
inline constexpr uint32_t TTORRENT_METAINFO_CAPSULE_MAGIC = 0x494d3754U;
inline constexpr uint16_t TTORRENT_METAINFO_CAPSULE_SCHEMA_VERSION = 1;
inline constexpr uint16_t TTORRENT_METAINFO_CAPSULE_HEADER_SIZE = 160;
inline constexpr uint16_t TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE = 32;
inline constexpr uint16_t TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE = 8;
inline constexpr uint16_t TTORRENT_METAINFO_CAPSULE_TRACKER_RECORD_SIZE = 16;
inline constexpr uint16_t TTORRENT_METAINFO_CAPSULE_PIECE_LAYER_RECORD_SIZE = 24;
inline constexpr uint16_t TTORRENT_METAINFO_CAPSULE_FILE_INDEX_RECORD_SIZE = 4;
inline constexpr int32_t TTORRENT_METAINFO_CAPSULE_MAX_BYTES = 96 * 1024 * 1024;
inline constexpr uint8_t TTORRENT_METAINFO_INPUT_TORRENT_FILE = 1;
inline constexpr uint8_t TTORRENT_METAINFO_INPUT_INFO_DICTIONARY = 2;
inline constexpr uint8_t TTORRENT_METAINFO_KIND_V1 = 1;
inline constexpr uint8_t TTORRENT_METAINFO_KIND_V2 = 2;
inline constexpr uint8_t TTORRENT_METAINFO_KIND_HYBRID = 3;
inline constexpr uint8_t TTORRENT_METAINFO_PRIVATE = 1U << 0U;
inline constexpr uint32_t TTORRENT_METAINFO_FILE_PADDING = 1U << 0U;
inline constexpr uint32_t TTORRENT_METAINFO_FILE_EXECUTABLE = 1U << 1U;
inline constexpr uint32_t TTORRENT_METAINFO_FILE_HIDDEN = 1U << 2U;
inline constexpr uint16_t TTORRENT_METAINFO_FIELD_ANNOUNCE = 1U << 0U;
inline constexpr uint16_t TTORRENT_METAINFO_FIELD_ANNOUNCE_LIST = 1U << 1U;
inline constexpr uint16_t TTORRENT_METAINFO_FIELD_URL_LIST = 1U << 2U;
inline constexpr uint16_t TTORRENT_METAINFO_FIELD_PIECE_LAYERS = 1U << 3U;
inline constexpr uint16_t TTORRENT_METAINFO_FIELD_COMMENT = 1U << 4U;
inline constexpr uint16_t TTORRENT_METAINFO_FIELD_CREATED_BY = 1U << 5U;
inline constexpr uint16_t TTORRENT_METAINFO_FIELD_CREATION_DATE = 1U << 6U;
inline constexpr uint16_t TTORRENT_METAINFO_FIELD_DHT_NODES = 1U << 7U;
inline constexpr uint32_t TTORRENT_BRIDGE_ABI_VERSION = 59;
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
    TTORRENT_MAX_NETWORK_INTERFACE_BYTES = 64,
    TTORRENT_ID_CAPACITY = 68,
    TTORRENT_TRACKER_HOST_CAPACITY = 256,
    TTORRENT_MAX_EVENT_COUNT = 1024,
    TTORRENT_MAX_RESUME_ID_COUNT = 8,
    TTORRENT_REMOVAL_TOMBSTONE_FILENAME_CAPACITY = 96,
    TTORRENT_EVENT_TORRENTS_CHANGED = 1,
    TTORRENT_EVENT_TRACKERS_CHANGED = 2,
    TTORRENT_EVENT_WEB_SEEDS_CHANGED = 3,
    TTORRENT_EVENT_FILES_CHANGED = 4,
    TTORRENT_EVENT_NETWORK_CHANGED = 5,
    TTORRENT_EVENT_ERRORS_AVAILABLE = 6,
    TTORRENT_EVENT_PIECES_CHANGED = 7,
    TTORRENT_EVENT_TRACKER_HOSTS_CHANGED = 8,
    TTORRENT_EVENT_HEALTH_CHANGED = 9,
    TTORRENT_EVENT_RESYNC_REQUIRED = 10,
    TTORRENT_EVENT_RESUME_SAVE_REQUESTED = 11,
    TTORRENT_EVENT_RESUME_RETRY_REQUESTED = 12,
    TTORRENT_EVENT_CRITICAL_FAULT = 13,
    TTORRENT_CRITICAL_FAULT_SESSION_IDENTITY_AUTHORITY = 1U << 0U,
    TTORRENT_CRITICAL_FAULT_NETWORK_CONTAINMENT_UNCONFIRMED = 1U << 1U,
    TTORRENT_RESUME_SAVE_ROUTINE = 0,
    TTORRENT_RESUME_SAVE_POLICY = 1,
    TTORRENT_RESUME_SAVE_FULL = 2,
    TTORRENT_MAX_PIECE_MAP_COUNT = 0x200000,
    TTORRENT_QUEUE_PRIORITY_LOW = 0,
    TTORRENT_QUEUE_PRIORITY_NORMAL = 1,
    TTORRENT_QUEUE_PRIORITY_HIGH = 2,
    TTORRENT_FILE_PRIORITY_SKIP = 0,
    TTORRENT_FILE_PRIORITY_LOW = 1,
    TTORRENT_FILE_PRIORITY_NORMAL = 4,
    TTORRENT_FILE_PRIORITY_HIGH = 7,
    TTORRENT_ADD_REJECTED = 0,
    TTORRENT_ADD_COMMITTED = 1,
    TTORRENT_ADD_OUTCOME_UNKNOWN = 2,
    TTORRENT_BOOLEAN_POLICY_INHERIT = 0,
    TTORRENT_BOOLEAN_POLICY_DISABLED = 1,
    TTORRENT_BOOLEAN_POLICY_ENABLED = 2,
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
    TTORRENT_MAGNET_IMPORT_SCHEMA_VERSION = 1,
    TTORRENT_MAGNET_HAS_V1 = 1U << 0U,
    TTORRENT_MAGNET_HAS_V2 = 1U << 1U,
    TTORRENT_MAGNET_HAS_FILE_SELECTION = 1U << 2U,
    TTORRENT_METAINFO_CAPSULE_MAGIC = 0x494d3754U,
    TTORRENT_METAINFO_CAPSULE_SCHEMA_VERSION = 1,
    TTORRENT_METAINFO_CAPSULE_HEADER_SIZE = 160,
    TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE = 32,
    TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE = 8,
    TTORRENT_METAINFO_CAPSULE_TRACKER_RECORD_SIZE = 16,
    TTORRENT_METAINFO_CAPSULE_PIECE_LAYER_RECORD_SIZE = 24,
    TTORRENT_METAINFO_CAPSULE_FILE_INDEX_RECORD_SIZE = 4,
    TTORRENT_METAINFO_CAPSULE_MAX_BYTES = 96 * 1024 * 1024,
    TTORRENT_METAINFO_INPUT_TORRENT_FILE = 1,
    TTORRENT_METAINFO_INPUT_INFO_DICTIONARY = 2,
    TTORRENT_METAINFO_KIND_V1 = 1,
    TTORRENT_METAINFO_KIND_V2 = 2,
    TTORRENT_METAINFO_KIND_HYBRID = 3,
    TTORRENT_METAINFO_PRIVATE = 1U << 0U,
    TTORRENT_METAINFO_FILE_PADDING = 1U << 0U,
    TTORRENT_METAINFO_FILE_EXECUTABLE = 1U << 1U,
    TTORRENT_METAINFO_FILE_HIDDEN = 1U << 2U,
    TTORRENT_METAINFO_FIELD_ANNOUNCE = 1U << 0U,
    TTORRENT_METAINFO_FIELD_ANNOUNCE_LIST = 1U << 1U,
    TTORRENT_METAINFO_FIELD_URL_LIST = 1U << 2U,
    TTORRENT_METAINFO_FIELD_PIECE_LAYERS = 1U << 3U,
    TTORRENT_METAINFO_FIELD_COMMENT = 1U << 4U,
    TTORRENT_METAINFO_FIELD_CREATED_BY = 1U << 5U,
    TTORRENT_METAINFO_FIELD_CREATION_DATE = 1U << 6U,
    TTORRENT_METAINFO_FIELD_DHT_NODES = 1U << 7U,
    TTORRENT_BRIDGE_ABI_VERSION = 59
};
#endif

#ifndef __cplusplus
typedef struct TTorrentClient TTorrentClient;
#endif
typedef void (* TORRENT_BRIDGE_NULLABLE TTorrentWakeCallback)(void * TORRENT_BRIDGE_NULLABLE context);

typedef struct TTorrentEvent {
    uint64_t native_token;
    uint8_t kind;
    uint8_t resume_save_mode;
    // Set only for TTORRENT_EVENT_CRITICAL_FAULT. Native contains network
    // traffic before publishing; Swift owns durable latching and recovery.
    uint32_t critical_faults;
} TTorrentEvent;

// One owned presentation update captured from native resume metadata. Swift
// drains these bounded records and retains the authoritative presentation
// value; native identity state does not cache it afterward.
typedef struct TTorrentPresentationMetadata {
    uint64_t native_token;
    int64_t created_time;
    char comment[1024];
} TTorrentPresentationMetadata;

typedef struct TTorrentResumeID {
    char value[68];
} TTorrentResumeID;

// One complete Swift-owned queue placement. The array order is authoritative;
// priority is persisted as policy but never interpreted into an order here.
typedef struct TTorrentQueuePlacement {
    uint64_t native_token;
    int32_t priority;
} TTorrentQueuePlacement;

typedef struct TTorrentSnapshot {
    uint64_t native_token;
    char id[68];
    char info_hash[68];
    char name[512];
    char save_path[1024];
    char error[512];
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
    uint64_t native_token;
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

typedef struct TTorrentPieceMapSnapshot {
    int32_t total_pieces;
    int32_t completed_pieces;
    int32_t available_pieces;
    uint8_t map_available;
    uint8_t map_truncated;
} TTorrentPieceMapSnapshot;

// Parsed magnets cross the native boundary as fixed hashes and checked ranges
// into one borrowed byte blob. No record contains a nested pointer.
typedef struct TTorrentMagnetImport {
    uint32_t schema_version;
    uint32_t flags;
    uint8_t v1_info_hash[20];
    uint8_t v2_info_hash[32];
    uint32_t display_name_offset;
    uint32_t display_name_size;
} TTorrentMagnetImport;

typedef struct TTorrentMagnetTracker {
    uint32_t url_offset;
    uint32_t url_size;
    uint8_t tier;
    uint8_t reserved[3];
} TTorrentMagnetTracker;

typedef struct TTorrentByteRange {
    uint32_t offset;
    uint32_t size;
} TTorrentByteRange;

typedef struct TTorrentFileSelectionRange {
    int32_t first_index;
    int32_t last_index;
} TTorrentFileSelectionRange;

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
    uint8_t dht_read_only;
    uint8_t enable_lsd;
    int32_t encryption_policy;
    uint8_t anonymous_mode;
    uint8_t network_blocked;
    uint8_t dht_discovery_policy;
} TTorrentSessionSettings;

typedef struct TTorrentNetworkStatus {
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

// Native facts and persisted intent for one torrent. Swift owns inheritance,
// policy mutation, and effective-state construction.
typedef struct TTorrentSourcePolicyState {
    uint64_t native_token;
    uint8_t dht_policy;
    uint8_t peer_exchange_policy;
    uint8_t lsd_policy;
    uint8_t https_tracker_policy;
    uint8_t https_web_seed_policy;
    uint8_t dht_locked;
    uint8_t peer_exchange_locked;
    uint8_t lsd_locked;
    uint8_t metadata_validation_pending;
    uint8_t allow_pre_metadata_dht;
} TTorrentSourcePolicyState;

// A complete policy decision produced by the Swift actor. Native code only
// validates safety constraints, applies libtorrent flags/source filters, and
// mirrors persisted intent into resume data.
typedef struct TTorrentSourcePolicyApplication {
    uint64_t native_token;
    uint8_t dht_policy;
    uint8_t peer_exchange_policy;
    uint8_t lsd_policy;
    uint8_t https_tracker_policy;
    uint8_t https_web_seed_policy;
    uint8_t effective_https_tracker_policy;
    uint8_t effective_https_web_seed_policy;
    uint8_t enable_dht;
    uint8_t enable_peer_exchange;
    uint8_t enable_lsd;
    uint8_t allow_pre_metadata_dht;
} TTorrentSourcePolicyApplication;

typedef struct TTorrentAddOptions {
    uint8_t starts_paused;
    uint8_t queue_priority;
    uint8_t enable_dht;
    uint8_t enable_peer_exchange;
    uint8_t enable_lsd;
    uint8_t https_tracker_policy;
    uint8_t https_web_seed_policy;
    uint8_t effective_https_tracker_policy;
    uint8_t effective_https_web_seed_policy;
    uint8_t allow_pre_metadata_dht;
    // Swift-generated application identity. Native code validates and reserves
    // it against the live session but does not choose a new-add identity.
    char canonical_id[TTORRENT_ID_CAPACITY];
} TTorrentAddOptions;

typedef struct TTorrentOptions {
    int32_t download_rate_limit;
    int32_t upload_rate_limit;
    int32_t max_uploads;
    int32_t max_connections;
    int32_t queue_priority;
} TTorrentOptions;

typedef struct TTorrentOptionsResult {
    int32_t status;
    TTorrentOptions options;
} TTorrentOptionsResult;

typedef struct TTorrentWebSeedActivityResult {
    int32_t status;
    TTorrentWebSeedActivitySnapshot activity;
} TTorrentWebSeedActivityResult;

typedef struct TTorrentPeerSourcesResult {
    int32_t status;
    TTorrentPeerSourceSnapshot sources;
} TTorrentPeerSourcesResult;

typedef struct TTorrentNetworkStatusResult {
    int32_t status;
    TTorrentNetworkStatus network_status;
} TTorrentNetworkStatusResult;

typedef struct TTorrentBridgeHealthResult {
    int32_t status;
    TTorrentBridgeHealth health;
} TTorrentBridgeHealthResult;

// The provider is process-local and pathless. Callbacks may run concurrently
// on libtorrent disk workers, must not throw or reenter TorrentBridge, and must
// return promptly when the broker session is cancelled. open_payload transfers
// one owned CLOEXEC regular-file descriptor through descriptor_out on success.
// payload_size returns the current size independently of open. Both callbacks
// return zero on success or a positive errno-compatible failure code.
typedef uint8_t (* TORRENT_BRIDGE_NULLABLE TTorrentPayloadContextRetainCallback)(
    void * TORRENT_BRIDGE_NULLABLE context
);
typedef void (* TORRENT_BRIDGE_NULLABLE TTorrentPayloadContextReleaseCallback)(
    void * TORRENT_BRIDGE_NULLABLE context
);
typedef int32_t (* TORRENT_BRIDGE_NULLABLE TTorrentPayloadOpenCallback)(
    void * TORRENT_BRIDGE_NULLABLE context,
    const uint8_t * TORRENT_BRIDGE_NONNULL TORRENT_BRIDGE_COUNTED_BY(16)
        claim_id TORRENT_BRIDGE_NOESCAPE,
    uint64_t claim_generation,
    int32_t file_index,
    uint8_t writable,
    int32_t * TORRENT_BRIDGE_NONNULL descriptor_out
);
typedef int32_t (* TORRENT_BRIDGE_NULLABLE TTorrentPayloadSizeCallback)(
    void * TORRENT_BRIDGE_NULLABLE context,
    const uint8_t * TORRENT_BRIDGE_NONNULL TORRENT_BRIDGE_COUNTED_BY(16)
        claim_id TORRENT_BRIDGE_NOESCAPE,
    uint64_t claim_generation,
    int32_t file_index,
    int64_t * TORRENT_BRIDGE_NONNULL size_out
);

typedef struct TTorrentPayloadBrokerCallbacks {
    void * TORRENT_BRIDGE_NULLABLE context;
    TTorrentPayloadContextRetainCallback retain_context;
    TTorrentPayloadContextReleaseCallback release_context;
    TTorrentPayloadOpenCallback open_payload;
    TTorrentPayloadSizeCallback payload_size;
} TTorrentPayloadBrokerCallbacks;

// Immutable activation authority for one known torrent. claim_id is the UUID's
// 16 RFC 4122 bytes. source_manifest_digest is the domain-separated SHA-256
// digest independently reproduced by Swift and libtorrent before admission.
// preserved_torrent_id is either all zeroes or an exact canonical 34-byte
// torrent identity being handed off from an entry already in removal.
typedef struct TTorrentStorageActivation {
    uint8_t claim_id[16];
    uint64_t claim_generation;
    uint8_t source_manifest_digest[32];
    uint8_t preserved_torrent_id[34];
} TTorrentStorageActivation;

const char * TORRENT_BRIDGE_NONNULL TORRENT_BRIDGE_NULL_TERMINATED TorrentBridgeLibtorrentVersion(void)
    TORRENT_BRIDGE_NOEXCEPT;

// Returns an owned client handle. Release it exactly once with
// TorrentClientDestroy. The broker context is retained synchronously before
// construction and released after every provider and disk worker is quiescent.
TTorrentClient * TORRENT_BRIDGE_NULLABLE TorrentClientCreateWithError(
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED state_path TORRENT_BRIDGE_NOESCAPE,
    uint8_t enable_pex_plugin,
    TTorrentPayloadBrokerCallbacks payload_broker,
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

// Drains a bounded batch of owned native event hints. When capacity is too
// small, no events are consumed and required_count_out reports the size needed.
int32_t TorrentClientDrainEvents(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentEvent * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) events TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

// Drains coalesced presentation values captured from native add/resume data.
// A zero-capacity call reports the required count without consuming records.
// Swift retains successfully copied values as part of its snapshot model.
int32_t TorrentClientDrainPresentationMetadata(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentPresentationMetadata * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity)
        metadata TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

// add_outcome_out is mandatory. It reports REJECTED until the native add can
// have committed, OUTCOME_UNKNOWN while libtorrent acceptance or rollback is
// not yet proven, and COMMITTED only after every bridge invariant and durable
// bookkeeping step succeeds. A failed call may therefore be distinguished as
// a definite rejection or a commit-ambiguous failure without replaying it.
int32_t TorrentClientAddParsedMagnet(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentMagnetImport magnet,
    const uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(blob_size)
        blob TORRENT_BRIDGE_NOESCAPE,
    int32_t blob_size,
    const TTorrentMagnetTracker * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(tracker_count)
        trackers TORRENT_BRIDGE_NOESCAPE,
    int32_t tracker_count,
    const TTorrentByteRange * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(web_seed_count)
        web_seeds TORRENT_BRIDGE_NOESCAPE,
    int32_t web_seed_count,
    const TTorrentFileSelectionRange * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(file_selection_count)
        file_selections TORRENT_BRIDGE_NOESCAPE,
    int32_t file_selection_count,
    TTorrentAddOptions options,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(added_id_capacity) added_id_out TORRENT_BRIDGE_NOESCAPE,
    int32_t added_id_capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE native_token_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE add_outcome_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientAddTorrentFileData(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(torrent_data_size)
        torrent_data TORRENT_BRIDGE_NOESCAPE,
    int32_t torrent_data_size,
    TTorrentStorageActivation activation,
    TTorrentAddOptions options,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(added_id_capacity) added_id_out TORRENT_BRIDGE_NOESCAPE,
    int32_t added_id_capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE native_token_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE add_outcome_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientAddTorrentFileDataWithPriorities(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(torrent_data_size)
        torrent_data TORRENT_BRIDGE_NOESCAPE,
    int32_t torrent_data_size,
    TTorrentStorageActivation activation,
    TTorrentAddOptions options,
    const TTorrentFilePriorityEntry * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(file_priority_count)
        file_priorities TORRENT_BRIDGE_NOESCAPE,
    int32_t file_priority_count,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(added_id_capacity) added_id_out TORRENT_BRIDGE_NOESCAPE,
    int32_t added_id_capacity,
    uint64_t * TORRENT_BRIDGE_NULLABLE native_token_out TORRENT_BRIDGE_NOESCAPE,
    int32_t * TORRENT_BRIDGE_NULLABLE add_outcome_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Extracts a bounded, lifetime-independent snapshot batch directly from the
// current libtorrent session. Native code does not retain an application
// snapshot cache. available_out is set only after a coherent extraction
// succeeds, including when the authoritative batch is empty.
int32_t TorrentClientCopySnapshotBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) snapshots TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

// Extracts an owned, bounded batch of immutable native source facts and
// persisted intent. The Swift actor derives all effective policy from it.
int32_t TorrentClientCopySourcePolicyStateBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentSourcePolicyState * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) states TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

// Applies one complete, bounded source-policy state chosen by the Swift actor.
// Every active torrent must appear exactly once.
int32_t TorrentClientApplySourcePolicyState(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const TTorrentSourcePolicyApplication * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(application_count)
        applications TORRENT_BRIDGE_NOESCAPE,
    int32_t application_count,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentOptionsResult TorrentClientCopyTorrentOptions(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSetTorrentOptions(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    TTorrentOptions options,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Applies one complete, bounded queue state chosen by the Swift actor. Native
// code only resolves handles, sets libtorrent positions, requests resume saves,
// and contains/rolls back C++ exceptions.
int32_t TorrentClientApplyQueueState(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const TTorrentQueuePlacement * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(placement_count)
        placements TORRENT_BRIDGE_NOESCAPE,
    int32_t placement_count,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Detail reads are stateless native extractions. The first zero-capacity call
// reports the bounded count; a subsequent call copies owned DTO values.
// available_out is false when the torrent cannot be inspected coherently.
// Semantic revisions and cache residency belong to the Swift actor.
int32_t TorrentClientCopyTrackerBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    TTorrentTrackerSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) trackers TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyTrackerHostBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    TTorrentTrackerHostSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) hosts TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyWebSeedBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    TTorrentWebSeedSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) web_seeds TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentWebSeedActivityResult TorrentClientCopyWebSeedActivity(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token
) TORRENT_BRIDGE_NOEXCEPT;

TTorrentPeerSourcesResult TorrentClientCopyPeerSources(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyFileBatch(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    TTorrentFileSnapshot * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) files TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyPieceMap(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    TTorrentPieceMapSnapshot * TORRENT_BRIDGE_NULLABLE snapshot TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) pieces TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

// Copies the exact immutable bencoded info dictionary retained by libtorrent.
// The first zero-capacity call reports required_count_out. available_out is
// false until metadata is resident and valid. The result is the copied byte
// count and never exceeds the caller-provided capacity.
int32_t TorrentClientCopyTorrentMetadata(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    uint8_t * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) metadata TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSetFilePriority(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    int32_t file_index,
    int32_t priority,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientPause(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientResume(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientReannounce(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientForceRecheck(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Technical libtorrent removal primitive. Swift must first persist a durable
// removal tombstone with the exact IDs returned by TorrentClientCopyResumeIDs.
// removal_committed_out becomes true immediately after libtorrent accepts the
// removal. Payload files are never deleted by the bridge.
int32_t TorrentClientRemove(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    uint8_t * TORRENT_BRIDGE_NULLABLE removal_committed_out TORRENT_BRIDGE_NOESCAPE,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyResumeIDs(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    TTorrentResumeID * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(capacity) ids TORRENT_BRIDGE_NOESCAPE,
    int32_t capacity,
    int32_t * TORRENT_BRIDGE_NULLABLE required_count_out TORRENT_BRIDGE_NOESCAPE,
    uint8_t * TORRENT_BRIDGE_NULLABLE available_out TORRENT_BRIDGE_NOESCAPE
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientPersistRemovalTombstone(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const TTorrentResumeID * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(id_count) ids TORRENT_BRIDGE_NOESCAPE,
    int32_t id_count,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(filename_capacity) filename_out TORRENT_BRIDGE_NOESCAPE,
    int32_t filename_capacity,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientRemoveResumeData(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const TTorrentResumeID * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(id_count) ids TORRENT_BRIDGE_NOESCAPE,
    int32_t id_count,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientClearRemovalTombstone(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    const char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_NULL_TERMINATED filename TORRENT_BRIDGE_NOESCAPE,
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

// Performs one synchronous native capture/encode/durable-write attempt. Swift
// owns save generations, coalescing, and retry state; this command retains no
// retryable encoded data or scheduling state.
int32_t TorrentClientSaveResumeDataChecked(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    uint64_t native_token,
    uint8_t save_mode,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Performs one stateless scan and crash-consistent cleanup of durable removal
// markers. Swift owns retry scheduling and failure state; native code retains
// no tombstone index for this command.
int32_t TorrentClientRecoverPendingRemovalsChecked(
    TTorrentClient * TORRENT_BRIDGE_NULLABLE client,
    char * TORRENT_BRIDGE_NULLABLE TORRENT_BRIDGE_COUNTED_BY(error_capacity) error_out TORRENT_BRIDGE_NOESCAPE,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

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
