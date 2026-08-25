#include <cstddef>
#include <cstdint>

extern "C" void TorrentStorageClaimFuzzOneInput(
    std::uint8_t const *data,
    std::size_t size
);

extern "C" int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    TorrentStorageClaimFuzzOneInput(data, size);
    return 0;
}
