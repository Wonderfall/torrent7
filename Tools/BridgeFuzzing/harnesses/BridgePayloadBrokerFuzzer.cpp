#include "TorrentBridgeInternal.hpp"
#include "BridgeFuzzSupport.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace {

namespace internal = torrent_bridge::internal;
namespace lt = libtorrent;

[[noreturn]] void fail()
{
    std::abort();
}

void require(bool condition)
{
    if (!condition) {
        fail();
    }
}

class DescriptorFixture final {
public:
    DescriptorFixture()
        : root_(bridge_fuzz::make_temp_root("payload-broker")),
          payload_(root_ / "payload.bin")
    {
        int const descriptor = ::open(
            payload_.c_str(),
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        );
        if (descriptor < 0) {
            fail();
        }
        std::array<char, 8> const contents{'p', 'a', 'y', 'l', 'o', 'a', 'd', '\n'};
        ssize_t const written = ::write(descriptor, contents.data(), contents.size());
        int const close_result = ::close(descriptor);
        if (written != static_cast<ssize_t>(contents.size()) || close_result != 0) {
            fail();
        }
    }

    ~DescriptorFixture()
    {
        bridge_fuzz::remove_all_quietly(root_);
    }

    DescriptorFixture(DescriptorFixture const &) = delete;
    DescriptorFixture &operator=(DescriptorFixture const &) = delete;

    [[nodiscard]] int open_regular(int flags) const
    {
        return ::open(payload_.c_str(), flags);
    }

    [[nodiscard]] int open_directory() const
    {
        return ::open(root_.c_str(), O_RDONLY | O_DIRECTORY);
    }

private:
    bridge_fuzz::fs::path root_;
    bridge_fuzz::fs::path payload_;
};

enum class OpenScenario : std::uint8_t {
    regularReadOnly,
    regularReadWrite,
    directory,
    pipe,
    characterDevice,
    closedDescriptor,
    successWithoutDescriptor,
    errorWithDescriptor,
    hostileErrorCode,
};

struct CallbackState {
    DescriptorFixture const *fixture = nullptr;
    TTorrentStorageActivation expected_activation{};
    std::int32_t expected_file_index = 0;
    bool expected_writable = false;
    OpenScenario open_scenario = OpenScenario::regularReadOnly;
    std::int32_t hostile_error = -1;
    std::uint8_t size_scenario = 0;
    std::int64_t requested_size = 0;
    int last_issued_descriptor = -1;
    unsigned int retain_count = 0;
    unsigned int release_count = 0;
    bool allow_retain = true;
    bool arguments_match = true;
};

bool callback_arguments_match(
    CallbackState const &state,
    std::uint8_t const *claim_id,
    std::uint64_t generation,
    std::int32_t file_index
)
{
    return claim_id != nullptr
        && std::equal(
            state.expected_activation.claim_id,
            std::end(state.expected_activation.claim_id),
            claim_id
        )
        && generation == state.expected_activation.claim_generation
        && file_index == state.expected_file_index;
}

std::uint8_t retain_callback(void *context)
{
    auto *state = static_cast<CallbackState *>(context);
    if (state == nullptr) {
        return 0U;
    }
    ++state->retain_count;
    return state->allow_retain ? 1U : 0U;
}

void release_callback(void *context)
{
    auto *state = static_cast<CallbackState *>(context);
    if (state == nullptr) {
        fail();
    }
    ++state->release_count;
}

std::int32_t open_callback(
    void *context,
    std::uint8_t const *claim_id,
    std::uint64_t generation,
    std::int32_t file_index,
    std::uint8_t writable,
    std::int32_t *descriptor_out
)
{
    auto *state = static_cast<CallbackState *>(context);
    if (state == nullptr || descriptor_out == nullptr || state->fixture == nullptr) {
        return EINVAL;
    }
    state->arguments_match = state->arguments_match
        && callback_arguments_match(*state, claim_id, generation, file_index)
        && (writable != 0U) == state->expected_writable;
    *descriptor_out = -1;

    int descriptor = -1;
    std::int32_t result = 0;
    switch (state->open_scenario) {
    case OpenScenario::regularReadOnly:
        descriptor = state->fixture->open_regular(O_RDONLY);
        break;
    case OpenScenario::regularReadWrite:
        descriptor = state->fixture->open_regular(O_RDWR);
        break;
    case OpenScenario::directory:
        descriptor = state->fixture->open_directory();
        break;
    case OpenScenario::pipe: {
        std::array<int, 2> descriptors{-1, -1};
        if (::pipe(descriptors.data()) == 0) {
            descriptor = descriptors[0];
            static_cast<void>(::close(descriptors[1]));
        }
        break;
    }
    case OpenScenario::characterDevice:
        descriptor = ::open("/dev/null", O_RDONLY);
        break;
    case OpenScenario::closedDescriptor:
        descriptor = state->fixture->open_regular(O_RDONLY);
        if (descriptor >= 0) {
            static_cast<void>(::close(descriptor));
        }
        break;
    case OpenScenario::successWithoutDescriptor:
        break;
    case OpenScenario::errorWithDescriptor:
        descriptor = state->fixture->open_regular(O_RDWR);
        result = EACCES;
        break;
    case OpenScenario::hostileErrorCode:
        descriptor = state->fixture->open_regular(O_RDWR);
        result = state->hostile_error == 0 ? -1 : state->hostile_error;
        break;
    }
    state->last_issued_descriptor = descriptor;
    *descriptor_out = descriptor;
    return result;
}

std::int32_t size_callback(
    void *context,
    std::uint8_t const *claim_id,
    std::uint64_t generation,
    std::int32_t file_index,
    std::int64_t *size_out
)
{
    auto *state = static_cast<CallbackState *>(context);
    if (state == nullptr || size_out == nullptr) {
        return EINVAL;
    }
    state->arguments_match = state->arguments_match
        && callback_arguments_match(*state, claim_id, generation, file_index);
    switch (state->size_scenario % 4U) {
    case 0:
        *size_out = state->requested_size;
        return 0;
    case 1:
        *size_out = -1;
        return 0;
    case 2:
        *size_out = state->requested_size;
        return ENOENT;
    default:
        *size_out = -1;
        return state->hostile_error == 0 ? -1 : state->hostile_error;
    }
}

TTorrentPayloadBrokerCallbacks callbacks_for(CallbackState &state)
{
    return TTorrentPayloadBrokerCallbacks{
        .context = &state,
        .retain_context = retain_callback,
        .release_context = release_callback,
        .open_payload = open_callback,
        .payload_size = size_callback,
    };
}

bool scenario_should_open(CallbackState const &state)
{
    switch (state.open_scenario) {
    case OpenScenario::regularReadWrite:
        return true;
    case OpenScenario::regularReadOnly:
        return !state.expected_writable;
    default:
        return false;
    }
}

void verify_open_result(CallbackState &state, int descriptor, lt::error_code const &error)
{
    bool const expected_success = scenario_should_open(state);
    require(state.arguments_match);
    require((descriptor >= 0) == expected_success);
    require(!error == expected_success);

    if (descriptor >= 0) {
        struct ::stat metadata {};
        require(::fstat(descriptor, &metadata) == 0);
        require(S_ISREG(metadata.st_mode));
        int const descriptor_flags = ::fcntl(descriptor, F_GETFD);
        require(descriptor_flags >= 0 && (descriptor_flags & FD_CLOEXEC) != 0);
        int const access_mode = ::fcntl(descriptor, F_GETFL);
        require(access_mode >= 0);
        if (state.expected_writable) {
            require((access_mode & O_ACCMODE) != O_RDONLY);
        }
        require(::close(descriptor) == 0);
        return;
    }

    if (state.last_issued_descriptor >= 0) {
        errno = 0;
        require(::fcntl(state.last_issued_descriptor, F_GETFD) == -1);
        require(errno == EBADF);
    }
}

void exercise_callback_table_rejection(std::uint8_t selector)
{
    CallbackState state;
    TTorrentPayloadBrokerCallbacks callbacks = callbacks_for(state);
    switch (selector % 5U) {
    case 0: callbacks.context = nullptr; break;
    case 1: callbacks.retain_context = nullptr; break;
    case 2: callbacks.release_context = nullptr; break;
    case 3: callbacks.open_payload = nullptr; break;
    default: callbacks.payload_size = nullptr; break;
    }

    try {
        auto rejected = std::make_shared<internal::PayloadBrokerContext>(callbacks);
        static_cast<void>(rejected);
        fail();
    } catch (std::invalid_argument const &) {
        require(state.retain_count == 0U);
        require(state.release_count == 0U);
    }

    state.allow_retain = false;
    callbacks = callbacks_for(state);
    try {
        auto rejected = std::make_shared<internal::PayloadBrokerContext>(callbacks);
        static_cast<void>(rejected);
        fail();
    } catch (std::invalid_argument const &) {
        require(state.retain_count == 1U);
        require(state.release_count == 0U);
    }
}

} // namespace

extern "C" __attribute__((visibility("default"))) int LLVMFuzzerTestOneInput(
    std::uint8_t const *data,
    std::size_t size
)
{
    static DescriptorFixture const fixture;
    bridge_fuzz::ByteReader reader(data, size);

    CallbackState state;
    state.fixture = &fixture;
    state.open_scenario = static_cast<OpenScenario>(reader.read_u8() % 9U);
    state.expected_writable = reader.read_bool();
    state.expected_file_index = reader.read_i32();
    state.hostile_error = reader.read_i32();
    state.size_scenario = reader.read_u8();
    state.requested_size = static_cast<std::int64_t>(
        static_cast<std::uint64_t>(reader.read_i32()) & 0x7fff'ffffULL
    );
    bool const call_open_directly = reader.read_bool();
    bool const call_size_directly = reader.read_bool();
    std::uint8_t const callback_table_selector = reader.read_u8();
    state.expected_activation = bridge_fuzz::storage_activation_from_reader(reader);

    {
        auto broker = std::make_shared<internal::PayloadBrokerContext>(
            callbacks_for(state)
        );
        internal::BridgePayloadFileProvider provider(
            broker,
            state.expected_activation
        );
        lt::error_code open_error;
        int const descriptor = call_open_directly
            ? broker->open_payload(
                state.expected_activation,
                lt::file_index_t(state.expected_file_index),
                state.expected_writable,
                open_error
            )
            : provider.open_payload(
                lt::file_index_t(state.expected_file_index),
                state.expected_writable,
                open_error
            );
        verify_open_result(state, descriptor, open_error);

        lt::error_code size_error;
        std::int64_t const payload_size = call_size_directly
            ? broker->payload_size(
                state.expected_activation,
                lt::file_index_t(state.expected_file_index),
                size_error
            )
            : provider.payload_size(
                lt::file_index_t(state.expected_file_index),
                size_error
            );
        bool const expected_size = state.size_scenario % 4U == 0U;
        require((payload_size >= 0) == expected_size);
        require(!size_error == expected_size);
        if (expected_size) {
            require(payload_size == state.requested_size);
        }
        require(state.arguments_match);
        require(state.retain_count == 1U);
        require(state.release_count == 0U);
    }
    require(state.release_count == 1U);

    try {
        internal::BridgePayloadFileProvider rejected(
            nullptr,
            state.expected_activation
        );
        static_cast<void>(rejected);
        fail();
    } catch (std::invalid_argument const &) {
    }
    exercise_callback_table_rejection(callback_table_selector);
    return 0;
}
