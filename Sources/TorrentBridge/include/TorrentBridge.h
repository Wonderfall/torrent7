#ifndef TORRENT_BRIDGE_H
#define TORRENT_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

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
inline constexpr uint32_t TTORRENT_BRIDGE_ABI_VERSION = 26;
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
    TTORRENT_BRIDGE_ABI_VERSION = 26
};
#endif

typedef struct TTorrentClient TTorrentClient;
typedef void (*TTorrentWakeCallback)(void *context);

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
    int32_t kind;
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
    uint8_t enable_lsd;
    uint8_t use_lsd_by_default;
    uint8_t use_pex_by_default;
    uint8_t require_https_trackers;
    uint8_t require_https_web_seeds;
    int32_t encryption_policy;
    uint8_t anonymous_mode;
    const char *required_network_interface;
    uint8_t network_blocked;
} TTorrentSessionSettings;

typedef struct TTorrentNetworkStatus {
    uint64_t requested_revision;
    uint64_t submitted_revision;
    int32_t listen_port;
    uint8_t network_blocked;
    uint8_t has_listener;
    char endpoint[128];
    char last_error[512];
} TTorrentNetworkStatus;

typedef struct TTorrentSourcePolicy {
    uint8_t enable_dht;
    uint8_t enable_peer_exchange;
    uint8_t enable_lsd;
    uint8_t require_https_trackers;
    uint8_t require_https_web_seeds;
    uint8_t dht_locked;
    uint8_t peer_exchange_locked;
    uint8_t lsd_locked;
} TTorrentSourcePolicy;

typedef struct TTorrentAddOptions {
    uint8_t starts_paused;
    uint8_t queue_priority;
    uint8_t enable_peer_exchange;
    uint8_t allow_non_https_trackers;
    uint8_t allow_non_https_web_seeds;
} TTorrentAddOptions;

typedef struct TTorrentOptions {
    int32_t download_rate_limit;
    int32_t upload_rate_limit;
    int32_t max_uploads;
    int32_t max_connections;
    int32_t queue_priority;
} TTorrentOptions;

const char *TorrentBridgeLibtorrentVersion(void) TORRENT_BRIDGE_NOEXCEPT;

// Returns an owned client handle. Release it exactly once with TorrentClientDestroy.
TTorrentClient *TorrentClientCreateWithError(
    const char *state_path,
    uint8_t enable_pex_plugin,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

// Consumes a client handle returned by TorrentClientCreateWithError. Passing NULL is allowed.
// No other bridge call may race with destruction of the same client.
void TorrentClientDestroy(TTorrentClient *client) TORRENT_BRIDGE_NOEXCEPT;

// Like TorrentClientDestroy, but waits for libtorrent's shutdown proxy before returning.
void TorrentClientDestroyBlocking(TTorrentClient *client) TORRENT_BRIDGE_NOEXCEPT;

// The wake callback is invoked outside the client lock. It may clear itself, but it must
// not destroy the client from inside the callback.
void TorrentClientSetWakeCallback(
    TTorrentClient *client,
    TTorrentWakeCallback callback,
    void *context
) TORRENT_BRIDGE_NOEXCEPT;

void TorrentClientClearWakeCallback(TTorrentClient *client) TORRENT_BRIDGE_NOEXCEPT;

uint64_t TorrentClientTakeChanges(
    TTorrentClient *client,
    uint32_t *dirty_mask_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientAddMagnet(
    TTorrentClient *client,
    const char *magnet_uri,
    const char *save_path,
    const TTorrentAddOptions *options,
    char *added_id_out,
    int32_t added_id_capacity,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientAddTorrentFileData(
    TTorrentClient *client,
    const char *torrent_data,
    int32_t torrent_data_size,
    const char *save_path,
    const TTorrentAddOptions *options,
    char *added_id_out,
    int32_t added_id_capacity,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientAddTorrentFileDataWithPriorities(
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
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientPreviewTorrentFileData(
    TTorrentClient *client,
    const char *torrent_data,
    int32_t torrent_data_size,
    TTorrentFilePreview *preview,
    TTorrentFileSnapshot *files,
    int32_t capacity,
    int32_t *required_count_out,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopySnapshotBatch(
    TTorrentClient *client,
    TTorrentSnapshot *snapshots,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientRequestSources(
    TTorrentClient *client,
    const char *torrent_id,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopySourcePolicy(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentSourcePolicy *policy,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSetSourcePolicy(
    TTorrentClient *client,
    const char *torrent_id,
    const TTorrentSourcePolicy *policy,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyTorrentOptions(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentOptions *options,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSetTorrentOptions(
    TTorrentClient *client,
    const char *torrent_id,
    const TTorrentOptions *options,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientMoveTorrentInQueue(
    TTorrentClient *client,
    const char *torrent_id,
    int32_t move,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyTrackerBatch(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentTrackerSnapshot *trackers,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyTrackerHostBatch(
    TTorrentClient *client,
    TTorrentTrackerHostSnapshot *hosts,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyWebSeedBatch(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentWebSeedSnapshot *web_seeds,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyWebSeedActivity(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentWebSeedActivitySnapshot *activity,
    uint64_t *revision_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyPeerSources(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentPeerSourceSnapshot *sources,
    uint64_t *revision_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientRequestFiles(
    TTorrentClient *client,
    const char *torrent_id,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyFileBatch(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentFileSnapshot *files,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientRequestPieceMap(
    TTorrentClient *client,
    const char *torrent_id,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyPieceMap(
    TTorrentClient *client,
    const char *torrent_id,
    TTorrentPieceMapSnapshot *snapshot,
    uint8_t *pieces,
    int32_t capacity,
    uint64_t *revision_out,
    int32_t *required_count_out
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSetFilePriority(
    TTorrentClient *client,
    const char *torrent_id,
    int32_t file_index,
    int32_t priority,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientPause(TTorrentClient *client, const char *torrent_id, char *error_out, int32_t error_capacity) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientResume(TTorrentClient *client, const char *torrent_id, char *error_out, int32_t error_capacity) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientReannounce(TTorrentClient *client, const char *torrent_id, char *error_out, int32_t error_capacity) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientForceRecheck(TTorrentClient *client, const char *torrent_id, char *error_out, int32_t error_capacity) TORRENT_BRIDGE_NOEXCEPT;
int32_t TorrentClientRemove(
    TTorrentClient *client,
    const char *torrent_id,
    uint8_t delete_files,
    uint8_t delete_partfile,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientApplySettings(
    TTorrentClient *client,
    const TTorrentSessionSettings *settings,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientBlockNetwork(
    TTorrentClient *client,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientCopyNetworkStatus(
    TTorrentClient *client,
    TTorrentNetworkStatus *status
) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientSaveAllChecked(
    TTorrentClient *client,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

void TorrentClientSaveAll(TTorrentClient *client) TORRENT_BRIDGE_NOEXCEPT;

int32_t TorrentClientTakeAlertError(
    TTorrentClient *client,
    char *error_out,
    int32_t error_capacity
) TORRENT_BRIDGE_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef TORRENT_BRIDGE_NOEXCEPT

#endif
