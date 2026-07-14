#include "BridgeFuzzSupport.hpp"

#include <array>
#include <atomic>
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

void poll_tracked_removal(bridge_fuzz::BridgeClientHarness &harness)
{
    std::optional<std::uint64_t> &request_token = harness.tracked_removal_token();
    if (!request_token.has_value()) {
        return;
    }

    TTorrentRemovalResult result{};
    bridge_fuzz::ErrorBuffer error;
    int32_t const status = TorrentClientTakeRemovalResult(
        harness.client(),
        *request_token,
        &result,
        error.data(),
        error.capacity()
    );
    if (status == 0 && result.state != TTORRENT_REMOVAL_PENDING) {
        request_token.reset();
    }
}

std::uint64_t malformed_removal_token(
    bridge_fuzz::ByteReader &reader,
    std::optional<std::uint64_t> const &tracked_token
)
{
    std::uint64_t token = static_cast<std::uint64_t>(static_cast<std::uint32_t>(reader.read_i32()));
    if (tracked_token == token) {
        ++token;
    }
    return token;
}

} // namespace

extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    auto &harness = bridge_fuzz::shared_harness("bridge-session-api");
    poll_tracked_removal(harness);
    bridge_fuzz::ByteReader reader(data, size);
    std::uint8_t const operation_count = static_cast<std::uint8_t>(1U + (reader.read_u8() % 28U));

    for (std::uint8_t operation = 0; operation < operation_count; ++operation) {
        bridge_fuzz::ErrorBuffer error;

        switch (reader.read_u8() % 20U) {
        case 0: {
            std::string magnet = reader.read_string(2048);
            std::string save_path = reader.read_bool() ? std::string(harness.save_path()) : reader.read_string(256);
            TTorrentAddOptions options = bridge_fuzz::add_options_from_reader(reader);
            bridge_fuzz::AddedIdBuffer added_id;
            static_cast<void>(TorrentClientAddMagnet(
                harness.client(),
                maybe_null(reader, magnet),
                maybe_null(reader, save_path),
                reader.read_bool() ? nullptr : &options,
                reader.read_bool() ? nullptr : added_id.data(),
                reader.read_bool() ? -1 : added_id.capacity(),
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 1: {
            std::vector<char> bytes = reader.read_bytes(8192);
            std::string save_path = reader.read_bool() ? std::string(harness.save_path()) : reader.read_string(256);
            TTorrentAddOptions options = bridge_fuzz::add_options_from_reader(reader);
            bridge_fuzz::AddedIdBuffer added_id;
            static_cast<void>(TorrentClientAddTorrentFileData(
                harness.client(),
                bytes.empty() || reader.read_bool() ? nullptr : bytes.data(),
                reader.read_bool() ? -1 : static_cast<int32_t>(bytes.size()),
                maybe_null(reader, save_path),
                reader.read_bool() ? nullptr : &options,
                reader.read_bool() ? nullptr : added_id.data(),
                reader.read_bool() ? -1 : added_id.capacity(),
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 2: {
            std::vector<char> bytes = reader.read_bytes(8192);
            std::vector<TTorrentFilePriorityEntry> priorities = bridge_fuzz::file_priorities_from_reader(reader);
            std::string save_path = reader.read_bool() ? std::string(harness.save_path()) : reader.read_string(256);
            TTorrentAddOptions options = bridge_fuzz::add_options_from_reader(reader);
            bridge_fuzz::AddedIdBuffer added_id;
            int32_t const priority_count = reader.read_bool()
                ? -1
                : static_cast<int32_t>(priorities.size());
            static_cast<void>(TorrentClientAddTorrentFileDataWithPriorities(
                harness.client(),
                bytes.empty() || reader.read_bool() ? nullptr : bytes.data(),
                reader.read_bool() ? -1 : static_cast<int32_t>(bytes.size()),
                maybe_null(reader, save_path),
                reader.read_bool() ? nullptr : &options,
                priorities.empty() || reader.read_bool() ? nullptr : priorities.data(),
                priority_count,
                reader.read_bool() ? nullptr : added_id.data(),
                reader.read_bool() ? -1 : added_id.capacity(),
                error.data(),
                error.capacity()
            ));
            break;
        }
        case 3: {
            std::vector<char> bytes = reader.read_bytes(8192);
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
                reader.read_bool() ? nullptr : &settings,
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
            poll_tracked_removal(harness);
            std::string id = selected_id(reader, harness.client());
            std::uint64_t request_token = 0;
            static_cast<void>(TorrentClientRemove(
                harness.client(),
                maybe_null(reader, id),
                reader.read_u8(),
                reader.read_u8(),
                reader.read_bool() ? nullptr : &request_token,
                error.data(),
                error.capacity()
            ));
            if (request_token != 0) {
                harness.tracked_removal_token() = request_token;
            }
            TTorrentRemovalResult result{};
            static_cast<void>(TorrentClientTakeRemovalResult(
                harness.client(),
                malformed_removal_token(reader, harness.tracked_removal_token()),
                reader.read_bool() ? nullptr : &result,
                error.data(),
                error.capacity()
            ));
            poll_tracked_removal(harness);
            break;
        }
        case 9: {
            std::string id = selected_id(reader, harness.client());
            TTorrentSourcePolicy policy = bridge_fuzz::source_policy_from_reader(reader);
            static_cast<void>(TorrentClientCopySourcePolicy(
                harness.client(),
                maybe_null(reader, id),
                reader.read_bool() ? nullptr : &policy,
                error.data(),
                error.capacity()
            ));
            static_cast<void>(TorrentClientSetSourcePolicy(
                harness.client(),
                maybe_null(reader, id),
                reader.read_bool() ? nullptr : &policy,
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
                reader.read_bool() ? nullptr : &options,
                error.data(),
                error.capacity()
            ));
            static_cast<void>(TorrentClientSetTorrentOptions(
                harness.client(),
                maybe_null(reader, id),
                reader.read_bool() ? nullptr : &options,
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
                reader.read_bool() ? nullptr : &required_count
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
        case 16:
            if (reader.read_bool()) {
                TorrentClientClearWakeCallback(harness.client());
            } else {
                static std::atomic_uint64_t wake_count = 0;
                TorrentClientSetWakeCallback(harness.client(), bridge_fuzz::wake_callback, &wake_count);
            }
            break;
        case 17: {
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
        case 18:
            TorrentClientSaveAll(harness.client());
            static_cast<void>(TorrentBridgeLibtorrentVersion());
            break;
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
    poll_tracked_removal(harness);
    return 0;
}
