#include <cstddef>
#include <cstdint>

extern "C" void TorrentStorageManifestFuzzOneInput(
    std::uint8_t const *data,
    std::size_t size
);

extern "C" int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    TorrentStorageManifestFuzzOneInput(data, size);
    return 0;
}
