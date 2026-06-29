#ifndef TORRENT_APP_TOOLS_FUZZING_BRIDGE_FUZZ_SUPPORT_HPP
#define TORRENT_APP_TOOLS_FUZZING_BRIDGE_FUZZ_SUPPORT_HPP

#include "TorrentBridge.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <unistd.h>
#include <vector>

namespace bridge_fuzz {

namespace fs = std::filesystem;

static_assert(TTORRENT_BRIDGE_ABI_VERSION == 26, "Update the fuzz harnesses for the current TorrentBridge ABI.");

inline constexpr int32_t kErrorCapacity = 1024;

inline void wake_callback(void *context)
{
    if (context == nullptr) {
        return;
    }

    auto *count = static_cast<std::atomic_uint64_t *>(context);
    count->fetch_add(1U, std::memory_order_relaxed);
}

class ByteReader {
public:
    ByteReader(std::uint8_t const *data, std::size_t size) noexcept
        : bytes_(data, size)
    {
    }

    [[nodiscard]] bool empty() const noexcept
    {
        return offset_ >= bytes_.size();
    }

    [[nodiscard]] std::size_t remaining() const noexcept
    {
        return offset_ >= bytes_.size() ? 0U : bytes_.size() - offset_;
    }

    std::uint8_t read_u8(std::uint8_t fallback = 0) noexcept
    {
        if (empty()) {
            return fallback;
        }
        return bytes_[offset_++];
    }

    bool read_bool() noexcept
    {
        return (read_u8() & 1U) != 0U;
    }

    std::uint16_t read_u16() noexcept
    {
        std::uint16_t value = read_u8();
        value |= static_cast<std::uint16_t>(read_u8()) << 8U;
        return value;
    }

    std::int32_t read_i32() noexcept
    {
        std::uint32_t value = read_u8();
        value |= static_cast<std::uint32_t>(read_u8()) << 8U;
        value |= static_cast<std::uint32_t>(read_u8()) << 16U;
        value |= static_cast<std::uint32_t>(read_u8()) << 24U;
        return static_cast<std::int32_t>(value);
    }

    std::string read_string(std::size_t max_length)
    {
        std::size_t length = 0;
        if (max_length > 0) {
            length = read_u16() % (max_length + 1U);
        }
        length = std::min(length, remaining());

        auto const begin = bytes_.begin() + static_cast<std::ptrdiff_t>(offset_);
        std::string value(
            reinterpret_cast<char const *>(std::to_address(begin)),
            reinterpret_cast<char const *>(std::to_address(begin + static_cast<std::ptrdiff_t>(length)))
        );
        offset_ += length;
        return value;
    }

    std::vector<char> read_bytes(std::size_t max_length)
    {
        std::size_t length = 0;
        if (max_length > 0) {
            length = read_u16() % (max_length + 1U);
        }
        length = std::min(length, remaining());

        auto const begin = bytes_.begin() + static_cast<std::ptrdiff_t>(offset_);
        std::vector<char> value(begin, begin + static_cast<std::ptrdiff_t>(length));
        offset_ += length;
        return value;
    }

private:
    std::span<std::uint8_t const> bytes_;
    std::size_t offset_ = 0;
};

inline std::string input_to_string(std::uint8_t const *data, std::size_t size, std::size_t max_size)
{
    if (data == nullptr || size == 0) {
        return {};
    }

    std::size_t const length = std::min(size, max_size);
    return {
        reinterpret_cast<char const *>(data),
        reinterpret_cast<char const *>(data + length)
    };
}

inline void remove_all_quietly(fs::path const &path) noexcept
{
    std::error_code ignored;
    fs::remove_all(path, ignored);
}

inline fs::path make_temp_root(std::string_view label)
{
    static std::atomic_uint64_t counter = 0;
    fs::path root = fs::temp_directory_path();
    root /= "torrent-app-fuzz-"
        + std::string(label)
        + "-"
        + std::to_string(static_cast<long long>(::getpid()))
        + "-"
        + std::to_string(counter.fetch_add(1, std::memory_order_relaxed));

    std::error_code ignored;
    fs::remove_all(root, ignored);
    fs::create_directories(root);
    fs::permissions(
        root,
        fs::perms::owner_all,
        fs::perm_options::replace
    );
    return root;
}

inline void write_file(fs::path const &path, std::span<char const> bytes)
{
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

struct ErrorBuffer {
    std::array<char, kErrorCapacity> bytes{};

    [[nodiscard]] char *data() noexcept
    {
        return bytes.data();
    }

    [[nodiscard]] int32_t capacity() const noexcept
    {
        return static_cast<int32_t>(bytes.size());
    }
};

struct AddedIdBuffer {
    std::array<char, TTORRENT_ID_CAPACITY> bytes{};

    [[nodiscard]] char *data() noexcept
    {
        return bytes.data();
    }

    [[nodiscard]] int32_t capacity() const noexcept
    {
        return static_cast<int32_t>(bytes.size());
    }
};

class BridgeClientHarness {
public:
    explicit BridgeClientHarness(std::string_view label)
        : root_(make_temp_root(label)),
          state_dir_(root_ / "state"),
          save_dir_(root_ / "downloads"),
          state_path_(state_dir_.string()),
          save_path_(save_dir_.string())
    {
        fs::create_directories(state_dir_);
        fs::create_directories(save_dir_);

        ErrorBuffer error;
        client_ = TorrentClientCreateWithError(state_path_.c_str(), 1, error.data(), error.capacity());
        if (client_ == nullptr) {
            std::abort();
        }

        TorrentClientSetWakeCallback(client_, wake_callback, &wake_count_);

        ErrorBuffer block_error;
        static_cast<void>(TorrentClientBlockNetwork(client_, block_error.data(), block_error.capacity()));
    }

    BridgeClientHarness(BridgeClientHarness const &) = delete;
    BridgeClientHarness &operator=(BridgeClientHarness const &) = delete;

    ~BridgeClientHarness()
    {
        if (client_ != nullptr) {
            TorrentClientClearWakeCallback(client_);
            TorrentClientDestroyBlocking(client_);
            client_ = nullptr;
        }
        remove_all_quietly(root_);
    }

    [[nodiscard]] TTorrentClient *client() const noexcept
    {
        return client_;
    }

    [[nodiscard]] char const *save_path() const noexcept
    {
        return save_path_.c_str();
    }

private:
    fs::path root_;
    fs::path state_dir_;
    fs::path save_dir_;
    std::string state_path_;
    std::string save_path_;
    TTorrentClient *client_ = nullptr;
    std::atomic_uint64_t wake_count_ = 0;
};

inline BridgeClientHarness &shared_harness(std::string_view label)
{
    static BridgeClientHarness harness(label);
    return harness;
}

inline int32_t snapshot_required_count(TTorrentClient *client)
{
    if (client == nullptr) {
        return 0;
    }

    std::uint64_t revision = 0;
    int32_t required_count = 0;
    static_cast<void>(TorrentClientCopySnapshotBatch(client, nullptr, 0, &revision, &required_count));
    return std::max<int32_t>(required_count, 0);
}

inline void exercise_change_copy(TTorrentClient *client)
{
    if (client == nullptr) {
        return;
    }

    uint32_t dirty_mask = 0;
    static_cast<void>(TorrentClientTakeChanges(client, nullptr));
    static_cast<void>(TorrentClientTakeChanges(client, &dirty_mask));

    TTorrentNetworkStatus status{};
    static_cast<void>(TorrentClientCopyNetworkStatus(client, nullptr));
    static_cast<void>(TorrentClientCopyNetworkStatus(client, &status));
}

inline void exercise_snapshot_copy(TTorrentClient *client)
{
    if (client == nullptr) {
        return;
    }

    std::array<TTorrentSnapshot, 8> snapshots{};
    std::uint64_t revision = 0;
    int32_t required_count = 0;
    static_cast<void>(TorrentClientCopySnapshotBatch(client, nullptr, 0, &revision, &required_count));
    static_cast<void>(TorrentClientCopySnapshotBatch(
        client,
        snapshots.data(),
        static_cast<int32_t>(snapshots.size()),
        &revision,
        &required_count
    ));

    std::array<TTorrentTrackerHostSnapshot, 8> tracker_hosts{};
    static_cast<void>(TorrentClientCopyTrackerHostBatch(client, nullptr, 0, &revision, &required_count));
    static_cast<void>(TorrentClientCopyTrackerHostBatch(
        client,
        tracker_hosts.data(),
        static_cast<int32_t>(tracker_hosts.size()),
        &revision,
        &required_count
    ));

    exercise_change_copy(client);
}

inline void drain_alert_error(TTorrentClient *client)
{
    if (client == nullptr) {
        return;
    }

    ErrorBuffer error;
    static_cast<void>(TorrentClientTakeAlertError(client, error.data(), error.capacity()));
}

inline std::vector<std::string> snapshot_ids(TTorrentClient *client)
{
    if (client == nullptr) {
        return {};
    }

    std::array<TTorrentSnapshot, 64> snapshots{};
    std::uint64_t revision = 0;
    int32_t required_count = 0;
    int32_t const copied = TorrentClientCopySnapshotBatch(
        client,
        snapshots.data(),
        static_cast<int32_t>(snapshots.size()),
        &revision,
        &required_count
    );

    std::vector<std::string> ids;
    for (int32_t index = 0; index < copied; ++index) {
        if (snapshots[static_cast<std::size_t>(index)].id[0] != '\0') {
            ids.emplace_back(snapshots[static_cast<std::size_t>(index)].id);
        }
    }
    return ids;
}

inline void exercise_detail_copies(TTorrentClient *client)
{
    if (client == nullptr) {
        return;
    }

    for (std::string const &id : snapshot_ids(client)) {
        ErrorBuffer error;
        static_cast<void>(TorrentClientRequestSources(client, id.c_str(), error.data(), error.capacity()));
        static_cast<void>(TorrentClientRequestFiles(client, id.c_str(), error.data(), error.capacity()));

        std::array<TTorrentTrackerSnapshot, 8> trackers{};
        std::array<TTorrentWebSeedSnapshot, 8> web_seeds{};
        std::array<TTorrentFileSnapshot, 16> files{};
        TTorrentWebSeedActivitySnapshot activity{};
        TTorrentPeerSourceSnapshot peer_sources{};
        TTorrentSourcePolicy policy{};
        TTorrentOptions options{};
        TTorrentPieceMapSnapshot piece_map{};
        std::array<std::uint8_t, 256> pieces{};
        std::uint64_t revision = 0;
        int32_t required_count = 0;

        static_cast<void>(TorrentClientCopySourcePolicy(client, id.c_str(), nullptr, error.data(), error.capacity()));
        static_cast<void>(TorrentClientCopySourcePolicy(client, id.c_str(), &policy, error.data(), error.capacity()));
        static_cast<void>(TorrentClientSetSourcePolicy(client, id.c_str(), &policy, error.data(), error.capacity()));
        static_cast<void>(TorrentClientCopyTorrentOptions(client, id.c_str(), nullptr, error.data(), error.capacity()));
        static_cast<void>(TorrentClientCopyTorrentOptions(client, id.c_str(), &options, error.data(), error.capacity()));
        static_cast<void>(TorrentClientSetTorrentOptions(client, id.c_str(), &options, error.data(), error.capacity()));
        static_cast<void>(TorrentClientCopyTrackerBatch(client, id.c_str(), nullptr, 0, &revision, &required_count));
        static_cast<void>(TorrentClientCopyTrackerBatch(
            client,
            id.c_str(),
            trackers.data(),
            static_cast<int32_t>(trackers.size()),
            &revision,
            &required_count
        ));
        static_cast<void>(TorrentClientCopyWebSeedBatch(client, id.c_str(), nullptr, 0, &revision, &required_count));
        static_cast<void>(TorrentClientCopyWebSeedBatch(
            client,
            id.c_str(),
            web_seeds.data(),
            static_cast<int32_t>(web_seeds.size()),
            &revision,
            &required_count
        ));
        static_cast<void>(TorrentClientCopyWebSeedActivity(client, id.c_str(), nullptr, &revision));
        static_cast<void>(TorrentClientCopyWebSeedActivity(client, id.c_str(), &activity, &revision));
        static_cast<void>(TorrentClientCopyPeerSources(client, id.c_str(), nullptr, &revision));
        static_cast<void>(TorrentClientCopyPeerSources(client, id.c_str(), &peer_sources, &revision));
        static_cast<void>(TorrentClientRequestPieceMap(client, id.c_str(), error.data(), error.capacity()));
        static_cast<void>(TorrentClientCopyPieceMap(client, id.c_str(), nullptr, nullptr, 0, &revision, &required_count));
        static_cast<void>(TorrentClientCopyPieceMap(
            client,
            id.c_str(),
            &piece_map,
            pieces.data(),
            static_cast<int32_t>(pieces.size()),
            &revision,
            &required_count
        ));
        static_cast<void>(TorrentClientCopyFileBatch(client, id.c_str(), nullptr, 0, &revision, &required_count));
        static_cast<void>(TorrentClientCopyFileBatch(
            client,
            id.c_str(),
            files.data(),
            static_cast<int32_t>(files.size()),
            &revision,
            &required_count
        ));
        static_cast<void>(TorrentClientSetFilePriority(
            client,
            id.c_str(),
            0,
            TTORRENT_FILE_PRIORITY_NORMAL,
            error.data(),
            error.capacity()
        ));
    }
}

inline void remove_all_torrents(TTorrentClient *client)
{
    if (client == nullptr) {
        return;
    }

    for (int round = 0; round < 8; ++round) {
        std::vector<std::string> ids = snapshot_ids(client);
        if (ids.empty()) {
            return;
        }

        for (std::string const &id : ids) {
            ErrorBuffer error;
            static_cast<void>(TorrentClientRemove(client, id.c_str(), 0, 1, error.data(), error.capacity()));
        }
    }
}

inline TTorrentSessionSettings settings_from_reader(ByteReader &reader, std::string &network_interface)
{
    TTorrentSessionSettings settings{};
    settings.download_rate_limit = reader.read_i32();
    settings.upload_rate_limit = reader.read_i32();
    settings.active_downloads = reader.read_i32();
    settings.active_seeds = reader.read_i32();
    settings.active_limit = reader.read_i32();
    settings.share_ratio_limit = reader.read_i32();
    settings.seed_time_limit = reader.read_i32();
    settings.incoming_port = reader.read_i32();
    settings.accept_incoming_connections = reader.read_u8();
    settings.enable_port_forwarding = reader.read_u8();
    settings.enable_dht = reader.read_u8();
    settings.use_dht_by_default = reader.read_u8();
    settings.enable_lsd = reader.read_u8();
    settings.use_lsd_by_default = reader.read_u8();
    settings.use_pex_by_default = reader.read_u8();
    settings.require_https_trackers = reader.read_u8();
    settings.require_https_web_seeds = reader.read_u8();
    settings.encryption_policy = reader.read_i32();
    settings.anonymous_mode = reader.read_u8();
    settings.network_blocked = reader.read_u8();

    network_interface = reader.read_string(128);
    settings.required_network_interface = reader.read_bool() ? nullptr : network_interface.c_str();
    return settings;
}

inline TTorrentAddOptions add_options_from_reader(ByteReader &reader)
{
    TTorrentAddOptions options{};
    options.starts_paused = reader.read_u8();
    options.queue_priority = reader.read_u8();
    options.enable_peer_exchange = reader.read_u8();
    options.allow_non_https_trackers = reader.read_u8();
    options.allow_non_https_web_seeds = reader.read_u8();
    return options;
}

inline std::vector<TTorrentFilePriorityEntry> file_priorities_from_reader(ByteReader &reader)
{
    std::vector<TTorrentFilePriorityEntry> priorities;
    int const count = reader.read_u8() % 16U;
    priorities.reserve(static_cast<std::size_t>(count));
    for (int index = 0; index < count; ++index) {
        priorities.push_back(TTorrentFilePriorityEntry{
            .index = reader.read_i32(),
            .priority = reader.read_i32(),
        });
    }
    return priorities;
}

inline TTorrentOptions torrent_options_from_reader(ByteReader &reader)
{
    TTorrentOptions options{};
    options.download_rate_limit = reader.read_i32();
    options.upload_rate_limit = reader.read_i32();
    options.max_uploads = reader.read_i32();
    options.max_connections = reader.read_i32();
    options.queue_priority = reader.read_i32();
    return options;
}

inline TTorrentSourcePolicy source_policy_from_reader(ByteReader &reader)
{
    TTorrentSourcePolicy policy{};
    policy.enable_dht = reader.read_u8();
    policy.enable_peer_exchange = reader.read_u8();
    policy.enable_lsd = reader.read_u8();
    policy.require_https_trackers = reader.read_u8();
    policy.require_https_web_seeds = reader.read_u8();
    policy.dht_locked = reader.read_u8();
    policy.peer_exchange_locked = reader.read_u8();
    policy.lsd_locked = reader.read_u8();
    return policy;
}

} // namespace bridge_fuzz

#endif
