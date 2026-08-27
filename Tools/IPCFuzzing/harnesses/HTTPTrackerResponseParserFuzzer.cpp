#include <cstddef>
#include <cstdint>

extern "C" void TorrentHTTPTrackerResponseParserFuzzOneInput(
    std::uint8_t const *data,
    std::size_t size
);

extern "C" int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    TorrentHTTPTrackerResponseParserFuzzOneInput(data, size);
    return 0;
}
