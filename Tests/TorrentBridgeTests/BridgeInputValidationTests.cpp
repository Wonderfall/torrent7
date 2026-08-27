#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <libtorrent/create_torrent.hpp>

#include <array>
#include <bit>
#include <cstdint>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
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

[[nodiscard]] std::string v1_capsule_info(std::uint32_t &piece_hash_offset)
{
    std::string info = "d6:lengthi4e4:name8:file.bin12:piece lengthi16384e6:pieces20:";
    piece_hash_offset = static_cast<std::uint32_t>(info.size());
    info.append(20U, 'p');
    info += "7:privatei1ee";
    return info;
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

TEST_CASE("torrent loading never interprets an embedded magnet URI")
{
    std::string const magnet =
        "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567";
    std::vector<char> input{'d'};
    append_bencoded_string(input, "magnet-uri");
    append_bencoded_string(input, magnet);
    input.push_back('e');

    TorrentLoadResult const loaded = load_torrent_data(input);

    REQUIRE_FALSE(loaded);
    CHECK(loaded.error().code == 2);
    CHECK(loaded.error().message == "The torrent file is invalid.");
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
