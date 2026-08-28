#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <libtorrent/aux_/preparsed_metainfo.hpp>
#include <libtorrent/create_torrent.hpp>

#include <array>
#include <atomic>
#include <bit>
#include <cerrno>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

[[nodiscard]] lt::add_torrent_params make_source_torrent_params(bool const private_torrent = false)
{
    std::vector<lt::create_file_entry> files;
    files.emplace_back("source-test.bin", 4);

    lt::create_torrent creator(
        std::move(files),
        16 * 1024,
        lt::create_torrent::v1_only | lt::create_torrent::symlinks
    );
    creator.set_priv(private_torrent);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(12U));
    creator.add_tracker("http://tracker.example/announce", 0);
    creator.add_tracker("https://secure-tracker.example/announce", 1);
    creator.add_url_seed("http://seed.example/file");
    creator.add_url_seed("https://secure-seed.example/file");

    std::vector<char> const buffer = creator.generate_buf();
    return bridge_tests::load_torrent_params(buffer, "source test torrent info");
}

[[nodiscard]] std::shared_ptr<lt::torrent_info const> make_file_priority_torrent_info()
{
    std::vector<lt::create_file_entry> files;
    files.emplace_back("files/high.bin", 4);
    files.emplace_back("files/skip.bin", 4);
    files.emplace_back("files/low.bin", 4);

    lt::create_torrent creator(std::move(files), 16 * 1024, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), bridge_tests::sha1_hash_from_seed(14U));

    std::vector<char> const buffer = creator.generate_buf();
    return bridge_tests::load_torrent_params(buffer, "file priority test torrent info").ti;
}

void append_bencoded_string(std::vector<char> &buffer, std::string_view value)
{
    std::string const size = std::to_string(value.size());
    buffer.insert(buffer.end(), size.begin(), size.end());
    buffer.push_back(':');
    buffer.insert(buffer.end(), value.begin(), value.end());
}

void append_bencoded_string(std::string &buffer, std::string_view value)
{
    buffer += std::to_string(value.size());
    buffer.push_back(':');
    buffer.append(value);
}

struct CapsuleFileFixture {
    std::vector<std::string> components;
    std::int64_t size;
    std::uint32_t flags = 0U;
    std::optional<std::uint32_t> info_root_offset;
};

struct CapsuleLayerFixture {
    std::array<std::uint8_t, 32U> root;
    std::vector<std::uint8_t> hashes;
    std::vector<std::int32_t> file_indices;
};

struct MetainfoCapsuleFixture {
    std::vector<std::uint8_t> bytes;
    std::uint32_t info_offset = 0U;
    std::uint32_t component_table_offset = 0U;
    std::uint32_t file_table_offset = 0U;
    std::uint32_t piece_layer_table_offset = 0U;
};

void write_u16(std::vector<std::uint8_t> &bytes, std::size_t const offset, std::uint16_t const value)
{
    bytes.at(offset) = static_cast<std::uint8_t>(value);
    bytes.at(offset + 1U) = static_cast<std::uint8_t>(value >> 8U);
}

void write_u32(std::vector<std::uint8_t> &bytes, std::size_t const offset, std::uint32_t const value)
{
    for (std::size_t byte = 0U; byte < sizeof(value); ++byte) {
        bytes.at(offset + byte) = static_cast<std::uint8_t>(value >> (byte * 8U));
    }
}

void write_i32(std::vector<std::uint8_t> &bytes, std::size_t const offset, std::int32_t const value)
{
    write_u32(bytes, offset, std::bit_cast<std::uint32_t>(value));
}

void write_i64(std::vector<std::uint8_t> &bytes, std::size_t const offset, std::int64_t const value)
{
    std::uint64_t const bits = std::bit_cast<std::uint64_t>(value);
    for (std::size_t byte = 0U; byte < sizeof(bits); ++byte) {
        bytes.at(offset + byte) = static_cast<std::uint8_t>(bits >> (byte * 8U));
    }
}

[[nodiscard]] std::size_t align_up(std::size_t const value, std::size_t const alignment)
{
    std::size_t const remainder = value % alignment;
    return remainder == 0U ? value : value + alignment - remainder;
}

[[nodiscard]] std::pair<std::uint32_t, std::uint32_t> append_capsule_bytes(
    std::vector<std::uint8_t> &bytes,
    std::span<std::uint8_t const> const value
)
{
    auto const offset = static_cast<std::uint32_t>(bytes.size());
    auto const size = static_cast<std::uint32_t>(value.size());
    bytes.insert(bytes.end(), value.begin(), value.end());
    return {offset, size};
}

[[nodiscard]] std::pair<std::uint32_t, std::uint32_t> append_capsule_string(
    std::vector<std::uint8_t> &bytes,
    std::string_view const value
)
{
    std::vector<std::uint8_t> encoded;
    encoded.reserve(value.size());
    std::ranges::transform(value, std::back_inserter(encoded), [](char const character) {
        return static_cast<std::uint8_t>(character);
    });
    return append_capsule_bytes(bytes, encoded);
}

void write_capsule_range(
    std::vector<std::uint8_t> &bytes,
    std::size_t const destination,
    std::pair<std::uint32_t, std::uint32_t> const range
)
{
    write_u32(bytes, destination, range.first);
    write_u32(bytes, destination + 4U, range.second);
}

[[nodiscard]] MetainfoCapsuleFixture make_metainfo_capsule(
    std::string const &info,
    std::string const &name,
    std::uint8_t const kind,
    std::uint8_t const content_kind,
    std::vector<CapsuleFileFixture> const &files,
    std::optional<std::pair<std::uint32_t, std::uint32_t>> const v1_piece_hashes = std::nullopt,
    std::vector<CapsuleLayerFixture> const &layers = {},
    bool const private_torrent = false,
    std::vector<std::pair<std::string, std::uint8_t>> const &trackers = {},
    std::vector<std::string> const &web_seeds = {},
    std::string const &comment = {},
    std::int64_t const creation_date = -1,
    std::uint8_t const input_kind = TTORRENT_METAINFO_INPUT_TORRENT_FILE
)
{
    std::size_t component_count = 0U;
    for (CapsuleFileFixture const &file : files) {
        component_count += file.components.size();
    }
    std::size_t layer_file_index_count = 0U;
    for (CapsuleLayerFixture const &layer : layers) {
        layer_file_index_count += layer.file_indices.size();
    }

    std::size_t cursor = TTORRENT_METAINFO_CAPSULE_HEADER_SIZE;
    cursor = align_up(cursor, 8U);
    std::size_t const file_table = cursor;
    cursor += files.size() * TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE;
    cursor = align_up(cursor, 4U);
    std::size_t const component_table = cursor;
    cursor += component_count * TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE;
    cursor = align_up(cursor, 4U);
    std::size_t const tracker_table = cursor;
    cursor += trackers.size() * TTORRENT_METAINFO_CAPSULE_TRACKER_RECORD_SIZE;
    cursor = align_up(cursor, 4U);
    std::size_t const web_seed_table = cursor;
    cursor += web_seeds.size() * TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE;
    cursor = align_up(cursor, 4U);
    std::size_t const piece_layer_table = cursor;
    cursor += layers.size() * TTORRENT_METAINFO_CAPSULE_PIECE_LAYER_RECORD_SIZE;
    cursor = align_up(cursor, 4U);
    std::size_t const piece_layer_file_index_table = cursor;
    cursor += layer_file_index_count * TTORRENT_METAINFO_CAPSULE_FILE_INDEX_RECORD_SIZE;
    std::size_t const payload = align_up(cursor, 8U);

    MetainfoCapsuleFixture fixture{
        .bytes = std::vector<std::uint8_t>(payload, 0U),
        .info_offset = 0U,
        .component_table_offset = static_cast<std::uint32_t>(component_table),
        .file_table_offset = static_cast<std::uint32_t>(file_table),
        .piece_layer_table_offset = static_cast<std::uint32_t>(piece_layer_table),
    };
    auto &bytes = fixture.bytes;
    write_u32(bytes, 0U, TTORRENT_METAINFO_CAPSULE_MAGIC);
    write_u16(bytes, 4U, TTORRENT_METAINFO_CAPSULE_SCHEMA_VERSION);
    write_u16(bytes, 6U, TTORRENT_METAINFO_CAPSULE_HEADER_SIZE);
    bytes.at(12U) = input_kind;
    bytes.at(13U) = kind;
    bytes.at(14U) = content_kind;
    bytes.at(15U) = private_torrent ? TTORRENT_METAINFO_PRIVATE : 0U;
    write_u32(bytes, 20U, 16U * 1024U);
    write_u32(bytes, 64U, static_cast<std::uint32_t>(file_table));
    write_u32(bytes, 68U, static_cast<std::uint32_t>(files.size()));
    write_u32(bytes, 72U, static_cast<std::uint32_t>(component_table));
    write_u32(bytes, 76U, static_cast<std::uint32_t>(component_count));
    write_u32(bytes, 80U, static_cast<std::uint32_t>(tracker_table));
    write_u32(bytes, 84U, static_cast<std::uint32_t>(trackers.size()));
    write_u32(bytes, 88U, static_cast<std::uint32_t>(web_seed_table));
    write_u32(bytes, 92U, static_cast<std::uint32_t>(web_seeds.size()));
    write_u32(bytes, 96U, static_cast<std::uint32_t>(piece_layer_table));
    write_u32(bytes, 100U, static_cast<std::uint32_t>(layers.size()));
    write_u32(bytes, 104U, static_cast<std::uint32_t>(piece_layer_file_index_table));
    write_u32(bytes, 108U, static_cast<std::uint32_t>(layer_file_index_count));
    write_i64(bytes, 128U, creation_date);
    write_u32(bytes, 136U, static_cast<std::uint32_t>(payload));
    write_u16(bytes, 144U, TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE);
    write_u16(bytes, 146U, TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE);
    write_u16(bytes, 148U, TTORRENT_METAINFO_CAPSULE_TRACKER_RECORD_SIZE);
    write_u16(bytes, 150U, TTORRENT_METAINFO_CAPSULE_PIECE_LAYER_RECORD_SIZE);
    write_u16(bytes, 152U, TTORRENT_METAINFO_CAPSULE_FILE_INDEX_RECORD_SIZE);

    std::uint16_t present_fields = 0U;
    if (!trackers.empty()) {
        present_fields = static_cast<std::uint16_t>(present_fields
            + TTORRENT_METAINFO_FIELD_ANNOUNCE_LIST);
    }
    if (!web_seeds.empty()) {
        present_fields = static_cast<std::uint16_t>(present_fields
            + TTORRENT_METAINFO_FIELD_URL_LIST);
    }
    if (!layers.empty()) {
        present_fields = static_cast<std::uint16_t>(present_fields
            + TTORRENT_METAINFO_FIELD_PIECE_LAYERS);
    }
    if (!comment.empty()) {
        present_fields = static_cast<std::uint16_t>(present_fields
            + TTORRENT_METAINFO_FIELD_COMMENT);
    }
    if (creation_date >= 0) {
        present_fields = static_cast<std::uint16_t>(present_fields
            + TTORRENT_METAINFO_FIELD_CREATION_DATE);
    }
    write_u16(bytes, 16U, present_fields);

    std::vector<std::uint8_t> info_bytes;
    info_bytes.reserve(info.size());
    std::ranges::transform(info, std::back_inserter(info_bytes), [](char const character) {
        return static_cast<std::uint8_t>(character);
    });
    auto const info_range = append_capsule_bytes(bytes, info_bytes);
    fixture.info_offset = info_range.first;
    write_capsule_range(bytes, 24U, info_range);
    write_capsule_range(bytes, 32U, append_capsule_string(bytes, name));

    bool const has_v1 = kind == TTORRENT_METAINFO_KIND_V1
        || kind == TTORRENT_METAINFO_KIND_HYBRID;
    bool const has_v2 = kind == TTORRENT_METAINFO_KIND_V2
        || kind == TTORRENT_METAINFO_KIND_HYBRID;
    if (has_v1) {
        lt::sha1_hash const hash = lt::hasher(lt::span<char const>(info)).final();
        std::array<std::uint8_t, 20U> encoded{};
        std::ranges::transform(hash, encoded.begin(), [](char const byte) {
            return static_cast<std::uint8_t>(byte);
        });
        write_capsule_range(bytes, 40U, append_capsule_bytes(bytes, encoded));
    }
    if (has_v2) {
        lt::sha256_hash const hash = lt::hasher256(lt::span<char const>(info)).final();
        std::array<std::uint8_t, 32U> encoded{};
        std::ranges::transform(hash, encoded.begin(), [](char const byte) {
            return static_cast<std::uint8_t>(byte);
        });
        write_capsule_range(bytes, 48U, append_capsule_bytes(bytes, encoded));
    }
    if (v1_piece_hashes) {
        write_capsule_range(bytes, 56U, {
            info_range.first + v1_piece_hashes->first,
            v1_piece_hashes->second,
        });
    }

    std::size_t next_component = 0U;
    for (std::size_t file_index = 0U; file_index < files.size(); ++file_index) {
        CapsuleFileFixture const &file = files.at(file_index);
        std::size_t const record = file_table
            + file_index * TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE;
        write_i32(bytes, record, static_cast<std::int32_t>(file_index));
        write_u32(bytes, record + 4U, static_cast<std::uint32_t>(next_component));
        write_u32(bytes, record + 8U, static_cast<std::uint32_t>(file.components.size()));
        write_u32(bytes, record + 12U, file.flags);
        write_i64(bytes, record + 16U, file.size);
        if (file.info_root_offset) {
            write_capsule_range(bytes, record + 24U, {
                info_range.first + *file.info_root_offset,
                32U,
            });
        }
        for (std::string const &component : file.components) {
            write_capsule_range(
                bytes,
                component_table + next_component * TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE,
                append_capsule_string(bytes, component)
            );
            ++next_component;
        }
    }

    for (std::size_t index = 0U; index < trackers.size(); ++index) {
        std::size_t const record = tracker_table
            + index * TTORRENT_METAINFO_CAPSULE_TRACKER_RECORD_SIZE;
        write_capsule_range(bytes, record, append_capsule_string(bytes, trackers.at(index).first));
        bytes.at(record + 8U) = trackers.at(index).second;
    }
    for (std::size_t index = 0U; index < web_seeds.size(); ++index) {
        write_capsule_range(
            bytes,
            web_seed_table + index * TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE,
            append_capsule_string(bytes, web_seeds.at(index))
        );
    }

    std::size_t next_layer_file_index = 0U;
    for (std::size_t index = 0U; index < layers.size(); ++index) {
        CapsuleLayerFixture const &layer = layers.at(index);
        std::size_t const record = piece_layer_table
            + index * TTORRENT_METAINFO_CAPSULE_PIECE_LAYER_RECORD_SIZE;
        write_capsule_range(bytes, record, append_capsule_bytes(bytes, layer.root));
        write_capsule_range(bytes, record + 8U, append_capsule_bytes(bytes, layer.hashes));
        write_u32(bytes, record + 16U, static_cast<std::uint32_t>(next_layer_file_index));
        write_u32(bytes, record + 20U, static_cast<std::uint32_t>(layer.file_indices.size()));
        for (std::int32_t const file_index : layer.file_indices) {
            write_i32(
                bytes,
                piece_layer_file_index_table
                    + next_layer_file_index * TTORRENT_METAINFO_CAPSULE_FILE_INDEX_RECORD_SIZE,
                file_index
            );
            ++next_layer_file_index;
        }
    }
    if (!comment.empty()) {
        write_capsule_range(bytes, 112U, append_capsule_string(bytes, comment));
    }
    write_u32(bytes, 8U, static_cast<std::uint32_t>(bytes.size()));
    return fixture;
}

class SwarmMetainfoParserProbe final {
public:
    enum class OutputMode : std::uint8_t {
        valid,
        allocation_failure,
        failure_with_allocation,
        null_with_positive_size,
        allocation_with_zero_size,
        allocation_with_oversized_size,
    };

    explicit SwarmMetainfoParserProbe(std::vector<std::uint8_t> capsule)
        : capsule_(std::move(capsule))
    {
    }

    [[nodiscard]] TTorrentSwarmMetainfoParserCallbacks callbacks() noexcept
    {
        return TTorrentSwarmMetainfoParserCallbacks{
            .context = this,
            .retain_context = retain_callback,
            .release_context = release_callback,
            .parse_info = parse_callback,
            .release_capsule = release_capsule_callback,
        };
    }

    std::atomic_int retain_count = 0;
    std::atomic_int context_release_count = 0;
    std::atomic_int parse_count = 0;
    std::atomic_int capsule_release_count = 0;
    std::atomic_int active_callback_count = 0;
    std::atomic_int outstanding_allocation_count = 0;
    std::atomic_int context_release_during_callback_count = 0;
    std::atomic_int context_release_with_allocation_count = 0;
    OutputMode output_mode = OutputMode::valid;

    void block_next_parse()
    {
        std::unique_lock guard(callback_lock_);
        block_parse_ = true;
        parse_entered_ = false;
        allow_parse_to_return_ = false;
    }

    [[nodiscard]] bool wait_for_blocked_parse()
    {
        std::unique_lock guard(callback_lock_);
        return callback_changed_.wait_for(guard, std::chrono::seconds(5), [this] {
            return parse_entered_;
        });
    }

    void unblock_parse()
    {
        {
            std::unique_lock guard(callback_lock_);
            allow_parse_to_return_ = true;
        }
        callback_changed_.notify_all();
    }

private:
    static std::uint8_t retain_callback(void *context) noexcept
    {
        auto *probe = static_cast<SwarmMetainfoParserProbe *>(context);
        if (probe == nullptr) {
            return 0U;
        }
        ++probe->retain_count;
        return 1U;
    }

    static void release_callback(void *context) noexcept
    {
        auto *probe = static_cast<SwarmMetainfoParserProbe *>(context);
        if (probe != nullptr) {
            if (probe->active_callback_count.load() != 0) {
                ++probe->context_release_during_callback_count;
            }
            if (probe->outstanding_allocation_count.load() != 0) {
                ++probe->context_release_with_allocation_count;
            }
            ++probe->context_release_count;
        }
    }

    static int32_t parse_callback(
        void *context,
        char const *info,
        int32_t const info_size,
        TTorrentOwnedMetainfoCapsule *result
    ) noexcept
    {
        auto *probe = static_cast<SwarmMetainfoParserProbe *>(context);
        if (result == nullptr) {
            return EINVAL;
        }
        *result = TTorrentOwnedMetainfoCapsule{};
        if (probe == nullptr || info == nullptr || info_size <= 0
            || probe->capsule_.empty()
            || probe->capsule_.size() > static_cast<std::size_t>(INT32_MAX)) {
            return EINVAL;
        }
        ++probe->parse_count;
        ++probe->active_callback_count;
        struct ActiveCallbackGuard final {
            explicit ActiveCallbackGuard(std::atomic_int &stored_count) noexcept
                : count(stored_count)
            {
            }

            ~ActiveCallbackGuard()
            {
                --count;
            }

            std::atomic_int &count;
        } active_guard(probe->active_callback_count);
        {
            std::unique_lock guard(probe->callback_lock_);
            if (probe->block_parse_) {
                probe->parse_entered_ = true;
                probe->callback_changed_.notify_all();
                probe->callback_changed_.wait(guard, [probe] {
                    return probe->allow_parse_to_return_;
                });
                probe->block_parse_ = false;
            }
        }
        if (probe->output_mode == OutputMode::allocation_failure) {
            return ENOMEM;
        }
        if (probe->output_mode == OutputMode::null_with_positive_size) {
            result->size = 1;
            return 0;
        }
        auto *copy = static_cast<std::uint8_t *>(std::malloc(probe->capsule_.size()));
        if (copy == nullptr) {
            return ENOMEM;
        }
        __unsafe_buffer_usage_begin
        std::memcpy(copy, probe->capsule_.data(), probe->capsule_.size());
        __unsafe_buffer_usage_end
        ++probe->outstanding_allocation_count;
        int32_t reported_size = static_cast<int32_t>(probe->capsule_.size());
        if (probe->output_mode == OutputMode::allocation_with_zero_size) {
            reported_size = 0;
        } else if (probe->output_mode == OutputMode::allocation_with_oversized_size) {
            reported_size = TTORRENT_METAINFO_CAPSULE_MAX_BYTES + 1;
        }
        *result = TTorrentOwnedMetainfoCapsule{
            .bytes = copy,
            .size = reported_size,
        };
        return probe->output_mode == OutputMode::failure_with_allocation ? EIO : 0;
    }

    static void release_capsule_callback(
        void *context,
        TTorrentOwnedMetainfoCapsule const capsule
    ) noexcept
    {
        auto *probe = static_cast<SwarmMetainfoParserProbe *>(context);
        if (probe != nullptr) {
            ++probe->capsule_release_count;
        }
        if (capsule.bytes != nullptr && probe != nullptr) {
            __unsafe_buffer_usage_begin
            std::memset(capsule.bytes, 0xa5, probe->capsule_.size());
            __unsafe_buffer_usage_end
        }
        std::free(capsule.bytes);
        if (probe != nullptr) {
            --probe->outstanding_allocation_count;
        }
    }

    std::vector<std::uint8_t> capsule_;
    std::mutex callback_lock_;
    std::condition_variable callback_changed_;
    bool block_parse_ = false;
    bool parse_entered_ = false;
    bool allow_parse_to_return_ = false;
};

class PeerProtocolParserProbe final {
public:
    PeerProtocolParserProbe()
    {
        handshake_result.ut_metadata_id = -1;
        handshake_result.ut_pex_id = -1;
        handshake_result.upload_only_id = -1;
        handshake_result.holepunch_id = -1;
        handshake_result.dont_have_id = -1;
    }

    [[nodiscard]] TTorrentPeerProtocolParserCallbacks callbacks() noexcept
    {
        return TTorrentPeerProtocolParserCallbacks{
            .context = this,
            .retain_context = retain_callback,
            .release_context = release_callback,
            .parse_extension_handshake = handshake_callback,
            .parse_metadata_message = metadata_callback,
            .parse_peer_exchange = pex_callback,
        };
    }

    TTorrentExtensionHandshakeResult handshake_result{};
    TTorrentMetadataMessageResult metadata_result{};
    TTorrentPeerExchangeResult pex_result{};
    std::vector<std::uint8_t> client_version;
    std::vector<TTorrentPeerExchangeRecord> pex_records;
    int32_t handshake_status = 0;
    int32_t metadata_status = 0;
    int32_t pex_status = 0;
    std::atomic_int retain_count = 0;
    std::atomic_int release_count = 0;
    std::atomic_int handshake_count = 0;
    std::atomic_int metadata_count = 0;
    std::atomic_int pex_count = 0;
    std::atomic_int last_version_capacity = 0;
    std::atomic_int last_record_capacity = 0;

private:
    static std::uint8_t retain_callback(void *context) noexcept
    {
        auto *probe = static_cast<PeerProtocolParserProbe *>(context);
        if (probe == nullptr) {
            return 0U;
        }
        ++probe->retain_count;
        return 1U;
    }

    static void release_callback(void *context) noexcept
    {
        auto *probe = static_cast<PeerProtocolParserProbe *>(context);
        if (probe != nullptr) {
            ++probe->release_count;
        }
    }

    static int32_t handshake_callback(
        void *context,
        char const *message,
        int32_t const message_size,
        std::uint8_t *client_version_out,
        int32_t const client_version_capacity,
        TTorrentExtensionHandshakeResult *result
    ) noexcept
    {
        auto *probe = static_cast<PeerProtocolParserProbe *>(context);
        if (probe == nullptr || message == nullptr || message_size <= 0
            || client_version_out == nullptr || client_version_capacity < 0
            || result == nullptr) {
            return EINVAL;
        }
        ++probe->handshake_count;
        probe->last_version_capacity = client_version_capacity;
        *result = probe->handshake_result;
        if (std::cmp_greater(probe->client_version.size(), client_version_capacity)) {
            return EOVERFLOW;
        }
        __unsafe_buffer_usage_begin
        std::span<std::uint8_t> const output(
            client_version_out,
            static_cast<std::size_t>(client_version_capacity)
        );
        __unsafe_buffer_usage_end
        std::ranges::copy(probe->client_version, output.begin());
        return probe->handshake_status;
    }

    static int32_t metadata_callback(
        void *context,
        char const *message,
        int32_t const message_size,
        TTorrentMetadataMessageResult *result
    ) noexcept
    {
        auto *probe = static_cast<PeerProtocolParserProbe *>(context);
        if (probe == nullptr || message == nullptr || message_size <= 0 || result == nullptr) {
            return EINVAL;
        }
        ++probe->metadata_count;
        *result = probe->metadata_result;
        return probe->metadata_status;
    }

    static int32_t pex_callback(
        void *context,
        char const *message,
        int32_t const message_size,
        TTorrentPeerExchangeRecord *records,
        int32_t const record_capacity,
        TTorrentPeerExchangeResult *result
    ) noexcept
    {
        auto *probe = static_cast<PeerProtocolParserProbe *>(context);
        if (probe == nullptr || message == nullptr || message_size <= 0
            || records == nullptr || record_capacity < 0 || result == nullptr) {
            return EINVAL;
        }
        ++probe->pex_count;
        probe->last_record_capacity = record_capacity;
        *result = probe->pex_result;
        if (std::cmp_greater(probe->pex_records.size(), record_capacity)) {
            return EOVERFLOW;
        }
        __unsafe_buffer_usage_begin
        std::span<TTorrentPeerExchangeRecord> const output(
            records,
            static_cast<std::size_t>(record_capacity)
        );
        __unsafe_buffer_usage_end
        std::ranges::copy(probe->pex_records, output.begin());
        return probe->pex_status;
    }
};

class TrackerResponseParserProbe final {
public:
    [[nodiscard]] TTorrentTrackerResponseParserCallbacks callbacks() noexcept
    {
        return TTorrentTrackerResponseParserCallbacks{
            .context = this,
            .retain_context = retain_callback,
            .release_context = release_callback,
            .parse_http_response = parse_callback,
        };
    }

    TTorrentHTTPTrackerResponseResult result{};
    std::vector<TTorrentTrackerPeerRecord> peers;
    int32_t status = 0;
    std::atomic_int retain_count = 0;
    std::atomic_int release_count = 0;
    std::atomic_int parse_count = 0;
    std::atomic_int last_peer_capacity = 0;
    std::atomic_int last_is_scrape = 0;
    std::string last_body;
    std::array<std::uint8_t, 20U> last_scrape_hash{};

private:
    static std::uint8_t retain_callback(void *context) noexcept
    {
        auto *probe = static_cast<TrackerResponseParserProbe *>(context);
        if (probe == nullptr) {
            return 0U;
        }
        ++probe->retain_count;
        return 1U;
    }

    static void release_callback(void *context) noexcept
    {
        auto *probe = static_cast<TrackerResponseParserProbe *>(context);
        if (probe != nullptr) {
            ++probe->release_count;
        }
    }

    static int32_t parse_callback(
        void *context,
        char const *body,
        int32_t const body_size,
        std::uint8_t const is_scrape,
        std::uint8_t const *scrape_info_hash,
        int32_t const scrape_info_hash_size,
        TTorrentTrackerPeerRecord *peers_out,
        int32_t const peer_capacity,
        TTorrentHTTPTrackerResponseResult *result_out
    ) noexcept
    {
        auto *probe = static_cast<TrackerResponseParserProbe *>(context);
        if (probe == nullptr || body == nullptr || body_size <= 0
            || is_scrape > 1U || peers_out == nullptr || peer_capacity < 0
            || result_out == nullptr) {
            return EINVAL;
        }
        if ((is_scrape != 0U && (scrape_info_hash == nullptr || scrape_info_hash_size != 20))
            || (is_scrape == 0U && (scrape_info_hash != nullptr || scrape_info_hash_size != 0))) {
            return EINVAL;
        }
        ++probe->parse_count;
        probe->last_peer_capacity = peer_capacity;
        probe->last_is_scrape = is_scrape;
        __unsafe_buffer_usage_begin
        std::span<char const> const input(body, static_cast<std::size_t>(body_size));
        __unsafe_buffer_usage_end
        probe->last_body.assign(input.begin(), input.end());
        if (is_scrape != 0U) {
            __unsafe_buffer_usage_begin
            std::span<std::uint8_t const> const hash(
                scrape_info_hash,
                static_cast<std::size_t>(scrape_info_hash_size)
            );
            __unsafe_buffer_usage_end
            std::ranges::copy(hash, probe->last_scrape_hash.begin());
        }
        *result_out = probe->result;
        if (std::cmp_greater(probe->peers.size(), peer_capacity)) {
            return EOVERFLOW;
        }
        __unsafe_buffer_usage_begin
        std::span<TTorrentTrackerPeerRecord> const output(
            peers_out,
            static_cast<std::size_t>(peer_capacity)
        );
        __unsafe_buffer_usage_end
        std::ranges::copy(probe->peers, output.begin());
        return probe->status;
    }
};

class DHTMessageParserProbe final {
public:
    [[nodiscard]] TTorrentDHTMessageParserCallbacks callbacks() noexcept
    {
        return TTorrentDHTMessageParserCallbacks{
            .context = this,
            .retain_context = retain_callback,
            .release_context = release_callback,
            .parse_message = parse_callback,
        };
    }

    TTorrentDHTMessageResult result{};
    std::vector<TTorrentDHTNodeRecord> nodes;
    std::vector<TTorrentDHTPeerRecord> peers;
    int32_t status = 0;
    std::atomic_int retain_count = 0;
    std::atomic_int release_count = 0;
    std::atomic_int parse_count = 0;
    std::atomic_int last_node_capacity = 0;
    std::atomic_int last_peer_capacity = 0;
    std::atomic_int last_source_family = 0;
    std::string last_body;

private:
    static std::uint8_t retain_callback(void *context) noexcept
    {
        auto *probe = static_cast<DHTMessageParserProbe *>(context);
        if (probe == nullptr) {
            return 0U;
        }
        ++probe->retain_count;
        return 1U;
    }

    static void release_callback(void *context) noexcept
    {
        auto *probe = static_cast<DHTMessageParserProbe *>(context);
        if (probe != nullptr) {
            ++probe->release_count;
        }
    }

    static int32_t parse_callback(
        void *context,
        char const *body,
        int32_t const body_size,
        std::uint8_t const source_address_family,
        TTorrentDHTNodeRecord *nodes_out,
        int32_t const node_capacity,
        TTorrentDHTPeerRecord *peers_out,
        int32_t const peer_capacity,
        TTorrentDHTMessageResult *result_out
    ) noexcept
    {
        auto *probe = static_cast<DHTMessageParserProbe *>(context);
        if (probe == nullptr || body == nullptr || body_size <= 0
            || nodes_out == nullptr || node_capacity < 0
            || peers_out == nullptr || peer_capacity < 0
            || result_out == nullptr) {
            return EINVAL;
        }
        ++probe->parse_count;
        probe->last_node_capacity = node_capacity;
        probe->last_peer_capacity = peer_capacity;
        probe->last_source_family = source_address_family;
        __unsafe_buffer_usage_begin
        std::span<char const> const input(body, static_cast<std::size_t>(body_size));
        std::span<TTorrentDHTNodeRecord> const node_output(
            nodes_out,
            static_cast<std::size_t>(node_capacity)
        );
        std::span<TTorrentDHTPeerRecord> const peer_output(
            peers_out,
            static_cast<std::size_t>(peer_capacity)
        );
        __unsafe_buffer_usage_end
        probe->last_body.assign(input.begin(), input.end());
        *result_out = probe->result;
        if (std::cmp_greater(probe->nodes.size(), node_capacity)
            || std::cmp_greater(probe->peers.size(), peer_capacity)) {
            return EOVERFLOW;
        }
        std::ranges::copy(probe->nodes, node_output.begin());
        std::ranges::copy(probe->peers, peer_output.begin());
        return probe->status;
    }
};

[[nodiscard]] std::string v1_capsule_info(std::uint32_t &piece_hash_offset)
{
    std::string info = "d6:lengthi4e4:name8:file.bin12:piece lengthi16384e6:pieces20:";
    piece_hash_offset = static_cast<std::uint32_t>(info.size());
    info.append(20U, 'p');
    info += "7:privatei1ee";
    return info;
}

[[nodiscard]] MetainfoCapsuleFixture make_v1_capsule(
    std::string const &info,
    std::uint32_t const piece_hash_offset,
    std::uint8_t const input_kind
)
{
    return make_metainfo_capsule(
        info,
        "file.bin",
        TTORRENT_METAINFO_KIND_V1,
        TTORRENT_CONTENT_KIND_SINGLE_FILE,
        {CapsuleFileFixture{.components = {"file.bin"}, .size = 4}},
        std::pair{piece_hash_offset, 20U},
        {},
        false,
        {},
        {},
        {},
        -1,
        input_kind
    );
}

[[nodiscard]] TTorrentAddOptions metainfo_capsule_add_options()
{
    TTorrentAddOptions options{
        .starts_paused = bridge_bool(false),
        .queue_priority = static_cast<std::uint8_t>(TTORRENT_QUEUE_PRIORITY_NORMAL),
        .enable_dht = bridge_bool(true),
        .enable_peer_exchange = bridge_bool(true),
        .enable_lsd = bridge_bool(true),
        .https_tracker_policy = TTORRENT_HTTPS_POLICY_INHERIT,
        .https_web_seed_policy = TTORRENT_HTTPS_POLICY_INHERIT,
        .effective_https_tracker_policy = TTORRENT_HTTPS_POLICY_PREFER,
        .effective_https_web_seed_policy = TTORRENT_HTTPS_POLICY_REQUIRE,
        .allow_pre_metadata_dht = bridge_bool(false),
    };
    constexpr std::string_view canonical_id = "t:0123456789abcdef0123456789abcdef";
    std::ranges::copy(canonical_id, options.canonical_id);
    return options;
}

[[nodiscard]] std::array<std::uint8_t, 32U> v2_root(
    std::span<std::uint8_t const> const piece_hashes
)
{
    std::vector<char> input;
    input.reserve(piece_hashes.size());
    std::ranges::transform(piece_hashes, std::back_inserter(input), [](std::uint8_t const byte) {
        return static_cast<char>(byte);
    });
    lt::sha256_hash const root = lt::hasher256(lt::span<char const>(input)).final();
    std::array<std::uint8_t, 32U> encoded{};
    std::ranges::transform(root, encoded.begin(), [](char const byte) {
        return static_cast<std::uint8_t>(byte);
    });
    return encoded;
}

[[nodiscard]] std::string v2_capsule_info(
    std::string_view const name,
    std::int64_t const size,
    std::array<std::uint8_t, 32U> const &root,
    std::uint32_t &root_offset,
    bool const include_v1,
    std::uint32_t &piece_hash_offset
)
{
    std::string info = "d9:file treed" + std::to_string(name.size()) + ":" + std::string(name)
        + "d0:d6:lengthi" + std::to_string(size) + "e11:pieces root32:";
    root_offset = static_cast<std::uint32_t>(info.size());
    for (std::uint8_t const byte : root) {
        info.push_back(static_cast<char>(byte));
    }
    info += "eee";
    if (include_v1) {
        info += "6:lengthi" + std::to_string(size) + "e";
    }
    info += "12:meta versioni2e4:name" + std::to_string(name.size()) + ":" + std::string(name)
        + "12:piece lengthi16384e";
    if (include_v1) {
        info += "6:pieces20:";
        piece_hash_offset = static_cast<std::uint32_t>(info.size());
        info.append(20U, 'h');
    }
    info.push_back('e');
    return info;
}

[[nodiscard]] std::shared_ptr<lt::torrent_info const> make_raw_v1_torrent_info(std::string_view files_payload)
{
    std::vector<char> buffer;
    auto append = [&buffer](std::string_view value) {
        buffer.insert(buffer.end(), value.begin(), value.end());
    };

    append("d4:infod5:filesl");
    append(files_payload);
    append("e4:name");
    append_bencoded_string(buffer, "source");
    append("12:piece lengthi16384e6:pieces");
    append_bencoded_string(buffer, std::string(20U, '\0'));
    append("ee");

    return bridge_tests::load_torrent_params(buffer, "raw validation test torrent info").ti;
}

} // namespace

TEST_CASE("preparsed v1 metainfo capsule constructs narrow native state")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture fixture = make_metainfo_capsule(
        info,
        "file.bin",
        TTORRENT_METAINFO_KIND_V1,
        TTORRENT_CONTENT_KIND_SINGLE_FILE,
        {CapsuleFileFixture{.components = {"file.bin"}, .size = 4}},
        std::pair{piece_hash_offset, 20U},
        {},
        true,
        {{"HTTPS://tracker.example/announce", 3U}},
        {"HTTPS://seed.example/file"},
        "capsule comment",
        1'234
    );

    TorrentLoadResult imported = import_preparsed_metainfo_capsule(fixture.bytes);

    REQUIRE(imported);
    REQUIRE(imported->ti);
    CHECK(imported->ti->is_loaded());
    CHECK(imported->ti->priv());
    CHECK(imported->ti->info_hashes().has_v1());
    CHECK_FALSE(imported->ti->info_hashes().has_v2());
    CHECK(imported->info_hashes == imported->ti->info_hashes());
    CHECK(imported->ti->name() == "file.bin");
    CHECK(imported->ti->piece_length() == 16 * 1024);
    CHECK(imported->ti->num_pieces() == 1);
    CHECK(imported->ti->layout().num_files() == 1);
    CHECK(imported->ti->layout().file_path(lt::file_index_t(0)) == "file.bin");
    CHECK(imported->ti->layout().file_size(lt::file_index_t(0)) == 4);
    CHECK(imported->ti->hash_for_piece(lt::piece_index_t(0)) == lt::sha1_hash(std::string(20U, 'p')));
    CHECK(std::ranges::equal(imported->ti->info_section(), info));
    CHECK(imported->trackers == std::vector<std::string>{"HTTPS://tracker.example/announce"});
    CHECK(imported->tracker_tiers == std::vector<int>{3});
    CHECK(imported->url_seeds == std::vector<std::string>{"HTTPS://seed.example/file"});
    CHECK(imported->comment == "capsule comment");
    CHECK(imported->creation_date == 1'234);
    CHECK(imported->peers.empty());
    CHECK(imported->banned_peers.empty());
    CHECK(imported->dht_nodes.empty());
    CHECK(imported->file_priorities.empty());
    CHECK(imported->piece_priorities.empty());
}

TEST_CASE("preparsed importer hashes and retains its final native-owned info bytes")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string source_info = v1_capsule_info(piece_hash_offset);
    std::string const expected_info = source_info;
    std::vector<lt::aux::preparsed_metainfo_file> files{{
        .path = "file.bin",
        .size = 4,
    }};
    lt::info_hash_t const expected_hashes(
        lt::hasher(lt::span<char const>(source_info)).final()
    );
    lt::aux::preparsed_metainfo const input{
        .info_section = lt::span<char const>(source_info),
        .files = lt::span<lt::aux::preparsed_metainfo_file const>(files),
        .expected_info_hashes = expected_hashes,
        .name = "file.bin",
        .piece_length = 16 * 1024,
        .piece_hashes_offset = static_cast<std::int32_t>(piece_hash_offset),
        .piece_hashes_size = 20,
        .multifile = false,
        .private_torrent = false,
    };

    char const * const borrowed_info = source_info.data();
    lt::error_code error;
    std::shared_ptr<lt::torrent_info> const imported
        = lt::aux::import_preparsed_metainfo(input, error);

    REQUIRE_FALSE(error);
    REQUIRE(imported);
    REQUIRE(imported->info_section().data() != borrowed_info);
    CHECK(std::ranges::equal(imported->info_section(), expected_info));
    CHECK(lt::hasher(imported->info_section()).final() == expected_hashes.v1);

    std::ranges::fill(source_info, '\xa5');
    CHECK(std::ranges::equal(imported->info_section(), expected_info));
    CHECK(lt::hasher(imported->info_section()).final() == imported->info_hashes().v1);
    CHECK(imported->hash_for_piece(lt::piece_index_t(0))
        == lt::sha1_hash(std::string(20U, 'p')));
}

TEST_CASE("preparsed hybrid importer independently verifies both native-owned hashes")
{
    std::array<std::uint8_t, 32U> root{};
    root.fill(0x5aU);
    std::uint32_t root_offset = 0U;
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v2_capsule_info(
        "tiny.bin",
        3,
        root,
        root_offset,
        true,
        piece_hash_offset
    );
    std::vector<lt::aux::preparsed_metainfo_file> files{{
        .path = "tiny.bin",
        .size = 3,
        .pieces_root_offset = static_cast<std::int32_t>(root_offset),
    }};
    lt::info_hash_t const expected_hashes(
        lt::hasher(lt::span<char const>(info)).final(),
        lt::hasher256(lt::span<char const>(info)).final()
    );
    lt::aux::preparsed_metainfo input{
        .info_section = lt::span<char const>(info),
        .files = lt::span<lt::aux::preparsed_metainfo_file const>(files),
        .expected_info_hashes = expected_hashes,
        .name = "tiny.bin",
        .piece_length = 16 * 1024,
        .piece_hashes_offset = static_cast<std::int32_t>(piece_hash_offset),
        .piece_hashes_size = 20,
        .multifile = false,
        .private_torrent = false,
    };

    lt::info_hash_t wrong_v1 = expected_hashes;
    wrong_v1.v1[0] ^= 1U;
    input.expected_info_hashes = wrong_v1;
    lt::error_code error;
    CHECK_FALSE(lt::aux::import_preparsed_metainfo(input, error));
    CHECK(error == lt::errors::mismatching_info_hash);

    lt::info_hash_t wrong_v2 = expected_hashes;
    wrong_v2.v2[0] ^= 1U;
    input.expected_info_hashes = wrong_v2;
    CHECK_FALSE(lt::aux::import_preparsed_metainfo(input, error));
    CHECK(error == lt::errors::mismatching_info_hash);

    input.expected_info_hashes = expected_hashes;
    std::shared_ptr<lt::torrent_info> const imported
        = lt::aux::import_preparsed_metainfo(input, error);
    REQUIRE_FALSE(error);
    REQUIRE(imported);
    CHECK(lt::hasher(imported->info_section()).final() == imported->info_hashes().v1);
    CHECK(lt::hasher256(imported->info_section()).final() == imported->info_hashes().v2);
}

TEST_CASE("metainfo capsule importers enforce their distinct input kinds")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const torrent_file = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_TORRENT_FILE
    );
    MetainfoCapsuleFixture const swarm_info = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );

    CHECK(import_preparsed_metainfo_capsule(torrent_file.bytes));
    CHECK_FALSE(import_preparsed_info_capsule(torrent_file.bytes));
    CHECK_FALSE(import_preparsed_metainfo_capsule(swarm_info.bytes));
    CHECK(import_preparsed_info_capsule(swarm_info.bytes));
}

TEST_CASE("swarm metainfo callback ownership is balanced on accept and reject")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const swarm_info = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );
    SwarmMetainfoParserProbe accepted_probe(swarm_info.bytes);
    {
        BridgeSwarmMetadataParser parser(accepted_probe.callbacks());
        lt::error_code error;
        std::shared_ptr<lt::torrent_info> parsed = parser.parse(
            lt::span<char const>(info),
            error
        );
        REQUIRE_FALSE(error);
        REQUIRE(parsed);
        CHECK(parsed->name() == "file.bin");
        CHECK(std::ranges::equal(parsed->info_section(), info));
        CHECK(accepted_probe.parse_count == 1);
        CHECK(accepted_probe.capsule_release_count == 1);
        CHECK(accepted_probe.context_release_count == 0);
    }
    CHECK(accepted_probe.retain_count == 1);
    CHECK(accepted_probe.context_release_count == 1);

    MetainfoCapsuleFixture wrong_kind = swarm_info;
    wrong_kind.bytes.at(12U) = TTORRENT_METAINFO_INPUT_TORRENT_FILE;
    SwarmMetainfoParserProbe rejected_probe(std::move(wrong_kind.bytes));
    {
        BridgeSwarmMetadataParser parser(rejected_probe.callbacks());
        lt::error_code error;
        CHECK_FALSE(parser.parse(lt::span<char const>(info), error));
        CHECK(error == lt::errors::invalid_swarm_metadata);
        CHECK(rejected_probe.parse_count == 1);
        CHECK(rejected_probe.capsule_release_count == 1);
    }
    CHECK(rejected_probe.retain_count == 1);
    CHECK(rejected_probe.context_release_count == 1);
}

TEST_CASE("swarm callback allocations have exactly one owner on every return path")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const fixture = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );
    struct ReturnCase {
        SwarmMetainfoParserProbe::OutputMode mode;
        int expected_capsule_releases;
    };
    std::array<ReturnCase, 5U> const cases{{
        {SwarmMetainfoParserProbe::OutputMode::allocation_failure, 0},
        {SwarmMetainfoParserProbe::OutputMode::failure_with_allocation, 1},
        {SwarmMetainfoParserProbe::OutputMode::null_with_positive_size, 0},
        {SwarmMetainfoParserProbe::OutputMode::allocation_with_zero_size, 1},
        {SwarmMetainfoParserProbe::OutputMode::allocation_with_oversized_size, 1},
    }};

    for (ReturnCase const &return_case : cases) {
        SwarmMetainfoParserProbe probe(fixture.bytes);
        probe.output_mode = return_case.mode;
        {
            BridgeSwarmMetadataParser parser(probe.callbacks());
            lt::error_code error;
            CHECK_FALSE(parser.parse(lt::span<char const>(info), error));
            CHECK(error == lt::errors::invalid_swarm_metadata);
            CHECK(probe.parse_count == 1);
            CHECK(probe.capsule_release_count == return_case.expected_capsule_releases);
            CHECK(probe.outstanding_allocation_count == 0);
            CHECK(probe.context_release_count == 0);
        }
        CHECK(probe.context_release_count == 1);
        CHECK(probe.context_release_during_callback_count == 0);
        CHECK(probe.context_release_with_allocation_count == 0);
    }
}

TEST_CASE("client construction failure releases each previously retained parser context")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const fixture = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );
    SwarmMetainfoParserProbe swarm_probe(fixture.bytes);
    PeerProtocolParserProbe peer_probe;
    TrackerResponseParserProbe tracker_probe;
    DHTMessageParserProbe dht_probe;
    TTorrentTrackerResponseParserCallbacks incomplete_tracker = tracker_probe.callbacks();
    incomplete_tracker.parse_http_response = nullptr;
    bridge_tests::TemporaryDirectory temporary_directory;
    bridge_tests::TestPayloadBroker broker(temporary_directory.path() / "Payload");
    std::array<char, 512U> error{};

    TTorrentClient * const client = ::TorrentClientCreateWithError(
        (temporary_directory.path() / "State").c_str(),
        1U,
        broker.callbacks(),
        swarm_probe.callbacks(),
        peer_probe.callbacks(),
        incomplete_tracker,
        dht_probe.callbacks(),
        error.data(),
        static_cast<int32_t>(error.size())
    );

    CHECK(client == nullptr);
    CHECK(std::string_view(error.data())
        == "The tracker response parser callback table is incomplete.");
    CHECK(swarm_probe.retain_count == 1);
    CHECK(swarm_probe.context_release_count == 1);
    CHECK(peer_probe.retain_count == 1);
    CHECK(peer_probe.release_count == 1);
    CHECK(tracker_probe.retain_count == 0);
    CHECK(tracker_probe.release_count == 0);
    CHECK(dht_probe.retain_count == 0);
    CHECK(dht_probe.release_count == 0);
}

TEST_CASE("resume metainfo stays opaque and returns through the typed importer")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const swarm_info = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );
    TorrentInfoLoadResult imported = import_preparsed_info_capsule(swarm_info.bytes);
    REQUIRE(imported);

    lt::add_torrent_params params;
    params.ti = *imported;
    params.info_hashes = params.ti->info_hashes();
    TorrentIdentity identity;
    identity.canonical_id = "t:0123456789abcdef0123456789abcdef";

    std::vector<char> const encoded = encoded_resume_data(params, &identity);
    REQUIRE_FALSE(encoded.empty());
    lt::error_code decode_error;
    lt::bdecode_node const root = lt::bdecode(
        lt::span<char const>(encoded),
        decode_error
    );
    REQUIRE_FALSE(decode_error);
    REQUIRE(root.type() == lt::bdecode_node::dict_t);
    CHECK_FALSE(root.dict_find("info"));
    lt::string_view const opaque_key(
        kPreparsedInfoResumeKey.data(),
        kPreparsedInfoResumeKey.size()
    );
    lt::bdecode_node const opaque_info = root.dict_find_string(opaque_key);
    REQUIRE(opaque_info);
    CHECK(opaque_info.string_value() == info);

    lt::error_code resume_error;
    lt::add_torrent_params const decoded = lt::read_resume_data(
        root,
        resume_error
    );
    REQUIRE_FALSE(resume_error);
    CHECK_FALSE(decoded.ti);
    ResumeInfoSectionResult extracted = preparsed_info_from_resume_data(encoded);
    REQUIRE(extracted);
    REQUIRE(extracted->has_value());
    CHECK(std::ranges::equal(**extracted, info));

    SwarmMetainfoParserProbe probe(swarm_info.bytes);
    BridgeSwarmMetadataParser parser(probe.callbacks());
    lt::error_code import_error;
    std::shared_ptr<lt::torrent_info> restored = parser.parse(
        lt::span<char const>(extracted->value()),
        import_error
    );
    REQUIRE_FALSE(import_error);
    REQUIRE(restored);
    CHECK(restored->info_hashes() == params.info_hashes);
    CHECK(std::ranges::equal(restored->info_section(), info));

    lt::add_torrent_params legacy_state = params;
    legacy_state.ti.reset();
    lt::entry legacy = lt::write_resume_data(legacy_state);
    legacy["info"].preformatted().assign(info.begin(), info.end());
    std::vector<char> legacy_encoded;
    lt::bencode(std::back_inserter(legacy_encoded), legacy);
    CHECK_FALSE(preparsed_info_from_resume_data(legacy_encoded));
    lt::error_code legacy_error;
    static_cast<void>(lt::read_resume_data(
        lt::span<char const>(legacy_encoded),
        legacy_error
    ));
    CHECK(legacy_error == lt::errors::invalid_bencoding);
}

TEST_CASE("peer protocol callback ownership and typed imports are exact")
{
    PeerProtocolParserProbe probe;
    probe.client_version = {'T', 'o', 'r', 'r', 'e', 'n', 't', ' ', '7'};
    probe.handshake_result = TTorrentExtensionHandshakeResult{
        .address_high = 0U,
        .address_low = 0xcb00'7108U,
        .ut_metadata_id = 2,
        .ut_pex_id = 1,
        .upload_only_id = 3,
        .holepunch_id = 4,
        .dont_have_id = 7,
        .metadata_size = 1'234,
        .listen_port = 6'881,
        .last_seen_complete = 9,
        .request_queue_limit = 250,
        .present_fields = TTORRENT_HANDSHAKE_HAS_METADATA_SIZE
            | TTORRENT_HANDSHAKE_HAS_LISTEN_PORT
            | TTORRENT_HANDSHAKE_HAS_LAST_SEEN_COMPLETE
            | TTORRENT_HANDSHAKE_HAS_REQUEST_QUEUE
            | TTORRENT_HANDSHAKE_HAS_CLIENT_VERSION
            | TTORRENT_HANDSHAKE_HAS_EXTERNAL_ADDRESS
            | TTORRENT_HANDSHAKE_HAS_UPLOAD_ONLY,
        .client_version_size = static_cast<int32_t>(probe.client_version.size()),
        .address_family = TTORRENT_PEER_ADDRESS_IPV4,
        .upload_only = 1U,
        .reserved = 0U,
    };
    probe.metadata_result = TTorrentMetadataMessageResult{
        .raw_message_type = 1,
        .piece = 2,
        .total_size = 40'000,
        .payload_offset = 4,
        .payload_size = 5,
        .kind = TTORRENT_METADATA_MESSAGE_DATA,
        .has_total_size = 1U,
        .reserved0 = 0U,
        .reserved1 = 0U,
    };
    probe.pex_records = {
        TTorrentPeerExchangeRecord{
            .address_high = 0U,
            .address_low = 0xcb00'7109U,
            .port = 6'881U,
            .address_family = TTORRENT_PEER_ADDRESS_IPV4,
            .action = TTORRENT_PEX_CONTACT_ADD,
            .flags = 0x1fU,
            .reserved0 = 0U,
            .reserved1 = 0U,
        },
        TTorrentPeerExchangeRecord{
            .address_high = 0x2001'0db8'0000'0000U,
            .address_low = 1U,
            .port = 6'882U,
            .address_family = TTORRENT_PEER_ADDRESS_IPV6,
            .action = TTORRENT_PEX_CONTACT_DROP,
            .flags = 0U,
            .reserved0 = 0U,
            .reserved1 = 0U,
        },
    };
    probe.pex_result = TTorrentPeerExchangeResult{
        .record_count = 2,
        .added_count = 1,
        .dropped_count = 1,
        .reserved = 0U,
    };

    {
        BridgePeerMessageParser parser(probe.callbacks());
        CHECK(probe.retain_count == 1);
        CHECK(probe.release_count == 0);

        std::string const handshake_message = "de";
        lt::aux::extension_handshake handshake;
        lt::error_code error;
        REQUIRE(parser.parse_extension_handshake(handshake_message, handshake, error));
        CHECK_FALSE(error);
        CHECK(handshake.ut_metadata_id == 2);
        CHECK(handshake.ut_pex_id == 1);
        CHECK(handshake.upload_only_id == 3);
        CHECK(handshake.holepunch_id == 4);
        CHECK(handshake.dont_have_id == 7);
        CHECK(handshake.metadata_size == 1'234);
        CHECK(handshake.listen_port == 6'881);
        CHECK(handshake.last_seen_complete == 9);
        CHECK(handshake.request_queue_limit == 250);
        CHECK(handshake.client_version == "Torrent 7");
        REQUIRE(handshake.external_address);
        CHECK(handshake.external_address->to_string() == "203.0.113.8");
        CHECK(handshake.upload_only == true);
        CHECK(probe.last_version_capacity == TTORRENT_MAX_PEER_CLIENT_VERSION_BYTES);

        std::string const metadata_message = "dictBLOCK";
        lt::aux::ut_metadata_message metadata;
        REQUIRE(parser.parse_ut_metadata(metadata_message, metadata, error));
        CHECK_FALSE(error);
        CHECK(metadata.type == lt::aux::ut_metadata_message_type::piece);
        CHECK(metadata.raw_type == 1);
        CHECK(metadata.piece == 2);
        CHECK(metadata.total_size == 40'000);
        CHECK(metadata.payload_offset == 4);
        CHECK(metadata.payload_size == 5);

        std::string const pex_message = "de";
        lt::aux::peer_exchange_message pex;
        REQUIRE(parser.parse_ut_pex(pex_message, pex, error));
        CHECK_FALSE(error);
        REQUIRE(pex.contacts.size() == 2U);
        CHECK(pex.added_count == 1);
        CHECK(pex.dropped_count == 1);
        CHECK(pex.contacts.at(0).endpoint.address().to_string() == "203.0.113.9");
        CHECK(pex.contacts.at(0).endpoint.port() == 6'881U);
        CHECK(pex.contacts.at(0).action == lt::aux::peer_exchange_action::add);
        CHECK(static_cast<std::uint8_t>(pex.contacts.at(0).flags) == 0x1fU);
        CHECK(pex.contacts.at(1).endpoint.address().to_string() == "2001:db8::1");
        CHECK(pex.contacts.at(1).endpoint.port() == 6'882U);
        CHECK(pex.contacts.at(1).action == lt::aux::peer_exchange_action::drop);
        CHECK(probe.last_record_capacity == TTORRENT_MAX_PEX_MESSAGE_CONTACTS);
    }

    CHECK(probe.release_count == 1);
    CHECK(probe.handshake_count == 1);
    CHECK(probe.metadata_count == 1);
    CHECK(probe.pex_count == 1);
}

TEST_CASE("peer protocol typed boundary rejects malformed callback records atomically")
{
    PeerProtocolParserProbe probe;
    BridgePeerMessageParser parser(probe.callbacks());
    lt::error_code error;

    probe.handshake_result.reserved = 1U;
    lt::aux::extension_handshake handshake;
    handshake.ut_metadata_id = 91;
    CHECK_FALSE(parser.parse_extension_handshake("de", handshake, error));
    CHECK(error == lt::errors::invalid_extended);
    CHECK(handshake.ut_metadata_id == 91);

    probe.handshake_result.reserved = 0U;
    probe.handshake_result.ut_metadata_id = 3;
    probe.handshake_result.ut_pex_id = 3;
    CHECK_FALSE(parser.parse_extension_handshake("de", handshake, error));
    CHECK(error == lt::errors::invalid_extended);
    CHECK(handshake.ut_metadata_id == 91);

    probe.metadata_result = TTorrentMetadataMessageResult{
        .raw_message_type = 0,
        .piece = 1,
        .total_size = 4,
        .payload_offset = 2,
        .payload_size = 0,
        .kind = TTORRENT_METADATA_MESSAGE_DATA,
        .has_total_size = 1U,
        .reserved0 = 0U,
        .reserved1 = 0U,
    };
    lt::aux::ut_metadata_message metadata;
    metadata.piece = 92;
    CHECK_FALSE(parser.parse_ut_metadata("de", metadata, error));
    CHECK(error == lt::errors::invalid_metadata_message);
    CHECK(metadata.piece == 92);

    TTorrentPeerExchangeRecord const duplicate{
        .address_high = 0U,
        .address_low = 0xcb00'7109U,
        .port = 6'881U,
        .address_family = TTORRENT_PEER_ADDRESS_IPV4,
        .action = TTORRENT_PEX_CONTACT_ADD,
        .flags = 0U,
        .reserved0 = 0U,
        .reserved1 = 0U,
    };
    probe.pex_records = {duplicate, duplicate};
    probe.pex_result = TTorrentPeerExchangeResult{
        .record_count = 2,
        .added_count = 2,
        .dropped_count = 0,
        .reserved = 0U,
    };
    lt::aux::peer_exchange_message pex;
    pex.added_count = 93;
    CHECK_FALSE(parser.parse_ut_pex("de", pex, error));
    CHECK(error == lt::errors::invalid_pex_message);
    CHECK(pex.added_count == 93);

    probe.pex_records = {duplicate};
    probe.pex_result = TTorrentPeerExchangeResult{
        .record_count = 1,
        .added_count = 0,
        .dropped_count = 0,
        .reserved = 1U,
    };
    CHECK_FALSE(parser.parse_ut_pex("de", pex, error));
    CHECK(error == lt::errors::invalid_pex_message);
    CHECK(pex.added_count == 93);
}

TEST_CASE("peer protocol PEX endpoint identity includes the port")
{
    PeerProtocolParserProbe probe;
    TTorrentPeerExchangeRecord const first{
        .address_high = 0U,
        .address_low = 0xcb00'7109U,
        .port = 6'881U,
        .address_family = TTORRENT_PEER_ADDRESS_IPV4,
        .action = TTORRENT_PEX_CONTACT_ADD,
        .flags = 0U,
        .reserved0 = 0U,
        .reserved1 = 0U,
    };
    TTorrentPeerExchangeRecord second = first;
    second.port = 6'882U;
    second.action = TTORRENT_PEX_CONTACT_DROP;
    probe.pex_records = {first, second};
    probe.pex_result = TTorrentPeerExchangeResult{
        .record_count = 2,
        .added_count = 1,
        .dropped_count = 1,
        .reserved = 0U,
    };

    BridgePeerMessageParser parser(probe.callbacks());
    lt::aux::peer_exchange_message imported;
    lt::error_code error;
    REQUIRE(parser.parse_ut_pex("de", imported, error));
    REQUIRE_FALSE(error);
    REQUIRE(imported.contacts.size() == 2U);
    CHECK(imported.contacts.at(0).endpoint.port() == 6'881U);
    CHECK(imported.contacts.at(1).endpoint.port() == 6'882U);

    second.port = first.port;
    probe.pex_records = {first, second};
    imported.added_count = 91;
    CHECK_FALSE(parser.parse_ut_pex("de", imported, error));
    CHECK(error == lt::errors::invalid_pex_message);
    CHECK(imported.added_count == 91);
}

TEST_CASE("HTTP tracker callback ownership and typed announce import are exact")
{
    std::string const body = "tracker-idwarninghost.exampleABCDEFGHIJKLMNOPQRST";
    auto const offset_of = [&](std::string_view const value) {
        std::size_t const offset = body.find(value);
        REQUIRE(offset != std::string::npos);
        REQUIRE(offset <= static_cast<std::size_t>(INT32_MAX));
        return static_cast<int32_t>(offset);
    };

    TrackerResponseParserProbe probe;
    probe.result = TTorrentHTTPTrackerResponseResult{
        .address_high = 0U,
        .address_low = 0xcb00'710aU,
        .interval = 1'800,
        .minimum_interval = 60,
        .complete = 12,
        .incomplete = 3,
        .downloaded = 44,
        .downloaders = -1,
        .tracker_id_offset = offset_of("tracker-id"),
        .tracker_id_size = 10,
        .failure_reason_offset = 0,
        .failure_reason_size = 0,
        .warning_message_offset = offset_of("warning"),
        .warning_message_size = 7,
        .peer_count = 3,
        .present_fields = TTORRENT_TRACKER_HAS_ID
            | TTORRENT_TRACKER_HAS_WARNING_MESSAGE
            | TTORRENT_TRACKER_HAS_EXTERNAL_ADDRESS,
        .address_family = TTORRENT_PEER_ADDRESS_IPV4,
        .reserved0 = 0U,
        .reserved1 = 0U,
    };
    probe.peers = {
        TTorrentTrackerPeerRecord{
            .address_high = 0U,
            .address_low = 0U,
            .hostname_offset = offset_of("host.example"),
            .hostname_size = 12,
            .peer_id_offset = offset_of("ABCDEFGHIJKLMNOPQRST"),
            .port = 6'881U,
            .kind = TTORRENT_TRACKER_PEER_HOSTNAME,
            .has_peer_id = 1U,
            .reserved = 0U,
        },
        TTorrentTrackerPeerRecord{
            .address_high = 0U,
            .address_low = 0xcb00'7109U,
            .hostname_offset = 0,
            .hostname_size = 0,
            .peer_id_offset = 0,
            .port = 6'882U,
            .kind = TTORRENT_PEER_ADDRESS_IPV4,
            .has_peer_id = 0U,
            .reserved = 0U,
        },
        TTorrentTrackerPeerRecord{
            .address_high = 0x2001'0db8'0000'0000U,
            .address_low = 1U,
            .hostname_offset = 0,
            .hostname_size = 0,
            .peer_id_offset = 0,
            .port = 6'883U,
            .kind = TTORRENT_PEER_ADDRESS_IPV6,
            .has_peer_id = 0U,
            .reserved = 0U,
        },
    };

    {
        BridgeTrackerResponseParser parser(probe.callbacks());
        CHECK(probe.retain_count == 1);
        CHECK(probe.release_count == 0);
        lt::aux::tracker_response imported;
        lt::error_code error = lt::errors::invalid_tracker_response;
        REQUIRE(parser.parse_http_response(body, false, lt::sha1_hash{}, imported, error));
        CHECK_FALSE(error);
        CHECK(imported.interval.count() == 1'800);
        CHECK(imported.min_interval.count() == 60);
        CHECK(imported.complete == 12);
        CHECK(imported.incomplete == 3);
        CHECK(imported.downloaded == 44);
        CHECK(imported.downloaders == -1);
        CHECK(imported.trackerid == "tracker-id");
        CHECK(imported.warning_message == "warning");
        CHECK(imported.external_ip.to_string() == "203.0.113.10");
        REQUIRE(imported.peers.size() == 1U);
        CHECK(imported.peers.at(0).hostname == "host.example");
        CHECK(imported.peers.at(0).port == 6'881U);
        CHECK(std::ranges::equal(
            imported.peers.at(0).pid,
            std::string_view("ABCDEFGHIJKLMNOPQRST")
        ));
        REQUIRE(imported.peers4.size() == 1U);
        CHECK(lt::address_v4(imported.peers4.at(0).ip).to_string() == "203.0.113.9");
        CHECK(imported.peers4.at(0).port == 6'882U);
        REQUIRE(imported.peers6.size() == 1U);
        CHECK(lt::address_v6(imported.peers6.at(0).ip).to_string() == "2001:db8::1");
        CHECK(imported.peers6.at(0).port == 6'883U);
        CHECK(probe.last_body == body);
        CHECK(probe.last_is_scrape == 0);
        CHECK(probe.last_peer_capacity >= 3);
    }

    CHECK(probe.parse_count == 1);
    CHECK(probe.release_count == 1);
}

TEST_CASE("HTTP tracker scrape passes the exact binary hash to the typed parser")
{
    TrackerResponseParserProbe probe;
    probe.result = TTorrentHTTPTrackerResponseResult{
        .address_high = 0U,
        .address_low = 0U,
        .interval = 1'800,
        .minimum_interval = 30,
        .complete = 20,
        .incomplete = 4,
        .downloaded = 100,
        .downloaders = 2,
        .tracker_id_offset = 0,
        .tracker_id_size = 0,
        .failure_reason_offset = 0,
        .failure_reason_size = 0,
        .warning_message_offset = 0,
        .warning_message_size = 0,
        .peer_count = 0,
        .present_fields = 0U,
        .address_family = 0U,
        .reserved0 = 0U,
        .reserved1 = 0U,
    };
    lt::sha1_hash const info_hash = bridge_tests::sha1_hash_from_seed(37U);
    BridgeTrackerResponseParser parser(probe.callbacks());
    lt::aux::tracker_response imported;
    lt::error_code error;
    REQUIRE(parser.parse_http_response("de", true, info_hash, imported, error));
    CHECK_FALSE(error);
    CHECK(probe.last_is_scrape == 1);
    CHECK(std::ranges::equal(probe.last_scrape_hash, info_hash));
    CHECK(imported.complete == 20);
    CHECK(imported.incomplete == 4);
    CHECK(imported.downloaded == 100);
    CHECK(imported.downloaders == 2);
}

TEST_CASE("HTTP tracker failures propagate and malformed callback output is atomic")
{
    TrackerResponseParserProbe probe;
    BridgeTrackerResponseParser parser(probe.callbacks());
    probe.result = TTorrentHTTPTrackerResponseResult{
        .address_high = 0U,
        .address_low = 0U,
        .interval = 90,
        .minimum_interval = 15,
        .complete = -1,
        .incomplete = -1,
        .downloaded = -1,
        .downloaders = -1,
        .tracker_id_offset = 0,
        .tracker_id_size = 0,
        .failure_reason_offset = 0,
        .failure_reason_size = 6,
        .warning_message_offset = 0,
        .warning_message_size = 0,
        .peer_count = 0,
        .present_fields = TTORRENT_TRACKER_HAS_FAILURE_REASON,
        .address_family = 0U,
        .reserved0 = 0U,
        .reserved1 = 0U,
    };

    lt::aux::tracker_response imported;
    lt::error_code error;
    REQUIRE(parser.parse_http_response("denied", false, lt::sha1_hash{}, imported, error));
    CHECK(error == lt::errors::tracker_failure);
    CHECK(imported.failure_reason == "denied");
    CHECK(imported.interval.count() == 90);
    CHECK(imported.min_interval.count() == 15);

    probe.result.failure_reason_size = 0;
    probe.result.present_fields = 0U;
    probe.result.peer_count = 1;
    probe.peers = {TTorrentTrackerPeerRecord{
        .address_high = 0U,
        .address_low = 0U,
        .hostname_offset = 99,
        .hostname_size = 4,
        .peer_id_offset = 0,
        .port = 6'881U,
        .kind = TTORRENT_TRACKER_PEER_HOSTNAME,
        .has_peer_id = 0U,
        .reserved = 0U,
    }};
    imported.trackerid = "sentinel";
    imported.complete = 77;
    CHECK_FALSE(parser.parse_http_response(
        "large-enough-body",
        false,
        lt::sha1_hash{},
        imported,
        error
    ));
    CHECK(error == lt::errors::invalid_tracker_response);
    CHECK(imported.trackerid == "sentinel");
    CHECK(imported.complete == 77);

    std::string invalid_utf8(1U, static_cast<char>(0xff));
    probe.peers.clear();
    probe.result.peer_count = 0;
    probe.result.warning_message_offset = 0;
    probe.result.warning_message_size = 1;
    probe.result.present_fields = TTORRENT_TRACKER_HAS_WARNING_MESSAGE;
    CHECK_FALSE(parser.parse_http_response(
        invalid_utf8,
        false,
        lt::sha1_hash{},
        imported,
        error
    ));
    CHECK(error == lt::errors::invalid_tracker_response);
    CHECK(imported.trackerid == "sentinel");
    CHECK(imported.complete == 77);
}

TEST_CASE("hash-verified swarm metadata installs only through the external parser")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const swarm_info = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );
    SwarmMetainfoParserProbe probe(swarm_info.bytes);
    auto parser = std::make_shared<BridgeSwarmMetadataParser>(probe.callbacks());
    bridge_tests::TemporaryDirectory temporary_directory;

    {
        lt::session session(make_session_params(false));
        lt::add_torrent_params params;
        params.info_hashes = lt::info_hash_t(lt::hasher(lt::span<char const>(info)).final());
        params.save_path = temporary_directory.path().string();
        params.swarm_metadata_parser = parser;
        params.flags |= lt::torrent_flags::paused;
        lt::error_code add_error;
        lt::torrent_handle handle = session.add_torrent(std::move(params), add_error);
        REQUIRE_FALSE(add_error);
        REQUIRE(handle.is_valid());

        REQUIRE(handle.set_metadata(lt::span<char const>(info)));
        std::shared_ptr<lt::torrent_info const> installed = handle.torrent_file();
        REQUIRE(installed);
        CHECK(installed->is_valid());
        CHECK(installed->name() == "file.bin");
        CHECK(std::ranges::equal(installed->info_section(), info));
        CHECK(probe.parse_count == 1);
        CHECK(probe.capsule_release_count == 1);
    }

    parser.reset();
    CHECK(probe.context_release_count == 1);
}

TEST_CASE("session teardown cannot release a blocked swarm parser context")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const swarm_info = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );
    SwarmMetainfoParserProbe probe(swarm_info.bytes);
    probe.block_next_parse();
    auto parser = std::make_shared<BridgeSwarmMetadataParser>(probe.callbacks());
    bridge_tests::TemporaryDirectory temporary_directory;
    auto session = std::make_unique<lt::session>(make_session_params(false));
    lt::add_torrent_params params;
    params.info_hashes = lt::info_hash_t(lt::hasher(lt::span<char const>(info)).final());
    params.save_path = temporary_directory.path().string();
    params.swarm_metadata_parser = parser;
    params.flags |= lt::torrent_flags::paused;
    lt::error_code add_error;
    lt::torrent_handle handle = session->add_torrent(std::move(params), add_error);
    REQUIRE_FALSE(add_error);
    REQUIRE(handle.is_valid());
    parser.reset();

    std::jthread metadata_worker([handle, &info]() mutable {
        static_cast<void>(handle.set_metadata(lt::span<char const>(info)));
    });
    bool const callback_entered = probe.wait_for_blocked_parse();
    if (!callback_entered) {
        probe.unblock_parse();
        metadata_worker.join();
        CHECK(callback_entered);
        return;
    }

    std::atomic_bool shutdown_started = false;
    std::jthread shutdown_worker([&session, &shutdown_started] {
        shutdown_started.store(true);
        shutdown_started.notify_all();
        session.reset();
    });
    shutdown_started.wait(false);
    CHECK(probe.active_callback_count == 1);
    CHECK(probe.context_release_count == 0);
    CHECK(probe.context_release_during_callback_count == 0);

    probe.unblock_parse();
    metadata_worker.join();
    shutdown_worker.join();
    handle = lt::torrent_handle{};

    CHECK(probe.parse_count == 1);
    CHECK(probe.capsule_release_count == 1);
    CHECK(probe.outstanding_allocation_count == 0);
    CHECK(probe.context_release_count == 1);
    CHECK(probe.context_release_during_callback_count == 0);
    CHECK(probe.context_release_with_allocation_count == 0);
}

TEST_CASE("bridge identity attachment carries every session parser")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const swarm_info = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );
    SwarmMetainfoParserProbe probe(swarm_info.bytes);
    auto parser = std::make_shared<BridgeSwarmMetadataParser>(probe.callbacks());
    PeerProtocolParserProbe peer_probe;
    auto peer_parser = std::make_shared<BridgePeerMessageParser>(peer_probe.callbacks());
    TrackerResponseParserProbe tracker_probe;
    auto tracker_parser = std::make_shared<BridgeTrackerResponseParser>(tracker_probe.callbacks());
    DHTMessageParserProbe dht_probe;
    auto dht_parser = std::make_shared<BridgeDHTMessageParser>(dht_probe.callbacks());
    bridge_tests::TemporaryDirectory temporary_directory;
    {
        TTorrentClient client(
            (temporary_directory.path() / "State").string(),
            false,
            nullptr,
            parser,
            peer_parser,
            tracker_parser,
            dht_parser
        );
        client.set_session_shutdown_asynchronous(false);
        lt::add_torrent_params params;
        params.info_hashes = lt::info_hash_t(lt::hasher(lt::span<char const>(info)).final());
        TorrentIdentity *identity = client.attach_identity(
            params,
            "t:0123456789abcdef0123456789abcdef"
        );

        REQUIRE(identity != nullptr);
        CHECK(params.swarm_metadata_parser == parser);
        CHECK(params.peer_message_parser == peer_parser);
        CHECK(params.tracker_response_parser == tracker_parser);
        CHECK(client.dht_message_parser == dht_parser);
        params.swarm_metadata_parser.reset();
        params.peer_message_parser.reset();
        params.tracker_response_parser.reset();
        parser.reset();
        peer_parser.reset();
        tracker_parser.reset();
        dht_parser.reset();
        CHECK(probe.context_release_count == 0);
        CHECK(peer_probe.release_count == 0);
        CHECK(tracker_probe.release_count == 0);
        CHECK(dht_probe.release_count == 0);
    }
    CHECK(probe.context_release_count == 1);
    CHECK(peer_probe.release_count == 1);
    CHECK(tracker_probe.release_count == 1);
    CHECK(dht_probe.release_count == 1);
}

TEST_CASE("a hash-valid rejected swarm dictionary enters a stable invalid state")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture invalid_capsule = make_v1_capsule(
        info,
        piece_hash_offset,
        TTORRENT_METAINFO_INPUT_INFO_DICTIONARY
    );
    invalid_capsule.bytes.at(0U) ^= 1U;
    SwarmMetainfoParserProbe probe(std::move(invalid_capsule.bytes));
    auto parser = std::make_shared<BridgeSwarmMetadataParser>(probe.callbacks());
    bridge_tests::TemporaryDirectory temporary_directory;

    {
        lt::session session(make_session_params(false));
        lt::add_torrent_params params;
        params.info_hashes = lt::info_hash_t(lt::hasher(lt::span<char const>(info)).final());
        params.save_path = temporary_directory.path().string();
        params.swarm_metadata_parser = parser;
        lt::error_code add_error;
        lt::torrent_handle handle = session.add_torrent(std::move(params), add_error);
        REQUIRE_FALSE(add_error);
        REQUIRE(handle.is_valid());

        CHECK_FALSE(handle.set_metadata(lt::span<char const>(info)));
        CHECK(handle.status().errc == lt::errors::invalid_swarm_metadata);
        CHECK(probe.parse_count == 1);
        CHECK(probe.capsule_release_count == 1);

        CHECK_FALSE(handle.set_metadata(lt::span<char const>(info)));
        CHECK(probe.parse_count == 1);
        CHECK(probe.capsule_release_count == 1);
    }

    parser.reset();
    CHECK(probe.context_release_count == 1);
}

TEST_CASE("metainfo capsule C ABI rejects raw bytes and commits typed priorities")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const fixture = make_metainfo_capsule(
        info,
        "file.bin",
        TTORRENT_METAINFO_KIND_V1,
        TTORRENT_CONTENT_KIND_SINGLE_FILE,
        {CapsuleFileFixture{.components = {"file.bin"}, .size = 4}},
        std::pair{piece_hash_offset, 20U}
    );
    TorrentLoadResult const decoded = import_preparsed_metainfo_capsule(fixture.bytes);
    REQUIRE(decoded);

    bridge_tests::TemporaryDirectory temporary_directory;
    bridge_tests::TestPayloadBroker broker(temporary_directory.path() / "Payload");
    TTorrentStorageActivation const activation = broker.register_torrent(*decoded);
    TTorrentClient client(
        (temporary_directory.path() / "State").string(),
        true,
        broker.context()
    );
    client.set_session_shutdown_asynchronous(false);

    TTorrentAddOptions const options = metainfo_capsule_add_options();
    char added_id[TTORRENT_ID_CAPACITY]{};
    char error[512]{};
    std::uint64_t native_token = 1U;
    int32_t add_outcome = TTORRENT_ADD_OUTCOME_UNKNOWN;
    std::array<std::uint8_t, 1U> const raw_bencode{{'d'}};
    CHECK(::TorrentClientAddMetainfoCapsule(
        &client,
        raw_bencode.data(),
        static_cast<int32_t>(raw_bencode.size()),
        activation,
        options,
        added_id,
        static_cast<int32_t>(sizeof(added_id)),
        &native_token,
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) != 0);
    CHECK(native_token == 0U);
    CHECK(add_outcome == TTORRENT_ADD_REJECTED);
    CHECK(added_id[0] == '\0');

    TTorrentFilePriorityEntry const priority{
        .index = 0,
        .priority = TTORRENT_FILE_PRIORITY_HIGH,
    };
    REQUIRE(::TorrentClientAddMetainfoCapsuleWithPriorities(
        &client,
        fixture.bytes.data(),
        static_cast<int32_t>(fixture.bytes.size()),
        activation,
        options,
        &priority,
        1,
        added_id,
        static_cast<int32_t>(sizeof(added_id)),
        &native_token,
        &add_outcome,
        error,
        static_cast<int32_t>(sizeof(error))
    ) == 0);
    CHECK(add_outcome == TTORRENT_ADD_COMMITTED);
    CHECK(native_token != 0U);
    CHECK(std::string_view(added_id) == "t:0123456789abcdef0123456789abcdef");
    std::optional<lt::torrent_handle> const handle = client.find(native_token);
    REQUIRE(handle.has_value());
    CHECK(handle->file_priority(lt::file_index_t(0)) == lt::top_priority);
}

TEST_CASE("preparsed v2 capsule imports verified piece layers with owned roots")
{
    std::vector<std::uint8_t> piece_hashes(64U);
    for (std::size_t index = 0U; index < piece_hashes.size(); ++index) {
        piece_hashes.at(index) = static_cast<std::uint8_t>(index + 1U);
    }
    std::array<std::uint8_t, 32U> const root = v2_root(piece_hashes);
    std::uint32_t root_offset = 0U;
    std::uint32_t ignored_piece_hash_offset = 0U;
    std::string const info = v2_capsule_info(
        "file.bin",
        32'768,
        root,
        root_offset,
        false,
        ignored_piece_hash_offset
    );
    MetainfoCapsuleFixture fixture = make_metainfo_capsule(
        info,
        "file.bin",
        TTORRENT_METAINFO_KIND_V2,
        TTORRENT_CONTENT_KIND_SINGLE_FILE,
        {CapsuleFileFixture{
            .components = {"file.bin"},
            .size = 32'768,
            .info_root_offset = root_offset,
        }},
        std::nullopt,
        {CapsuleLayerFixture{.root = root, .hashes = piece_hashes, .file_indices = {0}}}
    );

    TorrentLoadResult imported = import_preparsed_metainfo_capsule(fixture.bytes);
    REQUIRE(imported);
    REQUIRE(imported->ti);
    CHECK_FALSE(imported->ti->info_hashes().has_v1());
    CHECK(imported->ti->info_hashes().has_v2());
    CHECK(imported->ti->layout().root(lt::file_index_t(0)) == lt::sha256_hash(
        reinterpret_cast<char const *>(root.data())
    ));
    REQUIRE(imported->merkle_trees.size() == 1);
    CHECK_FALSE(imported->merkle_trees[lt::file_index_t(0)].empty());

    std::shared_ptr<lt::torrent_info> copy = std::make_shared<lt::torrent_info>(*imported->ti);
    imported->ti.reset();
    CHECK(copy->layout().root(lt::file_index_t(0)) == lt::sha256_hash(
        reinterpret_cast<char const *>(root.data())
    ));
    lt::torrent_info moved(copy->info_hashes());
    moved = std::move(*copy);
    copy.reset();
    CHECK(moved.layout().root(lt::file_index_t(0)) == lt::sha256_hash(
        reinterpret_cast<char const *>(root.data())
    ));
    std::span<char const> const owned_info = moved.info_section();
    char const * const owned_root = moved.layout().root_ptr(lt::file_index_t(0));
    REQUIRE(root_offset <= owned_info.size());
    REQUIRE(lt::sha256_hash::size() <= owned_info.size() - root_offset);
    CHECK(owned_root == owned_info.subspan(root_offset, lt::sha256_hash::size()).data());
}

TEST_CASE("preparsed hybrid capsule accepts the compatible omitted tail pad")
{
    std::array<std::uint8_t, 32U> root{};
    root.fill(0x5aU);
    std::uint32_t root_offset = 0U;
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v2_capsule_info(
        "tiny.bin",
        3,
        root,
        root_offset,
        true,
        piece_hash_offset
    );
    MetainfoCapsuleFixture fixture = make_metainfo_capsule(
        info,
        "tiny.bin",
        TTORRENT_METAINFO_KIND_HYBRID,
        TTORRENT_CONTENT_KIND_SINGLE_FILE,
        {CapsuleFileFixture{
            .components = {"tiny.bin"},
            .size = 3,
            .info_root_offset = root_offset,
        }},
        std::pair{piece_hash_offset, 20U}
    );

    TorrentLoadResult imported = import_preparsed_metainfo_capsule(fixture.bytes);

    REQUIRE(imported);
    REQUIRE(imported->ti);
    CHECK(imported->ti->info_hashes().has_v1());
    CHECK(imported->ti->info_hashes().has_v2());
    CHECK(imported->ti->layout().num_files() == 1);
    CHECK(imported->ti->total_size() == 3);
}

TEST_CASE("preparsed capsule supports a synthetic root for rootless v2 metadata")
{
    std::array<std::uint8_t, 32U> root{};
    root.fill(0x6bU);
    std::string info = "d9:file treed8:leaf.bind0:d6:lengthi16384e11:pieces root32:";
    std::uint32_t const root_offset = static_cast<std::uint32_t>(info.size());
    for (std::uint8_t const byte : root) {
        info.push_back(static_cast<char>(byte));
    }
    info += "eee12:meta versioni2e12:piece lengthi16384ee";
    MetainfoCapsuleFixture fixture = make_metainfo_capsule(
        info,
        "Torrent-0123456789ab",
        TTORRENT_METAINFO_KIND_V2,
        TTORRENT_CONTENT_KIND_DIRECTORY,
        {CapsuleFileFixture{
            .components = {"leaf.bin"},
            .size = 16'384,
            .info_root_offset = root_offset,
        }}
    );

    TorrentLoadResult imported = import_preparsed_metainfo_capsule(fixture.bytes);

    REQUIRE(imported);
    REQUIRE(imported->ti);
    CHECK(imported->ti->name() == "Torrent-0123456789ab");
    CHECK(imported->ti->layout().file_path(lt::file_index_t(0))
        == "Torrent-0123456789ab/leaf.bin");
}

TEST_CASE("preparsed metainfo capsule rejects corrupted framing and semantic ranges")
{
    std::uint32_t piece_hash_offset = 0U;
    std::string const info = v1_capsule_info(piece_hash_offset);
    MetainfoCapsuleFixture const valid = make_metainfo_capsule(
        info,
        "file.bin",
        TTORRENT_METAINFO_KIND_V1,
        TTORRENT_CONTENT_KIND_SINGLE_FILE,
        {CapsuleFileFixture{.components = {"file.bin"}, .size = 4}},
        std::pair{piece_hash_offset, 20U}
    );
    REQUIRE(import_preparsed_metainfo_capsule(valid.bytes));

    auto rejects = [](MetainfoCapsuleFixture fixture) {
        CHECK_FALSE(import_preparsed_metainfo_capsule(fixture.bytes));
    };

    MetainfoCapsuleFixture mutation = valid;
    mutation.bytes.at(0U) ^= 1U;
    rejects(mutation);

    mutation = valid;
    write_u32(mutation.bytes, 8U, static_cast<std::uint32_t>(mutation.bytes.size() - 1U));
    rejects(mutation);

    mutation = valid;
    write_u16(mutation.bytes, 144U, TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE + 1U);
    rejects(mutation);

    mutation = valid;
    mutation.bytes.at(154U) = 1U;
    rejects(mutation);

    mutation = valid;
    write_u32(mutation.bytes, 72U, mutation.component_table_offset + 4U);
    rejects(mutation);

    mutation = valid;
    write_i32(mutation.bytes, mutation.file_table_offset, 1);
    rejects(mutation);

    mutation = valid;
    write_u32(mutation.bytes, mutation.component_table_offset, 1U);
    rejects(mutation);

    mutation = valid;
    mutation.bytes.at(mutation.info_offset) = 'l';
    rejects(mutation);

    mutation = valid;
    mutation.bytes.back() ^= 1U;
    rejects(mutation);

    mutation = valid;
    write_u32(mutation.bytes, 56U, mutation.info_offset);
    rejects(mutation);

    mutation = valid;
    mutation.bytes.at(15U) = 0x80U;
    rejects(mutation);

    mutation = valid;
    write_u16(mutation.bytes, 16U, TTORRENT_METAINFO_FIELD_PIECE_LAYERS);
    rejects(mutation);

    MetainfoCapsuleFixture const unsupported_tracker = make_metainfo_capsule(
        info,
        "file.bin",
        TTORRENT_METAINFO_KIND_V1,
        TTORRENT_CONTENT_KIND_SINGLE_FILE,
        {CapsuleFileFixture{.components = {"file.bin"}, .size = 4}},
        std::pair{piece_hash_offset, 20U},
        {},
        false,
        {{"ftp://tracker.example/announce", 0U}}
    );
    rejects(unsupported_tracker);

    MetainfoCapsuleFixture const unsupported_web_seed = make_metainfo_capsule(
        info,
        "file.bin",
        TTORRENT_METAINFO_KIND_V1,
        TTORRENT_CONTENT_KIND_SINGLE_FILE,
        {CapsuleFileFixture{.components = {"file.bin"}, .size = 4}},
        std::pair{piece_hash_offset, 20U},
        {},
        false,
        {},
        {"udp://seed.example/file"}
    );
    rejects(unsupported_web_seed);

    std::vector<std::uint8_t> truncated(
        valid.bytes.begin(),
        std::next(valid.bytes.begin(), TTORRENT_METAINFO_CAPSULE_HEADER_SIZE - 1)
    );
    CHECK_FALSE(import_preparsed_metainfo_capsule(truncated));
}

TEST_CASE("torrent metadata rejects symbolic links and paths that cannot fit the bridge ABI")
{
    BridgeResult const symlink = validate_torrent_info(*make_raw_v1_torrent_info(
        "d4:attr1:l6:lengthi0e4:pathl4:linke12:symlink pathl8:file.txtee"
        "d6:lengthi4e4:pathl8:file.txtee"
    ));
    REQUIRE_FALSE(symlink);
    CHECK(symlink.error().code == 2);
    CHECK(symlink.error().message == "The torrent contains symbolic links, which are not supported.");

    std::string long_path_payload = "d6:lengthi4e4:pathl";
    for (char component = 'a'; component < 'f'; ++component) {
        append_bencoded_string(long_path_payload, std::string(240U, component));
    }
    long_path_payload += "ee";
    BridgeResult const long_path = validate_torrent_info(*make_raw_v1_torrent_info(long_path_payload));
    REQUIRE_FALSE(long_path);
    CHECK(long_path.error().code == 2);
    CHECK(long_path.error().message == "The torrent contains a file path that is too long.");
}

TEST_CASE("torrent metadata rejects unsafe renamed file layouts")
{
    std::shared_ptr<lt::torrent_info const> const info = make_file_priority_torrent_info();
    REQUIRE(info != nullptr);

    using RenameMap = std::map<lt::file_index_t, std::string>;
    auto expect_rejected = [&info](RenameMap const &renames) {
        BridgeResult const result = validate_torrent_info(*info, renames);
        CHECK_FALSE(result.has_value());
        if (!result) {
            CHECK(result.error().code == 2);
        }
    };

    CHECK(validate_torrent_info(
        *info,
        RenameMap{{lt::file_index_t(0), "renamed-high.bin"}}
    ).has_value());

    expect_rejected(RenameMap{{lt::file_index_t(0), ""}});
    expect_rejected(RenameMap{{lt::file_index_t(-1), "negative-index.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(info->layout().num_files()), "past-end.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "/tmp/escaped.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "../escaped.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "files/./renamed.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "files//renamed.bin"}});
    expect_rejected(RenameMap{{lt::file_index_t(0), "files/control\nname.bin"}});

    std::string nul_path = "files/nul";
    nul_path.push_back('\0');
    nul_path += "name.bin";
    expect_rejected(RenameMap{{lt::file_index_t(0), std::move(nul_path)}});

    std::string delete_path = "files/delete";
    delete_path.push_back(static_cast<char>(0x7f));
    delete_path += "name.bin";
    expect_rejected(RenameMap{{lt::file_index_t(0), std::move(delete_path)}});

    std::string overlong_path = "files/";
    overlong_path.append(sizeof(TTorrentFileSnapshot::path), 'x');
    expect_rejected(RenameMap{{lt::file_index_t(0), std::move(overlong_path)}});
}

TEST_CASE("peer source snapshots count overlapping libtorrent source flags")
{
    std::vector<lt::peer_info> peers(5);
    peers.at(0).source = lt::peer_info::tracker;
    peers.at(1).source = lt::peer_info::dht | lt::peer_info::pex;
    peers.at(2).source = lt::peer_info::resume_data | lt::peer_info::incoming;
    peers.at(3).source = lt::peer_info::lsd;
    peers.at(3).connection_type = lt::peer_info::web_seed;

    TTorrentPeerSourceSnapshot const snapshot = peer_source_snapshot(peers);

    CHECK(snapshot.connected == 5);
    CHECK(snapshot.tracker == 1);
    CHECK(snapshot.dht == 1);
    CHECK(snapshot.peer_exchange == 1);
    CHECK(snapshot.local_service_discovery == 1);
    CHECK(snapshot.resume_data == 1);
    CHECK(snapshot.incoming == 1);
    CHECK(snapshot.web_seed == 1);
    CHECK(snapshot.other == 1);
}

TEST_CASE("network binding trims input and classifies valid binding forms")
{
    NetworkBinding const any = network_binding("   ");
    CHECK(any.kind == NetworkBindingKind::any);
    CHECK(any.value.empty());

    NetworkBinding const name = network_binding(" en0 ");
    CHECK(name.kind == NetworkBindingKind::name);
    CHECK(name.value == "en0");

    NetworkBinding const ascii_whitespace = network_binding("\t\n\v\f\ren0 \t");
    CHECK(ascii_whitespace.kind == NetworkBindingKind::name);
    CHECK(ascii_whitespace.value == "en0");

    NetworkBinding const ipv4 = network_binding("192.0.2.10");
    CHECK(ipv4.kind == NetworkBindingKind::ipv4);
    CHECK(ipv4.value == "192.0.2.10");

    NetworkBinding const ipv6 = network_binding("2001:db8::1");
    CHECK(ipv6.kind == NetworkBindingKind::ipv6);
    CHECK(ipv6.value == "2001:db8::1");
}

TEST_CASE("network binding rejects ambiguous or unsafe input")
{
    CHECK_THROWS_AS(static_cast<void>(network_binding("en0,utun0")), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(network_binding("en0 utun0")), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(network_binding("en0\x7futun0")), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(network_binding("[2001:db8::1]")), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(network_binding("2001:db8:::1")), std::invalid_argument);
}

TEST_CASE("listen and outgoing interfaces honor blocked networking")
{
    CHECK(listen_interfaces(6881, "", true).empty());
    CHECK(outgoing_interfaces("en0", true).empty());
}

TEST_CASE("listen interfaces format all binding variants")
{
    CHECK(listen_interfaces(6881, "", false) == "0.0.0.0:6881,[::]:6881");
    CHECK(listen_interfaces(6881, "en0", false) == "en0:6881");
    CHECK(listen_interfaces(6881, "192.0.2.10", false) == "192.0.2.10:6881");
    CHECK(listen_interfaces(6881, "2001:db8::1", false) == "[2001:db8::1]:6881");
    CHECK(listen_interfaces(0, "", false) == "0.0.0.0:0,[::]:0");

    CHECK_THROWS_AS(static_cast<void>(listen_interfaces(-1, "", false)), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(listen_interfaces(1023, "", false)), std::invalid_argument);
    CHECK_THROWS_AS(static_cast<void>(listen_interfaces(65536, "", false)), std::invalid_argument);
}

TEST_CASE("outgoing interfaces pass through explicit bindings only")
{
    CHECK(outgoing_interfaces("", false).empty());
    CHECK(outgoing_interfaces("en0", false) == "en0");
    CHECK(outgoing_interfaces("192.0.2.10", false) == "192.0.2.10");
    CHECK(outgoing_interfaces("2001:db8::1", false) == "2001:db8::1");
}

TEST_CASE("encryption policy maps only the supported ABI values")
{
    CHECK(is_valid_encryption_policy(0));
    CHECK(is_valid_encryption_policy(1));
    CHECK(is_valid_encryption_policy(2));
    CHECK_FALSE(is_valid_encryption_policy(-1));
    CHECK_FALSE(is_valid_encryption_policy(3));

    CHECK(encryption_policy(0) == static_cast<int>(lt::settings_pack::pe_enabled));
    CHECK(encryption_policy(1) == static_cast<int>(lt::settings_pack::pe_forced));
    CHECK(encryption_policy(2) == static_cast<int>(lt::settings_pack::pe_disabled));
    CHECK(encryption_policy(99) == static_cast<int>(lt::settings_pack::pe_enabled));
}

TEST_CASE("add params map peer exchange preference to torrent flags")
{
    lt::add_torrent_params enabled = bridge_tests::add_params_with_hashes();
    prepare_add_params(enabled, "/tmp", false, true);
    CHECK_FALSE(static_cast<bool>(enabled.flags & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(enabled.flags & lt::torrent_flags::block_non_global_peers));

    lt::add_torrent_params already_disabled = bridge_tests::add_params_with_hashes();
    already_disabled.flags |= lt::torrent_flags::disable_pex;
    prepare_add_params(already_disabled, "/tmp", false, true);
    CHECK(static_cast<bool>(already_disabled.flags & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(already_disabled.flags & lt::torrent_flags::block_non_global_peers));

    lt::add_torrent_params disabled = bridge_tests::add_params_with_hashes();
    prepare_add_params(disabled, "/tmp", false, false);
    CHECK(static_cast<bool>(disabled.flags & lt::torrent_flags::disable_pex));
    CHECK(static_cast<bool>(disabled.flags & lt::torrent_flags::block_non_global_peers));
}

TEST_CASE("add params apply file priority classes")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.ti = make_file_priority_torrent_info();

    std::array<TTorrentFilePriorityEntry, 3> const priorities{{
        TTorrentFilePriorityEntry{.index = 0, .priority = TTORRENT_FILE_PRIORITY_HIGH},
        TTorrentFilePriorityEntry{.index = 1, .priority = TTORRENT_FILE_PRIORITY_SKIP},
        TTorrentFilePriorityEntry{.index = 2, .priority = TTORRENT_FILE_PRIORITY_LOW}
    }};

    BridgeResult const applied = apply_file_priorities(params, std::span{priorities});
    REQUIRE(applied);
    REQUIRE(params.file_priorities.size() == priorities.size());
    CHECK(params.file_priorities.at(0) == lt::top_priority);
    CHECK(params.file_priorities.at(1) == lt::dont_download);
    CHECK(params.file_priorities.at(2) == lt::low_priority);
}

TEST_CASE("add params reject invalid file priorities")
{
    lt::add_torrent_params all_skipped = bridge_tests::add_params_with_hashes();
    all_skipped.ti = make_file_priority_torrent_info();
    std::array<TTorrentFilePriorityEntry, 3> const skipped_priorities{{
        TTorrentFilePriorityEntry{.index = 0, .priority = TTORRENT_FILE_PRIORITY_SKIP},
        TTorrentFilePriorityEntry{.index = 1, .priority = TTORRENT_FILE_PRIORITY_SKIP},
        TTorrentFilePriorityEntry{.index = 2, .priority = TTORRENT_FILE_PRIORITY_SKIP}
    }};
    BridgeResult const skipped = apply_file_priorities(all_skipped, std::span{skipped_priorities});
    REQUIRE_FALSE(skipped);
    CHECK(skipped.error().message == "Choose at least one file.");

    lt::add_torrent_params duplicate = bridge_tests::add_params_with_hashes();
    duplicate.ti = make_file_priority_torrent_info();
    std::array<TTorrentFilePriorityEntry, 2> const duplicate_priorities{{
        TTorrentFilePriorityEntry{.index = 0, .priority = TTORRENT_FILE_PRIORITY_NORMAL},
        TTorrentFilePriorityEntry{.index = 0, .priority = TTORRENT_FILE_PRIORITY_HIGH}
    }};
    BridgeResult const duplicate_result = apply_file_priorities(duplicate, std::span{duplicate_priorities});
    REQUIRE_FALSE(duplicate_result);
    CHECK(duplicate_result.error().message == "The file priorities are invalid.");
}

TEST_CASE("HTTPS source URL classification is strict and case-insensitive")
{
    CHECK(is_https_url("https://tracker.example/announce"));
    CHECK(is_https_url("HTTPS://tracker.example/announce"));
    CHECK_FALSE(is_https_url("http://tracker.example/announce"));
    CHECK_FALSE(is_https_url("udp://tracker.example/announce"));
    CHECK_FALSE(is_https_url("tracker.example/announce"));
}

TEST_CASE("source counts include trackers and web seeds")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce"
    };
    params.url_seeds.push_back("http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    TorrentSourceCounts const counts = torrent_source_counts(params);

    CHECK(counts.tracker_count == 2);
    CHECK(counts.https_tracker_count == 1);
    CHECK(counts.web_seed_count == 2);
    CHECK(counts.https_web_seed_count == 1);
}

TEST_CASE("parsed magnet import constructs only narrow add fields")
{
    bridge_tests::ParsedMagnetFixture const fixture = bridge_tests::parsed_magnet_fixture(
        "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        "&dn=typed"
        "&tr=https%3A%2F%2Ftracker.example%2Fannounce"
        "&ws=https%3A%2F%2Fseed.example%2Ffile"
        "&so=1-2"
    );

    TorrentLoadResult const imported = import_parsed_magnet(
        fixture.header,
        fixture.blob,
        fixture.trackers,
        fixture.web_seeds,
        fixture.file_selections
    );

    REQUIRE(imported.has_value());
    CHECK(imported->info_hashes.has_v1());
    CHECK_FALSE(imported->info_hashes.has_v2());
    CHECK(imported->name == "typed");
    CHECK(imported->trackers == std::vector<std::string>{
        "https://tracker.example/announce"
    });
    CHECK(imported->tracker_tiers == std::vector<int>{0});
    CHECK(imported->url_seeds == std::vector<std::string>{
        "https://seed.example/file"
    });
    REQUIRE(imported->file_priorities.size() == 3U);
    CHECK(imported->file_priorities[0] == lt::dont_download);
    CHECK(imported->file_priorities[1] == lt::default_priority);
    CHECK(imported->file_priorities[2] == lt::default_priority);
    CHECK(imported->peers.empty());
    CHECK(imported->dht_nodes.empty());
}

TEST_CASE("parsed magnet import rejects noncanonical ranges and records")
{
    bridge_tests::ParsedMagnetFixture fixture = bridge_tests::parsed_magnet_fixture(
        "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        "&tr=https%3A%2F%2Ftracker.example%2Fannounce"
        "&so=1-2"
    );

    fixture.header.schema_version += 1U;
    CHECK_FALSE(import_parsed_magnet(
        fixture.header,
        fixture.blob,
        fixture.trackers,
        fixture.web_seeds,
        fixture.file_selections
    ));
    fixture.header.schema_version = TTORRENT_MAGNET_IMPORT_SCHEMA_VERSION;

    fixture.blob.push_back(static_cast<std::uint8_t>('x'));
    CHECK_FALSE(import_parsed_magnet(
        fixture.header,
        fixture.blob,
        fixture.trackers,
        fixture.web_seeds,
        fixture.file_selections
    ));
    fixture.blob.pop_back();

    fixture.trackers[0].url_offset += 1U;
    CHECK_FALSE(import_parsed_magnet(
        fixture.header,
        fixture.blob,
        fixture.trackers,
        fixture.web_seeds,
        fixture.file_selections
    ));
    fixture.trackers[0].url_offset -= 1U;

    fixture.file_selections.push_back(TTorrentFileSelectionRange{
        .first_index = 3,
        .last_index = 4,
    });
    CHECK_FALSE(import_parsed_magnet(
        fixture.header,
        fixture.blob,
        fixture.trackers,
        fixture.web_seeds,
        fixture.file_selections
    ));
}

TEST_CASE("source validation rejects source lists above bridge limits")
{
    lt::add_torrent_params trackers = bridge_tests::add_params_with_hashes();
    trackers.trackers.resize(static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT) + 1U, "http://tracker.example/announce");

    BridgeResult const too_many_trackers = validate_torrent_sources(trackers);
    REQUIRE_FALSE(too_many_trackers);
    CHECK(too_many_trackers.error().code == 2);
    CHECK(too_many_trackers.error().message == "The torrent contains too many trackers. The maximum is 2000.");

    lt::add_torrent_params web_seeds = bridge_tests::add_params_with_hashes();
    web_seeds.url_seeds.resize(static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT) + 1U, "http://seed.example/file");

    BridgeResult const too_many_web_seeds = validate_torrent_sources(web_seeds);
    REQUIRE_FALSE(too_many_web_seeds);
    CHECK(too_many_web_seeds.error().code == 2);
    CHECK(too_many_web_seeds.error().message == "The torrent contains too many web seeds. The maximum is 2000.");
}

TEST_CASE("HTTPS source filtering cannot make an oversized original source list admissible")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers.resize(static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT) + 1U, "http://tracker.example/announce");
    params.trackers.push_back("https://secure-tracker.example/announce");
    params.url_seeds.resize(static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT) + 1U, "http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    CHECK_FALSE(validate_torrent_sources(params));
    REQUIRE(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::require, .web_seeds = HTTPSPolicy::require}
    ));

    CHECK(validate_torrent_sources(params).has_value());
    CHECK(params.trackers == std::vector<std::string>{"https://secure-tracker.example/announce"});
    CHECK(params.url_seeds == std::vector<std::string>{"https://secure-seed.example/file"});
}

TEST_CASE("source restoration preserves all originals for explicit validation")
{
    TorrentIdentity identity;
    identity.source_trackers.emplace_back("https://secure-tracker.example/announce");
    identity.source_web_seeds.emplace_back("https://secure-seed.example/file");

    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers.reserve(static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT));
    for (int32_t index = 0; index < TTORRENT_MAX_TRACKER_COUNT; ++index) {
        params.trackers.push_back("http://tracker" + std::to_string(index) + ".example/announce");
    }
    params.url_seeds.reserve(static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT));
    for (int32_t index = 0; index < TTORRENT_MAX_WEB_SEED_COUNT; ++index) {
        params.url_seeds.push_back("http://seed" + std::to_string(index) + ".example/file");
    }

    restore_source_policy_sources(params, &identity);

    CHECK(params.trackers.size() == static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT) + 1U);
    CHECK(params.trackers.front() == "https://secure-tracker.example/announce");
    CHECK(params.url_seeds.size() == static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT) + 1U);
    CHECK(params.url_seeds.back() == "https://secure-seed.example/file");
    CHECK_FALSE(validate_torrent_sources(params));
}

TEST_CASE("requiring HTTPS sources keeps tracker tiers aligned")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce",
        "udp://tracker.example/announce",
        "HTTPS://second-secure-tracker.example/announce"
    };
    params.tracker_tiers = {0, 1, 2, 3};
    params.url_seeds.push_back("http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    CHECK(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::require, .web_seeds = HTTPSPolicy::require}
    ));

    std::vector<std::string> const expected_trackers{
        "https://secure-tracker.example/announce",
        "HTTPS://second-secure-tracker.example/announce"
    };
    std::vector<int> const expected_tiers{1, 3};
    std::vector<std::string> const expected_url_seeds{
        "https://secure-seed.example/file"
    };

    CHECK(params.trackers == expected_trackers);
    CHECK(params.tracker_tiers == expected_tiers);
    CHECK(std::vector<std::string>(params.url_seeds.begin(), params.url_seeds.end()) == expected_url_seeds);
}

TEST_CASE("preferring HTTPS creates secure leading tiers with insecure fallback")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://first-fallback.example/announce",
        "https://first-secure.example/announce",
        "https://second-secure.example/announce",
        "udp://second-fallback.example/announce",
        "http://third-fallback.example/announce",
    };
    params.tracker_tiers = {0, 1, 1, 2, 2};
    params.url_seeds = {
        "http://seed.example/file",
        "https://secure-seed.example/file",
    };

    CHECK(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::prefer, .web_seeds = HTTPSPolicy::original}
    ));

    CHECK(params.trackers == std::vector<std::string>{
        "https://first-secure.example/announce",
        "https://second-secure.example/announce",
        "http://first-fallback.example/announce",
        "udp://second-fallback.example/announce",
        "http://third-fallback.example/announce",
    });
    CHECK(params.tracker_tiers == std::vector<int>{0, 0, 1, 2, 2});
    CHECK(params.url_seeds == std::vector<std::string>{
        "http://seed.example/file",
        "https://secure-seed.example/file",
    });
}

TEST_CASE("original HTTPS policy preserves source order and tiers")
{
    lt::add_torrent_params params = make_source_torrent_params();
    lt::add_torrent_params const original = params;

    CHECK_FALSE(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::original, .web_seeds = HTTPSPolicy::original}
    ));
    CHECK(params.trackers == original.trackers);
    CHECK(params.tracker_tiers == original.tracker_tiers);
    CHECK(params.url_seeds == original.url_seeds);
}

TEST_CASE("requiring HTTPS can target trackers only")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce"
    };
    params.tracker_tiers = {0, 1};
    params.url_seeds.push_back("http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    CHECK(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::require, .web_seeds = HTTPSPolicy::original}
    ));

    std::vector<std::string> const expected_trackers{"https://secure-tracker.example/announce"};
    std::vector<std::string> const expected_url_seeds{
        "http://seed.example/file",
        "https://secure-seed.example/file"
    };
    CHECK(params.trackers == expected_trackers);
    CHECK(std::vector<std::string>(params.url_seeds.begin(), params.url_seeds.end()) == expected_url_seeds);
}

TEST_CASE("requiring HTTPS can target web seeds only")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers = {
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce"
    };
    params.tracker_tiers = {0, 1};
    params.url_seeds.push_back("http://seed.example/file");
    params.url_seeds.push_back("https://secure-seed.example/file");

    CHECK(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::original, .web_seeds = HTTPSPolicy::require}
    ));

    std::vector<std::string> const expected_trackers{
        "http://tracker.example/announce",
        "https://secure-tracker.example/announce"
    };
    std::vector<std::string> const expected_url_seeds{"https://secure-seed.example/file"};
    CHECK(params.trackers == expected_trackers);
    CHECK(std::vector<std::string>(params.url_seeds.begin(), params.url_seeds.end()) == expected_url_seeds);
}

TEST_CASE("requiring HTTPS filters loaded torrent sources")
{
    lt::add_torrent_params params = make_source_torrent_params();

    CHECK(apply_https_source_policy(
        params,
        HTTPSSourcePolicy{.trackers = HTTPSPolicy::require, .web_seeds = HTTPSPolicy::require}
    ));

    TorrentSourceCounts const counts = torrent_source_counts(params);
    CHECK(counts.tracker_count == 1);
    CHECK(counts.https_tracker_count == 1);
    CHECK(counts.web_seed_count == 1);
    CHECK(counts.https_web_seed_count == 1);
}

TEST_CASE("restricted DHT policy strips trackerless resume peer cache")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.peers.emplace_back(lt::make_address_v4("203.0.113.10"), 6881);
    TorrentIdentity identity;

    CHECK(should_strip_resume_peer_cache(params, &identity, true));
    strip_resume_peer_cache(params);

    std::vector<char> const encoded = encoded_resume_data(params, &identity, false, true);
    lt::error_code error;
    lt::add_torrent_params const decoded = lt::read_resume_data(
        lt::span<char const>(encoded.data(), static_cast<int>(encoded.size())),
        error
    );

    REQUIRE_FALSE(error);
    CHECK(decoded.peers.empty());
    CHECK(app_disabled_dht_from_resume_data(encoded));
}

TEST_CASE("restricted DHT policy keeps resume peer cache when trackers remain")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.trackers.push_back("https://secure-tracker.example/announce");
    params.tracker_tiers.push_back(0);
    params.peers.emplace_back(lt::make_address_v4("203.0.113.10"), 6881);
    TorrentIdentity identity;

    CHECK_FALSE(should_strip_resume_peer_cache(params, &identity, true));

    std::vector<char> const encoded = encoded_resume_data(params, &identity, false, true);
    lt::error_code error;
    lt::add_torrent_params const decoded = lt::read_resume_data(
        lt::span<char const>(encoded.data(), static_cast<int>(encoded.size())),
        error
    );

    REQUIRE_FALSE(error);
    REQUIRE(decoded.peers.size() == 1U);
    CHECK(decoded.peers.front().port() == 6881);
}

TEST_CASE("resume endpoint sanitization keeps only global public-torrent peers")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.peers = {
        {lt::make_address("8.8.8.8"), 6881},
        {lt::make_address("192.168.1.1"), 6882},
        {lt::make_address("::ffff:10.0.0.1"), 6883},
    };
    params.banned_peers = {
        {lt::make_address("2606:4700:4700::1111"), 6884},
        {lt::make_address("fd00::1"), 6885},
    };
    params.dht_nodes.emplace_back("router.example", 6886);

    sanitize_resume_endpoint_hints(params);

    REQUIRE(params.peers.size() == 1U);
    CHECK(params.peers.front().address() == lt::make_address("8.8.8.8"));
    REQUIRE(params.banned_peers.size() == 1U);
    CHECK(params.banned_peers.front().address() == lt::make_address("2606:4700:4700::1111"));
    CHECK(params.dht_nodes.empty());
}

TEST_CASE("resume endpoint sanitization strips private-torrent peers")
{
    lt::add_torrent_params params = make_source_torrent_params(true);
    params.peers.emplace_back(lt::make_address("8.8.8.8"), 6881);
    params.banned_peers.emplace_back(lt::make_address("1.1.1.1"), 6882);

    sanitize_resume_endpoint_hints(params);

    CHECK(params.peers.empty());
    CHECK(params.banned_peers.empty());
}

TEST_CASE("resume encoding uses captured source policy snapshot")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    TorrentIdentity identity;
    identity.canonical_id = "t:0123456789abcdef0123456789abcdef";
    identity.https_tracker_policy = HTTPSPolicy::original;
    identity.https_web_seed_policy = HTTPSPolicy::require;
    identity.dht_disabled_by_user = true;
    identity.lsd_disabled_by_user = true;
    identity.source_trackers.emplace_back("http://tracker.example/announce");

    ResumePolicySnapshot const snapshot = resume_policy_snapshot(&identity, false, true, true, false);

    identity.https_tracker_policy = HTTPSPolicy::inherit;
    identity.https_web_seed_policy = HTTPSPolicy::inherit;
    identity.dht_disabled_by_user = false;
    identity.lsd_disabled_by_user = false;
    identity.source_trackers.clear();

    std::vector<char> const encoded = encoded_resume_data(params, snapshot);

    CHECK(canonical_id_from_resume_data(encoded) == "t:0123456789abcdef0123456789abcdef");
    CHECK(https_tracker_policy_from_resume_data(encoded) == HTTPSPolicy::original);
    CHECK(https_web_seed_policy_from_resume_data(encoded) == HTTPSPolicy::require);
    CHECK(disable_dht_from_resume_data(encoded));
    CHECK(app_disabled_dht_from_resume_data(encoded));
    CHECK(disable_lsd_from_resume_data(encoded));
    CHECK(app_disabled_lsd_from_resume_data(encoded));
}

TEST_CASE("legacy HTTPS resume booleans migrate to explicit policies")
{
    lt::entry legacy;
    legacy.dict().insert_or_assign(std::string(kAllowNonHTTPSTrackersResumeKey), lt::entry(1));
    legacy.dict().insert_or_assign(std::string(kRequireHTTPSWebSeedsResumeKey), lt::entry(1));
    std::vector<char> encoded;
    lt::bencode(std::back_inserter(encoded), legacy);

    CHECK(https_tracker_policy_from_resume_data(encoded) == HTTPSPolicy::original);
    CHECK(https_web_seed_policy_from_resume_data(encoded) == HTTPSPolicy::require);
}

TEST_CASE("resume encoding records explicit pre-metadata DHT consent only for a pending validation")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    TorrentIdentity identity;
    identity.canonical_id = "t:0123456789abcdef0123456789abcdef";
    identity.allow_pre_metadata_dht = true;

    std::vector<char> const pending = encoded_resume_data(params, &identity, true);
    std::vector<char> const validated = encoded_resume_data(params, &identity, false);

    CHECK(metadata_validation_pending_from_resume_data(pending));
    CHECK(allow_pre_metadata_dht_from_resume_data(pending));
    CHECK_FALSE(metadata_validation_pending_from_resume_data(validated));
    CHECK_FALSE(allow_pre_metadata_dht_from_resume_data(validated));
}

TEST_CASE("restored source policy trackers are persisted in resume params with metadata")
{
    lt::add_torrent_params params = make_source_torrent_params();
    params.trackers.clear();
    params.tracker_tiers.clear();

    TorrentIdentity identity;
    lt::announce_entry tracker;
    tracker.url = "http://tracker.example/announce";
    tracker.tier = 0;
    identity.source_trackers.push_back(tracker);

    restore_source_policy_sources(params, &identity);

    REQUIRE(params.trackers.size() == 1U);
    CHECK(params.trackers.front() == "http://tracker.example/announce");
    REQUIRE(params.tracker_tiers.size() == 1U);
    CHECK(params.tracker_tiers.front() == 0);
}

TEST_CASE("network client identity is generic and coarse")
{
    lt::settings_pack const settings = make_settings();

    CHECK(settings.get_str(lt::settings_pack::user_agent) == std::string(kNetworkClientIdentity));
    CHECK(settings.get_str(lt::settings_pack::handshake_client_version) == std::string(kNetworkClientIdentity));
    CHECK(settings.get_str(lt::settings_pack::peer_fingerprint) == std::string(kCoarsePeerFingerprint));
    CHECK(settings.get_str(lt::settings_pack::user_agent).find("torrent-app") == std::string::npos);
    CHECK(settings.get_str(lt::settings_pack::handshake_client_version).find("torrent-app") == std::string::npos);
    CHECK(settings.get_str(lt::settings_pack::peer_fingerprint).find("torrent-app") == std::string::npos);
    CHECK(settings.get_bool(lt::settings_pack::no_connect_privileged_ports));
    CHECK(settings.get_int(lt::settings_pack::alert_queue_size) == kLibtorrentAlertQueueSize);
    auto const alert_mask = static_cast<std::uint32_t>(settings.get_int(lt::settings_pack::alert_mask));
    CHECK((alert_mask & static_cast<std::uint32_t>(lt::alert_category::dht)) == 0U);
    CHECK((alert_mask & static_cast<std::uint32_t>(lt::alert_category::error)) != 0U);
}

TEST_CASE("DHT security settings are explicit")
{
    lt::settings_pack const settings = make_settings();

    CHECK_FALSE(settings.get_bool(lt::settings_pack::dht_read_only));
    CHECK_FALSE(settings.get_bool(lt::settings_pack::use_dht_as_fallback));
    CHECK(settings.get_bool(lt::settings_pack::dht_enforce_node_id));
    CHECK(settings.get_bool(lt::settings_pack::dht_prefer_verified_node_ids));
    CHECK(settings.get_bool(lt::settings_pack::dht_restrict_routing_ips));
    CHECK(settings.get_bool(lt::settings_pack::dht_restrict_search_ips));
    CHECK(settings.get_bool(lt::settings_pack::dht_ignore_dark_internet));
    CHECK(settings.get_bool(lt::settings_pack::apply_filter_to_dht));
}

TEST_CASE("DHT callback ownership and typed KRPC response import are exact")
{
    std::string body = "tx";
    int32_t const sender_offset = static_cast<int32_t>(body.size());
    body.append(20U, 's');
    int32_t const token_offset = static_cast<int32_t>(body.size());
    body += "token";
    int32_t const node_id_offset = static_cast<int32_t>(body.size());
    body.append(20U, 'n');
    int32_t const samples_offset = static_cast<int32_t>(body.size());
    body.append(20U, 'a');
    body.append(20U, 'b');

    DHTMessageParserProbe probe;
    probe.result.external_address_low = 0xcb00'7105U;
    probe.result.transaction_offset = 0;
    probe.result.transaction_size = 2;
    probe.result.sender_id_offset = sender_offset;
    probe.result.token_offset = token_offset;
    probe.result.token_size = 5;
    probe.result.sample_hashes_offset = samples_offset;
    probe.result.node_count = 1;
    probe.result.peer_count = 1;
    probe.result.sample_count = 2;
    probe.result.interval = 300;
    probe.result.total_infohash_count = 12;
    probe.result.present_fields = TTORRENT_DHT_HAS_TRANSACTION
        | TTORRENT_DHT_HAS_SENDER_ID
        | TTORRENT_DHT_HAS_TOKEN
        | TTORRENT_DHT_HAS_EXTERNAL_ADDRESS
        | TTORRENT_DHT_HAS_INTERVAL
        | TTORRENT_DHT_HAS_INFOHASH_COUNT
        | TTORRENT_DHT_HAS_PEERS
        | TTORRENT_DHT_HAS_SAMPLES;
    probe.result.message_kind = TTORRENT_DHT_MESSAGE_RESPONSE;
    probe.result.query_kind = TTORRENT_DHT_QUERY_NONE;
    probe.result.external_address_family = TTORRENT_PEER_ADDRESS_IPV4;
    probe.result.query_is_valid = 1U;
    probe.nodes = {TTorrentDHTNodeRecord{
        .address_high = 0x2001'0db8'0000'0000U,
        .address_low = 7U,
        .id_offset = node_id_offset,
        .port = 6'881U,
        .address_family = TTORRENT_PEER_ADDRESS_IPV6,
        .reserved0 = 0U,
        .reserved1 = 0U,
    }};
    probe.peers = {TTorrentDHTPeerRecord{
        .address_high = 0U,
        .address_low = 0xcb00'7109U,
        .port = 6'882U,
        .address_family = TTORRENT_PEER_ADDRESS_IPV4,
        .reserved0 = 0U,
        .reserved1 = 0U,
    }};

    {
        BridgeDHTMessageParser parser(probe.callbacks());
        CHECK(probe.retain_count == 1);
        CHECK(probe.release_count == 0);
        lt::dht::krpc_message imported;
        REQUIRE(parser.parse_message(body, true, imported));
        CHECK(imported.kind == lt::dht::krpc_message_kind::response);
        CHECK(imported.query == lt::dht::krpc_query_kind::none);
        CHECK(imported.query_valid);
        CHECK(imported.transaction_id == "tx");
        REQUIRE(imported.sender_id.has_value());
        CHECK(imported.sender_id->to_string() == std::string(20U, 's'));
        REQUIRE(imported.token.has_value());
        CHECK(*imported.token == "token");
        REQUIRE(imported.external_address.has_value());
        CHECK(imported.external_address->to_string() == "203.0.113.5");
        REQUIRE(imported.interval.has_value());
        CHECK(*imported.interval == 300);
        REQUIRE(imported.total_infohash_count.has_value());
        CHECK(*imported.total_infohash_count == 12);
        REQUIRE(imported.nodes.size() == 1U);
        CHECK(imported.nodes.at(0).id.to_string() == std::string(20U, 'n'));
        CHECK(imported.nodes.at(0).endpoint.address().to_string() == "2001:db8::7");
        CHECK(imported.nodes.at(0).endpoint.port() == 6'881U);
        CHECK(imported.peers_present);
        REQUIRE(imported.peers.size() == 1U);
        CHECK(imported.peers.at(0).address().to_string() == "203.0.113.9");
        CHECK(imported.peers.at(0).port() == 6'882U);
        CHECK(imported.samples_present);
        REQUIRE(imported.samples.size() == 2U);
        CHECK(imported.samples.at(0).to_string() == std::string(20U, 'a'));
        CHECK(imported.samples.at(1).to_string() == std::string(20U, 'b'));
        CHECK(probe.last_body == body);
        CHECK(probe.last_source_family == TTORRENT_PEER_ADDRESS_IPV6);
        CHECK(probe.last_node_capacity == TTORRENT_MAX_DHT_MESSAGE_NODES);
        CHECK(probe.last_peer_capacity == TTORRENT_MAX_DHT_MESSAGE_PEERS);
    }

    CHECK(probe.parse_count == 1);
    CHECK(probe.release_count == 1);
}

TEST_CASE("DHT malformed callback output fails atomically")
{
    DHTMessageParserProbe probe;
    probe.result.message_kind = TTORRENT_DHT_MESSAGE_RESPONSE;
    probe.result.query_kind = TTORRENT_DHT_QUERY_NONE;
    probe.result.query_is_valid = 1U;
    probe.result.node_count = 1;
    probe.nodes = {TTorrentDHTNodeRecord{
        .address_high = 0U,
        .address_low = 0xcb00'7109U,
        .id_offset = 99,
        .port = 6'881U,
        .address_family = TTORRENT_PEER_ADDRESS_IPV4,
        .reserved0 = 0U,
        .reserved1 = 0U,
    }};

    BridgeDHTMessageParser parser(probe.callbacks());
    lt::dht::krpc_message imported;
    imported.kind = lt::dht::krpc_message_kind::error;
    imported.transaction_id = "sentinel";
    imported.error_code = 777;
    imported.nodes.push_back(lt::dht::krpc_node{});

    CHECK_FALSE(parser.parse_message("de", false, imported));
    CHECK(imported.kind == lt::dht::krpc_message_kind::error);
    CHECK(imported.transaction_id == "sentinel");
    REQUIRE(imported.error_code.has_value());
    CHECK(*imported.error_code == 777);
    CHECK(imported.nodes.size() == 1U);

    int const calls_before_oversize = probe.parse_count;
    std::string const oversized(
        static_cast<std::size_t>(TTORRENT_MAX_DHT_MESSAGE_BYTES) + 1U,
        'x'
    );
    CHECK_FALSE(parser.parse_message(oversized, false, imported));
    CHECK(probe.parse_count == calls_before_oversize);
    CHECK(imported.transaction_id == "sentinel");

    std::string query_body = "ping";
    int32_t const sender_offset = static_cast<int32_t>(query_body.size());
    query_body.append(20U, 's');
    int32_t const target_offset = static_cast<int32_t>(query_body.size());
    query_body.append(20U, 't');
    probe.result = TTorrentDHTMessageResult{};
    probe.nodes.clear();
    probe.result.message_kind = TTORRENT_DHT_MESSAGE_QUERY;
    probe.result.query_kind = TTORRENT_DHT_QUERY_PING;
    probe.result.query_is_valid = 1U;
    probe.result.present_fields = TTORRENT_DHT_HAS_QUERY_NAME
        | TTORRENT_DHT_HAS_SENDER_ID
        | TTORRENT_DHT_HAS_TARGET;
    probe.result.query_name_offset = 0;
    probe.result.query_name_size = 4;
    probe.result.sender_id_offset = sender_offset;
    probe.result.target_offset = target_offset;

    CHECK_FALSE(parser.parse_message(query_body, false, imported));
    CHECK(imported.kind == lt::dht::krpc_message_kind::error);
    CHECK(imported.transaction_id == "sentinel");
    CHECK(imported.nodes.size() == 1U);
}

TEST_CASE("untrusted magnet endpoint hints are discarded")
{
    lt::add_torrent_params params = bridge_tests::add_params_with_hashes();
    params.dht_nodes.emplace_back("127.0.0.1", 6881);
    params.peers.emplace_back(lt::make_address_v4("127.0.0.1"), 6881);
    params.peers.emplace_back(lt::make_address_v4("8.8.8.8"), 80);
    params.peers.emplace_back(lt::make_address_v4("8.8.8.8"), 6881);
    params.peers.emplace_back(lt::make_address("2001:4860:4860::8888"), 6881);

    sanitize_magnet_endpoint_hints(params);

    CHECK(params.dht_nodes.empty());
    CHECK(params.peers.empty());
}
