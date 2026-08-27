#include "TorrentBridgeInternal.hpp"
#include "ParserBridgeFuzzSupport.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>

namespace {

[[nodiscard]] lt::span<char const> message_span(
    std::uint8_t const *data,
    std::size_t const size
) noexcept
{
    return {
        reinterpret_cast<char const *>(data),
        static_cast<std::ptrdiff_t>(size),
    };
}

void exercise_swarm(lt::span<char const> const message)
{
    TTorrentSwarmMetainfoParserCallbacks callbacks{};
    if (TorrentParserFuzzMakeSwarmMetainfoCallbacks(&callbacks) != 0) {
        __builtin_trap();
    }
    torrent_bridge::internal::BridgeSwarmMetadataParser parser(callbacks);
    lt::error_code error;
    std::shared_ptr<lt::torrent_info> const parsed = parser.parse(message, error);
    if ((parsed && error)
        || (!parsed && error != lt::errors::invalid_swarm_metadata)) {
        __builtin_trap();
    }
}

void exercise_handshake(lt::span<char const> const message)
{
    TTorrentPeerProtocolParserCallbacks callbacks{};
    if (TorrentParserFuzzMakePeerProtocolCallbacks(&callbacks) != 0) {
        __builtin_trap();
    }
    torrent_bridge::internal::BridgePeerMessageParser parser(callbacks);
    lt::aux::extension_handshake parsed;
    lt::error_code error;
    bool const accepted = parser.parse_extension_handshake(message, parsed, error);
    if ((accepted && error)
        || (!accepted && error != lt::errors::invalid_extended)) {
        __builtin_trap();
    }
}

void exercise_metadata(lt::span<char const> const message)
{
    TTorrentPeerProtocolParserCallbacks callbacks{};
    if (TorrentParserFuzzMakePeerProtocolCallbacks(&callbacks) != 0) {
        __builtin_trap();
    }
    torrent_bridge::internal::BridgePeerMessageParser parser(callbacks);
    lt::aux::ut_metadata_message parsed;
    lt::error_code error;
    bool const accepted = parser.parse_ut_metadata(message, parsed, error);
    if ((accepted && error)
        || (!accepted && error != lt::errors::invalid_metadata_message)) {
        __builtin_trap();
    }
}

void exercise_peer_exchange(lt::span<char const> const message)
{
    TTorrentPeerProtocolParserCallbacks callbacks{};
    if (TorrentParserFuzzMakePeerProtocolCallbacks(&callbacks) != 0) {
        __builtin_trap();
    }
    torrent_bridge::internal::BridgePeerMessageParser parser(callbacks);
    lt::aux::peer_exchange_message parsed;
    lt::error_code error;
    bool const accepted = parser.parse_ut_pex(message, parsed, error);
    if ((accepted && error)
        || (!accepted && error != lt::errors::invalid_pex_message)) {
        __builtin_trap();
    }
}

void exercise_tracker(
    lt::span<char const> message,
    bool const scrape
)
{
    lt::sha1_hash scrape_hash{};
    if (scrape) {
        std::size_t const copied = std::min<std::size_t>(message.size(), scrape_hash.size());
        std::copy_n(message.begin(), copied, scrape_hash.begin());
        message = message.subspan(copied);
    }

    TTorrentTrackerResponseParserCallbacks callbacks{};
    if (TorrentParserFuzzMakeTrackerResponseCallbacks(&callbacks) != 0) {
        __builtin_trap();
    }
    torrent_bridge::internal::BridgeTrackerResponseParser parser(callbacks);
    lt::aux::tracker_response parsed;
    lt::error_code error;
    bool const accepted = parser.parse_http_response(
        message,
        scrape,
        scrape_hash,
        parsed,
        error
    );
    if ((!accepted && error != lt::errors::invalid_tracker_response)
        || (accepted && error
            && error != lt::errors::tracker_failure)) {
        __builtin_trap();
    }
}

void exercise_dht(
    lt::span<char const> const message,
    bool const source_is_ipv6
)
{
    TTorrentDHTMessageParserCallbacks callbacks{};
    if (TorrentParserFuzzMakeDHTMessageCallbacks(&callbacks) != 0) {
        __builtin_trap();
    }
    torrent_bridge::internal::BridgeDHTMessageParser parser(callbacks);
    lt::dht::krpc_message parsed;
    static_cast<void>(parser.parse_message(message, source_is_ipv6, parsed));
}

void exercise_selected(
    std::uint8_t const selector,
    std::uint8_t const options,
    lt::span<char const> const message
)
{
    switch (selector % 6U) {
    case 0U:
        exercise_swarm(message);
        break;
    case 1U:
        exercise_handshake(message);
        break;
    case 2U:
        exercise_metadata(message);
        break;
    case 3U:
        exercise_peer_exchange(message);
        break;
    case 4U:
        exercise_tracker(message, (options & 1U) != 0U);
        break;
    default:
        exercise_dht(message, (options & 1U) != 0U);
        break;
    }
}

} // namespace

extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t const size
)
{
    if (size < 2U) {
        return 0;
    }
    std::uint8_t const selector = data[0];
    std::uint8_t const options = data[1];
    lt::span<char const> const message = message_span(data + 2U, size - 2U);
    exercise_selected(selector, options, message);
    if (!message.empty() && message.back() == '\n') {
        exercise_selected(selector, options, message.first(message.size() - 1));
    }
    return 0;
}
