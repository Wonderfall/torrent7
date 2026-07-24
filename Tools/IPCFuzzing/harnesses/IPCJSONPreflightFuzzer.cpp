#include <cstddef>
#include <cstdint>

extern "C" void TorrentEngineIPCJSONPreflightFuzzOneInput(
    std::uint8_t const *bytes,
    std::size_t byte_count
);

extern "C" int LLVMFuzzerTestOneInput(
    std::uint8_t const *bytes,
    std::size_t byte_count
)
{
    TorrentEngineIPCJSONPreflightFuzzOneInput(bytes, byte_count);
    return 0;
}
