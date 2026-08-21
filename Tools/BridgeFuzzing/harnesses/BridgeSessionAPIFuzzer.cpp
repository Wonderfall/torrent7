#include "BridgeFuzzSupport.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace {

std::string selected_id(bridge_fuzz::ByteReader &reader, TTorrentClient *client)
{
    std::vector<std::string> ids = bridge_fuzz::snapshot_ids(client);
    if (!ids.empty() && reader.read_bool()) {
        return ids[reader.read_u8() % ids.size()];
    }

    return reader.read_string(96);
}

char const *maybe_null(bridge_fuzz::ByteReader &reader, std::string const &value)
{
    return reader.read_bool() ? nullptr : value.c_str();
}

} // namespace

extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    auto &harness = bridge_fuzz::shared_harness("bridge-session-api");
    bridge_fuzz::ByteReader reader(data, size);
    std::uint8_t const operation_count = static_cast<std::uint8_t>(1U + (reader.read_u8() % 28U));

    for (std::uint8_t operation = 0; operation < operation_count; ++operation) {
        bridge_fuzz::ErrorBuffer error;

        switch (reader.read_u8() % 20U) {
        case 0: {
            std::string magnet = reader.read_string(2048);
            TTorrentAddOptions options = bridge_fuzz::add_options_from_reader(reader);
            bridge_fuzz::AddedIdBuffer added_id;
            int32_t add_outcome = TTORRENT_ADD_REJECTED;
            static_cast<void>(TorrentClientAddMagnet(
                harness.client(),
                maybe_null(reader, magnet),
                options,
                reader.read_bool() ? nullptr : added_id.data(),
                reader.read_bool() ? -1 : added_id.capacity(),
                reader.read_bool() ? nullptr : &add_outcome,
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 1: {
            std::vector<std::uint8_t> bytes = reader.read_bytes(8192);
            TTorrentStorageActivation activation =
                bridge_fuzz::storage_activation_from_reader(reader);
            TTorrentAddOptions options = bridge_fuzz::add_options_from_reader(reader);
            bridge_fuzz::AddedIdBuffer added_id;
            int32_t add_outcome = TTORRENT_ADD_REJECTED;
            static_cast<void>(TorrentClientAddTorrentFileData(
                harness.client(),
                bytes.empty() || reader.read_bool() ? nullptr : bytes.data(),
                reader.read_bool() ? -1 : static_cast<int32_t>(bytes.size()),
                activation,
                options,
                reader.read_bool() ? nullptr : added_id.data(),
                reader.read_bool() ? -1 : added_id.capacity(),
                reader.read_bool() ? nullptr : &add_outcome,
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 2: {
            std::vector<std::uint8_t> bytes = reader.read_bytes(8192);
            std::vector<TTorrentFilePriorityEntry> priorities = bridge_fuzz::file_priorities_from_reader(reader);
            TTorrentStorageActivation activation =
                bridge_fuzz::storage_activation_from_reader(reader);
            TTorrentAddOptions options = bridge_fuzz::add_options_from_reader(reader);
            bridge_fuzz::AddedIdBuffer added_id;
            int32_t add_outcome = TTORRENT_ADD_REJECTED;
            int32_t const priority_count = reader.read_bool()
                ? -1
                : static_cast<int32_t>(priorities.size());
            static_cast<void>(TorrentClientAddTorrentFileDataWithPriorities(
                harness.client(),
                bytes.empty() || reader.read_bool() ? nullptr : bytes.data(),
                reader.read_bool() ? -1 : static_cast<int32_t>(bytes.size()),
                activation,
                options,
                priorities.empty() || reader.read_bool() ? nullptr : priorities.data(),
                priority_count,
                reader.read_bool() ? nullptr : added_id.data(),
                reader.read_bool() ? -1 : added_id.capacity(),
                reader.read_bool() ? nullptr : &add_outcome,
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 3: {
            std::vector<std::uint8_t> bytes = reader.read_bytes(8192);
            std::array<TTorrentFileSnapshot, 16> files{};
            TTorrentFilePreview preview{};
            int32_t required_count = 0;
            static_cast<void>(TorrentClientPreviewTorrentFileData(
                harness.client(),
                bytes.empty() || reader.read_bool() ? nullptr : bytes.data(),
                reader.read_bool() ? -1 : static_cast<int32_t>(bytes.size()),
                reader.read_bool() ? nullptr : &preview,
                reader.read_bool() ? nullptr : files.data(),
                reader.read_bool() ? -1 : static_cast<int32_t>(files.size()),
                reader.read_bool() ? nullptr : &required_count,
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 4: {
            std::string network_interface;
            TTorrentSessionSettings settings = bridge_fuzz::settings_from_reader(reader, network_interface);
            static_cast<void>(TorrentClientApplySettings(
                harness.client(),
                settings,
                reader.read_bool() ? nullptr : network_interface.c_str(),
                reader.read_bool() ? -1 : static_cast<int32_t>(network_interface.size()),
                error.data(),
                error.capacity()
            ));
            static_cast<void>(TorrentClientBlockNetwork(harness.client(), error.data(), error.capacity()));
            break;
        }
        case 5: {
            std::string id = selected_id(reader, harness.client());
            static_cast<void>(TorrentClientPause(
                harness.client(),
                maybe_null(reader, id),
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 6: {
            std::string id = selected_id(reader, harness.client());
            static_cast<void>(TorrentClientResume(
                harness.client(),
                maybe_null(reader, id),
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 7: {
            std::string id = selected_id(reader, harness.client());
            if (reader.read_bool()) {
                static_cast<void>(TorrentClientReannounce(
                    harness.client(),
                    maybe_null(reader, id),
                    error.data(),
                    error.capacity()
                ));
            } else {
                static_cast<void>(TorrentClientForceRecheck(
                    harness.client(),
                    maybe_null(reader, id),
                    error.data(),
                    error.capacity()
                ));
            }
            break;
        }
        case 8: {
            std::string id = selected_id(reader, harness.client());
            std::uint8_t removal_committed = 0;
            static_cast<void>(TorrentClientRemove(
                harness.client(),
                maybe_null(reader, id),
                reader.read_bool() ? nullptr : &removal_committed,
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 9: {
            std::string id = selected_id(reader, harness.client());
            static_cast<void>(TorrentClientCopySourcePolicy(
                harness.client(),
                maybe_null(reader, id),
                error.data(),
                error.capacity()
            ));
            static_cast<void>(TorrentClientSetSourcePolicyField(
                harness.client(),
                maybe_null(reader, id),
                reader.read_i32(),
                reader.read_u8(),
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 10: {
            std::string id = selected_id(reader, harness.client());
            TTorrentOptions options = bridge_fuzz::torrent_options_from_reader(reader);
            static_cast<void>(TorrentClientCopyTorrentOptions(
                harness.client(),
                maybe_null(reader, id),
                error.data(),
                error.capacity()
            ));
            static_cast<void>(TorrentClientSetTorrentOptions(
                harness.client(),
                maybe_null(reader, id),
                options,
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 11: {
            std::string id = selected_id(reader, harness.client());
            static_cast<void>(TorrentClientMoveTorrentInQueue(
                harness.client(),
                maybe_null(reader, id),
                reader.read_i32(),
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 12: {
            std::string id = selected_id(reader, harness.client());
            static_cast<void>(TorrentClientSetFilePriority(
                harness.client(),
                maybe_null(reader, id),
                reader.read_i32(),
                reader.read_i32(),
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 13: {
            std::string id = selected_id(reader, harness.client());
            TTorrentPieceMapSnapshot piece_map{};
            std::array<std::uint8_t, 256> pieces{};
            std::uint64_t revision = 0;
            int32_t required_count = 0;
            std::uint8_t resident = 0;
            static_cast<void>(TorrentClientRequestPieceMap(
                harness.client(),
                maybe_null(reader, id),
                error.data(),
                error.capacity()
            ));
            static_cast<void>(TorrentClientCopyPieceMap(
                harness.client(),
                maybe_null(reader, id),
                reader.read_bool() ? nullptr : &piece_map,
                reader.read_bool() ? nullptr : pieces.data(),
                reader.read_bool() ? -1 : static_cast<int32_t>(pieces.size()),
                reader.read_bool() ? nullptr : &revision,
                reader.read_bool() ? nullptr : &required_count,
                reader.read_bool() ? nullptr : &resident
            ));
            break;
        }
        case 14:
            bridge_fuzz::exercise_snapshot_copy(harness.client());
            bridge_fuzz::exercise_detail_copies(harness.client());
            break;
        case 15:
            if (reader.read_bool()) {
                static_cast<void>(TorrentClientSaveAllChecked(harness.client(), error.data(), error.capacity()));
            } else {
                static_cast<void>(TorrentClientBlockNetwork(harness.client(), error.data(), error.capacity()));
            }
            bridge_fuzz::drain_alert_error(harness.client());
            break;
        case 16: {
            std::string id = selected_id(reader, harness.client());
            if (reader.read_bool()) {
                static_cast<void>(TorrentClientRequestSources(
                    harness.client(),
                    maybe_null(reader, id),
                    error.data(),
                    error.capacity()
                ));
            } else {
                static_cast<void>(TorrentClientRequestFiles(
                    harness.client(),
                    maybe_null(reader, id),
                    error.data(),
                    error.capacity()
                ));
            }
            break;
        }
        case 17:
            TorrentClientSaveAll(harness.client());
            static_cast<void>(TorrentBridgeLibtorrentVersion());
            break;
        case 18: {
            std::uint32_t dirty_mask = 0;
            static_cast<void>(TorrentClientTakeChanges(
                harness.client(),
                reader.read_bool() ? nullptr : &dirty_mask
            ));
            break;
        }
        default:
            bridge_fuzz::exercise_change_copy(harness.client());
            bridge_fuzz::drain_alert_error(harness.client());
            break;
        }

        if (bridge_fuzz::snapshot_required_count(harness.client()) > 32) {
            bridge_fuzz::remove_all_torrents(harness.client());
        }
    }

    bridge_fuzz::exercise_snapshot_copy(harness.client());
    bridge_fuzz::exercise_detail_copies(harness.client());
    bridge_fuzz::drain_alert_error(harness.client());
    return 0;
}
