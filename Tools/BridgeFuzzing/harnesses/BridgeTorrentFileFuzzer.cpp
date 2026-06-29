#include "BridgeFuzzSupport.hpp"

#include <cstddef>
#include <cstdint>

extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    auto &harness = bridge_fuzz::shared_harness("bridge-torrent-file");
    auto const *begin = reinterpret_cast<char const *>(data);

    TTorrentAddOptions options{
        .starts_paused = 1,
        .queue_priority = TTORRENT_QUEUE_PRIORITY_NORMAL,
        .enable_peer_exchange = 0,
        .allow_non_https_trackers = 0,
        .allow_non_https_web_seeds = 0,
    };
    bridge_fuzz::AddedIdBuffer added_id;
    bridge_fuzz::ErrorBuffer error;
    int32_t const result = TorrentClientAddTorrentFileData(
        harness.client(),
        begin,
        static_cast<int32_t>(size),
        harness.save_path(),
        &options,
        added_id.data(),
        added_id.capacity(),
        error.data(),
        error.capacity()
    );

    bridge_fuzz::exercise_snapshot_copy(harness.client());
    bridge_fuzz::exercise_detail_copies(harness.client());
    bridge_fuzz::drain_alert_error(harness.client());

    if (result == 0 || bridge_fuzz::snapshot_required_count(harness.client()) > 16) {
        bridge_fuzz::remove_all_torrents(harness.client());
    }

    return 0;
}
