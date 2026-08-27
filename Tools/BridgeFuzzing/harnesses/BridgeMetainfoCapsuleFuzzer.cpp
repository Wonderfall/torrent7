#include "BridgeFuzzSupport.hpp"

#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>
#include <vector>

namespace {

[[nodiscard]] std::optional<std::uint8_t> hex_nibble(std::uint8_t const value)
{
    if (value >= '0' && value <= '9') {
        return static_cast<std::uint8_t>(value - '0');
    }
    if (value >= 'a' && value <= 'f') {
        return static_cast<std::uint8_t>(value - 'a' + 10U);
    }
    if (value >= 'A' && value <= 'F') {
        return static_cast<std::uint8_t>(value - 'A' + 10U);
    }
    return std::nullopt;
}

[[nodiscard]] std::optional<std::vector<std::uint8_t>> decode_hex_seed(
    std::uint8_t const *data,
    std::size_t const size
)
{
    constexpr std::string_view prefix = "hex:";
    if (size < prefix.size()) {
        return std::nullopt;
    }
    for (std::size_t index = 0; index < prefix.size(); ++index) {
        if (data[index] != static_cast<std::uint8_t>(prefix[index])) {
            return std::nullopt;
        }
    }

    std::size_t const digit_count = size - prefix.size();
    if ((digit_count % 2U) != 0U) {
        return std::nullopt;
    }
    std::vector<std::uint8_t> decoded;
    decoded.reserve(digit_count / 2U);
    for (std::size_t index = prefix.size(); index < size; index += 2U) {
        std::optional<std::uint8_t> const high = hex_nibble(data[index]);
        std::optional<std::uint8_t> const low = hex_nibble(data[index + 1U]);
        if (!high || !low) {
            return std::nullopt;
        }
        decoded.push_back(static_cast<std::uint8_t>((*high << 4U) | *low));
    }
    return decoded;
}

} // namespace

extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    auto &harness = bridge_fuzz::shared_harness("bridge-metainfo-capsule");
    std::optional<std::vector<std::uint8_t>> const decoded = decode_hex_seed(data, size);
    std::uint8_t const *capsule = decoded ? decoded->data() : data;
    std::size_t const capsule_size = decoded ? decoded->size() : size;
    int32_t const capsule_size_for_bridge = capsule_size <= std::numeric_limits<int32_t>::max()
        ? static_cast<int32_t>(capsule_size)
        : -1;

    constexpr std::string_view canonical_id = "t:00000000000000000000000000000002";
    TTorrentAddOptions options = bridge_fuzz::valid_add_options(canonical_id);
    bridge_fuzz::AddedIdBuffer added_id;
    bridge_fuzz::ErrorBuffer error;
    int32_t add_outcome = TTORRENT_ADD_REJECTED;
    std::uint64_t native_token = 0;
    TTorrentStorageActivation activation{};
    int32_t const result = TorrentClientAddMetainfoCapsule(
        harness.client(),
        capsule,
        capsule_size_for_bridge,
        activation,
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
