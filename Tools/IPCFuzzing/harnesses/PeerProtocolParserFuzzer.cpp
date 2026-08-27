#include <cstddef>
#include <cstdint>

extern "C" void TorrentPeerProtocolParserFuzzOneInput(
    std::uint8_t const *data,
    std::size_t size
);

extern "C" int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    TorrentPeerProtocolParserFuzzOneInput(data, size);
    return 0;
}
