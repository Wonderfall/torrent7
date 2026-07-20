#include "TorrentBridgeInternal.hpp"

#include <libtorrent/extensions.hpp>
#include <libtorrent/extensions/smart_ban.hpp>
#include <libtorrent/extensions/ut_metadata.hpp>
#include <libtorrent/extensions/ut_pex.hpp>
#include <libtorrent/pread_disk_io.hpp>

namespace torrent_bridge::internal {

namespace {

constexpr bool is_ascii_alpha(unsigned char const character) noexcept
{
    return (character >= 'A' && character <= 'Z')
        || (character >= 'a' && character <= 'z');
}

constexpr bool is_ascii_digit(unsigned char const character) noexcept
{
    return character >= '0' && character <= '9';
}

constexpr bool is_ascii_hex_digit(unsigned char const character) noexcept
{
    return is_ascii_digit(character)
        || (character >= 'A' && character <= 'F')
        || (character >= 'a' && character <= 'f');
}

constexpr bool is_ascii_unreserved(unsigned char const character) noexcept
{
    return is_ascii_alpha(character) || is_ascii_digit(character)
        || character == '-' || character == '.' || character == '_' || character == '~';
}

constexpr bool is_ascii_space(unsigned char const character) noexcept
{
    return character == ' ' || (character >= '\t' && character <= '\r');
}

constexpr bool is_ascii_control(unsigned char const character) noexcept
{
    return character < 0x20U || character == 0x7fU;
}

constexpr char ascii_lower(unsigned char const character) noexcept
{
    return character >= 'A' && character <= 'Z'
        ? static_cast<char>(character + ('a' - 'A'))
        : static_cast<char>(character);
}

#ifndef TORRENT_DISABLE_EXTENSIONS
class TorrentPluginFactory final : public lt::plugin {
public:
    using Factory = std::shared_ptr<lt::torrent_plugin> (*)(lt::torrent_handle const &, lt::client_data_t);

    explicit TorrentPluginFactory(Factory factory)
        : factory_(factory)
    {
    }

    std::shared_ptr<lt::torrent_plugin> new_torrent(lt::torrent_handle const &handle, lt::client_data_t userdata) override
    {
        return factory_(handle, userdata);
    }

private:
    Factory factory_;
};
#endif

} // namespace

std::vector<std::shared_ptr<lt::plugin>> session_plugins(bool enable_peer_exchange_plugin)
{
    std::vector<std::shared_ptr<lt::plugin>> plugins;
#ifndef TORRENT_DISABLE_EXTENSIONS
    plugins.reserve(enable_peer_exchange_plugin ? 3U : 2U);
    if (enable_peer_exchange_plugin) {
        plugins.push_back(std::make_shared<TorrentPluginFactory>(lt::create_ut_pex_plugin));
    }
    plugins.push_back(std::make_shared<TorrentPluginFactory>(lt::create_ut_metadata_plugin));
    plugins.push_back(std::make_shared<TorrentPluginFactory>(lt::create_smart_ban_plugin));
#else
    static_cast<void>(enable_peer_exchange_plugin);
#endif
    return plugins;
}

std::string_view c_string_view(char const *value)
{
    return value == nullptr ? std::string_view() : std::string_view(value);
}

bool is_valid_queue_priority(int32_t value) noexcept
{
    return value >= TTORRENT_QUEUE_PRIORITY_LOW && value <= TTORRENT_QUEUE_PRIORITY_HIGH;
}

bool is_valid_queue_rank(int32_t value) noexcept
{
    return value >= 0;
}

bool is_continuation_byte(unsigned char value) noexcept
{
    return (value & 0xc0U) == 0x80U;
}

bool is_c_string_control_byte(unsigned char value) noexcept
{
    return is_ascii_control(value);
}

unsigned char byte_at(std::string_view source, std::size_t offset) noexcept
{
    return static_cast<unsigned char>(*std::next(source.begin(), static_cast<std::ptrdiff_t>(offset)));
}

UTF8Sequence utf8_sequence(std::string_view source, std::size_t offset) noexcept
{
    auto const first = byte_at(source, offset);
    std::size_t const remaining = source.size() - offset;

    if (first <= 0x7fU) {
        return {.length = 1, .valid = true};
    }

    if (first >= 0xc2U && first <= 0xdfU) {
        bool const valid = remaining >= 2
            && is_continuation_byte(byte_at(source, offset + 1));
        return {.length = valid ? 2U : 1U, .valid = valid};
    }

    if (first >= 0xe0U && first <= 0xefU) {
        if (remaining < 3) {
            return {.length = 1, .valid = false};
        }

        auto const second = byte_at(source, offset + 1);
        auto const third = byte_at(source, offset + 2);
        bool const valid = is_continuation_byte(second)
            && is_continuation_byte(third)
            && (first != 0xe0U || second >= 0xa0U)
            && (first != 0xedU || second <= 0x9fU);
        return {.length = valid ? 3U : 1U, .valid = valid};
    }

    if (first >= 0xf0U && first <= 0xf4U) {
        if (remaining < 4) {
            return {.length = 1, .valid = false};
        }

        auto const second = byte_at(source, offset + 1);
        auto const third = byte_at(source, offset + 2);
        auto const fourth = byte_at(source, offset + 3);
        bool const valid = is_continuation_byte(second)
            && is_continuation_byte(third)
            && is_continuation_byte(fourth)
            && (first != 0xf0U || second >= 0x90U)
            && (first != 0xf4U || second <= 0x8fU);
        return {.length = valid ? 4U : 1U, .valid = valid};
    }

    return {.length = 1, .valid = false};
}

void copy_string_dynamic(std::span<char> destination, std::string_view source) noexcept
{
    if (destination.empty()) {
        return;
    }

    std::size_t const writable = destination.size() - 1;
    std::size_t input_index = 0;
    std::size_t output_index = 0;

    while (input_index < source.size() && output_index < writable) {
        if (is_c_string_control_byte(byte_at(source, input_index))) {
            if (kUTF8ReplacementCharacter.size() > writable - output_index) {
                break;
            }

            for (unsigned char const byte : kUTF8ReplacementCharacter) {
                *std::next(destination.begin(), static_cast<std::ptrdiff_t>(output_index)) = static_cast<char>(byte);
                ++output_index;
            }
            ++input_index;
            continue;
        }

        UTF8Sequence const sequence = utf8_sequence(source, input_index);
        if (sequence.valid) {
            if (sequence.length > writable - output_index) {
                break;
            }

            auto const begin = std::next(source.begin(), static_cast<std::ptrdiff_t>(input_index));
            std::ranges::copy_n(
                begin,
                static_cast<std::ptrdiff_t>(sequence.length),
                destination.begin() + static_cast<std::ptrdiff_t>(output_index)
            );
            input_index += sequence.length;
            output_index += sequence.length;
            continue;
        }

        if (kUTF8ReplacementCharacter.size() > writable - output_index) {
            break;
        }

        for (unsigned char const byte : kUTF8ReplacementCharacter) {
            *std::next(destination.begin(), static_cast<std::ptrdiff_t>(output_index)) = static_cast<char>(byte);
            ++output_index;
        }
        input_index += sequence.length;
    }

    *std::next(destination.begin(), static_cast<std::ptrdiff_t>(output_index)) = '\0';
}

std::span<char> output_buffer(char *destination, int32_t capacity) noexcept
{
    return output_span_from_c_buffer(destination, capacity);
}

void copy_error(std::span<char> destination, std::string_view message) noexcept
{
    copy_string_dynamic(destination, message);
}

BridgeResult bridge_error(int32_t code, std::string message)
{
    return std::unexpected(BridgeError{.code = code, .message = std::move(message)});
}

std::uint8_t bridge_bool(bool value) noexcept
{
    return value ? 1U : 0U;
}

bool bridge_bool(std::uint8_t value) noexcept
{
    return value != 0U;
}

int32_t bridge_torrent_state(lt::torrent_status::state_t state) noexcept
{
    switch (state) {
    case lt::torrent_status::checking_files:
        return TTORRENT_BRIDGE_STATE_CHECKING_FILES;
    case lt::torrent_status::downloading_metadata:
        return TTORRENT_BRIDGE_STATE_DOWNLOADING_METADATA;
    case lt::torrent_status::downloading:
        return TTORRENT_BRIDGE_STATE_DOWNLOADING;
    case lt::torrent_status::finished:
        return TTORRENT_BRIDGE_STATE_FINISHED;
    case lt::torrent_status::seeding:
        return TTORRENT_BRIDGE_STATE_SEEDING;
    case lt::torrent_status::checking_resume_data:
        return TTORRENT_BRIDGE_STATE_CHECKING_RESUME_DATA;
    default:
        return TTORRENT_BRIDGE_STATE_UNKNOWN;
    }
}

void ignore_shutdown_failure() noexcept {}

std::string system_error_message(std::string_view action, int error_number)
{
    return std::string(action) + ": " + std::error_code(error_number, std::generic_category()).message();
}

char hex_digit(unsigned char value) noexcept
{
    switch (value & 0x0fU) {
    case 0x0U:
        return '0';
    case 0x1U:
        return '1';
    case 0x2U:
        return '2';
    case 0x3U:
        return '3';
    case 0x4U:
        return '4';
    case 0x5U:
        return '5';
    case 0x6U:
        return '6';
    case 0x7U:
        return '7';
    case 0x8U:
        return '8';
    case 0x9U:
        return '9';
    case 0xaU:
        return 'a';
    case 0xbU:
        return 'b';
    case 0xcU:
        return 'c';
    case 0xdU:
        return 'd';
    case 0xeU:
        return 'e';
    default:
        return 'f';
    }
}

std::string hex_string(std::string_view bytes)
{
    std::string result;
    result.reserve(bytes.size() * 2U);
    for (char const byte : bytes) {
        auto const value = static_cast<unsigned char>(byte);
        result.push_back(hex_digit(value >> 4U));
        result.push_back(hex_digit(value));
    }
    return result;
}

std::uint32_t random_u32() noexcept
{
    return arc4random();
}

bool is_hex_character(char value) noexcept
{
    return (value >= '0' && value <= '9')
        || (value >= 'a' && value <= 'f');
}

bool is_canonical_torrent_id(std::string_view id) noexcept
{
    constexpr std::size_t kCanonicalIDLength = kCanonicalIDPrefix.size() + 32U;
    if (id.size() != kCanonicalIDLength || !id.starts_with(kCanonicalIDPrefix)) {
        return false;
    }

    id.remove_prefix(kCanonicalIDPrefix.size());
    return std::ranges::all_of(id, is_hex_character);
}

bool is_prefixed_hex_id(std::string_view id, std::string_view prefix, std::size_t hex_length) noexcept
{
    if (id.size() != prefix.size() + hex_length || !id.starts_with(prefix)) {
        return false;
    }

    id.remove_prefix(prefix.size());
    return std::ranges::all_of(id, is_hex_character);
}

bool is_resume_data_id(std::string_view id) noexcept
{
    return is_canonical_torrent_id(id)
        || is_prefixed_hex_id(id, "v1:", 40U)
        || is_prefixed_hex_id(id, "v2:", 64U);
}

std::string make_canonical_torrent_id()
{
    std::array<unsigned char, 16> bytes{};
    arc4random_buf(bytes.data(), bytes.size());

    std::string id(kCanonicalIDPrefix);
    id.reserve(kCanonicalIDPrefix.size() + 32U);
    for (unsigned char const byte : bytes) {
        id.push_back(hex_digit(byte >> 4U));
        id.push_back(hex_digit(byte));
    }
    return id;
}

std::string resume_temp_extension(std::uint32_t attempt)
{
    auto const now = std::chrono::steady_clock::now().time_since_epoch().count();
    return std::string(kTempExtension)
        + "."
        + std::to_string(now)
        + "."
        + std::to_string(random_u32())
        + "."
        + std::to_string(attempt);
}

void remove_file_quietly(fs::path const &path) noexcept
{
    std::error_code ignored;
    fs::remove(path, ignored);
}

void remove_file_at_quietly(int const directory_descriptor, std::string const &filename) noexcept
{
    if (filename.empty() || filename.contains('/') || filename.contains('\0')) {
        return;
    }

    static_cast<void>(::unlinkat(directory_descriptor, filename.c_str(), 0));
}

ResumeTempFileResult open_resume_temp_file(fs::path const &final_path)
{
    constexpr std::uint32_t kMaxTempCreateAttempts = 16;
    constexpr mode_t kOwnerReadWrite = S_IRUSR | S_IWUSR;

    for (std::uint32_t attempt = 0; attempt < kMaxTempCreateAttempts; ++attempt) {
        fs::path temp_path = final_path;
        temp_path += resume_temp_extension(attempt);

        int const descriptor = ::open(
            temp_path.c_str(),
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            kOwnerReadWrite
        );
        if (descriptor < 0) {
            if (errno == EEXIST) {
                continue;
            }
            return std::unexpected(system_error_message("Resume data temp file could not be created", errno));
        }

        UniqueFileDescriptor file(descriptor);
        if (::fchmod(file.get(), kOwnerReadWrite) != 0) {
            int const error_number = errno;
            std::error_code const close_error = file.close();
            if (close_error) {
                ignore_shutdown_failure();
            }
            remove_file_quietly(temp_path);
            return std::unexpected(system_error_message("Resume data permissions could not be restricted", error_number));
        }

        return ResumeTempFile{.path = std::move(temp_path), .descriptor = std::move(file)};
    }

    return std::unexpected("Resume data temp file could not be created.");
}

ResumeTempFileResult open_resume_temp_file_at(
    int const directory_descriptor,
    std::string const &final_filename
)
{
    constexpr std::uint32_t kMaxTempCreateAttempts = 16;
    constexpr mode_t kOwnerReadWrite = S_IRUSR | S_IWUSR;

    if (final_filename.empty() || final_filename.contains('/') || final_filename.contains('\0')) {
        return std::unexpected("Resume data filename is invalid.");
    }

    for (std::uint32_t attempt = 0; attempt < kMaxTempCreateAttempts; ++attempt) {
        std::string const temp_filename = final_filename + resume_temp_extension(attempt);
        int const descriptor = ::openat(
            directory_descriptor,
            temp_filename.c_str(),
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            kOwnerReadWrite
        );
        if (descriptor < 0) {
            if (errno == EEXIST) {
                continue;
            }
            return std::unexpected(system_error_message("Resume data temp file could not be created", errno));
        }

        UniqueFileDescriptor file(descriptor);
        if (::fchmod(file.get(), kOwnerReadWrite) != 0) {
            int const error_number = errno;
            std::error_code const close_error = file.close();
            if (close_error) {
                ignore_shutdown_failure();
            }
            remove_file_at_quietly(directory_descriptor, temp_filename);
            return std::unexpected(system_error_message("Resume data permissions could not be restricted", error_number));
        }

        return ResumeTempFile{.path = temp_filename, .descriptor = std::move(file)};
    }

    return std::unexpected("Resume data temp file could not be created.");
}

ResumeSaveResult write_all(int descriptor, std::span<char const> bytes)
{
    while (!bytes.empty()) {
        ssize_t const written = ::write(descriptor, bytes.data(), bytes.size());
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return std::unexpected(system_error_message("Resume data could not be written", errno));
        }
        if (written == 0) {
            return std::unexpected("Resume data could not be written.");
        }

        bytes = bytes.subspan(static_cast<std::size_t>(written));
    }

    return {};
}

ResumeSaveResult close_resume_temp_file(UniqueFileDescriptor &file)
{
    std::error_code const close_error = file.close();
    if (close_error) {
        return std::unexpected("Resume data could not be written: " + close_error.message());
    }
    return {};
}

ResumeSaveResult sync_file(int descriptor)
{
    while (::fsync(descriptor) != 0) {
        if (errno == EINTR) {
            continue;
        }
        return std::unexpected(system_error_message("Resume data could not be synced", errno));
    }

    return {};
}

ResumeSaveResult sync_directory(fs::path const &directory)
{
    UniqueFileDescriptor descriptor(::open(
        directory.c_str(),
        O_RDONLY | O_DIRECTORY | O_CLOEXEC
    ));
    if (!descriptor.is_valid()) {
        return std::unexpected(system_error_message("Resume data directory could not be opened", errno));
    }

    while (::fsync(descriptor.get()) != 0) {
        if (errno == EINTR) {
            continue;
        }
        return std::unexpected(system_error_message("Resume data directory could not be synced", errno));
    }

    std::error_code const close_error = descriptor.close();
    if (close_error) {
        return std::unexpected("Resume data directory could not be closed: " + close_error.message());
    }
    return {};
}

ResumeSaveResult sync_directory(int const directory_descriptor)
{
    while (::fsync(directory_descriptor) != 0) {
        if (errno == EINTR) {
            continue;
        }
        return std::unexpected(system_error_message("Resume data directory could not be synced", errno));
    }
    return {};
}

ResumeSaveResult write_owner_only_file_checked(fs::path const &path, std::string_view bytes)
{
    ResumeTempFileResult opened_temp_file = open_resume_temp_file(path);
    if (!opened_temp_file) {
        return std::unexpected(opened_temp_file.error());
    }

    ResumeTempFile temp_file = std::move(*opened_temp_file);
    fs::path const &temp_path = temp_file.path;
    ResumeSaveResult written = write_all(
        temp_file.descriptor.get(),
        std::span<char const>{bytes.data(), bytes.size()}
    );
    if (!written) {
        std::error_code const close_error = temp_file.descriptor.close();
        if (close_error) {
            ignore_shutdown_failure();
        }
        remove_file_quietly(temp_path);
        return written;
    }

    ResumeSaveResult synced = sync_file(temp_file.descriptor.get());
    if (!synced) {
        std::error_code const close_error = temp_file.descriptor.close();
        if (close_error) {
            ignore_shutdown_failure();
        }
        remove_file_quietly(temp_path);
        return synced;
    }

    ResumeSaveResult closed = close_resume_temp_file(temp_file.descriptor);
    if (!closed) {
        remove_file_quietly(temp_path);
        return closed;
    }

    if (::rename(temp_path.c_str(), path.c_str()) != 0) {
        int const error_number = errno;
        remove_file_quietly(temp_path);
        return std::unexpected(system_error_message("File could not be committed", error_number));
    }
    return {};
}

ResumeSaveResult write_owner_only_file_at_checked(
    int const directory_descriptor,
    std::string const &filename,
    std::string_view const bytes
)
{
    ResumeTempFileResult opened_temp_file = open_resume_temp_file_at(directory_descriptor, filename);
    if (!opened_temp_file) {
        return std::unexpected(opened_temp_file.error());
    }

    ResumeTempFile temp_file = std::move(*opened_temp_file);
    std::string const temp_filename = temp_file.path.string();
    ResumeSaveResult written = write_all(
        temp_file.descriptor.get(),
        std::span<char const>{bytes.data(), bytes.size()}
    );
    if (!written) {
        std::error_code const close_error = temp_file.descriptor.close();
        if (close_error) {
            ignore_shutdown_failure();
        }
        remove_file_at_quietly(directory_descriptor, temp_filename);
        return written;
    }

    ResumeSaveResult synced = sync_file(temp_file.descriptor.get());
    if (!synced) {
        std::error_code const close_error = temp_file.descriptor.close();
        if (close_error) {
            ignore_shutdown_failure();
        }
        remove_file_at_quietly(directory_descriptor, temp_filename);
        return synced;
    }

    ResumeSaveResult closed = close_resume_temp_file(temp_file.descriptor);
    if (!closed) {
        remove_file_at_quietly(directory_descriptor, temp_filename);
        return closed;
    }

    if (::renameat(
            directory_descriptor,
            temp_filename.c_str(),
            directory_descriptor,
            filename.c_str()
        ) != 0) {
        int const error_number = errno;
        remove_file_at_quietly(directory_descriptor, temp_filename);
        return std::unexpected(system_error_message("File could not be committed", error_number));
    }
    return {};
}

void clear_count_outputs(std::uint64_t *revision_out, int32_t *required_count_out) noexcept
{
    if (revision_out != nullptr) {
        *revision_out = 0;
    }
    if (required_count_out != nullptr) {
        *required_count_out = 0;
    }
}

std::string safe_c_string(char const *value)
{
    return value == nullptr ? std::string() : std::string(value);
}

std::string operation_label(lt::operation_t operation)
{
    char const *name = lt::operation_name(operation);
    return name == nullptr ? std::string("unknown") : std::string(name);
}

std::string alert_label(lt::alert const *alert)
{
    if (alert == nullptr) {
        return "unknown alert";
    }

    char const *name = alert->what();
    return name == nullptr ? std::string("unknown alert") : std::string(name);
}

std::string address_string(lt::address const &address)
{
    try {
        return address.to_string();
    } catch (...) {
        return {};
    }
}

std::string endpoint_string(lt::address const &address, int port)
{
    std::string const host = address_string(address);
    std::string const port_string = std::to_string(port);
    if (host.empty()) {
        return ":" + port_string;
    }
    if (address.is_v6()) {
        return "[" + host + "]:" + port_string;
    }
    return host + ":" + port_string;
}

std::vector<std::string> hash_keys(lt::info_hash_t const &hashes)
{
    std::vector<std::string> keys;
    if (hashes.has_v1()) {
        keys.push_back("v1:" + hex_string(hashes.v1.to_string()));
    }

    if (hashes.has_v2()) {
        keys.push_back("v2:" + hex_string(hashes.v2.to_string()));
    }

    return keys;
}

std::vector<std::string> hash_keys_with_requested(lt::info_hash_t const &hashes, std::string_view requested_id)
{
    std::vector<std::string> ids = hash_keys(hashes);
    if (!requested_id.empty() && std::ranges::find(ids, requested_id) == ids.end()) {
        ids.emplace_back(requested_id);
    }
    return ids;
}

void append_unique(std::vector<std::string> &values, std::string value)
{
    if (!value.empty() && std::ranges::find(values, value) == values.end()) {
        values.push_back(std::move(value));
    }
}

bool collections_overlap(std::vector<std::string> const &left, std::vector<std::string> const &right)
{
    return std::ranges::any_of(left, [&right](std::string const &value) {
        return std::ranges::find(right, value) != right.end();
    });
}

std::string removal_tombstone_suffix()
{
    return std::string(kResumeExtension) + std::string(kRemovalTombstoneExtension);
}

std::string make_removal_tombstone_filename()
{
    std::array<unsigned char, kRemovalTombstoneNonceBytes> bytes{};
    arc4random_buf(bytes.data(), bytes.size());

    std::string name(kRemovalTombstonePrefix);
    name.reserve(kRemovalTombstonePrefix.size() + (bytes.size() * 2U) + removal_tombstone_suffix().size());
    for (unsigned char const byte : bytes) {
        name.push_back(hex_digit(byte >> 4U));
        name.push_back(hex_digit(byte));
    }
    name += removal_tombstone_suffix();
    return name;
}

fs::path removal_tombstone_path(fs::path const &resume_directory)
{
    return resume_directory / make_removal_tombstone_filename();
}

bool is_removal_tombstone_path(fs::path const &path)
{
    std::string const name = path.filename().string();
    std::string const suffix = removal_tombstone_suffix();
    constexpr std::size_t kNonceHexLength = kRemovalTombstoneNonceBytes * 2U;
    if (
        name.size() != kRemovalTombstonePrefix.size() + kNonceHexLength + suffix.size()
        || !name.starts_with(kRemovalTombstonePrefix)
        || !name.ends_with(suffix)
    ) {
        return false;
    }

    std::string_view nonce(name);
    nonce.remove_prefix(kRemovalTombstonePrefix.size());
    nonce.remove_suffix(suffix.size());
    return std::ranges::all_of(nonce, is_hex_character);
}

std::optional<std::string> resume_id_from_resume_path(fs::path const &path)
{
    if (path.extension() != std::string(kResumeExtension)) {
        return std::nullopt;
    }

    std::string id = path.stem().string();
    return id.empty() ? std::nullopt : std::optional<std::string>(std::move(id));
}

ResumeIDListResult normalized_resume_ids(std::vector<std::string> const &ids)
{
    std::vector<std::string> normalized;
    for (std::string const &id : ids) {
        if (id.empty()) {
            continue;
        }
        if (!is_resume_data_id(id)) {
            return std::unexpected("Resume data identifier is invalid.");
        }
        append_unique(normalized, id);
    }

    return normalized;
}

TombstonePayloadResult tombstone_payload_from_bytes(std::vector<char> const &buffer)
{
    std::string_view remaining(buffer.data(), buffer.size());
    if (!remaining.starts_with("version=2\n")) {
        return std::unexpected("Removal tombstone version is invalid.");
    }
    remaining.remove_prefix(std::string_view("version=2\n").size());

    RemovalTombstonePayload payload;
    bool saw_state = false;
    bool saw_delete_files = false;
    bool saw_delete_partfile = false;
    while (!remaining.empty()) {
        std::size_t const newline = remaining.find('\n');
        std::string_view line = newline == std::string_view::npos
            ? remaining
            : remaining.substr(0, newline);
        if (line.empty()) {
            return std::unexpected("Removal tombstone contains an empty field.");
        }

        if (line == "state=resume_cleanup") {
            payload.state = RemovalTombstoneState::resume_cleanup;
            saw_state = true;
        } else if (line == "state=awaiting_payload_delete") {
            payload.state = RemovalTombstoneState::awaiting_payload_delete;
            saw_state = true;
        } else if (line == "delete_files=0") {
            payload.delete_files = false;
            saw_delete_files = true;
        } else if (line == "delete_files=1") {
            payload.delete_files = true;
            saw_delete_files = true;
        } else if (line == "delete_partfile=0") {
            payload.delete_partfile = false;
            saw_delete_partfile = true;
        } else if (line == "delete_partfile=1") {
            payload.delete_partfile = true;
            saw_delete_partfile = true;
        } else if (line.starts_with("id=")) {
            line.remove_prefix(std::string_view("id=").size());
            if (!is_resume_data_id(line)) {
                return std::unexpected("Removal tombstone contains an invalid identifier.");
            }
            append_unique(payload.ids, std::string(line));
        } else {
            return std::unexpected("Removal tombstone contains an unknown field.");
        }

        if (newline == std::string_view::npos) {
            remaining = {};
        } else {
            remaining.remove_prefix(newline + 1U);
        }
    }

    if (payload.ids.empty()) {
        return std::unexpected("Removal tombstone is empty.");
    }
    if (!saw_state || !saw_delete_files || !saw_delete_partfile) {
        return std::unexpected("Removal tombstone metadata is incomplete.");
    }
    return payload;
}

std::string tombstone_read_error(FileReadFailure failure)
{
    switch (failure) {
    case FileReadFailure::unreadable:
        return "Removal tombstone could not be read.";
    case FileReadFailure::empty:
        return "Removal tombstone is empty.";
    case FileReadFailure::too_large:
        return "Removal tombstone is too large.";
    }

    return "Removal tombstone could not be read.";
}

std::string tombstone_state_name(RemovalTombstoneState state)
{
    switch (state) {
    case RemovalTombstoneState::resume_cleanup:
        return "resume_cleanup";
    case RemovalTombstoneState::awaiting_payload_delete:
        return "awaiting_payload_delete";
    }
    return "resume_cleanup";
}

std::string tombstone_payload(
    std::vector<std::string> const &ids,
    RemovalTombstoneState state,
    bool delete_files,
    bool delete_partfile
)
{
    std::string payload;
    payload += "version=2\n";
    payload += "state=";
    payload += tombstone_state_name(state);
    payload.push_back('\n');
    payload += delete_files ? "delete_files=1\n" : "delete_files=0\n";
    payload += delete_partfile ? "delete_partfile=1\n" : "delete_partfile=0\n";
    for (std::string const &id : ids) {
        payload += "id=";
        payload += id;
        payload.push_back('\n');
    }
    return payload;
}

std::string joined_error_messages(std::vector<std::string> const &errors)
{
    if (errors.empty()) {
        return {};
    }
    if (errors.size() == 1U) {
        return errors.front();
    }

    std::string message = "Multiple resume operations failed";
    std::size_t appended = 0;
    for (std::string const &error : errors) {
        if (error.empty()) {
            continue;
        }
        message += appended == 0U ? ": " : "; ";
        message += error;
        ++appended;
        if (appended >= 8U && errors.size() > appended) {
            message += "; ";
            message += std::to_string(errors.size() - appended);
            message += " more";
            break;
        }
    }
    message.push_back('.');
    return message;
}

std::string primary_hash_key(lt::info_hash_t const &hashes)
{
    std::vector<std::string> const keys = hash_keys(hashes);
    return keys.empty() ? std::string() : keys.front();
}

bool resume_filename_matches_identity(std::string_view resume_id, lt::add_torrent_params const &params)
{
    std::string const expected_id = primary_hash_key(params.info_hashes);
    return !expected_id.empty() && resume_id == expected_id;
}

std::string torrent_alert_id(lt::torrent_alert const &alert)
{
    try {
        return primary_hash_key(alert.handle.info_hashes());
    } catch (...) {
        return {};
    }
}

std::string torrent_context(lt::torrent_alert const &alert)
{
    std::string const id = torrent_alert_id(alert);
    return id.empty() ? std::string() : " [" + id + "]";
}

ResumePolicySnapshot resume_policy_snapshot(
    TorrentIdentity const *identity,
    bool metadata_validation_pending,
    bool app_disabled_dht,
    bool app_disabled_lsd,
    bool app_disabled_peer_exchange
)
{
    ResumePolicySnapshot policy;
    if (identity == nullptr) {
        return policy;
    }

    policy.has_identity = true;
    policy.canonical_id = identity->canonical_id;
    policy.allows_non_https_trackers = identity->allows_non_https_trackers;
    policy.allows_non_https_web_seeds = identity->allows_non_https_web_seeds;
    policy.requires_https_trackers = identity->requires_https_trackers;
    policy.requires_https_web_seeds = identity->requires_https_web_seeds;
    policy.dht_enabled_by_user = identity->dht_enabled_by_user;
    policy.dht_disabled_by_user = identity->dht_disabled_by_user;
    policy.peer_exchange_enabled_by_user = identity->peer_exchange_enabled_by_user;
    policy.peer_exchange_disabled_by_user = identity->peer_exchange_disabled_by_user;
    policy.lsd_enabled_by_user = identity->lsd_enabled_by_user;
    policy.lsd_disabled_by_user = identity->lsd_disabled_by_user;
    policy.dht_locked_by_source = identity->dht_locked_by_source;
    policy.peer_exchange_locked_by_source = identity->peer_exchange_locked_by_source;
    policy.lsd_locked_by_source = identity->lsd_locked_by_source;
    policy.metadata_validation_pending = metadata_validation_pending;
    policy.allow_pre_metadata_dht = identity->allow_pre_metadata_dht;
    policy.intended_default_dont_download = identity->intended_default_dont_download;
    policy.app_disabled_dht = app_disabled_dht;
    policy.app_disabled_lsd = app_disabled_lsd;
    policy.app_disabled_peer_exchange = app_disabled_peer_exchange;
    policy.queue_priority = identity->queue_priority;
    policy.queue_rank = identity->queue_rank;
    policy.source_trackers = identity->source_trackers;
    policy.source_web_seeds = identity->source_web_seeds;
    policy.intended_file_priorities = identity->intended_file_priorities;
    return policy;
}

std::vector<char> encoded_resume_data(
    lt::add_torrent_params const &params,
    ResumePolicySnapshot const &policy
)
{
    lt::entry resume_entry = lt::write_resume_data(params);
    if (policy.has_identity && is_canonical_torrent_id(policy.canonical_id)) {
        resume_entry.dict().insert_or_assign(
            std::string(kCanonicalIDResumeKey),
            lt::entry(policy.canonical_id)
        );
    }
    if (policy.metadata_validation_pending) {
        resume_entry.dict().insert_or_assign(
            std::string(kMetadataValidationPendingResumeKey),
            lt::entry(1)
        );
    }
    if (policy.metadata_validation_pending && policy.allow_pre_metadata_dht) {
        resume_entry.dict().insert_or_assign(
            std::string(kAllowPreMetadataDHTResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.allows_non_https_trackers) {
        resume_entry.dict().insert_or_assign(
            std::string(kAllowNonHTTPSTrackersResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.allows_non_https_web_seeds) {
        resume_entry.dict().insert_or_assign(
            std::string(kAllowNonHTTPSWebSeedsResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.requires_https_trackers) {
        resume_entry.dict().insert_or_assign(
            std::string(kRequireHTTPSTrackersResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.requires_https_web_seeds) {
        resume_entry.dict().insert_or_assign(
            std::string(kRequireHTTPSWebSeedsResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.dht_enabled_by_user) {
        resume_entry.dict().insert_or_assign(
            std::string(kEnableDHTResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.dht_disabled_by_user) {
        resume_entry.dict().insert_or_assign(
            std::string(kDisableDHTResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.app_disabled_dht) {
        resume_entry.dict().insert_or_assign(
            std::string(kAppDisabledDHTResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.peer_exchange_enabled_by_user) {
        resume_entry.dict().insert_or_assign(
            std::string(kEnablePeerExchangeResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.peer_exchange_disabled_by_user) {
        resume_entry.dict().insert_or_assign(
            std::string(kDisablePeerExchangeResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.lsd_enabled_by_user) {
        resume_entry.dict().insert_or_assign(
            std::string(kEnableLSDResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.lsd_disabled_by_user) {
        resume_entry.dict().insert_or_assign(
            std::string(kDisableLSDResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && policy.app_disabled_lsd) {
        resume_entry.dict().insert_or_assign(
            std::string(kAppDisabledLSDResumeKey),
            lt::entry(1)
        );
    }
    if (policy.has_identity && is_valid_queue_priority(policy.queue_priority)
        && policy.queue_priority != TTORRENT_QUEUE_PRIORITY_NORMAL) {
        resume_entry.dict().insert_or_assign(
            std::string(kQueuePriorityResumeKey),
            lt::entry(policy.queue_priority)
        );
    }
    if (policy.has_identity && is_valid_queue_rank(policy.queue_rank)) {
        resume_entry.dict().insert_or_assign(
            std::string(kQueueRankResumeKey),
            lt::entry(policy.queue_rank)
        );
    }

    std::vector<char> encoded;
    lt::bencode(std::back_inserter(encoded), resume_entry);
    return encoded;
}

std::vector<char> encoded_resume_data(
    lt::add_torrent_params const &params,
    TorrentIdentity const *identity,
    bool metadata_validation_pending,
    bool app_disabled_dht,
    bool app_disabled_lsd
)
{
    return encoded_resume_data(
        params,
        resume_policy_snapshot(identity, metadata_validation_pending, app_disabled_dht, app_disabled_lsd, false)
    );
}

std::string canonical_id_from_resume_data(std::vector<char> const &buffer)
{
    lt::error_code error;
    lt::bdecode_node const root = lt::bdecode(
        lt::span<char const>(buffer.data(), static_cast<int>(buffer.size())),
        error
    );
    if (error || root.type() != lt::bdecode_node::dict_t) {
        return {};
    }

    lt::string_view const key(kCanonicalIDResumeKey.data(), kCanonicalIDResumeKey.size());
    lt::string_view const value = root.dict_find_string_value(key);
    if (value.empty()) {
        return {};
    }
    std::string id(value.data(), value.size());
    return is_canonical_torrent_id(id) ? id : std::string();
}

bool resume_data_bool(std::vector<char> const &buffer, std::string_view key_name)
{
    lt::error_code error;
    lt::bdecode_node const root = lt::bdecode(
        lt::span<char const>(buffer.data(), static_cast<int>(buffer.size())),
        error
    );
    if (error || root.type() != lt::bdecode_node::dict_t) {
        return false;
    }

    lt::string_view const key(key_name.data(), key_name.size());
    return root.dict_find_int_value(key, 0) != 0;
}

int32_t resume_data_int(std::vector<char> const &buffer, std::string_view key_name, int32_t default_value)
{
    lt::error_code error;
    lt::bdecode_node const root = lt::bdecode(
        lt::span<char const>(buffer.data(), static_cast<int>(buffer.size())),
        error
    );
    if (error || root.type() != lt::bdecode_node::dict_t) {
        return default_value;
    }

    lt::string_view const key(key_name.data(), key_name.size());
    return static_cast<int32_t>(root.dict_find_int_value(key, default_value));
}

bool metadata_validation_pending_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kMetadataValidationPendingResumeKey);
}

bool allow_pre_metadata_dht_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kAllowPreMetadataDHTResumeKey);
}

bool allow_non_https_trackers_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kAllowNonHTTPSTrackersResumeKey);
}

bool allow_non_https_web_seeds_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kAllowNonHTTPSWebSeedsResumeKey);
}

bool require_https_trackers_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kRequireHTTPSTrackersResumeKey);
}

bool require_https_web_seeds_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kRequireHTTPSWebSeedsResumeKey);
}

bool enable_dht_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kEnableDHTResumeKey);
}

bool disable_dht_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kDisableDHTResumeKey);
}

bool app_disabled_dht_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kAppDisabledDHTResumeKey);
}

bool enable_peer_exchange_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kEnablePeerExchangeResumeKey);
}

bool disable_peer_exchange_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kDisablePeerExchangeResumeKey);
}

bool enable_lsd_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kEnableLSDResumeKey);
}

bool disable_lsd_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kDisableLSDResumeKey);
}

bool app_disabled_lsd_from_resume_data(std::vector<char> const &buffer)
{
    return resume_data_bool(buffer, kAppDisabledLSDResumeKey);
}

int32_t queue_priority_from_resume_data(std::vector<char> const &buffer)
{
    int32_t const priority = resume_data_int(
        buffer,
        kQueuePriorityResumeKey,
        TTORRENT_QUEUE_PRIORITY_NORMAL
    );
    return is_valid_queue_priority(priority) ? priority : TTORRENT_QUEUE_PRIORITY_NORMAL;
}

int32_t queue_rank_from_resume_data(std::vector<char> const &buffer)
{
    int32_t const rank = resume_data_int(
        buffer,
        kQueueRankResumeKey,
        kUnsetQueueRank
    );
    return is_valid_queue_rank(rank) ? rank : kUnsetQueueRank;
}

void copy_primary_hash_key(std::span<char> destination, lt::info_hash_t const &hashes) noexcept
{
    if (hashes.has_v1()) {
        copy_hash_key(destination, "v1:", hashes.v1);
        return;
    }

    if (hashes.has_v2()) {
        copy_hash_key(destination, "v2:", hashes.v2);
        return;
    }

    copy_string_dynamic(destination, "");
}

TorrentIdentity *identity_from_client_data(lt::client_data_t const &userdata) noexcept
{
    try {
        auto *const token = userdata.get<TorrentIdentityToken>();
        return token == nullptr
            ? nullptr
            : token->active_identity.load(std::memory_order_acquire);
    } catch (...) {
        return nullptr;
    }
}

TorrentIdentity *identity_from_handle(lt::torrent_handle const &handle) noexcept
{
    try {
        return identity_from_client_data(handle.userdata());
    } catch (...) {
        return nullptr;
    }
}

TorrentIdentity *identity_from_resume_alert(lt::save_resume_data_alert const &alert) noexcept
{
    if (TorrentIdentity *identity = identity_from_client_data(alert.params.userdata)) {
        return identity;
    }

    return identity_from_handle(alert.handle);
}

std::string identity_snapshot_id(TorrentIdentity const *identity, lt::info_hash_t const &hashes)
{
    if (identity != nullptr && is_canonical_torrent_id(identity->canonical_id)) {
        return identity->canonical_id;
    }
    return primary_hash_key(hashes);
}

bool hash_matches(lt::info_hash_t const &hashes, std::string_view id)
{
    if (id.empty()) {
        return false;
    }

    std::vector<std::string> const keys = hash_keys(hashes);
    return std::ranges::any_of(keys, [id](std::string const &key) {
        return key == id;
    });
}

double download_progress(lt::torrent_status const &status)
{
    if (status.is_seeding || status.is_finished) {
        return 1.0;
    }

    if (status.total_wanted <= 0) {
        return 0.0;
    }

    return std::clamp(
        static_cast<double>(status.total_wanted_done) / static_cast<double>(status.total_wanted),
        0.0,
        1.0
    );
}

namespace {

std::uint8_t content_kind_for_torrent_info(
    std::shared_ptr<lt::torrent_info const> const &torrent_file
) noexcept
{
    if (!torrent_file || !torrent_file->is_valid()) {
        return TTORRENT_CONTENT_KIND_UNKNOWN;
    }

    try {
        lt::file_storage const &layout = torrent_file->layout();
        if (layout.num_files() <= 0) {
            return TTORRENT_CONTENT_KIND_UNKNOWN;
        }
        if (layout.num_files() > 1) {
            return TTORRENT_CONTENT_KIND_DIRECTORY;
        }

        // A v1 multi-file torrent can contain one file. Comparing the complete
        // metainfo path with the root name preserves that distinction instead
        // of guessing from file count or from a version-like name suffix.
        return layout.file_path(lt::file_index_t(0)) == layout.name()
            ? TTORRENT_CONTENT_KIND_SINGLE_FILE
            : TTORRENT_CONTENT_KIND_DIRECTORY;
    } catch (...) {
        return TTORRENT_CONTENT_KIND_UNKNOWN;
    }
}

} // namespace

TTorrentSnapshot snapshot_from_status(
    lt::torrent_status const &status,
    TorrentIdentity const *identity
)
{
    TTorrentSnapshot snapshot{};
    copy_string(std::span{snapshot.id}, primary_hash_key(status.info_hashes));
    copy_string(std::span{snapshot.info_hash}, primary_hash_key(status.info_hashes));
    copy_string(std::span{snapshot.name}, status.name.empty() ? std::string_view("Metadata pending") : std::string_view(status.name));
    copy_string(std::span{snapshot.save_path}, status.save_path);
    copy_string(std::span{snapshot.error}, status.errc ? status.errc.message() : std::string());
    std::shared_ptr<lt::torrent_info const> const torrent_file = status.torrent_file.lock();
    snapshot.content_kind = content_kind_for_torrent_info(torrent_file);
    if (torrent_file && torrent_file->is_valid()) {
        snapshot.total_size = torrent_file->total_size();
        snapshot.private_torrent = bridge_bool(torrent_file->priv());
    } else {
        snapshot.total_size = status.total;
    }
    if (identity != nullptr) {
        copy_string(std::span{snapshot.comment}, identity->comment);
        snapshot.created_time = static_cast<int64_t>(identity->creation_date);
    }
    snapshot.progress = download_progress(status);
    snapshot.total_done = status.total_wanted_done;
    snapshot.total_wanted = status.total_wanted;
    snapshot.total_upload = status.total_upload;
    snapshot.total_download = status.total_download;
    snapshot.total_payload_upload = status.total_payload_upload;
    snapshot.total_payload_download = status.total_payload_download;
    snapshot.all_time_upload = status.all_time_upload;
    snapshot.all_time_download = status.all_time_download;
    snapshot.added_time = static_cast<int64_t>(status.added_time);
    snapshot.completed_time = static_cast<int64_t>(status.completed_time);
    snapshot.download_rate = status.download_rate;
    snapshot.upload_rate = status.upload_rate;
    snapshot.download_payload_rate = status.download_payload_rate;
    snapshot.upload_payload_rate = status.upload_payload_rate;
    snapshot.peers = status.num_peers;
    snapshot.known_peers = status.list_peers;
    snapshot.seeds = status.num_seeds;
    snapshot.state = bridge_torrent_state(status.state);
    snapshot.queue_position = static_cast<int>(status.queue_position);
    snapshot.queue_priority = TTORRENT_QUEUE_PRIORITY_NORMAL;
    snapshot.paused = bridge_bool(static_cast<bool>(status.flags & lt::torrent_flags::paused));
    snapshot.auto_managed = bridge_bool(static_cast<bool>(status.flags & lt::torrent_flags::auto_managed));
    snapshot.seeding = bridge_bool(status.is_seeding);
    snapshot.finished = bridge_bool(status.is_finished);
    snapshot.has_metadata = bridge_bool(status.has_metadata);
    return snapshot;
}

bool tracker_info_failed(lt::announce_infohash const &info)
{
    return info.fails > 0 || static_cast<bool>(info.last_error);
}

void merge_tracker_info(
    TTorrentTrackerSnapshot &snapshot,
    lt::announce_infohash const &info,
    std::string &message,
    TrackerEndpointAggregate &aggregate
)
{
    ++aggregate.relevant_count;
    snapshot.updating = bridge_bool(bridge_bool(snapshot.updating) || info.updating);

    if (info.scrape_complete >= 0) {
        snapshot.scrape_seeders = std::max(snapshot.scrape_seeders, info.scrape_complete);
    }
    if (info.scrape_incomplete >= 0) {
        snapshot.scrape_leechers = std::max(snapshot.scrape_leechers, info.scrape_incomplete);
    }
    if (info.scrape_downloaded >= 0) {
        snapshot.scrape_downloaded = std::max(snapshot.scrape_downloaded, info.scrape_downloaded);
    }

    if (tracker_info_failed(info)) {
        ++aggregate.failed_count;
        aggregate.max_fail_count = std::max(aggregate.max_fail_count, static_cast<int32_t>(info.fails));
        if (aggregate.first_failure_message.empty()) {
            if (info.last_error) {
                aggregate.first_failure_message = info.last_error.message();
            } else if (!info.message.empty()) {
                aggregate.first_failure_message = info.message;
            }
        }
        return;
    }

    if (message.empty() && !info.message.empty()) {
        message = info.message;
    }
}

TTorrentTrackerSnapshot tracker_snapshot_from_entry(lt::announce_entry const &entry, lt::info_hash_t const &hashes)
{
    TTorrentTrackerSnapshot snapshot{};
    snapshot.scrape_seeders = -1;
    snapshot.scrape_leechers = -1;
    snapshot.scrape_downloaded = -1;
    snapshot.tier = static_cast<int32_t>(entry.tier);
    snapshot.verified = bridge_bool(entry.verified);
    snapshot.enabled = bridge_bool(entry.endpoints.empty());
    copy_string(std::span{snapshot.url}, entry.url);

    std::string message;
    TrackerEndpointAggregate aggregate;
    for (lt::announce_endpoint const &endpoint : entry.endpoints) {
        snapshot.enabled = bridge_bool(bridge_bool(snapshot.enabled) || endpoint.enabled);
        if (!endpoint.enabled) {
            continue;
        }
        for (lt::protocol_version const protocol : {lt::protocol_version::V1, lt::protocol_version::V2}) {
            if (!hashes.has(protocol)) {
                continue;
            }
            merge_tracker_info(
                snapshot,
                endpoint.info_hashes.at(static_cast<std::size_t>(protocol)),
                message,
                aggregate
            );
        }
    }

    snapshot.has_error = bridge_bool(
        aggregate.relevant_count > 0 && aggregate.failed_count == aggregate.relevant_count
    );
    if (bridge_bool(snapshot.has_error)) {
        snapshot.fail_count = aggregate.max_fail_count;
        if (message.empty()) {
            message = std::move(aggregate.first_failure_message);
        }
    } else {
        snapshot.fail_count = 0;
    }
    copy_string(std::span{snapshot.message}, message);
    return snapshot;
}

std::optional<std::string> normalized_tracker_host(std::string const &url)
{
    if (std::ranges::any_of(url, [](unsigned char const character) {
            return character <= 0x20U || character == 0x7fU;
        })) {
        return std::nullopt;
    }

    std::size_t const scheme_separator = url.find("://");
    if (scheme_separator == std::string::npos || scheme_separator == 0U) {
        return std::nullopt;
    }

    auto const valid_scheme_character = [](unsigned char const character) noexcept {
        return is_ascii_alpha(character) || is_ascii_digit(character)
            || character == '+' || character == '-' || character == '.';
    };
    if (!is_ascii_alpha(static_cast<unsigned char>(url.front()))
        || !std::ranges::all_of(
            std::string_view(url).substr(1U, scheme_separator - 1U),
            valid_scheme_character
        )) {
        return std::nullopt;
    }

    std::size_t const authority_start = scheme_separator + 3U;
    std::size_t const authority_end = url.find_first_of("/?#", authority_start);
    std::string_view authority = std::string_view(url).substr(
        authority_start,
        (authority_end == std::string::npos ? url.size() : authority_end) - authority_start
    );
    if (authority.empty()) {
        return std::nullopt;
    }

    if (std::size_t const userinfo_end = authority.rfind('@'); userinfo_end != std::string_view::npos) {
        authority.remove_prefix(userinfo_end + 1U);
    }
    if (authority.empty()) {
        return std::nullopt;
    }

    std::string_view host;
    std::string_view port;
    bool const bracketed_ipv6 = authority.front() == '[';
    if (bracketed_ipv6) {
        std::size_t const bracket_end = authority.find(']');
        if (bracket_end == std::string_view::npos || bracket_end == 1U) {
            return std::nullopt;
        }
        host = authority.substr(1U, bracket_end - 1U);
        std::string_view const suffix = authority.substr(bracket_end + 1U);
        if (!suffix.empty()) {
            if (suffix.front() != ':') {
                return std::nullopt;
            }
            port = suffix.substr(1U);
        }
    } else {
        std::size_t const colon = authority.rfind(':');
        if (colon == std::string_view::npos) {
            host = authority;
        } else {
            if (authority.find(':') != colon) {
                return std::nullopt;
            }
            host = authority.substr(0U, colon);
            port = authority.substr(colon + 1U);
        }
    }

    if (!port.empty()) {
        unsigned int value = 0U;
        for (unsigned char const character : port) {
            if (!is_ascii_digit(character)) {
                return std::nullopt;
            }
            value = (value * 10U) + static_cast<unsigned int>(character - '0');
            if (value > 65'535U) {
                return std::nullopt;
            }
        }
        if (value == 0U) {
            return std::nullopt;
        }
    } else if (authority.ends_with(':')) {
        return std::nullopt;
    }

    if (host.empty() || host.size() >= static_cast<std::size_t>(TTORRENT_TRACKER_HOST_CAPACITY)
        || std::ranges::any_of(host, [](unsigned char character) {
            return character <= 0x20U || character == 0x7fU
                || character == '/' || character == '?' || character == '#'
                || character == '[' || character == ']' || character == '@'
                || character == '\\' || character == '\'' || character == '"';
        })) {
        return std::nullopt;
    }
    if (!bracketed_ipv6 && !std::ranges::all_of(host, [](unsigned char const character) {
            return is_ascii_alpha(character) || is_ascii_digit(character)
                || character == '-' || character == '.';
        })) {
        return std::nullopt;
    }
    std::string normalized;
    normalized.reserve(host.size());
    if (bracketed_ipv6) {
        std::string_view address_host = host;
        std::string_view zone;
        if (std::size_t const zone_separator = host.find("%25"); zone_separator != std::string_view::npos) {
            address_host = host.substr(0U, zone_separator);
            zone = host.substr(zone_separator + 3U);
            if (address_host.empty() || zone.empty()) {
                return std::nullopt;
            }

            for (std::size_t index = 0U; index < zone.size();) {
                auto const character = static_cast<unsigned char>(zone.at(index));
                if (is_ascii_unreserved(character)) {
                    ++index;
                    continue;
                }
                if (character != '%' || index + 2U >= zone.size()
                    || !is_ascii_hex_digit(static_cast<unsigned char>(zone.at(index + 1U)))
                    || !is_ascii_hex_digit(static_cast<unsigned char>(zone.at(index + 2U)))) {
                    return std::nullopt;
                }
                index += 3U;
            }
        }

        in6_addr address{};
        std::string const host_string(address_host);
        if (::inet_pton(AF_INET6, host_string.c_str(), &address) != 1) {
            return std::nullopt;
        }
        std::ranges::transform(address_host, std::back_inserter(normalized), ascii_lower);
        if (!zone.empty()) {
            normalized.append("%25");
            normalized.append(zone);
        }
    } else {
        std::ranges::transform(host, std::back_inserter(normalized), ascii_lower);
        if (normalized.ends_with('.')) {
            normalized.pop_back();
        }
    }
    if (normalized.empty()) {
        return std::nullopt;
    }
    return normalized;
}

TTorrentWebSeedSnapshot web_seed_snapshot(std::string const &url)
{
    TTorrentWebSeedSnapshot snapshot{};
    copy_string(std::span{snapshot.url}, url);
    return snapshot;
}

void append_web_seed_snapshots(
    std::vector<TTorrentWebSeedSnapshot> &snapshots,
    std::set<std::string> const &urls,
    std::size_t limit
)
{
    for (std::string const &url : urls) {
        if (snapshots.size() >= limit) {
            return;
        }
        snapshots.push_back(web_seed_snapshot(url));
    }
}

TTorrentFileSnapshot file_snapshot_from_files(
    lt::filenames const &files,
    lt::file_index_t file,
    int32_t priority
)
{
    TTorrentFileSnapshot snapshot{};
    std::int64_t const size = files.file_size(file);
    copy_string(std::span{snapshot.path}, files.file_path(file));
    snapshot.size = size;
    snapshot.downloaded = 0;
    snapshot.progress = size <= 0 ? 1.0 : 0.0;
    snapshot.index = static_cast<int32_t>(file);
    snapshot.priority = priority;
    snapshot.pad_file = bridge_bool(files.pad_file_at(file));
    return snapshot;
}

bool is_web_seed_peer(lt::peer_info const &peer) noexcept
{
    return peer.connection_type == lt::peer_info::web_seed;
}

TTorrentPeerSourceSnapshot peer_source_snapshot(std::vector<lt::peer_info> const &peers) noexcept
{
    TTorrentPeerSourceSnapshot snapshot{};
    snapshot.connected = static_cast<int32_t>(std::min(
        peers.size(),
        static_cast<std::size_t>(std::numeric_limits<int32_t>::max())
    ));

    for (lt::peer_info const &peer : peers) {
        bool has_source = false;
        if (static_cast<bool>(peer.source & lt::peer_info::tracker)) {
            ++snapshot.tracker;
            has_source = true;
        }
        if (static_cast<bool>(peer.source & lt::peer_info::dht)) {
            ++snapshot.dht;
            has_source = true;
        }
        if (static_cast<bool>(peer.source & lt::peer_info::pex)) {
            ++snapshot.peer_exchange;
            has_source = true;
        }
        if (static_cast<bool>(peer.source & lt::peer_info::lsd)) {
            ++snapshot.local_service_discovery;
            has_source = true;
        }
        if (static_cast<bool>(peer.source & lt::peer_info::resume_data)) {
            ++snapshot.resume_data;
            has_source = true;
        }
        if (static_cast<bool>(peer.source & lt::peer_info::incoming)) {
            ++snapshot.incoming;
            has_source = true;
        }
        if (is_web_seed_peer(peer)) {
            ++snapshot.web_seed;
            has_source = true;
        }
        if (!has_source) {
            ++snapshot.other;
        }
    }

    return snapshot;
}

bool is_https_url(std::string_view url) noexcept
{
    auto const separator = std::ranges::find(url, ':');
    if (separator == url.end()) {
        return false;
    }

    std::string_view const scheme(url.begin(), static_cast<std::size_t>(std::distance(url.begin(), separator)));
    if (scheme.size() != std::string_view("https").size()) {
        return false;
    }

    return std::ranges::equal(scheme, std::string_view("https"), [](char left, char right) {
        return ascii_lower(static_cast<unsigned char>(left)) == ascii_lower(static_cast<unsigned char>(right));
    });
}

TorrentSourceCounts torrent_source_counts(lt::add_torrent_params const &params)
{
    TorrentSourceCounts counts{};
    counts.tracker_count = static_cast<int32_t>(std::min(
        params.trackers.size(),
        static_cast<std::size_t>(std::numeric_limits<int32_t>::max())
    ));
    counts.https_tracker_count = static_cast<int32_t>(std::ranges::count_if(params.trackers, [](std::string const &url) {
        return is_https_url(url);
    }));
    counts.web_seed_count = static_cast<int32_t>(std::min(
        params.url_seeds.size(),
        static_cast<std::size_t>(std::numeric_limits<int32_t>::max())
    ));
    counts.https_web_seed_count = static_cast<int32_t>(std::ranges::count_if(params.url_seeds, [](std::string const &url) {
        return is_https_url(url);
    }));
    return counts;
}

BridgeResult validate_torrent_sources(lt::add_torrent_params const &params)
{
    TorrentSourceCounts const counts = torrent_source_counts(params);
    if (counts.tracker_count > TTORRENT_MAX_TRACKER_COUNT) {
        return bridge_error(
            2,
            "The torrent contains too many trackers. The maximum is "
                + std::to_string(TTORRENT_MAX_TRACKER_COUNT)
                + "."
        );
    }
    if (counts.web_seed_count > TTORRENT_MAX_WEB_SEED_COUNT) {
        return bridge_error(
            2,
            "The torrent contains too many web seeds. The maximum is "
                + std::to_string(TTORRENT_MAX_WEB_SEED_COUNT)
                + "."
        );
    }

    return {};
}

template <typename Strings>
bool filter_non_https_strings(Strings &strings)
{
    Strings filtered;
    filtered.reserve(strings.size());
    std::ranges::copy_if(strings, std::back_inserter(filtered), [](std::string const &url) {
        return is_https_url(url);
    });
    bool const changed = filtered.size() != strings.size();
    strings = std::move(filtered);
    return changed;
}

bool filter_non_https_sources(
    lt::add_torrent_params &params,
    bool const require_https_trackers,
    bool const require_https_web_seeds
)
{
    bool changed = false;

    if (require_https_trackers && !params.trackers.empty()) {
        std::vector<std::string> filtered_trackers;
        std::vector<int> filtered_tiers;
        filtered_trackers.reserve(params.trackers.size());
        filtered_tiers.reserve(params.tracker_tiers.size());
        auto tier = params.tracker_tiers.begin();
        for (std::string const &tracker : params.trackers) {
            if (!is_https_url(tracker)) {
                changed = true;
                if (tier != params.tracker_tiers.end()) {
                    ++tier;
                }
                continue;
            }
            filtered_trackers.push_back(tracker);
            if (!params.tracker_tiers.empty()) {
                filtered_tiers.push_back(tier != params.tracker_tiers.end() ? *tier : 0);
            }
            if (tier != params.tracker_tiers.end()) {
                ++tier;
            }
        }
        params.trackers = std::move(filtered_trackers);
        params.tracker_tiers = std::move(filtered_tiers);
    }

    if (require_https_web_seeds) {
        changed = filter_non_https_strings(params.url_seeds) || changed;
    }
    return changed;
}

void remember_source_policy_tracker(TorrentIdentity &identity, lt::announce_entry const &tracker)
{
    if (identity.source_trackers.size() >= static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT)) {
        return;
    }
    if (std::ranges::any_of(identity.source_trackers, [&](lt::announce_entry const &stored) {
            return stored.url == tracker.url;
        })) {
        return;
    }
    identity.source_trackers.push_back(tracker);
}

void remember_source_policy_web_seed(TorrentIdentity &identity, std::string const &web_seed)
{
    if (identity.source_web_seeds.size() >= static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT)) {
        return;
    }
    if (std::ranges::find(identity.source_web_seeds, web_seed) != identity.source_web_seeds.end()) {
        return;
    }
    identity.source_web_seeds.push_back(web_seed);
}

void remember_source_policy_sources(TorrentIdentity &identity, lt::add_torrent_params const &params)
{
    auto tier = params.tracker_tiers.begin();
    for (std::string const &tracker_url : params.trackers) {
        lt::announce_entry tracker(tracker_url);
        tracker.tier = static_cast<std::uint8_t>(tier != params.tracker_tiers.end() ? *tier : 0);
        remember_source_policy_tracker(identity, tracker);
        if (tier != params.tracker_tiers.end()) {
            ++tier;
        }
    }

    for (std::string const &url_seed : params.url_seeds) {
        remember_source_policy_web_seed(identity, url_seed);
    }
}

void restore_source_policy_sources(lt::add_torrent_params &params, TorrentIdentity const *identity)
{
    restore_source_policy_sources(params, resume_policy_snapshot(identity, false, false, false, false));
}

void restore_source_policy_sources(lt::add_torrent_params &params, ResumePolicySnapshot const &policy)
{
    if (!policy.has_identity
        || (policy.source_trackers.empty() && policy.source_web_seeds.empty())) {
        return;
    }

    std::set<std::string> tracker_urls(params.trackers.begin(), params.trackers.end());
    std::size_t tracker_count = static_cast<std::size_t>(torrent_source_counts(params).tracker_count);
    for (lt::announce_entry const &tracker : policy.source_trackers) {
        if (tracker_count >= static_cast<std::size_t>(TTORRENT_MAX_TRACKER_COUNT)) {
            break;
        }
        if (tracker_urls.insert(tracker.url).second) {
            params.trackers.push_back(tracker.url);
            params.tracker_tiers.push_back(tracker.tier);
            ++tracker_count;
        }
    }

    std::set<std::string> url_seed_urls(params.url_seeds.begin(), params.url_seeds.end());
    std::size_t web_seed_count = static_cast<std::size_t>(torrent_source_counts(params).web_seed_count);
    for (std::string const &web_seed : policy.source_web_seeds) {
        if (web_seed_count >= static_cast<std::size_t>(TTORRENT_MAX_WEB_SEED_COUNT)) {
            break;
        }
        if (url_seed_urls.insert(web_seed).second) {
            params.url_seeds.push_back(web_seed);
            ++web_seed_count;
        }
    }
}

bool should_strip_resume_peer_cache(
    lt::add_torrent_params const &params,
    TorrentIdentity const *identity,
    bool app_disabled_dht
) noexcept
{
    bool const dht_disabled =
        app_disabled_dht
        || static_cast<bool>(params.flags & lt::torrent_flags::disable_dht)
        || (identity != nullptr && (identity->dht_disabled_by_user || identity->dht_locked_by_source));
    if (!dht_disabled) {
        return false;
    }

    return params.trackers.empty();
}

bool should_strip_resume_peer_cache(
    lt::add_torrent_params const &params,
    ResumePolicySnapshot const &policy
) noexcept
{
    bool const dht_disabled =
        policy.app_disabled_dht
        || static_cast<bool>(params.flags & lt::torrent_flags::disable_dht)
        || (policy.has_identity && (policy.dht_disabled_by_user || policy.dht_locked_by_source));
    if (!dht_disabled) {
        return false;
    }

    return params.trackers.empty();
}

void strip_resume_peer_cache(lt::add_torrent_params &params) noexcept
{
    params.peers.clear();
    params.banned_peers.clear();
}

void sanitize_magnet_endpoint_hints(lt::add_torrent_params &params)
{
    sanitize_resume_endpoint_hints(params);
    params.peers.clear();
}

TorrentLoadResult parse_sanitized_magnet(std::string_view const magnet)
{
    if (magnet.size() > kMaxMagnetURIBytes) {
        return std::unexpected(BridgeError{.code = 2, .message = "The magnet link is too large."});
    }

    lt::error_code parse_error;
    lt::add_torrent_params params = lt::parse_magnet_uri(std::string(magnet), parse_error);
    if (parse_error) {
        return std::unexpected(BridgeError{.code = 2, .message = parse_error.message()});
    }

    sanitize_magnet_endpoint_hints(params);
    return params;
}

void sanitize_resume_endpoint_hints(lt::add_torrent_params &params) noexcept
{
    params.dht_nodes.clear();
}

lt::settings_pack make_settings()
{
    lt::settings_pack settings;
    settings.set_str(lt::settings_pack::user_agent, std::string(kNetworkClientIdentity));
    settings.set_str(lt::settings_pack::handshake_client_version, std::string(kNetworkClientIdentity));
    settings.set_str(lt::settings_pack::listen_interfaces, "");
    settings.set_bool(lt::settings_pack::enable_lsd, false);
    settings.set_bool(lt::settings_pack::enable_upnp, false);
    settings.set_bool(lt::settings_pack::enable_natpmp, false);
    settings.set_bool(lt::settings_pack::enable_dht, false);
    settings.set_bool(lt::settings_pack::dont_count_slow_torrents, false);
    settings.set_bool(lt::settings_pack::enable_outgoing_tcp, false);
    settings.set_bool(lt::settings_pack::enable_incoming_tcp, false);
    settings.set_bool(lt::settings_pack::enable_outgoing_utp, false);
    settings.set_bool(lt::settings_pack::enable_incoming_utp, false);
    settings.set_bool(lt::settings_pack::anonymous_mode, true);
    settings.set_bool(lt::settings_pack::dht_privacy_lookups, true);
    settings.set_bool(lt::settings_pack::announce_to_all_trackers, false);
    settings.set_bool(lt::settings_pack::announce_to_all_tiers, false);
    settings.set_bool(lt::settings_pack::prefer_udp_trackers, false);
    settings.set_bool(lt::settings_pack::validate_https_trackers, true);
    settings.set_bool(lt::settings_pack::ssrf_mitigation, true);
    settings.set_bool(lt::settings_pack::always_send_user_agent, false);
    settings.set_bool(lt::settings_pack::allow_idna, false);
    settings.set_bool(lt::settings_pack::no_connect_privileged_ports, true);
    settings.set_int(lt::settings_pack::alert_queue_size, kLibtorrentAlertQueueSize);

    auto const categories = lt::alert_category::error
        | lt::alert_category::storage
        | lt::alert_category::status
        | lt::alert_category::tracker
        | lt::alert_category::file_progress
        | lt::alert_category::dht;
    settings.set_int(lt::settings_pack::alert_mask, static_cast<int>(static_cast<std::uint32_t>(categories)));
    return settings;
}

lt::session_params make_session_params(bool enable_peer_exchange_plugin)
{
    lt::session_params params{
        make_settings(),
        session_plugins(enable_peer_exchange_plugin),
    };
    // Descriptor-backed storage authority is implemented by the pread
    // backend. Select it explicitly so a future libtorrent build default
    // cannot silently fall back to pathname-only POSIX storage.
    params.disk_io_constructor = lt::pread_disk_io_constructor;
    return params;
}

void prepare_add_params(
    lt::add_torrent_params &params,
    std::string_view save_path,
    bool starts_paused,
    bool enable_peer_exchange
)
{
    params.save_path = std::string(save_path);
    params.flags |= lt::torrent_flags::duplicate_is_error;
    params.flags |= lt::torrent_flags::paused;
    params.flags |= lt::torrent_flags::update_subscribe;
    if (!enable_peer_exchange) {
        params.flags |= lt::torrent_flags::disable_pex;
    }
    if (starts_paused) {
        params.flags &= ~lt::torrent_flags::auto_managed;
    } else {
        params.flags |= lt::torrent_flags::auto_managed;
    }
}

BridgeResult validate_save_path(std::string_view save_path)
{
    if (save_path.empty()) {
        return bridge_error(1, "Missing save path.");
    }

    fs::path const path{std::string(save_path)};
    if (!path.is_absolute()) {
        return bridge_error(1, "The save path must be absolute.");
    }

    return {};
}

std::optional<std::string> normalize_authorized_save_path(std::string_view const save_path)
{
    if (save_path.empty()
        || save_path.size() > static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES)
        || save_path.contains('\0')) {
        return std::nullopt;
    }

    std::size_t offset = 0U;
    while (offset < save_path.size()) {
        UTF8Sequence const sequence = utf8_sequence(save_path, offset);
        if (!sequence.valid) {
            return std::nullopt;
        }
        offset += sequence.length;
    }

    fs::path const path{std::string(save_path)};
    if (!path.is_absolute()) {
        return std::nullopt;
    }

    std::string normalized = path.lexically_normal().native();
    if (normalized.empty()
        || normalized.size() > static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BYTES)) {
        return std::nullopt;
    }
    return normalized;
}

AuthorizedSavePathListResult parse_authorized_save_path_list_blob(
    std::span<std::uint8_t const> const blob
)
{
    if (blob.empty()) {
        return AuthorizedSavePathList{};
    }
    if (blob.size() > static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_BLOB_BYTES)) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save path list is too large.",
        });
    }
    if (blob.back() != 0U) {
        return std::unexpected(BridgeError{
            .code = 1,
            .message = "The authorized save path list is not NUL terminated.",
        });
    }

    AuthorizedSavePathList paths;
    std::size_t offset = 0U;
    std::size_t path_count = 0U;
    while (offset < blob.size()) {
        std::span<std::uint8_t const> const remaining = blob.subspan(offset);
        auto const terminator = std::ranges::find(remaining, std::uint8_t{0});
        std::size_t const length = static_cast<std::size_t>(std::ranges::distance(
            remaining.begin(),
            terminator
        ));
        if (length == 0U) {
            return std::unexpected(BridgeError{
                .code = 1,
                .message = "The authorized save path list contains an empty path.",
            });
        }

        ++path_count;
        if (path_count > static_cast<std::size_t>(TTORRENT_MAX_AUTHORIZED_SAVE_PATH_COUNT)) {
            return std::unexpected(BridgeError{
                .code = 1,
                .message = "The authorized save path list contains too many paths.",
            });
        }

        std::string path;
        path.reserve(length);
        for (std::uint8_t const byte : remaining.first(length)) {
            path.push_back(static_cast<char>(byte));
        }
        std::optional<std::string> const normalized = normalize_authorized_save_path(path);
        if (!normalized) {
            return std::unexpected(BridgeError{
                .code = 1,
                .message = "The authorized save path list contains an invalid path.",
            });
        }
        paths.push_back(*normalized);
        offset += length + 1U;
    }
    return paths;
}

std::string trimmed(std::string_view value)
{
    auto const first = std::ranges::find_if_not(value, [](unsigned char character) {
        return is_ascii_space(character);
    });
    auto const reversed = std::views::reverse(value);
    auto const last = std::ranges::find_if_not(reversed, [](unsigned char character) {
        return is_ascii_space(character);
    }).base();

    if (first >= last) {
        return {};
    }

    return {first, last};
}

bool contains_invalid_interface_character(std::string_view value)
{
    return std::ranges::any_of(value, [](unsigned char character) {
        return character == ',' || is_ascii_control(character) || is_ascii_space(character);
    });
}

bool is_ipv4_address(std::string const &value)
{
    in_addr address{};
    return inet_pton(AF_INET, value.c_str(), &address) == 1;
}

bool is_ipv6_address(std::string const &value)
{
    in6_addr address{};
    return inet_pton(AF_INET6, value.c_str(), &address) == 1;
}

NetworkBinding network_binding(std::string_view network_interface)
{
    std::string const value = trimmed(network_interface);
    if (value.empty()) {
        return {};
    }

    if (contains_invalid_interface_character(value)) {
        throw std::invalid_argument("Network interface must be a single interface name or IP address.");
    }

    if (value.contains('[') || value.contains(']')) {
        throw std::invalid_argument("IPv6 network interfaces must be unbracketed.");
    }

    NetworkBinding binding;
    binding.value = value;
    if (is_ipv4_address(value)) {
        binding.kind = NetworkBindingKind::ipv4;
    } else if (is_ipv6_address(value)) {
        binding.kind = NetworkBindingKind::ipv6;
    } else if (value.contains(':')) {
        throw std::invalid_argument("Invalid IPv6 address.");
    } else {
        binding.kind = NetworkBindingKind::name;
    }
    return binding;
}

std::string listen_interfaces(int32_t incoming_port, std::string_view network_interface, bool network_blocked)
{
    if (network_blocked) {
        return {};
    }

    if (incoming_port < 0 || incoming_port > 65535 || (incoming_port > 0 && incoming_port < 1024)) {
        throw std::invalid_argument("Incoming port must be 0 or between 1024 and 65535.");
    }

    NetworkBinding const binding = network_binding(network_interface);
    std::string const port_string = std::to_string(incoming_port);

    switch (binding.kind) {
    case NetworkBindingKind::any:
        return "0.0.0.0:" + port_string + ",[::]:" + port_string;
    case NetworkBindingKind::ipv4:
        return binding.value + ":" + port_string;
    case NetworkBindingKind::ipv6:
        return "[" + binding.value + "]:" + port_string;
    case NetworkBindingKind::name:
        return binding.value + ":" + port_string;
    }

    return {};
}

std::string outgoing_interfaces(std::string_view network_interface, bool network_blocked)
{
    if (network_blocked) {
        return {};
    }

    NetworkBinding const binding = network_binding(network_interface);
    switch (binding.kind) {
    case NetworkBindingKind::any:
        return {};
    case NetworkBindingKind::ipv4:
    case NetworkBindingKind::ipv6:
    case NetworkBindingKind::name:
        return binding.value;
    }

    return {};
}

int encryption_policy(int32_t value)
{
    switch (value) {
    case 1:
        return static_cast<int>(lt::settings_pack::pe_forced);
    case 2:
        return static_cast<int>(lt::settings_pack::pe_disabled);
    default:
        return static_cast<int>(lt::settings_pack::pe_enabled);
    }
}

bool is_valid_encryption_policy(int32_t value) noexcept
{
    return value >= 0 && value <= 2;
}

namespace {

FileReadResult read_open_file(UniqueFileDescriptor input, std::uintmax_t const max_size)
{
    if (!input.is_valid()) {
        return std::unexpected(FileReadFailure::unreadable);
    }

    struct stat metadata{};
    if (::fstat(input.get(), &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
        return std::unexpected(FileReadFailure::unreadable);
    }

    if (metadata.st_size < 0) {
        return std::unexpected(FileReadFailure::unreadable);
    }
    if (metadata.st_size == 0) {
        return std::unexpected(FileReadFailure::empty);
    }

    auto const size = static_cast<std::uintmax_t>(metadata.st_size);
    if (size > max_size || size > static_cast<std::uintmax_t>(std::numeric_limits<int>::max())) {
        return std::unexpected(FileReadFailure::too_large);
    }

    std::vector<char> buffer(static_cast<std::size_t>(size));
    std::size_t offset = 0;
    while (offset < buffer.size()) {
        std::size_t const remaining = buffer.size() - offset;
        ssize_t const bytes_read = ::read(
            input.get(),
            std::next(buffer.data(), static_cast<std::ptrdiff_t>(offset)),
            remaining
        );
        if (bytes_read < 0) {
            if (errno == EINTR) {
                continue;
            }
            return std::unexpected(FileReadFailure::unreadable);
        }
        if (bytes_read == 0) {
            return std::unexpected(FileReadFailure::unreadable);
        }

        offset += static_cast<std::size_t>(bytes_read);
    }
    return buffer;
}

} // namespace

FileReadResult read_file(fs::path const &path, std::uintmax_t const max_size)
{
    return read_open_file(
        UniqueFileDescriptor(::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)),
        max_size
    );
}

FileReadResult read_file_at(
    int const directory_descriptor,
    std::string const &filename,
    std::uintmax_t const max_size
)
{
    if (filename.empty() || filename.contains('/') || filename.contains('\0')) {
        return std::unexpected(FileReadFailure::unreadable);
    }

    return read_open_file(
        UniqueFileDescriptor(::openat(
            directory_descriptor,
            filename.c_str(),
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )),
        max_size
    );
}

UniqueFileDescriptor open_directory_no_follow(fs::path const &path, std::string_view description)
{
    UniqueFileDescriptor descriptor(::open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (!descriptor.is_valid()) {
        throw std::system_error(
            std::error_code(errno, std::generic_category()),
            "Could not open " + std::string(description)
        );
    }

    struct stat metadata{};
    if (::fstat(descriptor.get(), &metadata) != 0) {
        int const error_number = errno;
        throw std::system_error(
            std::error_code(error_number, std::generic_category()),
            "Invalid " + std::string(description)
        );
    }
    if (!S_ISDIR(metadata.st_mode)) {
        throw std::system_error(
            std::error_code(ENOTDIR, std::generic_category()),
            "Invalid " + std::string(description)
        );
    }
    return descriptor;
}

UniqueFileDescriptor open_directory_at_no_follow(
    int const parent_directory_descriptor,
    char const *const filename,
    std::string_view const description
)
{
    std::string_view const filename_view = c_string_view(filename);
    if (filename_view.empty() || filename_view.contains('/')) {
        throw std::system_error(
            std::error_code(EINVAL, std::generic_category()),
            "Invalid " + std::string(description)
        );
    }

    UniqueFileDescriptor descriptor(::openat(
        parent_directory_descriptor,
        filename,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    ));
    if (!descriptor.is_valid()) {
        throw std::system_error(
            std::error_code(errno, std::generic_category()),
            "Could not open " + std::string(description)
        );
    }

    struct stat metadata{};
    if (::fstat(descriptor.get(), &metadata) != 0) {
        int const error_number = errno;
        throw std::system_error(
            std::error_code(error_number, std::generic_category()),
            "Invalid " + std::string(description)
        );
    }
    if (!S_ISDIR(metadata.st_mode)) {
        throw std::system_error(
            std::error_code(ENOTDIR, std::generic_category()),
            "Invalid " + std::string(description)
        );
    }
    return descriptor;
}

void restrict_permissions(fs::path const &path, FileSystemNodeKind kind)
{
    fs::perms permissions = fs::perms::owner_read | fs::perms::owner_write;
    if (kind == FileSystemNodeKind::directory) {
        permissions |= fs::perms::owner_exec;
    }

    std::error_code permission_error;
    fs::permissions(
        path,
        permissions,
        fs::perm_options::replace,
        permission_error
    );
    if (permission_error) {
        throw std::system_error(permission_error, "Could not restrict permissions for " + path.string());
    }
}

void restrict_permissions(int descriptor, std::string_view description, FileSystemNodeKind kind)
{
    mode_t permissions = S_IRUSR | S_IWUSR;
    if (kind == FileSystemNodeKind::directory) {
        permissions |= S_IXUSR;
    }

    if (::fchmod(descriptor, permissions) != 0) {
        int const error_number = errno;
        throw std::system_error(
            std::error_code(error_number, std::generic_category()),
            "Could not restrict permissions for " + std::string(description)
        );
    }
}

UniqueFileDescriptor acquire_state_directory_lock(int state_directory_descriptor)
{
    constexpr mode_t kOwnerReadWrite = S_IRUSR | S_IWUSR;
    UniqueFileDescriptor descriptor(::openat(
        state_directory_descriptor,
        "State.lock",
        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
        kOwnerReadWrite
    ));
    if (!descriptor.is_valid()) {
        throw std::system_error(
            std::error_code(errno, std::generic_category()),
            "Could not open state directory lock"
        );
    }
    if (::fchmod(descriptor.get(), kOwnerReadWrite) != 0) {
        int const error_number = errno;
        throw std::system_error(
            std::error_code(error_number, std::generic_category()),
            "Could not restrict state directory lock permissions"
        );
    }
    if (::flock(descriptor.get(), LOCK_EX | LOCK_NB) != 0) {
        int const error_number = errno;
        throw std::system_error(
            std::error_code(error_number, std::generic_category()),
            "Could not lock state directory"
        );
    }
    return descriptor;
}

TorrentLoadResult load_torrent_data(std::span<char const> torrent_data)
{
    if (torrent_data.empty()) {
        return std::unexpected(BridgeError{.code = 2, .message = "The torrent file is empty."});
    }
    if (torrent_data.size() > kMaxTorrentFileBytes) {
        return std::unexpected(BridgeError{.code = 2, .message = "The torrent file is too large."});
    }

    try {
        return lt::load_torrent_buffer(
            lt::span<char const>(torrent_data.data(), static_cast<int>(torrent_data.size()))
        );
    } catch (std::exception const &) {
        return std::unexpected(BridgeError{.code = 2, .message = "The torrent file is invalid."});
    } catch (...) {
        return std::unexpected(BridgeError{.code = 2, .message = "The torrent file is invalid."});
    }
}

namespace {

BridgeResult validate_relative_torrent_path(std::string_view path)
{
    if (path.empty() || std::ranges::any_of(path, [](unsigned char const character) {
            return is_c_string_control_byte(character);
        })) {
        return bridge_error(2, "The torrent contains an invalid file path.");
    }
    if (path.starts_with('/')) {
        return bridge_error(2, "The torrent contains a file path outside its download folder.");
    }

    std::size_t component_start = 0U;
    while (component_start < path.size()) {
        std::size_t const separator = path.find('/', component_start);
        std::string_view const component = path.substr(
            component_start,
            separator == std::string_view::npos ? std::string_view::npos : separator - component_start
        );
        if (component.empty() || component == "." || component == "..") {
            return bridge_error(2, "The torrent contains a file path outside its download folder.");
        }
        if (separator == std::string_view::npos) {
            break;
        }
        component_start = separator + 1U;
        if (component_start == path.size()) {
            return bridge_error(2, "The torrent contains an invalid file path.");
        }
    }

    return {};
}

BridgeResult validate_rename_map(
    lt::file_storage const &layout,
    std::map<lt::file_index_t, std::string> const &renamed_files
)
{
    for (auto const &[file, path] : renamed_files) {
        if (file < lt::file_index_t(0) || file >= layout.end_file()) {
            return bridge_error(2, "The torrent contains an invalid file rename.");
        }
        BridgeResult const valid_path = validate_relative_torrent_path(path);
        if (!valid_path) {
            return valid_path;
        }
    }
    return {};
}

BridgeResult validate_effective_files(lt::filenames const &files)
{
    for (lt::file_index_t const file : files.file_range()) {
        if (static_cast<bool>(files.file_flags(file) & lt::file_storage::flag_symlink)) {
            return bridge_error(2, "The torrent contains symbolic links, which are not supported.");
        }
        if (files.file_absolute_path(file)) {
            return bridge_error(2, "The torrent contains a file path outside its download folder.");
        }

        std::string const effective_path = files.file_path(file);
        BridgeResult const valid_path = validate_relative_torrent_path(effective_path);
        if (!valid_path) {
            return valid_path;
        }
        if (effective_path.size() >= sizeof(TTorrentFileSnapshot::path)) {
            return bridge_error(2, "The torrent contains a file path that is too long.");
        }
    }
    return {};
}

}

BridgeResult validate_torrent_info(lt::torrent_info const &info)
{
    static std::map<lt::file_index_t, std::string> const no_renames;
    return validate_torrent_info(info, no_renames);
}

BridgeResult validate_torrent_info(
    lt::torrent_info const &info,
    std::map<lt::file_index_t, std::string> const &renamed_files
)
{
    if (!info.is_valid()) {
        return bridge_error(2, "The torrent file is invalid.");
    }

    lt::file_storage const &layout = info.layout();
    int const file_count = layout.num_files();
    if (file_count > TTORRENT_MAX_FILE_COUNT) {
        return bridge_error(
            2,
            "The torrent contains too many files. The maximum is "
                + std::to_string(TTORRENT_MAX_FILE_COUNT)
                + "."
        );
    }

    BridgeResult const valid_renames = validate_rename_map(layout, renamed_files);
    if (!valid_renames) {
        return valid_renames;
    }

    lt::renamed_files effective_renames;
    effective_renames.import_filenames(layout, renamed_files);
    return validate_effective_files(lt::filenames(layout, effective_renames));
}

BridgeResult validate_torrent_info(lt::add_torrent_params const &params)
{
    if (!params.ti) {
        return bridge_error(2, "The torrent file is invalid.");
    }

    return validate_torrent_info(*params.ti, params.renamed_files);
}

void copy_torrent_preview(lt::add_torrent_params const &params, TTorrentFilePreview *preview) noexcept
{
    if (preview == nullptr) {
        return;
    }

    lt::torrent_info const &info = *params.ti;
    copy_string(std::span{preview->name}, info.name());
    copy_primary_hash_key(std::span{preview->id}, info.info_hashes());
    preview->total_size = info.total_size();
    preview->file_count = info.layout().num_files();
    TorrentSourceCounts const counts = torrent_source_counts(params);
    preview->tracker_count = counts.tracker_count;
    preview->https_tracker_count = counts.https_tracker_count;
    preview->web_seed_count = counts.web_seed_count;
    preview->https_web_seed_count = counts.https_web_seed_count;
}

void copy_torrent_preview_files(
    lt::add_torrent_params const &params,
    std::span<TTorrentFileSnapshot> output
)
{
    lt::file_storage const &layout = params.ti->layout();
    lt::renamed_files renamed_files;
    renamed_files.import_filenames(layout, params.renamed_files);
    lt::filenames const files(layout, renamed_files);
    std::size_t const count = std::min(output.size(), static_cast<std::size_t>(files.num_files()));
    for (std::size_t index = 0; index < count; ++index) {
        auto const file = lt::file_index_t(static_cast<int>(index));
        auto destination = std::next(output.begin(), static_cast<std::ptrdiff_t>(index));
        *destination = file_snapshot_from_files(
            files,
            file,
            static_cast<int32_t>(static_cast<std::uint8_t>(lt::default_priority))
        );
    }
}

bool is_valid_file_priority(int32_t priority) noexcept
{
    return priority == TTORRENT_FILE_PRIORITY_SKIP
        || priority == TTORRENT_FILE_PRIORITY_LOW
        || priority == TTORRENT_FILE_PRIORITY_NORMAL
        || priority == TTORRENT_FILE_PRIORITY_HIGH;
}

lt::download_priority_t file_priority_from_bridge(int32_t priority) noexcept
{
    return lt::download_priority_t(static_cast<std::uint8_t>(priority));
}

BridgeResult apply_file_priorities(
    lt::add_torrent_params &params,
    std::optional<std::span<TTorrentFilePriorityEntry const>> file_priorities
)
{
    if (!file_priorities) {
        return {};
    }

    BridgeResult const valid_info = validate_torrent_info(params);
    if (!valid_info) {
        return valid_info;
    }

    lt::file_storage const &files = params.ti->layout();
    if (file_priorities->empty()) {
        return bridge_error(2, "Choose at least one file.");
    }

    std::vector<lt::download_priority_t> priorities(
        static_cast<std::size_t>(files.num_files()),
        lt::default_priority
    );
    std::set<int32_t> assigned_indexes;
    for (TTorrentFilePriorityEntry const &entry : *file_priorities) {
        if (entry.index < 0 || entry.index >= files.num_files() || !is_valid_file_priority(entry.priority)) {
            return bridge_error(2, "The file priorities are invalid.");
        }
        if (!assigned_indexes.insert(entry.index).second) {
            return bridge_error(2, "The file priorities are invalid.");
        }

        priorities.at(static_cast<std::size_t>(entry.index)) = file_priority_from_bridge(entry.priority);
    }

    bool const has_downloadable_file = std::ranges::any_of(priorities, [](lt::download_priority_t priority) {
        return priority != lt::dont_download;
    });
    if (!has_downloadable_file) {
        return bridge_error(2, "Choose at least one file.");
    }

    params.file_priorities = std::move(priorities);
    return {};
}

} // namespace torrent_bridge::internal
