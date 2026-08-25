#include <cstddef>
#include <cstdint>

extern "C" void TorrentStorageBrokerIPCFuzzOneInput(
    std::uint8_t const *data,
    std::size_t size
);

extern "C" int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    TorrentStorageBrokerIPCFuzzOneInput(data, size);
    return 0;
}
