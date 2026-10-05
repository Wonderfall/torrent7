#include <cstddef>
#include <cstdint>

extern "C" void TorrentCountryDatabaseFuzzOneInput(std::uint8_t const *bytes, std::size_t byte_count);

extern "C" int LLVMFuzzerTestOneInput(std::uint8_t const *bytes, std::size_t byte_count)
{
    TorrentCountryDatabaseFuzzOneInput(bytes, byte_count);
    return 0;
}
