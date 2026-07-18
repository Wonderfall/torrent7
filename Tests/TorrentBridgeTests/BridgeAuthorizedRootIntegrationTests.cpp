#include "BridgeTestSupport.hpp"

#include <doctest.h>

#include <libtorrent/create_torrent.hpp>
#include <libtorrent/hasher.hpp>
#include <libtorrent/hex.hpp>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <stdexcept>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr int kPieceSize = 16 * 1024;

template <typename Predicate>
[[nodiscard]] bool eventually(Predicate &&predicate)
{
    for (int attempt = 0; attempt < 200; ++attempt) {
        if (predicate()) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    return predicate();
}

[[nodiscard]] bool file_exists(fs::path const &path)
{
    std::error_code ignored;
    return fs::exists(path, ignored);
}

[[nodiscard]] std::uintmax_t file_size_or_zero(fs::path const &path)
{
    std::error_code error;
    std::uintmax_t const size = fs::file_size(path, error);
    return error ? 0U : size;
}

struct RootLifetimeProbe {
    std::atomic<int> retain_count = 0;
    std::atomic<int> release_count = 0;
    std::atomic_bool destroyed = false;
};

struct RootLifetimeContext {
    explicit RootLifetimeContext(fs::path const &path, std::shared_ptr<RootLifetimeProbe> lifetime_probe)
        : descriptor(::open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)),
          probe(std::move(lifetime_probe))
    {
        if (!descriptor.is_valid()) {
            throw std::system_error(errno, std::generic_category(), "Could not open authorized integration-test root");
        }
        struct ::stat metadata {};
        if (::fstat(descriptor.get(), &metadata) != 0) {
            throw std::system_error(
                errno,
                std::generic_category(),
                "Could not inspect authorized integration-test root"
            );
        }
        if (!S_ISDIR(metadata.st_mode)) {
            throw std::runtime_error("Authorized integration-test root is not a directory");
        }
        device = static_cast<std::uint64_t>(metadata.st_dev);
        inode = static_cast<std::uint64_t>(metadata.st_ino);
    }

    std::atomic<int> references = 1;
    UniqueFileDescriptor descriptor;
    std::shared_ptr<RootLifetimeProbe> probe;
    std::uint64_t device = 0U;
    std::uint64_t inode = 0U;
};

void release_root_reference(RootLifetimeContext *context) noexcept
{
    if (context->references.fetch_sub(1, std::memory_order_acq_rel) != 1) {
        return;
    }

    std::shared_ptr<RootLifetimeProbe> const probe = context->probe;
    delete context;
    probe->destroyed.store(true, std::memory_order_release);
}

void retain_authorized_root(void *opaque_context) noexcept
{
    auto *context = static_cast<RootLifetimeContext *>(opaque_context);
    context->references.fetch_add(1, std::memory_order_relaxed);
    context->probe->retain_count.fetch_add(1, std::memory_order_relaxed);
}

void release_authorized_root(void *opaque_context) noexcept
{
    auto *context = static_cast<RootLifetimeContext *>(opaque_context);
    context->probe->release_count.fetch_add(1, std::memory_order_relaxed);
    release_root_reference(context);
}

class RootCapabilityOwner {
public:
    explicit RootCapabilityOwner(fs::path const &path)
        : probe_(std::make_shared<RootLifetimeProbe>()),
          context_(new RootLifetimeContext(path, probe_))
    {
    }

    RootCapabilityOwner(RootCapabilityOwner const &) = delete;
    RootCapabilityOwner &operator=(RootCapabilityOwner const &) = delete;
    RootCapabilityOwner(RootCapabilityOwner &&) = delete;
    RootCapabilityOwner &operator=(RootCapabilityOwner &&) = delete;

    ~RootCapabilityOwner()
    {
        drop_caller_ownership();
    }

    [[nodiscard]] TTorrentAuthorizedSaveRoot record() const noexcept
    {
        return TTorrentAuthorizedSaveRoot{
            .directory_descriptor = context_->descriptor.get(),
            .device = context_->device,
            .inode = context_->inode,
            .lifetime_context = context_,
        };
    }

    [[nodiscard]] std::shared_ptr<RootLifetimeProbe> const &probe() const noexcept
    {
        return probe_;
    }

    void drop_caller_ownership() noexcept
    {
        RootLifetimeContext *const context = std::exchange(context_, nullptr);
        if (context != nullptr) {
            release_root_reference(context);
        }
    }

private:
    std::shared_ptr<RootLifetimeProbe> probe_;
    RootLifetimeContext *context_;
};

struct TorrentFixture {
    std::vector<char> metainfo;
    std::array<std::vector<char>, 2> pieces;
    std::string payload_path;
    std::string skipped_path;
    std::string renamed_path;
    std::string partfile_name;
};

[[nodiscard]] TorrentFixture make_torrent_fixture(char const payload_byte, char const skipped_byte)
{
    TorrentFixture fixture;
    fixture.pieces.at(0) = std::vector<char>(static_cast<std::size_t>(kPieceSize), payload_byte);
    fixture.pieces.at(1) = std::vector<char>(static_cast<std::size_t>(kPieceSize), skipped_byte);

    std::vector<lt::create_file_entry> files;
    files.emplace_back("authority-bundle/payload.bin", kPieceSize);
    files.emplace_back("authority-bundle/skipped.bin", kPieceSize);
    lt::create_torrent creator(std::move(files), kPieceSize, lt::create_torrent::v1_only);
    creator.set_hash(lt::piece_index_t(0), lt::hasher(fixture.pieces.at(0)).final());
    creator.set_hash(lt::piece_index_t(1), lt::hasher(fixture.pieces.at(1)).final());
    fixture.metainfo = creator.generate_buf();

    lt::add_torrent_params const params = bridge_tests::load_torrent_params(
        fixture.metainfo,
        "descriptor-authority integration torrent"
    );
    fixture.payload_path = params.ti->layout().file_path(lt::file_index_t(0));
    fixture.skipped_path = params.ti->layout().file_path(lt::file_index_t(1));
    fixture.renamed_path = "authority-bundle/renamed.bin";
    fixture.partfile_name = "." + lt::aux::to_hex(params.ti->info_hashes().v1) + ".parts";
    return fixture;
}

[[nodiscard]] TTorrentAddOptions default_add_options()
{
    return TTorrentAddOptions{
        .starts_paused = bridge_bool(false),
        .queue_priority = static_cast<std::uint8_t>(TTORRENT_QUEUE_PRIORITY_NORMAL),
        .enable_peer_exchange = bridge_bool(false),
        .allow_non_https_trackers = bridge_bool(false),
        .allow_non_https_web_seeds = bridge_bool(false),
        .allow_pre_metadata_dht = bridge_bool(false),
    };
}

[[nodiscard]] TTorrentClient *create_client(
    fs::path const &state_directory,
    fs::path const &authorized_directory,
    RootCapabilityOwner &capability
)
{
    std::string const authorized_path = authorized_directory.lexically_normal().string();
    std::vector<std::uint8_t> path_blob(authorized_path.begin(), authorized_path.end());
    path_blob.push_back(0U);
    TTorrentAuthorizedSaveRoot const root_record = capability.record();
    std::array<char, 512> error{};
    TTorrentClient *client = TorrentClientCreateWithError(
        state_directory.c_str(),
        bridge_bool(false),
        path_blob.data(),
        static_cast<std::int32_t>(path_blob.size()),
        &root_record,
        1,
        retain_authorized_root,
        release_authorized_root,
        error.data(),
        static_cast<std::int32_t>(error.size())
    );
    INFO(error.data());
    REQUIRE(client != nullptr);
    client->stop_alert_worker();
    return client;
}

[[nodiscard]] std::string add_torrent_with_skipped_file(
    TTorrentClient *client,
    fs::path const &save_path,
    TorrentFixture const &fixture
)
{
    TTorrentAddOptions const options = default_add_options();
    TTorrentFilePriorityEntry const skipped_file{
        .index = 1,
        .priority = TTORRENT_FILE_PRIORITY_SKIP,
    };
    std::array<char, TTORRENT_ID_CAPACITY> added_id{};
    std::array<char, 512> error{};
    int32_t const result = TorrentClientAddTorrentFileDataWithPriorities(
        client,
        fixture.metainfo.data(),
        static_cast<std::int32_t>(fixture.metainfo.size()),
        save_path.c_str(),
        &options,
        &skipped_file,
        1,
        added_id.data(),
        static_cast<std::int32_t>(added_id.size()),
        error.data(),
        static_cast<std::int32_t>(error.size())
    );
    INFO(error.data());
    REQUIRE(result == 0);
    REQUIRE(is_canonical_torrent_id(added_id.data()));
    return added_id.data();
}

[[nodiscard]] lt::torrent_handle active_handle(TTorrentClient &client, std::string const &torrent_id)
{
    std::optional<lt::torrent_handle> const handle = client.find(torrent_id);
    REQUIRE(handle.has_value());
    REQUIRE(handle->is_valid());
    client.session.resume();
    handle->unset_flags(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
    handle->resume();
    REQUIRE(eventually([&client, &handle] {
        client.pump_alerts();
        lt::torrent_status const status = handle->status();
        return status.state != lt::torrent_status::checking_files
            && status.state != lt::torrent_status::checking_resume_data;
    }));
    return *handle;
}

void clear_authorized_roots(TTorrentClient *client)
{
    std::array<char, 512> error{};
    int32_t const result = TorrentClientReplaceAuthorizedSavePaths(
        client,
        nullptr,
        0,
        nullptr,
        0,
        nullptr,
        nullptr,
        error.data(),
        static_cast<std::int32_t>(error.size())
    );
    INFO(error.data());
    REQUIRE(result == 0);
}

[[nodiscard]] bool state_lock_is_available(fs::path const &state_directory)
{
    UniqueFileDescriptor lock(::open(
        (state_directory / "State.lock").c_str(),
        O_RDWR | O_CLOEXEC | O_NOFOLLOW
    ));
    return lock.is_valid() && ::flock(lock.get(), LOCK_EX | LOCK_NB) == 0;
}

void exercise_confined_storage_and_destroy(
    TTorrentClient *client,
    std::string const &torrent_id,
    TorrentFixture const &fixture,
    fs::path const &root_path,
    fs::path const &retained_path,
    RootCapabilityOwner &capability
)
{
    lt::torrent_handle const handle = active_handle(*client, torrent_id);
    clear_authorized_roots(client);
    std::shared_ptr<RootLifetimeProbe> const probe = capability.probe();
    capability.drop_caller_ownership();
    CHECK(probe->retain_count.load(std::memory_order_relaxed) == 1);
    CHECK(probe->release_count.load(std::memory_order_relaxed) == 0);
    CHECK_FALSE(probe->destroyed.load(std::memory_order_acquire));

    std::error_code rename_error;
    fs::rename(root_path, retained_path, rename_error);
    REQUIRE_FALSE(rename_error);
    REQUIRE(fs::create_directories(root_path / "authority-bundle"));

    fs::path const decoy_payload = root_path / fixture.payload_path;
    fs::path const decoy_skipped = root_path / fixture.skipped_path;
    fs::path const decoy_renamed = root_path / fixture.renamed_path;
    fs::path const decoy_partfile = root_path / fixture.partfile_name;
    bridge_tests::write_text_file(decoy_payload, "decoy-payload");
    bridge_tests::write_text_file(decoy_skipped, "decoy-skipped");
    bridge_tests::write_text_file(decoy_renamed, "decoy-renamed");
    bridge_tests::write_text_file(decoy_partfile, "decoy-partfile");

    fs::path const retained_payload = retained_path / fixture.payload_path;
    fs::path const retained_skipped = retained_path / fixture.skipped_path;
    fs::path const retained_renamed = retained_path / fixture.renamed_path;
    fs::path const retained_partfile = retained_path / fixture.partfile_name;
    std::uintmax_t const initial_partfile_size = file_size_or_zero(retained_partfile);

    handle.add_piece(
        lt::piece_index_t(0),
        fixture.pieces.at(0),
        lt::torrent_handle::overwrite_existing
    );
    handle.add_piece(
        lt::piece_index_t(1),
        fixture.pieces.at(1),
        lt::torrent_handle::overwrite_existing
    );
    std::string const expected_payload(fixture.pieces.at(0).begin(), fixture.pieces.at(0).end());
    REQUIRE(eventually([&] {
        client->pump_alerts();
        return bridge_tests::read_text_file(retained_payload) == expected_payload
            && file_size_or_zero(retained_partfile) > initial_partfile_size;
    }));
    CHECK_FALSE(file_exists(retained_skipped));
    CHECK(bridge_tests::read_text_file(decoy_payload) == "decoy-payload");
    CHECK(bridge_tests::read_text_file(decoy_skipped) == "decoy-skipped");
    CHECK(bridge_tests::read_text_file(decoy_partfile) == "decoy-partfile");

    handle.rename_file(lt::file_index_t(0), fixture.renamed_path);
    REQUIRE(eventually([&] {
        client->pump_alerts();
        return file_exists(retained_renamed) && !file_exists(retained_payload);
    }));
    CHECK(bridge_tests::read_text_file(retained_renamed) == expected_payload);
    CHECK(bridge_tests::read_text_file(decoy_renamed) == "decoy-renamed");
    CHECK_FALSE(probe->destroyed.load(std::memory_order_acquire));

    std::uint64_t removal_token = 0U;
    std::uint8_t removal_committed = bridge_bool(false);
    std::array<char, 512> error{};
    int32_t const removal_result = TorrentClientRemove(
        client,
        torrent_id.c_str(),
        bridge_bool(true),
        bridge_bool(true),
        &removal_token,
        &removal_committed,
        error.data(),
        static_cast<std::int32_t>(error.size())
    );
    INFO(error.data());
    REQUIRE(removal_result == 0);
    REQUIRE(bridge_bool(removal_committed));
    REQUIRE(removal_token != 0U);

    TTorrentRemovalResult terminal_result{};
    REQUIRE(eventually([&] {
        client->pump_alerts();
        error.fill('\0');
        return TorrentClientTakeRemovalResult(
            client,
            removal_token,
            &terminal_result,
            error.data(),
            static_cast<std::int32_t>(error.size())
        ) == 0 && terminal_result.state != TTORRENT_REMOVAL_PENDING;
    }));
    INFO(error.data());
    CHECK(terminal_result.state == TTORRENT_REMOVAL_SUCCEEDED);
    CHECK_FALSE(file_exists(retained_renamed));
    CHECK_FALSE(file_exists(retained_partfile));
    CHECK(bridge_tests::read_text_file(decoy_payload) == "decoy-payload");
    CHECK(bridge_tests::read_text_file(decoy_skipped) == "decoy-skipped");
    CHECK(bridge_tests::read_text_file(decoy_renamed) == "decoy-renamed");
    CHECK(bridge_tests::read_text_file(decoy_partfile) == "decoy-partfile");

    TorrentClientDestroyBlocking(client);
    REQUIRE(eventually([&probe] {
        return probe->destroyed.load(std::memory_order_acquire);
    }));
    CHECK(probe->retain_count.load(std::memory_order_relaxed) == 1);
    CHECK(probe->release_count.load(std::memory_order_relaxed) == 1);
}

} // namespace

TEST_CASE("live descriptor authority confines libtorrent storage after the root pathname is replaced")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const root_path = temporary_directory.path() / "Downloads";
    fs::path const retained_path = temporary_directory.path() / "RetainedDownloads";
    REQUIRE(fs::create_directory(root_path));

    TorrentFixture const fixture = make_torrent_fixture('l', 's');
    RootCapabilityOwner capability(root_path);
    TTorrentClient *client = create_client(state_directory, root_path, capability);
    std::string const torrent_id = add_torrent_with_skipped_file(client, root_path, fixture);
    exercise_confined_storage_and_destroy(
        client,
        torrent_id,
        fixture,
        root_path,
        retained_path,
        capability
    );
}

TEST_CASE("resume-restored torrents retain the descriptor authority used during startup")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const root_path = temporary_directory.path() / "Downloads";
    fs::path const retained_path = temporary_directory.path() / "RetainedDownloads";
    REQUIRE(fs::create_directory(root_path));
    TorrentFixture const fixture = make_torrent_fixture('r', 'p');

    std::string torrent_id;
    {
        RootCapabilityOwner initial_capability(root_path);
        std::shared_ptr<RootLifetimeProbe> const initial_probe = initial_capability.probe();
        TTorrentClient *initial_client = create_client(state_directory, root_path, initial_capability);
        torrent_id = add_torrent_with_skipped_file(initial_client, root_path, fixture);
        TorrentClientDestroyBlocking(initial_client);
        CHECK(initial_probe->retain_count.load(std::memory_order_relaxed) == 1);
        CHECK(initial_probe->release_count.load(std::memory_order_relaxed) == 1);
        CHECK_FALSE(initial_probe->destroyed.load(std::memory_order_acquire));
        initial_capability.drop_caller_ownership();
        CHECK(initial_probe->destroyed.load(std::memory_order_acquire));
    }

    RootCapabilityOwner restored_capability(root_path);
    TTorrentClient *restored_client = create_client(state_directory, root_path, restored_capability);
    REQUIRE(restored_client->find(torrent_id).has_value());
    exercise_confined_storage_and_destroy(
        restored_client,
        torrent_id,
        fixture,
        root_path,
        retained_path,
        restored_capability
    );
}

TEST_CASE("nonblocking client destruction keeps active root authority alive through deferred session shutdown")
{
    bridge_tests::TemporaryDirectory temporary_directory;
    fs::path const state_directory = temporary_directory.path() / "State";
    fs::path const root_path = temporary_directory.path() / "Downloads";
    REQUIRE(fs::create_directory(root_path));

    TorrentFixture const fixture = make_torrent_fixture('a', 'b');
    RootCapabilityOwner capability(root_path);
    std::shared_ptr<RootLifetimeProbe> const probe = capability.probe();
    TTorrentClient *client = create_client(state_directory, root_path, capability);
    static_cast<void>(add_torrent_with_skipped_file(client, root_path, fixture));
    clear_authorized_roots(client);
    capability.drop_caller_ownership();
    CHECK(probe->retain_count.load(std::memory_order_relaxed) == 1);
    CHECK(probe->release_count.load(std::memory_order_relaxed) == 0);
    CHECK_FALSE(probe->destroyed.load(std::memory_order_acquire));

    TorrentClientDestroy(client);

    REQUIRE(eventually([&] {
        return probe->destroyed.load(std::memory_order_acquire)
            && state_lock_is_available(state_directory);
    }));
    CHECK(probe->retain_count.load(std::memory_order_relaxed) == 1);
    CHECK(probe->release_count.load(std::memory_order_relaxed) == 1);
}
