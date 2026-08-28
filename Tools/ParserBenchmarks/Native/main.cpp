#include <libtorrent/aux_/socket_io.hpp>
#include <libtorrent/aux_/tracker_manager.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/torrent_info.hpp>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace lt = libtorrent;

struct measurement
{
    std::string name;
    std::size_t bytes = 0;
    int iterations = 0;
    int samples = 0;
    double median_ns = 0;
    double p95_ns = 0;
    double p99_ns = 0;
    double minimum_ns = 0;
    double maximum_ns = 0;
    std::uint64_t checksum = 0;
};

double percentile(std::vector<double> const& sorted_values, int const value)
{
    auto const index = (std::size_t(value) * sorted_values.size() + 99U) / 100U - 1U;
    return sorted_values[index];
}

template <typename Operation>
[[gnu::noinline]] std::uint64_t run_batch(int const iterations, Operation& operation)
{
    std::uint64_t checksum = 0;
    for (int i = 0; i < iterations; ++i) checksum += operation();
    return checksum;
}

template <typename Operation>
measurement measure(std::string name, std::size_t const bytes
    , int const iterations, Operation operation)
{
    constexpr int warmups = 3;
    constexpr int samples = 20;
    for (int i = 0; i < warmups; ++i) (void)run_batch(iterations, operation);

    std::vector<double> values;
    values.reserve(samples);
    std::uint64_t checksum = 0;
    for (int i = 0; i < samples; ++i)
    {
        auto const started = std::chrono::steady_clock::now();
        checksum += run_batch(iterations, operation);
        auto const elapsed = std::chrono::steady_clock::now() - started;
        auto const elapsed_ns = std::chrono::duration<double, std::nano>(elapsed).count();
        values.push_back(elapsed_ns / double(iterations));
    }
    std::sort(values.begin(), values.end());
    return {std::move(name), bytes, iterations, samples, values[values.size() / 2]
        , percentile(values, 95), percentile(values, 99), values.front(), values.back()
        , checksum};
}

std::string read_file(std::filesystem::path const& path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("could not open " + path.string());
    return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

lt::span<char const> as_span(std::string const& bytes)
{
    return {bytes.data(), static_cast<std::ptrdiff_t>(bytes.size())};
}

std::span<char const> string_span(lt::bdecode_node const& value)
{
    int const length = value.string_length();
    if (length < 0) throw std::runtime_error("native string length is negative");
    __unsafe_buffer_usage_begin
    auto result = std::span<char const>(value.string_ptr(), std::size_t(length));
    __unsafe_buffer_usage_end
    return result;
}

std::uint64_t handshake_checksum(std::string const& bytes)
{
    lt::error_code ec;
    int position = 0;
    lt::bdecode_node const root = lt::bdecode(as_span(bytes), ec, &position);
    if (ec || root.type() != lt::bdecode_node::dict_t)
        throw std::runtime_error("native extension handshake parse failed");

    std::uint64_t result = 0;
    if (lt::bdecode_node const messages = root.dict_find_dict("m"))
    {
        result += std::uint64_t(messages.dict_find_int_value("ut_metadata", 0));
        result += std::uint64_t(messages.dict_find_int_value("ut_pex", 0));
        result += std::uint64_t(messages.dict_find_int_value("upload_only", 0));
        result += std::uint64_t(messages.dict_find_int_value("ut_holepunch", 0));
        result += std::uint64_t(messages.dict_find_int_value("lt_donthave", 0));
    }
    result += std::uint64_t(root.dict_find_int_value("metadata_size", 0));
    result += std::uint64_t(root.dict_find_int_value("p", 0));
    result += std::uint64_t(root.dict_find_int_value("complete_ago", 0));
    result += std::uint64_t(root.dict_find_int_value("reqq", 0));
    result += std::uint64_t(root.dict_find_int_value("upload_only", 0));

    std::string const client(root.dict_find_string_value("v"));
    result += client.size();
    auto const your_ip = root.dict_find_string_value("yourip");
    for (char const byte : your_ip) result += static_cast<unsigned char>(byte);
    return result;
}

std::uint64_t metadata_checksum(std::string const& bytes)
{
    lt::error_code ec;
    lt::bdecode_node const message = lt::bdecode(as_span(bytes), ec);
    if (ec || message.type() != lt::bdecode_node::dict_t)
        throw std::runtime_error("native ut_metadata parse failed");
    lt::bdecode_node const type = message.dict_find_int("msg_type");
    lt::bdecode_node const piece = message.dict_find_int("piece");
    if (!type || !piece) throw std::runtime_error("native ut_metadata fields missing");
    return std::uint64_t(type.int_value())
        + std::uint64_t(piece.int_value())
        + std::uint64_t(message.dict_find_int_value("total_size", 0))
        + std::uint64_t(bytes.size() - std::size_t(message.data_section().size()));
}

std::uint64_t compact_peer_checksum(lt::bdecode_node const& value, std::size_t const stride
    , lt::bdecode_node const& flags = {})
{
    if (!value) return 0;
    if (value.type() != lt::bdecode_node::string_t || stride < 2)
        throw std::runtime_error("native compact peer list malformed");
    auto const peers = string_span(value);
    if (peers.size() % stride != 0)
        throw std::runtime_error("native compact peer list malformed");
    std::size_t const count = peers.size() / stride;
    std::span<char const> flag_bytes;
    if (flags)
    {
        if (flags.type() != lt::bdecode_node::string_t)
            throw std::runtime_error("native compact peer flags malformed");
        flag_bytes = string_span(flags);
    }
    if (!flag_bytes.empty() && flag_bytes.size() != count)
        throw std::runtime_error("native compact peer flags malformed");
    std::uint64_t result = std::uint64_t(count);
    for (std::size_t i = 0; i < count; ++i)
    {
        auto const peer = peers.subspan(i * stride, stride);
        for (char const byte : peer.first(stride - 2))
            result += static_cast<unsigned char>(byte);
        result += (std::uint64_t(static_cast<unsigned char>(peer[stride - 2])) << 8)
            | std::uint64_t(static_cast<unsigned char>(peer[stride - 1]));
        if (!flag_bytes.empty()) result += static_cast<unsigned char>(flag_bytes[i]);
    }
    return result;
}

std::uint64_t pex_checksum(std::string const& bytes)
{
    lt::error_code ec;
    lt::bdecode_node const root = lt::bdecode(as_span(bytes), ec);
    if (ec || root.type() != lt::bdecode_node::dict_t)
        throw std::runtime_error("native ut_pex parse failed");
    return compact_peer_checksum(root.dict_find_string("added"), 6
            , root.dict_find_string("added.f"))
        + compact_peer_checksum(root.dict_find_string("added6"), 18
            , root.dict_find_string("added6.f"))
        + compact_peer_checksum(root.dict_find_string("dropped"), 6)
        + compact_peer_checksum(root.dict_find_string("dropped6"), 18);
}

lt::aux::tracker_response parse_tracker_response(std::string const& bytes, lt::error_code& ec)
{
    lt::aux::tracker_response response;
    lt::bdecode_node const root = lt::bdecode(as_span(bytes), ec);
    if (ec) return response;
    if (root.type() != lt::bdecode_node::dict_t)
    {
        ec = lt::errors::invalid_tracker_response;
        return response;
    }

    response.interval = lt::seconds32{root.dict_find_int_value("interval", 1800)};
    response.min_interval = lt::seconds32{root.dict_find_int_value("min interval", 30)};
    if (lt::bdecode_node const tracker_id = root.dict_find_string("tracker id"))
        response.trackerid = tracker_id.string_value();
    if (lt::bdecode_node const warning = root.dict_find_string("warning message"))
        response.warning_message = warning.string_value();
    response.complete = int(root.dict_find_int_value("complete", -1));
    response.incomplete = int(root.dict_find_int_value("incomplete", -1));
    response.downloaded = int(root.dict_find_int_value("downloaded", -1));

    lt::bdecode_node const peers = root.dict_find_string("peers");
    if (peers)
    {
        char const* cursor = peers.string_ptr();
        int const length = peers.string_length();
        if (length < 0 || length % 6 != 0)
        {
            ec = lt::errors::invalid_peers_entry;
            return response;
        }
        response.peers4.reserve(std::size_t(length / 6));
        for (int offset = 0; offset < length; offset += 6)
        {
            lt::aux::ipv4_peer_entry peer;
            peer.ip = lt::aux::read_v4_address(cursor).to_bytes();
            peer.port = lt::aux::read_uint16(cursor);
            response.peers4.push_back(peer);
        }
    }
    return response;
}

std::uint64_t tracker_checksum(lt::aux::tracker_response const& value)
{
    std::uint64_t result = std::uint64_t(value.peers4.size())
        + std::uint64_t(value.complete)
        + value.trackerid.size()
        + value.warning_message.size();
    for (auto const& peer : value.peers4)
    {
        for (auto const byte : peer.ip) result += std::uint64_t(byte);
        result += std::uint64_t(peer.port);
    }
    return result;
}

std::uint64_t dht_checksum(lt::bdecode_node const& root)
{
    if (root.type() != lt::bdecode_node::dict_t)
        throw std::runtime_error("native DHT root malformed");
    std::uint64_t result = 0;
    auto const transaction = root.dict_find_string_value("t");
    auto const kind = root.dict_find_string_value("y");
    for (char const byte : transaction) result += static_cast<unsigned char>(byte);
    for (char const byte : kind) result += static_cast<unsigned char>(byte);
    if (kind == "q")
    {
        auto const query = root.dict_find_string_value("q");
        lt::bdecode_node const arguments = root.dict_find_dict("a");
        auto const id = arguments.dict_find_string_value("id");
        result += query.size() + id.size();
    }
    else if (kind == "r")
    {
        lt::bdecode_node const response = root.dict_find_dict("r");
        auto const id = response.dict_find_string_value("id");
        result += id.size();
        lt::bdecode_node const nodes = response.dict_find_string("nodes");
        if (nodes)
        {
            auto const data = string_span(nodes);
            if (data.size() % 26 != 0)
                throw std::runtime_error("native DHT nodes malformed");
            result += std::uint64_t(data.size() / 26);
            for (std::size_t offset = 0; offset < data.size(); offset += 26)
            {
                result += static_cast<unsigned char>(data[offset]);
                result += static_cast<unsigned char>(data[offset + 20]);
                result += (std::uint64_t(static_cast<unsigned char>(data[offset + 24])) << 8)
                    | std::uint64_t(static_cast<unsigned char>(data[offset + 25]));
            }
        }
    }
    return result;
}

void print(measurement const& value)
{
    std::cout << std::setprecision(12)
        << "{\"runtime\":\"native\",\"name\":\"" << value.name
        << "\",\"bytes\":" << value.bytes
        << ",\"iterations\":" << value.iterations
        << ",\"samples\":" << value.samples
        << ",\"median_ns\":" << value.median_ns
        << ",\"p95_ns\":" << value.p95_ns
        << ",\"p99_ns\":" << value.p99_ns
        << ",\"min_ns\":" << value.minimum_ns
        << ",\"max_ns\":" << value.maximum_ns
        << ",\"median_messages_per_second\":" << 1.0e9 / value.median_ns
        << ",\"median_bytes_per_second\":"
        << double(value.bytes) * 1.0e9 / value.median_ns
        << ",\"checksum\":" << value.checksum << "}\n";
}

int main(int argc, char** argv)
{
    if (argc != 2) throw std::runtime_error("usage: native_bench FIXTURE_DIRECTORY");
    __unsafe_buffer_usage_begin
    auto const arguments = std::span<char*>(argv, std::size_t(argc));
    __unsafe_buffer_usage_end
    std::filesystem::path const directory(arguments[1]);
    std::string const basic_magnet = read_file(directory / "magnet_basic.txt");
    std::string const rich_magnet = read_file(directory / "magnet_rich.txt");
    std::string const torrent_small = read_file(directory / "torrent_small.bin");
    std::string const torrent_128 = read_file(directory / "torrent_128.bin");
    std::string const torrent_4096 = read_file(directory / "torrent_4096.bin");
    std::string const info_128 = read_file(directory / "info_128.bin");
    std::string const info_4096 = read_file(directory / "info_4096.bin");
    std::string const handshake = read_file(directory / "extension_handshake.bin");
    std::string const metadata = read_file(directory / "ut_metadata.bin");
    std::string const pex = read_file(directory / "ut_pex.bin");
    std::string const tracker_512 = read_file(directory / "tracker_512.bin");
    std::string const tracker_3000 = read_file(directory / "tracker_3000.bin");
    std::string const dht_ping = read_file(directory / "dht_ping.bin");
    std::string const dht_dense = read_file(directory / "dht_dense.bin");
    std::string const dht_maxwork = read_file(directory / "dht_maxwork.bin");

    print(measure("magnet_basic", basic_magnet.size(), 50000, [&] {
        lt::error_code ec;
        lt::add_torrent_params value = lt::parse_magnet_uri(basic_magnet, ec);
        if (ec) throw std::runtime_error("native basic magnet parse failed: " + ec.message());
        return std::uint64_t(value.info_hashes.has_v1()) + value.trackers.size();
    }));
    print(measure("magnet_rich", rich_magnet.size(), 20000, [&] {
        lt::error_code ec;
        lt::add_torrent_params value = lt::parse_magnet_uri(rich_magnet, ec);
        if (ec) throw std::runtime_error("native rich magnet parse failed: " + ec.message());
        return std::uint64_t(value.info_hashes.has_v1())
            + std::uint64_t(value.info_hashes.has_v2())
            + value.trackers.size() + value.url_seeds.size() + value.file_priorities.size();
    }));

    lt::load_torrent_limits torrent_limits;
    auto const torrent_operation = [&](std::string const& bytes) {
        lt::error_code ec;
        lt::add_torrent_params value = lt::load_torrent_buffer(as_span(bytes), ec, torrent_limits);
        if (ec || !value.ti) throw std::runtime_error("native torrent parse failed: " + ec.message());
        return std::uint64_t(value.ti->num_files())
            + std::uint64_t(value.ti->total_size()) + value.trackers.size();
    };
    print(measure("torrent_small", torrent_small.size(), 5000
        , [&] { return torrent_operation(torrent_small); }));
    print(measure("torrent_128", torrent_128.size(), 500
        , [&] { return torrent_operation(torrent_128); }));
    print(measure("torrent_4096", torrent_4096.size(), 20
        , [&] { return torrent_operation(torrent_4096); }));

    auto const info_operation = [&](std::string const& bytes) {
        lt::error_code ec;
        int position = 0;
        lt::bdecode_node const root = lt::bdecode(as_span(bytes), ec, &position, 200
            , torrent_limits.max_decode_tokens);
        if (ec || root.type() != lt::bdecode_node::dict_t)
            throw std::runtime_error("native info bdecode failed: " + ec.message());
        auto value = std::make_shared<lt::torrent_info>(root, ec, torrent_limits, lt::from_info_section);
        if (ec || !value->is_valid())
            throw std::runtime_error("native info semantic parse failed: " + ec.message());
        return std::uint64_t(value->num_files()) + std::uint64_t(value->total_size());
    };
    print(measure("info_128", info_128.size(), 500
        , [&] { return info_operation(info_128); }));
    print(measure("info_4096", info_4096.size(), 20
        , [&] { return info_operation(info_4096); }));

    print(measure("extension_handshake", handshake.size(), 30000
        , [&] { return handshake_checksum(handshake); }));
    print(measure("ut_metadata", metadata.size(), 30000
        , [&] { return metadata_checksum(metadata); }));
    print(measure("ut_pex", pex.size(), 3000
        , [&] { return pex_checksum(pex); }));
    print(measure("tracker_512", tracker_512.size(), 3000, [&] {
        lt::error_code ec;
        auto value = parse_tracker_response(tracker_512, ec);
        if (ec) throw std::runtime_error("native tracker parse failed: " + ec.message());
        return tracker_checksum(value);
    }));
    print(measure("tracker_3000", tracker_3000.size(), 500, [&] {
        lt::error_code ec;
        auto value = parse_tracker_response(tracker_3000, ec);
        if (ec) throw std::runtime_error("native tracker parse failed: " + ec.message());
        return tracker_checksum(value);
    }));

    print(measure("dht_ping", dht_ping.size(), 50000, [&] {
        lt::error_code ec;
        int position = 0;
        auto const ping_root = lt::bdecode(as_span(dht_ping), ec, &position, 10, 500);
        if (ec) throw std::runtime_error("native DHT ping parse failed");
        return dht_checksum(ping_root);
    }));
    print(measure("dht_dense", dht_dense.size(), 5000, [&] {
        lt::error_code ec;
        int position = 0;
        auto const dense_root = lt::bdecode(as_span(dht_dense), ec, &position, 10, 500);
        if (ec) throw std::runtime_error("native dense DHT parse failed");
        return dht_checksum(dense_root);
    }));
    // The Swift maximum-work fixture is intentionally accepted at its own
    // 500-value limit. Libtorrent's retired decoder counts tokens differently
    // and rejects this fixture at its 500-token ingress limit, so it is not an
    // accepted-intersection timing case.
    (void)dht_maxwork;
}
