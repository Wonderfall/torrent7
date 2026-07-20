#ifndef TORRENT_BRIDGE_TEST_SUPPORT_HPP
#define TORRENT_BRIDGE_TEST_SUPPORT_HPP

#include "TorrentBridgeInternal.hpp"

#include <array>
#include <atomic>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

// Bridge tests intentionally exercise the private C++ implementation surface.
using namespace torrent_bridge::internal;

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

struct AuthorizedSaveRootLifetimeProbe {
    std::atomic<int> retain_count = 0;
    std::atomic<int> release_count = 0;
};

inline void retain_authorized_save_root(void *context)
{
    auto *probe = static_cast<AuthorizedSaveRootLifetimeProbe *>(context);
    probe->retain_count.fetch_add(1, std::memory_order_relaxed);
}

inline void release_authorized_save_root(void *context)
{
    auto *probe = static_cast<AuthorizedSaveRootLifetimeProbe *>(context);
    probe->release_count.fetch_add(1, std::memory_order_relaxed);
}

class AuthorizedSaveRoot {
public:
    explicit AuthorizedSaveRoot(fs::path path)
        : path_(std::move(path)),
          descriptor_(::open(path_.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    {
        if (!descriptor_.is_valid()) {
            throw std::system_error(errno, std::generic_category(), "Could not open authorized test root");
        }
        struct ::stat metadata {};
        if (::fstat(descriptor_.get(), &metadata) != 0) {
            throw std::system_error(errno, std::generic_category(), "Could not inspect authorized test root");
        }
        if (!S_ISDIR(metadata.st_mode)) {
            throw std::runtime_error("Authorized test root is not a directory");
        }
        device_ = static_cast<std::uint64_t>(metadata.st_dev);
        inode_ = static_cast<std::uint64_t>(metadata.st_ino);
    }

    AuthorizedSaveRoot(AuthorizedSaveRoot const &) = delete;
    AuthorizedSaveRoot &operator=(AuthorizedSaveRoot const &) = delete;
    AuthorizedSaveRoot(AuthorizedSaveRoot &&) = delete;
    AuthorizedSaveRoot &operator=(AuthorizedSaveRoot &&) = delete;

    [[nodiscard]] TTorrentAuthorizedSaveRoot record() noexcept
    {
        return TTorrentAuthorizedSaveRoot{
            .directory_descriptor = descriptor_.get(),
            .device = device_,
            .inode = inode_,
            .lifetime_context = &lifetime_probe_,
        };
    }

    [[nodiscard]] fs::path const &path() const noexcept
    {
        return path_;
    }

    [[nodiscard]] AuthorizedSaveRootLifetimeProbe const &lifetime_probe() const noexcept
    {
        return lifetime_probe_;
    }

    void close_borrowed_descriptor()
    {
        std::error_code const error = descriptor_.close();
        if (error) {
            throw std::system_error(error, "Could not close authorized test root");
        }
    }

private:
    fs::path path_;
    UniqueFileDescriptor descriptor_;
    std::uint64_t device_ = 0U;
    std::uint64_t inode_ = 0U;
    AuthorizedSaveRootLifetimeProbe lifetime_probe_;
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
