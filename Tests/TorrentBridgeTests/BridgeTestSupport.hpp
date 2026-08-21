#ifndef TORRENT_BRIDGE_TEST_SUPPORT_HPP
#define TORRENT_BRIDGE_TEST_SUPPORT_HPP

#include "TorrentBridgeInternal.hpp"

#include <array>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <iterator>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <unordered_map>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// Bridge tests intentionally exercise the private C++ implementation surface.
using namespace torrent_bridge::internal;

// White-box state inspection must obey the same locking contract as production
// code. The lambda's deduced return type copies values out instead of allowing a
// guarded reference to escape after the lock is released.
#define BRIDGE_WITH_CLIENT_LOCK(client, expression) ([&]() { \
    std::scoped_lock bridge_test_client_guard((client).lock); \
    return (expression); \
}())

#define BRIDGE_WITH_RESUME_IO_LOCK(client, expression) ([&]() { \
    std::scoped_lock bridge_test_resume_io_guard((client).resume_io_lock); \
    return (expression); \
}())

namespace bridge_tests {

class TemporaryDirectory {
public:
    TemporaryDirectory()
    {
        constexpr int kMaxAttempts = 32;
        fs::path const parent = fs::temp_directory_path();
        for (int attempt = 0; attempt < kMaxAttempts; ++attempt) {
            fs::path const candidate = parent / (
                "TorrentBridgeTests-"
                + std::to_string(random_u32())
                + "-"
                + std::to_string(attempt)
            );

            std::error_code error;
            if (fs::create_directory(candidate, error)) {
                path_ = candidate;
                return;
            }
            if (error && error != std::errc::file_exists) {
                throw std::system_error(error, "Could not create temporary test directory");
            }
        }

        throw std::runtime_error("Could not create a unique temporary test directory.");
    }

    TemporaryDirectory(TemporaryDirectory const &) = delete;
    TemporaryDirectory &operator=(TemporaryDirectory const &) = delete;
    TemporaryDirectory(TemporaryDirectory &&) = delete;
    TemporaryDirectory &operator=(TemporaryDirectory &&) = delete;

    ~TemporaryDirectory()
    {
        std::error_code ignored;
        fs::remove_all(path_, ignored);
    }

    [[nodiscard]] fs::path const &path() const noexcept
    {
        return path_;
    }

private:
    fs::path path_;
};

[[nodiscard]] inline std::string string_from_c_buffer(std::span<char const> buffer)
{
    auto const terminator = std::ranges::find(buffer, '\0');
    return {buffer.begin(), terminator};
}

[[nodiscard]] inline std::vector<char> byte_vector(std::string_view value)
{
    return {value.begin(), value.end()};
}

[[nodiscard]] inline std::uint8_t const *byte_data(
    std::vector<char> const &bytes
) noexcept
{
    return reinterpret_cast<std::uint8_t const *>(bytes.data());
}

[[nodiscard]] inline lt::add_torrent_params load_torrent_params(
    std::vector<char> const &buffer,
    std::string_view description
)
{
    lt::error_code error;
    lt::add_torrent_params params = lt::load_torrent_buffer(
        lt::span<char const>(buffer),
        error,
        lt::load_torrent_limits{}
    );
    if (error || !params.ti) {
        std::string const reason = error ? error.message() : "missing torrent metadata";
        throw std::runtime_error("Could not load " + std::string(description) + ": " + reason);
    }
    return params;
}

class TestPayloadBroker final {
public:
    explicit TestPayloadBroker(fs::path root)
        : state_(new State(std::move(root)))
    {
    }

    TestPayloadBroker(TestPayloadBroker const &) = delete;
    TestPayloadBroker &operator=(TestPayloadBroker const &) = delete;
    TestPayloadBroker(TestPayloadBroker &&) = delete;
    TestPayloadBroker &operator=(TestPayloadBroker &&) = delete;

    ~TestPayloadBroker()
    {
        release_state(state_);
    }

    [[nodiscard]] TTorrentPayloadBrokerCallbacks callbacks() const noexcept
    {
        return TTorrentPayloadBrokerCallbacks{
            .context = state_,
            .retain_context = retain_callback,
            .release_context = release_callback,
            .open_payload = open_callback,
            .payload_size = size_callback,
        };
    }

    [[nodiscard]] std::shared_ptr<PayloadBrokerContext> context() const
    {
        return std::make_shared<PayloadBrokerContext>(callbacks());
    }

    [[nodiscard]] TTorrentStorageActivation register_torrent(
        lt::add_torrent_params const &params,
        std::uint64_t generation = 1U
    )
    {
        if (!params.ti || generation == 0U) {
            throw std::invalid_argument("A test payload claim requires torrent metadata and a generation.");
        }

        TTorrentStorageActivation activation{};
        Claim claim;
        {
            std::scoped_lock guard(state_->lock);
            std::uint64_t const sequence = state_->next_claim++;
            std::size_t index = 0U;
            for (std::uint8_t &byte : activation.claim_id) {
                byte = static_cast<std::uint8_t>(((sequence + index) % 255U) + 1U);
                ++index;
            }
        }
        activation.claim_generation = generation;
        std::string const digest = testing_logical_manifest_digest(params).to_string();
        std::ranges::transform(
            digest,
            activation.source_manifest_digest,
            [](char const byte) { return static_cast<std::uint8_t>(byte); }
        );

        claim.generation = generation;
        lt::file_storage const &files = params.ti->layout();
        for (lt::file_index_t const file : files.file_range()) {
            if (files.pad_file_at(file)) {
                continue;
            }
            int32_t const index = static_cast<int32_t>(static_cast<int>(file));
            fs::path const path = state_->root
                / (storage_claim_key(activation) + "-" + std::to_string(index));
            int const descriptor = ::open(
                path.c_str(),
                O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            );
            if (descriptor < 0) {
                throw std::system_error(
                    std::error_code(errno, std::generic_category()),
                    "Could not create a test payload file"
                );
            }
            std::int64_t const size = files.file_size(file);
            if (size < 0 || size > std::numeric_limits<off_t>::max()
                || ::ftruncate(descriptor, static_cast<off_t>(size)) != 0) {
                int const error_number = size < 0 ? EINVAL : errno;
                static_cast<void>(::close(descriptor));
                throw std::system_error(
                    std::error_code(error_number, std::generic_category()),
                    "Could not size a test payload file"
                );
            }
            if (::close(descriptor) != 0) {
                throw std::system_error(
                    std::error_code(errno, std::generic_category()),
                    "Could not close a test payload file"
                );
            }
            claim.files.emplace(index, path);
        }

        {
            std::scoped_lock guard(state_->lock);
            auto const [iterator, inserted] = state_->claims.emplace(
                storage_claim_key(activation),
                std::move(claim)
            );
            if (!inserted) {
                throw std::logic_error("A duplicate test payload claim was generated.");
            }
            static_cast<void>(iterator);
        }
        return activation;
    }

    void revoke(TTorrentStorageActivation const &activation)
    {
        std::scoped_lock guard(state_->lock);
        state_->claims.erase(storage_claim_key(activation));
    }

private:
    struct Claim {
        std::uint64_t generation = 0U;
        std::unordered_map<int32_t, fs::path> files;
    };

    struct State {
        explicit State(fs::path requested_root)
            : root(std::move(requested_root))
        {
            std::error_code error;
            if (!fs::create_directories(root, error) && error) {
                throw std::system_error(error, "Could not create the test payload directory");
            }
        }

        std::atomic<std::uint32_t> references{1U};
        std::mutex lock;
        fs::path root;
        std::uint64_t next_claim = 1U;
        std::unordered_map<std::string, Claim> claims;
    };

    static void release_state(State *state) noexcept
    {
        if (state != nullptr && state->references.fetch_sub(1U, std::memory_order_acq_rel) == 1U) {
            delete state;
        }
    }

    static std::uint8_t retain_callback(void *context) noexcept
    {
        auto *state = static_cast<State *>(context);
        if (state == nullptr) {
            return 0U;
        }
        std::uint32_t count = state->references.load(std::memory_order_acquire);
        while (count != 0U && count != std::numeric_limits<std::uint32_t>::max()) {
            if (state->references.compare_exchange_weak(
                    count,
                    count + 1U,
                    std::memory_order_acq_rel,
                    std::memory_order_acquire
                )) {
                return 1U;
            }
        }
        return 0U;
    }

    static void release_callback(void *context) noexcept
    {
        release_state(static_cast<State *>(context));
    }

    static std::optional<fs::path> payload_path(
        State &state,
        std::span<std::uint8_t const, 16U> claim_id,
        std::uint64_t generation,
        int32_t file_index
    )
    {
        TTorrentStorageActivation key{};
        std::ranges::copy(claim_id, key.claim_id);
        std::scoped_lock guard(state.lock);
        auto const claim = state.claims.find(storage_claim_key(key));
        if (claim == state.claims.end() || claim->second.generation != generation) {
            return std::nullopt;
        }
        auto const file = claim->second.files.find(file_index);
        return file == claim->second.files.end()
            ? std::nullopt
            : std::optional<fs::path>(file->second);
    }

    [[nodiscard]] static std::array<std::uint8_t, 16U> copy_claim_id(
        std::uint8_t const *claim_id
    ) noexcept
    {
        std::array<std::uint8_t, 16U> bounded{};
        // The callback ABI fixes this field at 16 bytes. Keep the raw C-buffer
        // boundary isolated, then use bounded containers everywhere else.
        __unsafe_buffer_usage_begin
        std::memcpy(bounded.data(), claim_id, bounded.size());
        __unsafe_buffer_usage_end
        return bounded;
    }

    static int32_t open_callback(
        void *context,
        std::uint8_t const *claim_id,
        std::uint64_t generation,
        int32_t file_index,
        std::uint8_t writable,
        int32_t *descriptor_out
    ) noexcept
    {
        if (context == nullptr || claim_id == nullptr || descriptor_out == nullptr) {
            return EINVAL;
        }
        *descriptor_out = -1;
        try {
            std::array<std::uint8_t, 16U> const bounded_claim_id = copy_claim_id(claim_id);
            std::optional<fs::path> const path = payload_path(
                *static_cast<State *>(context),
                bounded_claim_id,
                generation,
                file_index
            );
            if (!path) {
                return ENOENT;
            }
            int const descriptor = ::open(
                path->c_str(),
                (writable != 0U ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW
            );
            if (descriptor < 0) {
                return errno;
            }
            *descriptor_out = descriptor;
            return 0;
        } catch (...) {
            return EIO;
        }
    }

    static int32_t size_callback(
        void *context,
        std::uint8_t const *claim_id,
        std::uint64_t generation,
        int32_t file_index,
        std::int64_t *size_out
    ) noexcept
    {
        if (context == nullptr || claim_id == nullptr || size_out == nullptr) {
            return EINVAL;
        }
        *size_out = -1;
        try {
            std::array<std::uint8_t, 16U> const bounded_claim_id = copy_claim_id(claim_id);
            std::optional<fs::path> const path = payload_path(
                *static_cast<State *>(context),
                bounded_claim_id,
                generation,
                file_index
            );
            if (!path) {
                return ENOENT;
            }
            int const descriptor = ::open(path->c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
            if (descriptor < 0) {
                return errno;
            }
            struct ::stat metadata {};
            if (::fstat(descriptor, &metadata) != 0) {
                int const error_number = errno;
                static_cast<void>(::close(descriptor));
                return error_number;
            }
            if (::close(descriptor) != 0) {
                return errno;
            }
            if (!S_ISREG(metadata.st_mode) || metadata.st_size < 0) {
                return EFTYPE;
            }
            *size_out = metadata.st_size;
            return 0;
        } catch (...) {
            return EIO;
        }
    }

    State *state_;
};

[[nodiscard]] inline std::string read_text_file(fs::path const &path)
{
    std::ifstream input(path, std::ios::binary);
    return {
        std::istreambuf_iterator<char>(input),
        std::istreambuf_iterator<char>()
    };
}

inline void write_text_file(fs::path const &path, std::string_view contents)
{
    std::ofstream output(path, std::ios::binary);
    output << contents;
    if (!output) {
        throw std::runtime_error("Could not write test file: " + path.string());
    }
}

[[nodiscard]] inline std::string canonical_id(char digit)
{
    return std::string(kCanonicalIDPrefix) + std::string(32U, digit);
}

[[nodiscard]] inline std::string v1_id(char digit)
{
    return "v1:" + std::string(40U, digit);
}

[[nodiscard]] inline std::string v2_id(char digit)
{
    return "v2:" + std::string(64U, digit);
}

template <std::size_t Count>
[[nodiscard]] std::array<char, Count> sequential_bytes(unsigned char seed)
{
    std::array<char, Count> bytes{};
    for (std::size_t index = 0; index < bytes.size(); ++index) {
        bytes.at(index) = static_cast<char>(seed + static_cast<unsigned char>(index));
    }
    return bytes;
}

[[nodiscard]] inline std::string hex_for_sequential_bytes(std::size_t count, unsigned char seed)
{
    std::string bytes;
    bytes.reserve(count);
    for (std::size_t index = 0; index < count; ++index) {
        bytes.push_back(static_cast<char>(seed + static_cast<unsigned char>(index)));
    }
    return hex_string(bytes);
}

[[nodiscard]] inline lt::sha1_hash sha1_hash_from_seed(unsigned char seed)
{
    auto const bytes = sequential_bytes<20U>(seed);
    return lt::sha1_hash(bytes.data());
}

[[nodiscard]] inline lt::sha256_hash sha256_hash_from_seed(unsigned char seed)
{
    auto const bytes = sequential_bytes<32U>(seed);
    return lt::sha256_hash(bytes.data());
}

[[nodiscard]] inline lt::info_hash_t info_hashes_from_seed(unsigned char v1_seed, unsigned char v2_seed)
{
    return lt::info_hash_t(sha1_hash_from_seed(v1_seed), sha256_hash_from_seed(v2_seed));
}

[[nodiscard]] inline lt::add_torrent_params add_params_with_hashes()
{
    lt::add_torrent_params params;
    params.info_hashes = info_hashes_from_seed(1U, 33U);
    params.save_path = "/tmp";
    return params;
}

} // namespace bridge_tests

#endif
