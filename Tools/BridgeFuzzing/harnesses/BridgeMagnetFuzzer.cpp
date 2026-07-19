#include "BridgeFuzzSupport.hpp"

#include <cstddef>
#include <cstdint>
#include <string>

extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    auto &harness = bridge_fuzz::shared_harness("bridge-magnet");
    std::string magnet = bridge_fuzz::input_to_string(data, size, 64U * 1024U + 16U);

    TTorrentSourceSecurityInspection inspection{};
    static_cast<void>(TorrentBridgeInspectMagnetSources(magnet.c_str(), &inspection));

    TTorrentAddOptions options{
        .starts_paused = 1,
        .queue_priority = TTORRENT_QUEUE_PRIORITY_NORMAL,
        .enable_peer_exchange = 0,
        .allow_non_https_trackers = 0,
        .allow_non_https_web_seeds = 0,
        .allow_pre_metadata_dht = 0,
    };
    bridge_fuzz::AddedIdBuffer added_id;
    bridge_fuzz::ErrorBuffer error;
    int32_t add_outcome = TTORRENT_ADD_REJECTED;
    int32_t const result = TorrentClientAddMagnet(
        harness.client(),
        magnet.c_str(),
        harness.save_path(),
        &options,
        added_id.data(),
        added_id.capacity(),
        &add_outcome,
        error.data(),
        error.capacity()
    );
    if (add_outcome < TTORRENT_ADD_REJECTED || add_outcome > TTORRENT_ADD_OUTCOME_UNKNOWN
        || (result == 0 && add_outcome != TTORRENT_ADD_COMMITTED)) {
        __builtin_trap();
    }

    bridge_fuzz::exercise_snapshot_copy(harness.client());
    bridge_fuzz::exercise_detail_copies(harness.client());
    bridge_fuzz::drain_alert_error(harness.client());

    if (result == 0 || bridge_fuzz::snapshot_required_count(harness.client()) > 16) {
        bridge_fuzz::remove_all_torrents(harness.client());
    }

    return 0;
}
