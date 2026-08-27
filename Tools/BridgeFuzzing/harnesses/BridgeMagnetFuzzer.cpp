#include "BridgeFuzzSupport.hpp"

#include <cstddef>
#include <cstdint>
extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    auto &harness = bridge_fuzz::shared_harness("bridge-magnet");
    bridge_fuzz::ByteReader reader(data, size);
    bridge_fuzz::MagnetImportInput const magnet = bridge_fuzz::magnet_import_from_reader(reader);

    constexpr std::string_view canonical_id = "t:00000000000000000000000000000001";
    TTorrentAddOptions options = bridge_fuzz::valid_add_options(canonical_id);
    bridge_fuzz::AddedIdBuffer added_id;
    bridge_fuzz::ErrorBuffer error;
    int32_t add_outcome = TTORRENT_ADD_REJECTED;
    std::uint64_t native_token = 0;
    int32_t const result = TorrentClientAddParsedMagnet(
        harness.client(),
        magnet.header,
        magnet.blob.data(),
        static_cast<int32_t>(magnet.blob.size()),
        magnet.trackers.data(),
        static_cast<int32_t>(magnet.trackers.size()),
        magnet.web_seeds.data(),
        static_cast<int32_t>(magnet.web_seeds.size()),
        magnet.file_selections.data(),
        static_cast<int32_t>(magnet.file_selections.size()),
        options,
        added_id.data(),
        added_id.capacity(),
        &native_token,
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
