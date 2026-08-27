#include <cstddef>
#include <cstdint>

extern "C" void TorrentSwarmInfoParserFuzzOneInput(
    std::uint8_t const *data,
    std::size_t size
);

extern "C" int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    TorrentSwarmInfoParserFuzzOneInput(data, size);
    return 0;
}
