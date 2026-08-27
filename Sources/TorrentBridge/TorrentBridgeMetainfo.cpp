#include "TorrentBridgeInternal.hpp"

#include <libtorrent/aux_/merkle_tree.hpp>
#include <libtorrent/aux_/parse_url.hpp>
#include <libtorrent/aux_/string_util.hpp>

#include <bit>

namespace torrent_bridge::internal {

namespace {

constexpr std::size_t kHeaderSize = TTORRENT_METAINFO_CAPSULE_HEADER_SIZE;
constexpr std::size_t kFileRecordSize = TTORRENT_METAINFO_CAPSULE_FILE_RECORD_SIZE;
constexpr std::size_t kRangeRecordSize = TTORRENT_METAINFO_CAPSULE_RANGE_RECORD_SIZE;
constexpr std::size_t kTrackerRecordSize = TTORRENT_METAINFO_CAPSULE_TRACKER_RECORD_SIZE;
constexpr std::size_t kPieceLayerRecordSize =
    TTORRENT_METAINFO_CAPSULE_PIECE_LAYER_RECORD_SIZE;
constexpr std::size_t kFileIndexRecordSize =
    TTORRENT_METAINFO_CAPSULE_FILE_INDEX_RECORD_SIZE;
constexpr std::size_t kMaximumCapsuleBytes = TTORRENT_METAINFO_CAPSULE_MAX_BYTES;
constexpr std::size_t kMaximumComponentCount = 200'000U;
constexpr std::size_t kMaximumComponentBytes = 255U;
constexpr std::size_t kMaximumPathBytes = std::size_t{8} * 1024U * 1024U;
constexpr std::size_t kMaximumSourceURLBytes = std::size_t{16} * 1024U;
constexpr std::size_t kMaximumAggregateSourceBytes = std::size_t{1024} * 1024U;
constexpr std::size_t kMaximumCommentBytes = std::size_t{16} * 1024U;
constexpr std::size_t kMaximumCreatorBytes = std::size_t{4} * 1024U;
constexpr std::uint8_t kKnownHeaderFlags = TTORRENT_METAINFO_PRIVATE;
constexpr std::uint32_t kKnownFileFlags = 0x0000'0007U;
constexpr std::uint16_t kKnownEnvelopeFields = 0x00ffU;

struct Alignment {
    std::size_t value;
};

struct TableDescriptor {
    std::uint32_t offset;
    std::uint32_t count;
    std::size_t record_size;
    Alignment alignment;
};

struct CapsuleRange {
    std::uint32_t offset;
    std::uint32_t size;
};

struct CapsuleHeader {
    std::uint32_t total_size;
    std::uint8_t input_kind;
    std::uint8_t metainfo_kind;
    std::uint8_t content_kind;
    std::uint8_t flags;
    std::uint16_t present_fields;
    std::uint32_t piece_length;
    CapsuleRange info;
    CapsuleRange name;
    CapsuleRange v1_hash;
    CapsuleRange v2_hash;
    CapsuleRange v1_piece_hashes;
    std::uint32_t file_table_offset;
    std::uint32_t file_count;
    std::uint32_t component_table_offset;
    std::uint32_t component_count;
    std::uint32_t tracker_table_offset;
    std::uint32_t tracker_count;
    std::uint32_t web_seed_table_offset;
    std::uint32_t web_seed_count;
    std::uint32_t piece_layer_table_offset;
    std::uint32_t piece_layer_count;
    std::uint32_t piece_layer_file_index_table_offset;
    std::uint32_t piece_layer_file_index_count;
    CapsuleRange comment;
    CapsuleRange created_by;
    std::int64_t creation_date;
    std::uint32_t payload_offset;
};

struct DecodedPieceLayer {
    std::span<std::uint8_t const> root;
    std::span<std::uint8_t const> hashes;
    std::uint32_t first_file_index;
    std::uint32_t file_index_count;
};

[[nodiscard]] BridgeError invalid_capsule()
{
    return BridgeError{.code = 2, .message = "The validated torrent metainfo capsule is invalid."};
}

class CapsuleReader final {
public:
    explicit CapsuleReader(std::span<std::uint8_t const> bytes) : bytes_(bytes) {}

    [[nodiscard]] std::uint8_t u8(std::size_t const offset) const
    {
        return *std::next(bytes_.begin(), static_cast<std::ptrdiff_t>(offset));
    }

    [[nodiscard]] std::uint16_t u16(std::size_t const offset) const
    {
        std::uint32_t const value = static_cast<std::uint32_t>(u8(offset))
            + (static_cast<std::uint32_t>(u8(offset + 1U)) << 8U);
        return static_cast<std::uint16_t>(value);
    }

    [[nodiscard]] std::uint32_t u32(std::size_t const offset) const
    {
        return static_cast<std::uint32_t>(u8(offset))
            + (static_cast<std::uint32_t>(u8(offset + 1U)) << 8U)
            + (static_cast<std::uint32_t>(u8(offset + 2U)) << 16U)
            + (static_cast<std::uint32_t>(u8(offset + 3U)) << 24U);
    }

    [[nodiscard]] std::int32_t i32(std::size_t const offset) const
    {
        return std::bit_cast<std::int32_t>(u32(offset));
    }

    [[nodiscard]] std::int64_t i64(std::size_t const offset) const
    {
        std::uint64_t value = 0U;
        for (std::size_t byte = 0U; byte < sizeof(value); ++byte) {
            value += static_cast<std::uint64_t>(u8(offset + byte)) << (byte * 8U);
        }
        return std::bit_cast<std::int64_t>(value);
    }

    [[nodiscard]] CapsuleRange range(std::size_t const offset) const
    {
        return CapsuleRange{.offset = u32(offset), .size = u32(offset + 4U)};
    }

    [[nodiscard]] bool contains(std::size_t const offset, std::size_t const size) const
    {
        return offset <= bytes_.size() && size <= bytes_.size() - offset;
    }

    [[nodiscard]] bool is_payload_range(
        CapsuleRange const range,
        std::size_t const payload_offset,
        bool const allow_empty = false
    ) const
    {
        if (range.size == 0U) {
            return allow_empty && range.offset == 0U;
        }
        return range.offset >= payload_offset && contains(range.offset, range.size);
    }

    [[nodiscard]] std::span<std::uint8_t const> bytes(CapsuleRange const range) const
    {
        return bytes_.subspan(range.offset, range.size);
    }

    [[nodiscard]] std::string string(CapsuleRange const range) const
    {
        std::span<std::uint8_t const> const source = bytes(range);
        std::string result;
        result.reserve(source.size());
        std::ranges::transform(
            source,
            std::back_inserter(result),
            [](std::uint8_t const byte) { return static_cast<char>(byte); }
        );
        return result;
    }

    [[nodiscard]] std::span<std::uint8_t const> all_bytes() const noexcept
    {
        return bytes_;
    }

private:
    std::span<std::uint8_t const> bytes_;
};

[[nodiscard]] bool checked_align(
    std::size_t &value,
    Alignment const alignment,
    std::size_t const limit
)
{
    if (value > limit) {
        return false;
    }
    std::size_t const remainder = value % alignment.value;
    std::size_t const increment = remainder == 0U ? 0U : alignment.value - remainder;
    if (increment > limit - value) {
        return false;
    }
    value += increment;
    return true;
}

[[nodiscard]] bool consume_table(
    std::size_t &cursor,
    TableDescriptor const table,
    std::size_t const limit
)
{
    if (cursor > limit
        || !checked_align(cursor, table.alignment, limit)
        || table.offset != cursor) {
        return false;
    }
    std::size_t const checked_count = table.count;
    if (checked_count > (limit - cursor) / table.record_size) {
        return false;
    }
    cursor += checked_count * table.record_size;
    return true;
}

template <typename Value, typename Flag>
[[nodiscard]] bool flag_is_set(Value const flags, Flag const expected_flag)
{
    return (static_cast<std::uint64_t>(flags)
        & static_cast<std::uint64_t>(expected_flag)) != 0U;
}

[[nodiscard]] char const *character_bytes(std::span<std::uint8_t const> const bytes)
{
    // Character types may alias any object representation. Keep this audited
    // view conversion at one boundary; no pointer survives the import call.
    // NOLINTNEXTLINE(cppcoreguidelines-pro-type-reinterpret-cast)
    return reinterpret_cast<char const *>(bytes.data());
}

[[nodiscard]] bool reserved_bytes_are_zero(
    CapsuleReader const &reader,
    std::size_t const offset,
    std::size_t const count
)
{
    std::span<std::uint8_t const> const bytes = reader.all_bytes().subspan(offset, count);
    return std::ranges::all_of(bytes, [](std::uint8_t const byte) { return byte == 0U; });
}

[[nodiscard]] bool valid_utf8(
    std::string_view const value,
    bool const allow_human_readable_controls
)
{
    std::size_t offset = 0U;
    while (offset < value.size()) {
        unsigned char const byte = byte_at(value, offset);
        if (byte < 0x20U || byte == 0x7fU) {
            if (!allow_human_readable_controls || (byte != '\n' && byte != '\t')) {
                return false;
            }
        }
        UTF8Sequence const sequence = utf8_sequence(value, offset);
        if (!sequence.valid) {
            return false;
        }
        offset += sequence.length;
    }
    return true;
}

[[nodiscard]] bool valid_component(std::string_view const value)
{
    return !value.empty()
        && value.size() <= kMaximumComponentBytes
        && value != "."
        && value != ".."
        && value.find('/') == std::string_view::npos
        && value.find('\\') == std::string_view::npos
        && valid_utf8(value, false);
}

[[nodiscard]] bool range_inside(CapsuleRange const inner, CapsuleRange const outer)
{
    if (inner.size == 0U || inner.offset < outer.offset) {
        return false;
    }
    std::uint64_t const inner_end = static_cast<std::uint64_t>(inner.offset) + inner.size;
    std::uint64_t const outer_end = static_cast<std::uint64_t>(outer.offset) + outer.size;
    return inner_end <= outer_end;
}

[[nodiscard]] bool parse_header(CapsuleReader const &reader, CapsuleHeader &header)
{
    if (reader.all_bytes().size() < kHeaderSize
        || reader.all_bytes().size() > kMaximumCapsuleBytes
        || reader.u32(0U) != TTORRENT_METAINFO_CAPSULE_MAGIC
        || reader.u16(4U) != TTORRENT_METAINFO_CAPSULE_SCHEMA_VERSION
        || reader.u16(6U) != kHeaderSize
        || reader.u16(18U) != 0U
        || reader.u32(140U) != 0U
        || reader.u16(144U) != kFileRecordSize
        || reader.u16(146U) != kRangeRecordSize
        || reader.u16(148U) != kTrackerRecordSize
        || reader.u16(150U) != kPieceLayerRecordSize
        || reader.u16(152U) != kFileIndexRecordSize
        || !reserved_bytes_are_zero(reader, 154U, 6U)) {
        return false;
    }

    header = CapsuleHeader{
        .total_size = reader.u32(8U),
        .input_kind = reader.u8(12U),
        .metainfo_kind = reader.u8(13U),
        .content_kind = reader.u8(14U),
        .flags = reader.u8(15U),
        .present_fields = reader.u16(16U),
        .piece_length = reader.u32(20U),
        .info = reader.range(24U),
        .name = reader.range(32U),
        .v1_hash = reader.range(40U),
        .v2_hash = reader.range(48U),
        .v1_piece_hashes = reader.range(56U),
        .file_table_offset = reader.u32(64U),
        .file_count = reader.u32(68U),
        .component_table_offset = reader.u32(72U),
        .component_count = reader.u32(76U),
        .tracker_table_offset = reader.u32(80U),
        .tracker_count = reader.u32(84U),
        .web_seed_table_offset = reader.u32(88U),
        .web_seed_count = reader.u32(92U),
        .piece_layer_table_offset = reader.u32(96U),
        .piece_layer_count = reader.u32(100U),
        .piece_layer_file_index_table_offset = reader.u32(104U),
        .piece_layer_file_index_count = reader.u32(108U),
        .comment = reader.range(112U),
        .created_by = reader.range(120U),
        .creation_date = reader.i64(128U),
        .payload_offset = reader.u32(136U),
    };

    if (header.total_size != reader.all_bytes().size()
        || header.file_count == 0U
        || header.file_count > static_cast<std::uint32_t>(TTORRENT_MAX_FILE_COUNT)
        || header.component_count == 0U
        || header.component_count > kMaximumComponentCount
        || header.tracker_count > static_cast<std::uint32_t>(TTORRENT_MAX_TRACKER_COUNT)
        || header.web_seed_count > static_cast<std::uint32_t>(TTORRENT_MAX_WEB_SEED_COUNT)
        || header.piece_layer_count > header.file_count
        || header.piece_layer_file_index_count > header.file_count
        || header.piece_length == 0U
        || header.piece_length > static_cast<std::uint32_t>(std::numeric_limits<int>::max())
        || header.flags > kKnownHeaderFlags
        || header.present_fields > kKnownEnvelopeFields) {
        return false;
    }

    std::size_t cursor = kHeaderSize;
    if (!consume_table(cursor, TableDescriptor{
            .offset = header.file_table_offset,
            .count = header.file_count,
            .record_size = kFileRecordSize,
            .alignment = Alignment{8U},
        }, header.total_size)
        || !consume_table(cursor, TableDescriptor{
            .offset = header.component_table_offset,
            .count = header.component_count,
            .record_size = kRangeRecordSize,
            .alignment = Alignment{4U},
        }, header.total_size)
        || !consume_table(cursor, TableDescriptor{
            .offset = header.tracker_table_offset,
            .count = header.tracker_count,
            .record_size = kTrackerRecordSize,
            .alignment = Alignment{4U},
        }, header.total_size)
        || !consume_table(cursor, TableDescriptor{
            .offset = header.web_seed_table_offset,
            .count = header.web_seed_count,
            .record_size = kRangeRecordSize,
            .alignment = Alignment{4U},
        }, header.total_size)
        || !consume_table(cursor, TableDescriptor{
            .offset = header.piece_layer_table_offset,
            .count = header.piece_layer_count,
            .record_size = kPieceLayerRecordSize,
            .alignment = Alignment{4U},
        }, header.total_size)
        || !consume_table(cursor, TableDescriptor{
            .offset = header.piece_layer_file_index_table_offset,
            .count = header.piece_layer_file_index_count,
            .record_size = kFileIndexRecordSize,
            .alignment = Alignment{4U},
        }, header.total_size)
        || !checked_align(cursor, Alignment{8U}, header.total_size)
        || cursor != header.payload_offset) {
        return false;
    }

    return header.input_kind == TTORRENT_METAINFO_INPUT_TORRENT_FILE
        || header.input_kind == TTORRENT_METAINFO_INPUT_INFO_DICTIONARY;
}

[[nodiscard]] bool validate_envelope_shape(
    CapsuleReader const &reader,
    CapsuleHeader const &header
)
{
    bool const has_trackers = header.tracker_count > 0U;
    bool const tracker_field = flag_is_set(
        header.present_fields,
        static_cast<std::uint16_t>(TTORRENT_METAINFO_FIELD_ANNOUNCE
            + TTORRENT_METAINFO_FIELD_ANNOUNCE_LIST)
    );
    bool const has_web_seeds = header.web_seed_count > 0U;
    bool const web_seed_field = flag_is_set(
        header.present_fields,
        TTORRENT_METAINFO_FIELD_URL_LIST
    );
    bool const has_piece_layers = header.piece_layer_count > 0U
        || header.piece_layer_file_index_count > 0U;
    bool const piece_layer_field =
        flag_is_set(header.present_fields, TTORRENT_METAINFO_FIELD_PIECE_LAYERS);
    bool const has_v2 = header.metainfo_kind == TTORRENT_METAINFO_KIND_V2
        || header.metainfo_kind == TTORRENT_METAINFO_KIND_HYBRID;
    bool const comment_field = flag_is_set(
        header.present_fields,
        TTORRENT_METAINFO_FIELD_COMMENT
    );
    bool const creator_field = flag_is_set(
        header.present_fields,
        TTORRENT_METAINFO_FIELD_CREATED_BY
    );
    bool const date_field = flag_is_set(
        header.present_fields,
        TTORRENT_METAINFO_FIELD_CREATION_DATE
    );

    if ((has_trackers && !tracker_field)
        || (has_web_seeds && !web_seed_field)
        || (has_piece_layers && !piece_layer_field)
        || (!has_v2 && piece_layer_field)
        || (!comment_field && (header.comment.offset != 0U || header.comment.size != 0U))
        || (!creator_field && (header.created_by.offset != 0U || header.created_by.size != 0U))
        || (!date_field && header.creation_date != -1)
        || header.creation_date < -1) {
        return false;
    }

    if (header.input_kind == TTORRENT_METAINFO_INPUT_INFO_DICTIONARY) {
        return header.present_fields == 0U
            && header.tracker_count == 0U
            && header.web_seed_count == 0U
            && header.piece_layer_count == 0U
            && header.piece_layer_file_index_count == 0U
            && header.comment.offset == 0U
            && header.comment.size == 0U
            && header.created_by.offset == 0U
            && header.created_by.size == 0U
            && header.creation_date == -1;
    }

    return reader.is_payload_range(header.comment, header.payload_offset, true)
        && reader.is_payload_range(header.created_by, header.payload_offset, true);
}

[[nodiscard]] std::expected<lt::info_hash_t, BridgeError> decode_hashes(
    CapsuleReader const &reader,
    CapsuleHeader const &header
)
{
    bool const has_v1 = header.metainfo_kind == TTORRENT_METAINFO_KIND_V1
        || header.metainfo_kind == TTORRENT_METAINFO_KIND_HYBRID;
    bool const has_v2 = header.metainfo_kind == TTORRENT_METAINFO_KIND_V2
        || header.metainfo_kind == TTORRENT_METAINFO_KIND_HYBRID;
    if ((!has_v1 && !has_v2)
        || (has_v1 && (!reader.is_payload_range(header.v1_hash, header.payload_offset)
            || header.v1_hash.size != lt::sha1_hash::size()))
        || (!has_v1 && (header.v1_hash.offset != 0U || header.v1_hash.size != 0U))
        || (has_v2 && (!reader.is_payload_range(header.v2_hash, header.payload_offset)
            || header.v2_hash.size != lt::sha256_hash::size()))
        || (!has_v2 && (header.v2_hash.offset != 0U || header.v2_hash.size != 0U))) {
        return std::unexpected(invalid_capsule());
    }

    lt::info_hash_t hashes;
    if (has_v1) {
        std::ranges::copy(reader.bytes(header.v1_hash), hashes.v1.begin());
        if (!hashes.has_v1()) {
            return std::unexpected(invalid_capsule());
        }
    }
    if (has_v2) {
        std::ranges::copy(reader.bytes(header.v2_hash), hashes.v2.begin());
        if (!hashes.has_v2()) {
            return std::unexpected(invalid_capsule());
        }
    }
    return hashes;
}

[[nodiscard]] std::expected<std::vector<lt::aux::preparsed_metainfo_file>, BridgeError>
decode_files(
    CapsuleReader const &reader,
    CapsuleHeader const &header,
    std::string const &name
)
{
    bool const has_v2 = header.metainfo_kind == TTORRENT_METAINFO_KIND_V2
        || header.metainfo_kind == TTORRENT_METAINFO_KIND_HYBRID;
    bool const single_file = header.content_kind == TTORRENT_CONTENT_KIND_SINGLE_FILE;
    if (!single_file && header.content_kind != TTORRENT_CONTENT_KIND_DIRECTORY) {
        return std::unexpected(invalid_capsule());
    }

    std::vector<lt::aux::preparsed_metainfo_file> files;
    files.reserve(header.file_count);
    std::set<std::string> logical_paths;
    std::size_t next_component = 0U;
    std::size_t total_path_bytes = 0U;
    std::size_t payload_file_count = 0U;
    for (std::uint32_t file_index = 0U; file_index < header.file_count; ++file_index) {
        std::size_t const record = header.file_table_offset + (file_index * kFileRecordSize);
        std::int32_t const encoded_index = reader.i32(record);
        std::uint32_t const component_start = reader.u32(record + 4U);
        std::uint32_t const component_count = reader.u32(record + 8U);
        std::uint32_t const flags = reader.u32(record + 12U);
        std::int64_t const size = reader.i64(record + 16U);
        CapsuleRange const root = reader.range(record + 24U);
        if (!std::cmp_equal(encoded_index, file_index)
            || component_start != next_component
            || component_count == 0U
            || component_count > 32U
            || component_start > header.component_count
            || component_count > header.component_count - component_start
            || flags > kKnownFileFlags
            || size < 0) {
            return std::unexpected(invalid_capsule());
        }

        std::vector<std::string> components;
        components.reserve(component_count);
        std::string relative_path;
        for (std::uint32_t offset = 0U; offset < component_count; ++offset) {
            std::size_t const component_record = header.component_table_offset
                + ((component_start + offset) * kRangeRecordSize);
            CapsuleRange const range = reader.range(component_record);
            if (!reader.is_payload_range(range, header.payload_offset)
                || range.size > kMaximumComponentBytes) {
                return std::unexpected(invalid_capsule());
            }
            std::string component = reader.string(range);
            if (!valid_component(component)) {
                return std::unexpected(invalid_capsule());
            }
            if (!relative_path.empty()) {
                relative_path.push_back('/');
            }
            relative_path += component;
            if (component.size() > kMaximumPathBytes - total_path_bytes) {
                return std::unexpected(invalid_capsule());
            }
            total_path_bytes += component.size();
            components.push_back(std::move(component));
        }
        next_component = static_cast<std::size_t>(component_start) + component_count;

        bool const padding = flag_is_set(flags, TTORRENT_METAINFO_FILE_PADDING);
        if (padding) {
            std::string expected_leaf = std::to_string(size);
            expected_leaf.push_back('-');
            expected_leaf += std::to_string(file_index);
            if (components.size() != 2U
                || components.at(0) != ".pad"
                || components.at(1) != expected_leaf
                || root.offset != 0U
                || root.size != 0U) {
                return std::unexpected(invalid_capsule());
            }
        } else {
            ++payload_file_count;
            if ((has_v2 && size > 0
                    && (!reader.is_payload_range(root, header.payload_offset)
                        || root.size != lt::sha256_hash::size()
                        || !range_inside(root, header.info)))
                || ((!has_v2 || size == 0) && (root.offset != 0U || root.size != 0U))) {
                return std::unexpected(invalid_capsule());
            }
        }

        if (!logical_paths.insert(relative_path).second) {
            return std::unexpected(invalid_capsule());
        }
        std::string storage_path;
        if (single_file) {
            storage_path = relative_path;
        } else {
            storage_path.reserve(name.size() + 1U + relative_path.size());
            storage_path = name;
            storage_path.push_back('/');
            storage_path += relative_path;
        }
        if (storage_path.size() >= sizeof(TTorrentFileSnapshot::path)) {
            return std::unexpected(invalid_capsule());
        }

        lt::file_flags_t native_flags;
        if (padding) {
            native_flags |= lt::file_storage::flag_pad_file;
        }
        if (flag_is_set(flags, TTORRENT_METAINFO_FILE_EXECUTABLE)) {
            native_flags |= lt::file_storage::flag_executable;
        }
        if (flag_is_set(flags, TTORRENT_METAINFO_FILE_HIDDEN)) {
            native_flags |= lt::file_storage::flag_hidden;
        }
        std::int32_t root_offset = -1;
        if (root.size != 0U) {
            root_offset = static_cast<std::int32_t>(root.offset - header.info.offset);
        }
        files.push_back(lt::aux::preparsed_metainfo_file{
            .path = std::move(storage_path),
            .size = size,
            .flags = native_flags,
            .pieces_root_offset = root_offset,
        });
    }
    if (next_component != header.component_count || payload_file_count == 0U) {
        return std::unexpected(invalid_capsule());
    }
    if (single_file && (payload_file_count != 1U
        || files.front().path != name
        || static_cast<bool>(files.front().flags & lt::file_storage::flag_pad_file))) {
        return std::unexpected(invalid_capsule());
    }

    for (auto current = logical_paths.begin(); current != logical_paths.end(); ++current) {
        auto next = std::next(current);
        if (next != logical_paths.end()
            && next->size() > current->size()
            && next->starts_with(*current)
            && next->at(current->size()) == '/') {
            return std::unexpected(invalid_capsule());
        }
    }
    return files;
}

[[nodiscard]] std::expected<std::vector<DecodedPieceLayer>, BridgeError> decode_piece_layers(
    CapsuleReader const &reader,
    CapsuleHeader const &header
)
{
    std::vector<DecodedPieceLayer> layers;
    layers.reserve(header.piece_layer_count);
    std::uint32_t next_file_index = 0U;
    for (std::uint32_t index = 0U; index < header.piece_layer_count; ++index) {
        std::size_t const record = header.piece_layer_table_offset
            + (index * kPieceLayerRecordSize);
        CapsuleRange const root = reader.range(record);
        CapsuleRange const hashes = reader.range(record + 8U);
        std::uint32_t const first_file_index = reader.u32(record + 16U);
        std::uint32_t const file_index_count = reader.u32(record + 20U);
        if (!reader.is_payload_range(root, header.payload_offset)
            || root.size != lt::sha256_hash::size()
            || !reader.is_payload_range(hashes, header.payload_offset)
            || hashes.size % lt::sha256_hash::size() != 0U
            || first_file_index != next_file_index
            || file_index_count == 0U
            || first_file_index > header.piece_layer_file_index_count
            || file_index_count > header.piece_layer_file_index_count - first_file_index) {
            return std::unexpected(invalid_capsule());
        }
        next_file_index = first_file_index + file_index_count;
        layers.push_back(DecodedPieceLayer{
            .root = reader.bytes(root),
            .hashes = reader.bytes(hashes),
            .first_file_index = first_file_index,
            .file_index_count = file_index_count,
        });
    }
    if (next_file_index != header.piece_layer_file_index_count) {
        return std::unexpected(invalid_capsule());
    }
    return layers;
}

[[nodiscard]] BridgeResult import_piece_layers(
    CapsuleReader const &reader,
    CapsuleHeader const &header,
    std::span<DecodedPieceLayer const> const layers,
    lt::add_torrent_params &params
)
{
    bool const field_present =
        flag_is_set(header.present_fields, TTORRENT_METAINFO_FIELD_PIECE_LAYERS);
    if (!field_present) {
        return {};
    }
    lt::file_storage const &files = params.ti->layout();
    params.merkle_trees.resize(files.num_files());
    params.merkle_tree_mask.resize(files.num_files());
    params.verified_leaf_hashes.resize(files.num_files());
    std::vector<bool> imported(static_cast<std::size_t>(files.num_files()), false);

    for (DecodedPieceLayer const &layer : layers) {
        lt::sha256_hash root;
        std::ranges::copy(layer.root, root.begin());
        for (std::uint32_t offset = 0U; offset < layer.file_index_count; ++offset) {
            std::size_t const index_offset = header.piece_layer_file_index_table_offset
                + ((layer.first_file_index + offset) * kFileIndexRecordSize);
            std::int32_t const raw_file = reader.i32(index_offset);
            if (raw_file < 0 || raw_file >= files.num_files()) {
                return std::unexpected(invalid_capsule());
            }
            lt::file_index_t const file(raw_file);
            auto const checked_file = static_cast<std::size_t>(raw_file);
            std::int64_t const expected_size =
                static_cast<std::int64_t>(files.file_num_pieces(file))
                    * lt::sha256_hash::size();
            if (imported.at(checked_file)
                || files.pad_file_at(file)
                || files.file_size(file) <= files.piece_length()
                || files.root(file) != root
                || !std::cmp_equal(expected_size, layer.hashes.size())) {
                return std::unexpected(invalid_capsule());
            }

            std::string_view const hashes(
                character_bytes(layer.hashes),
                layer.hashes.size()
            );
            lt::aux::merkle_tree tree(
                files.file_num_blocks(file),
                files.blocks_per_piece(),
                files.root_ptr(file)
            );
            if (!tree.load_piece_layer(hashes)) {
                return std::unexpected(invalid_capsule());
            }
            auto [sparse_tree, mask] = tree.build_sparse_vector();
            *std::next(params.merkle_trees.begin(), raw_file) = std::move(sparse_tree);
            *std::next(params.merkle_tree_mask.begin(), raw_file) = std::move(mask);
            *std::next(params.verified_leaf_hashes.begin(), raw_file) = tree.verified_leafs();
            imported.at(checked_file) = true;
        }
    }

    for (lt::file_index_t const file : files.file_range()) {
        bool const required = !files.pad_file_at(file)
            && files.file_size(file) > files.piece_length();
        if (required != imported.at(static_cast<std::size_t>(static_cast<int>(file)))) {
            return std::unexpected(invalid_capsule());
        }
    }
    return {};
}

[[nodiscard]] TorrentLoadResult import_capsule_impl(
    std::span<std::uint8_t const> const capsule,
    std::uint8_t const expected_input_kind,
    std::shared_ptr<lt::torrent_info> *const imported_info_out
)
{
    CapsuleReader const reader(capsule);
    CapsuleHeader header{};
    if (!parse_header(reader, header)
        || header.input_kind != expected_input_kind
        || !validate_envelope_shape(reader, header)
        || !reader.is_payload_range(header.info, header.payload_offset)
        || header.info.size > kMaxTorrentFileBytes
        || !reader.is_payload_range(header.name, header.payload_offset)
        || header.name.size > kMaximumComponentBytes) {
        return std::unexpected(invalid_capsule());
    }

    std::string const name = reader.string(header.name);
    if (!valid_component(name)) {
        return std::unexpected(invalid_capsule());
    }
    auto hashes = decode_hashes(reader, header);
    if (!hashes) {
        return std::unexpected(hashes.error());
    }
    auto files = decode_files(reader, header, name);
    if (!files) {
        return std::unexpected(files.error());
    }

    bool const has_v1 = hashes->has_v1();
    if ((has_v1 && (!reader.is_payload_range(header.v1_piece_hashes, header.payload_offset)
            || header.v1_piece_hashes.size % lt::sha1_hash::size() != 0U
            || !range_inside(header.v1_piece_hashes, header.info)))
        || (!has_v1 && (header.v1_piece_hashes.offset != 0U
            || header.v1_piece_hashes.size != 0U))) {
        return std::unexpected(invalid_capsule());
    }

    auto piece_layers = decode_piece_layers(reader, header);
    if (!piece_layers) {
        return std::unexpected(piece_layers.error());
    }

    lt::aux::preparsed_metainfo const input{
        .info_section = lt::span<char const>(
            character_bytes(reader.bytes(header.info)),
            static_cast<std::ptrdiff_t>(header.info.size)
        ),
        .files = lt::span<lt::aux::preparsed_metainfo_file const>(*files),
        .expected_info_hashes = *hashes,
        .name = name,
        .piece_length = static_cast<int>(header.piece_length),
        .piece_hashes_offset = has_v1
            ? static_cast<std::int32_t>(header.v1_piece_hashes.offset - header.info.offset)
            : -1,
        .piece_hashes_size = static_cast<std::int32_t>(header.v1_piece_hashes.size),
        .multifile = header.content_kind == TTORRENT_CONTENT_KIND_DIRECTORY,
        .private_torrent = flag_is_set(header.flags, TTORRENT_METAINFO_PRIVATE),
    };
    lt::error_code error;
    std::shared_ptr<lt::torrent_info> info = lt::aux::import_preparsed_metainfo(input, error);
    if (error || !info) {
        return std::unexpected(invalid_capsule());
    }

    lt::add_torrent_params params;
    params.ti = info;
    params.info_hashes = params.ti->info_hashes();
    std::size_t aggregate_source_bytes = 0U;
    for (std::uint32_t index = 0U; index < header.tracker_count; ++index) {
        std::size_t const record = header.tracker_table_offset + (index * kTrackerRecordSize);
        CapsuleRange const range = reader.range(record);
        if (!reserved_bytes_are_zero(reader, record + 9U, 7U)
            || !reader.is_payload_range(range, header.payload_offset)
            || range.size > kMaximumSourceURLBytes) {
            return std::unexpected(invalid_capsule());
        }
        std::string tracker = reader.string(range);
        bool const valid_scheme = lt::aux::string_begins_no_case("http://", tracker)
            || lt::aux::string_begins_no_case("https://", tracker)
            || lt::aux::string_begins_no_case("udp://", tracker);
        if (!valid_scheme
            || !valid_utf8(tracker, false)
            || !lt::aux::is_valid_tracker_url(tracker)
            || range.size > kMaximumAggregateSourceBytes - aggregate_source_bytes) {
            return std::unexpected(invalid_capsule());
        }
        aggregate_source_bytes += range.size;
        params.trackers.push_back(std::move(tracker));
        params.tracker_tiers.push_back(reader.u8(record + 8U));
    }
    for (std::uint32_t index = 0U; index < header.web_seed_count; ++index) {
        std::size_t const record = header.web_seed_table_offset + (index * kRangeRecordSize);
        CapsuleRange const range = reader.range(record);
        if (!reader.is_payload_range(range, header.payload_offset)
            || range.size > kMaximumSourceURLBytes) {
            return std::unexpected(invalid_capsule());
        }
        std::string web_seed = reader.string(range);
        bool const valid_scheme = lt::aux::string_begins_no_case("http://", web_seed)
            || lt::aux::string_begins_no_case("https://", web_seed);
        if (!valid_scheme
            || !valid_utf8(web_seed, false)
            || range.size > kMaximumAggregateSourceBytes - aggregate_source_bytes) {
            return std::unexpected(invalid_capsule());
        }
        aggregate_source_bytes += range.size;
        if (header.content_kind == TTORRENT_CONTENT_KIND_DIRECTORY) {
            lt::aux::ensure_trailing_slash(web_seed);
        }
        params.url_seeds.push_back(std::move(web_seed));
    }

    if (header.comment.size > kMaximumCommentBytes
        || header.created_by.size > kMaximumCreatorBytes) {
        return std::unexpected(invalid_capsule());
    }
    if (header.comment.size != 0U) {
        params.comment = reader.string(header.comment);
        if (!valid_utf8(params.comment, true)) {
            return std::unexpected(invalid_capsule());
        }
    }
    if (header.created_by.size != 0U) {
        params.created_by = reader.string(header.created_by);
        if (!valid_utf8(params.created_by, true)) {
            return std::unexpected(invalid_capsule());
        }
    }
    if (header.creation_date >= 0) {
        params.creation_date = static_cast<std::time_t>(header.creation_date);
    }

    BridgeResult const imported_layers = import_piece_layers(
        reader,
        header,
        *piece_layers,
        params
    );
    if (!imported_layers) {
        return std::unexpected(imported_layers.error());
    }
    BridgeResult const valid_info = validate_torrent_info(params);
    if (!valid_info) {
        return std::unexpected(valid_info.error());
    }
    if (imported_info_out != nullptr) {
        *imported_info_out = std::move(info);
    }
    return params;
}

} // namespace

TorrentLoadResult import_preparsed_metainfo_capsule(
    std::span<std::uint8_t const> const capsule
)
{
    try {
        return import_capsule_impl(
            capsule,
            TTORRENT_METAINFO_INPUT_TORRENT_FILE,
            nullptr
        );
    } catch (...) {
        return std::unexpected(invalid_capsule());
    }
}

TorrentInfoLoadResult import_preparsed_info_capsule(
    std::span<std::uint8_t const> const capsule
)
{
    try {
        std::shared_ptr<lt::torrent_info> info;
        TorrentLoadResult const imported = import_capsule_impl(
            capsule,
            TTORRENT_METAINFO_INPUT_INFO_DICTIONARY,
            &info
        );
        if (!imported || !info) {
            return std::unexpected(imported
                ? invalid_capsule()
                : imported.error());
        }
        return info;
    } catch (...) {
        return std::unexpected(invalid_capsule());
    }
}

} // namespace torrent_bridge::internal
