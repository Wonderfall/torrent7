#include "BridgeFuzzSupport.hpp"

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <span>
#include <string>

namespace {

void exercise_asynchronous_destroy_once(std::filesystem::path const &root)
{
    static std::atomic_bool exercised = false;
    if (exercised.exchange(true, std::memory_order_relaxed)) {
        return;
    }

    TorrentClientDestroy(nullptr);

    std::string const state_path = (root / "async-state").string();
    bridge_fuzz::PayloadBroker payload_broker;
    bridge_fuzz::ErrorBuffer create_error;
    TTorrentClient *client = TorrentClientCreateWithError(
        state_path.c_str(),
        1,
        payload_broker.callbacks(),
        create_error.data(),
        create_error.capacity()
    );
    if (client == nullptr) {
        std::abort();
    }

    bridge_fuzz::ErrorBuffer error;
    static_cast<void>(TorrentClientBlockNetwork(client, error.data(), error.capacity()));
    TorrentClientDestroy(client);
}

} // namespace

extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    namespace fs = std::filesystem;

    fs::path const root = bridge_fuzz::make_temp_root("bridge-resume-startup");
    fs::path const state_dir = root / "state";
    fs::path const resume_dir = state_dir / "ResumeData";
    fs::create_directories(resume_dir);

    fs::path const resume_file = resume_dir / "v1:0000000000000000000000000000000000000000.fastresume";
    auto const *begin = reinterpret_cast<char const *>(data);
    bridge_fuzz::write_file(resume_file, std::span<char const>{begin, size});

    std::string const state_path = state_dir.string();
    bridge_fuzz::PayloadBroker payload_broker;
    bridge_fuzz::ErrorBuffer create_error;
    TTorrentClient *client = TorrentClientCreateWithError(
        state_path.c_str(),
        1,
        payload_broker.callbacks(),
        create_error.data(),
        create_error.capacity()
    );

    if (client != nullptr) {
        bridge_fuzz::ErrorBuffer error;
        static_cast<void>(TorrentClientBlockNetwork(client, error.data(), error.capacity()));
        bridge_fuzz::exercise_snapshot_copy(client);
        bridge_fuzz::exercise_detail_copies(client);
        static_cast<void>(TorrentClientSaveAllChecked(client, error.data(), error.capacity()));
        TorrentClientDestroyBlocking(client);
    }

    exercise_asynchronous_destroy_once(root);

    bridge_fuzz::remove_all_quietly(root);
    return 0;
}
