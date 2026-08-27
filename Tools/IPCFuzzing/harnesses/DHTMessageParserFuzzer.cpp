#include <cstddef>
#include <cstdint>

extern "C" void TorrentDHTMessageParserFuzzOneInput(
    std::uint8_t const *data,
    std::size_t size
);

extern "C" int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    TorrentDHTMessageParserFuzzOneInput(data, size);
    return 0;
}
