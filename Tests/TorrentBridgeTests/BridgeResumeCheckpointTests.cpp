#include "BridgeTestSupport.hpp"

#include <doctest.h>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/aux_/part_file.hpp>
#include <libtorrent/aux_/session_impl.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/pread_disk_io.hpp>
#include <libtorrent/session.hpp>
#include <crt_externs.h>
#include <cstdlib>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <thread>

namespace {

struct PayloadOpenGate {
    std::atomic_bool armed{false};
    std::atomic_bool fail_write{false};
    std::promise<void> entered;
    std::promise<void> release;
};

class GatedPayloadProvider final : public lt::aux::payload_file_provider {
public:
    GatedPayloadProvider(std::shared_ptr<lt::aux::payload_file_provider> provider,
        std::shared_ptr<PayloadOpenGate> gate) : provider_(std::move(provider)), gate_(std::move(gate)) {}

    int open_payload(lt::file_index_t file, bool write, lt::error_code &error) override
    {
        if (file == lt::file_index_t{1} && write && gate_->armed.exchange(false)) {
            gate_->entered.set_value();
            if (gate_->release.get_future().wait_for(std::chrono::seconds(5)) != std::future_status::ready) {
                error = make_error_code(boost::system::errc::timed_out);
                return -1;
            }
            if (gate_->fail_write) {
                error = make_error_code(boost::system::errc::io_error);
                return -1;
            }
        }
        return provider_->open_payload(file, write, error);
    }

    std::int64_t payload_size(lt::file_index_t file, lt::error_code &error) override
    {
        return provider_->payload_size(file, error);
    }

private:
    std::shared_ptr<lt::aux::payload_file_provider> provider_;
    std::shared_ptr<PayloadOpenGate> gate_;
};

class CheckpointFixture final {
public:
    explicit CheckpointFixture(fs::path root)
        : root_(std::move(root)), broker_(root_ / "payload")
    {
        std::vector<lt::create_file_entry> entries;
        entries.emplace_back("bundle/skipped.bin", 8192);
        entries.emplace_back("bundle/wanted.bin", 24576);
        lt::create_torrent creator(std::move(entries), 16384, lt::create_torrent::v1_only);
        std::string const bytes(16384, 'x');
        auto const hash = lt::hasher(lt::span<char const>{bytes}).final();
        creator.set_hash(lt::piece_index_t{0}, hash);
        creator.set_hash(lt::piece_index_t{1}, hash);
        auto params = bridge_tests::load_torrent_params(creator.generate_buf(), "checkpoint fixture");
        info_hash_ = params.ti->info_hashes().get_best();
        auto activation = broker_.register_torrent(params);
        provider_ = std::make_shared<GatedPayloadProvider>(
            std::make_shared<BridgePayloadFileProvider>(broker_.context(), activation), open_gate);
        params.file_provider = provider_;
        fs::create_directories(root_ / "parts");
        params.save_path = (root_ / "parts").string();
        params.file_priorities = {lt::dont_download, lt::default_priority};
        params.flags = lt::torrent_flags::disable_dht | lt::torrent_flags::disable_lsd | lt::torrent_flags::disable_pex;
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces, "");
        settings.set_bool(lt::settings_pack::enable_dht, false);
        settings.set_bool(lt::settings_pack::enable_lsd, false);
        settings.set_bool(lt::settings_pack::enable_upnp, false);
        settings.set_bool(lt::settings_pack::enable_natpmp, false);
        constexpr auto alert_mask = static_cast<std::uint32_t>(
            lt::alert_category::status | lt::alert_category::piece_progress
            | lt::alert_category::block_progress | lt::alert_category::error);
        static_assert(std::in_range<int>(alert_mask));
        settings.set_int(lt::settings_pack::alert_mask, static_cast<int>(alert_mask));
        lt::session_params session_params(settings);
        session_params.disk_io_constructor = lt::pread_disk_io_constructor;
        session_ = std::make_unique<lt::session>(std::move(session_params));
        handle = session_->add_torrent(std::move(params));
        wait_for<lt::torrent_checked_alert>();
        handle.pause();
        wait_for<lt::torrent_paused_alert>();
    }

    void write_piece(lt::piece_index_t piece = lt::piece_index_t{0})
    {
        handle.add_piece(piece, std::vector<char>(16384, 'x'));
        // Hash verification can finish against the write cache. Wait for both
        // the hash and disk-write callbacks before asserting saved completion.
        wait_for<lt::piece_finished_alert, lt::block_finished_alert>();
    }

    void wait_for_piece_hash() { wait_for<lt::piece_finished_alert>(); }
    void wait_for_piece_write() { wait_for<lt::block_finished_alert>(); }
    void wait_for_write_error() { wait_for<lt::file_error_alert>(); }

    void check_wanted_payload(char prefix) const
    {
        lt::error_code error;
        REQUIRE(provider_->payload_size(lt::file_index_t{1}, error) == 24576);
        REQUIRE_FALSE(error);
        UniqueFileDescriptor descriptor(provider_->open_payload(lt::file_index_t{1}, false, error));
        REQUIRE_FALSE(error);
        REQUIRE(descriptor.is_valid());
        std::vector<char> bytes(24576);
        // SAFETY: pread borrows this live descriptor and writes at most the
        // owned vector's size; no asynchronous work retains either resource.
        __unsafe_buffer_usage_begin
        auto const count = ::pread(descriptor.get(), bytes.data(), bytes.size(), 0);
        __unsafe_buffer_usage_end
        REQUIRE(count == 24576);
        auto const content = std::span<char const>(bytes);
        CHECK(std::ranges::all_of(content.first(8192), [prefix](char value) { return value == prefix; }));
        CHECK(std::ranges::all_of(content.subspan(8192), [](char value) { return value == 'x'; }));
    }

    void restart(lt::add_torrent_params const &checkpoint)
    {
        auto const encoded = encoded_resume_data(checkpoint, nullptr);
        REQUIRE_FALSE(encoded.empty());
        lt::error_code error;
        auto params = lt::read_resume_data(lt::span<char const>{encoded}, error);
        REQUIRE_FALSE(error);
        // Production restores separately validated metadata and broker authority;
        // neither belongs to the native resume decoder.
        params.ti = checkpoint.ti;
        params.file_provider = provider_;
        params.save_path = (root_ / "parts").string();
        params.flags &= ~(lt::torrent_flags::paused | lt::torrent_flags::auto_managed);
        lt::session_params settings(session_->get_settings());
        settings.disk_io_constructor = lt::pread_disk_io_constructor;
        session_.reset();
        session_ = std::make_unique<lt::session>(std::move(settings));
        handle = session_->add_torrent(std::move(params));
        wait_for<lt::torrent_checked_alert>();
        handle.pause();
        wait_for<lt::torrent_paused_alert>();
    }

    [[nodiscard]] lt::resume_checkpoint_result capture(lt::resume_data_flags_t flags = lt::torrent_handle::flush_disk_cache)
    {
        auto result = handle.capture_resume_data(flags | lt::torrent_handle::save_info_dict);
        REQUIRE(result.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
        return result.get();
    }

    [[nodiscard]] bool persisted_part_is_readable() const
    {
        // An independent reader sees only the on-disk mapping, never the live
        // storage's dirty slot table. No release or destruction flushes it first.
        lt::aux::part_file reader((root_ / "parts").string(), part_name(), 2, 16384);
        std::vector<char> bytes(8192);
        lt::error_code error;
        int const count = reader.read(lt::span<char>{bytes}, lt::piece_index_t{0}, 0, error);
        return !error && count == 8192
            && std::ranges::all_of(bytes, [](char value) { return value == 'x'; });
    }

    [[nodiscard]] fs::path part_path() const { return root_ / "parts" / part_name(); }
    [[nodiscard]] boost::asio::io_context &context() { return session_->native_handle()->get_context(); }

    lt::torrent_handle handle;
    std::shared_ptr<PayloadOpenGate> open_gate = std::make_shared<PayloadOpenGate>();

private:
    [[nodiscard]] std::string part_name() const { return "." + lt::aux::to_hex(info_hash_) + ".parts"; }

    template <typename... Alerts>
    void wait_for()
    {
        std::array<bool, sizeof...(Alerts)> received{};
        auto const deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (std::chrono::steady_clock::now() < deadline) {
            static_cast<void>(session_->wait_for_alert(lt::milliseconds{100}));
            std::vector<lt::alert *> alerts;
            session_->pop_alerts(&alerts);
            for (auto const *alert : alerts) {
                std::size_t index = 0;
                ((received[index] = received[index] || lt::alert_cast<Alerts>(alert) != nullptr, ++index), ...);
                if (std::ranges::all_of(received, [](bool value) { return value; })) return;
                if (auto const *error = lt::alert_cast<lt::file_error_alert>(alert)) {
                    FAIL(error->message());
                }
            }
        }
        FAIL("Native storage did not complete before its test deadline.");
    }

    fs::path root_;
    bridge_tests::TestPayloadBroker broker_;
    lt::sha1_hash info_hash_;
    std::shared_ptr<GatedPayloadProvider> provider_;
    std::unique_ptr<lt::session> session_;
};

class CheckpointChild final {
public:
    explicit CheckpointChild(fs::path const &directory)
    {
        std::uint32_t size = 0;
        static_cast<void>(_NSGetExecutablePath(nullptr, &size));
        if (size == 0 || size > 1024U * 1024U) throw std::runtime_error("Invalid executable path size.");
        std::vector<char> executable(size);
        if (_NSGetExecutablePath(executable.data(), &size) != 0) throw std::runtime_error("Missing executable path.");
        std::string filter = "--test-case=resume checkpoint crash writer";
        std::string no_skip = "--no-skip";
        std::array<char *, 4> arguments{executable.data(), filter.data(), no_skip.data(), nullptr};
        std::vector<std::string> environment;
        // SAFETY: The C runtime owns a stable, NUL-terminated environment pointer
        // array; this sequential test copies it before spawning any new process.
        __unsafe_buffer_usage_begin
        for (char **entry = *_NSGetEnviron(); *entry != nullptr; ++entry) {
            std::string_view const value(*entry);
            if (!value.starts_with("TORRENT7_CHECKPOINT_CRASH_DIRECTORY=")) environment.emplace_back(value);
        }
        __unsafe_buffer_usage_end
        environment.push_back("TORRENT7_CHECKPOINT_CRASH_DIRECTORY=" + directory.string());
        std::vector<char *> environment_pointers;
        for (auto &value : environment) environment_pointers.push_back(value.data());
        environment_pointers.push_back(nullptr);
        // SAFETY: Both pointer arrays are NUL-terminated and borrow owned strings
        // that outlive this synchronous POSIX spawn call; the child receives copies.
        __unsafe_buffer_usage_begin
        int const result = ::posix_spawn(&process_, executable.data(), nullptr, nullptr,
            arguments.data(), environment_pointers.data());
        __unsafe_buffer_usage_end
        if (result != 0) throw std::system_error(result, std::generic_category(), "Could not spawn checkpoint writer");
    }

    CheckpointChild(CheckpointChild const &) = delete;
    CheckpointChild &operator=(CheckpointChild const &) = delete;

    ~CheckpointChild()
    {
        if (process_ <= 0) return;
        static_cast<void>(::kill(process_, SIGKILL));
        // Reap the owned process after termination; abandoning a live child is
        // never a valid response to the operational deadline below.
        while (::waitpid(process_, nullptr, 0) < 0 && errno == EINTR) {}
    }

    [[nodiscard]] int wait()
    {
        auto const deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        while (std::chrono::steady_clock::now() < deadline) {
            int status = 0;
            pid_t const result = ::waitpid(process_, &status, WNOHANG);
            if (result == process_) {
                process_ = -1;
                return status;
            }
            if (result < 0 && errno != EINTR) throw std::runtime_error("Could not wait for checkpoint writer.");
            // This integration test exercises an actual process crash and exit.
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        throw std::runtime_error("Checkpoint writer exceeded its process deadline.");
    }

private:
    pid_t process_ = -1;
};

}

TEST_CASE("resume checkpoint commits a new private partfile mapping before completion")
{
    bridge_tests::TemporaryDirectory directory;
    CheckpointFixture fixture(directory.path());
    fixture.write_piece();
    REQUIRE_FALSE(fixture.persisted_part_is_readable());
    auto checkpoint = fixture.capture();
    REQUIRE(checkpoint);
    REQUIRE(checkpoint->has_value());
    CHECK((**checkpoint).params.have_pieces[lt::piece_index_t{0}]);
    REQUIRE(fixture.persisted_part_is_readable());
}

TEST_CASE("routine checkpoints skip unchanged state and stale acknowledgements retain new changes")
{
    bridge_tests::TemporaryDirectory directory;
    CheckpointFixture fixture(directory.path());
    auto first = fixture.capture();
    REQUIRE(first);
    REQUIRE(first->has_value());
    fixture.handle.set_upload_limit(1234);
    fixture.handle.acknowledge_resume_data((**first).revision);
    auto changed = fixture.capture(lt::torrent_handle::only_if_modified);
    REQUIRE(changed);
    REQUIRE(changed->has_value());
    CHECK((**changed).revision > (**first).revision);
    // A capture alone is not a commit acknowledgement.
    auto retry = fixture.capture(lt::torrent_handle::only_if_modified);
    REQUIRE(retry);
    REQUIRE(retry->has_value());
    fixture.handle.acknowledge_resume_data((**retry).revision);
    auto unchanged = fixture.capture(lt::torrent_handle::only_if_modified);
    REQUIRE(unchanged);
    CHECK_FALSE(unchanged->has_value());
}

TEST_CASE("changes while the checkpoint fence is pending remain outside its captured revision")
{
    bridge_tests::TemporaryDirectory directory;
    CheckpointFixture fixture(directory.path());
    int const original_limit = fixture.handle.upload_limit();
    auto entered = fixture.open_gate->entered.get_future();
    fixture.open_gate->armed = true;
    fixture.handle.add_piece(lt::piece_index_t{0}, std::vector<char>(16384, 'x'));
    auto completion = fixture.handle.capture_resume_data(lt::torrent_handle::flush_disk_cache);
    REQUIRE(entered.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    fixture.handle.set_upload_limit(4321);
    REQUIRE(fixture.handle.upload_limit() == 4321);
    fixture.open_gate->release.set_value();
    REQUIRE(completion.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    auto checkpoint = completion.get();
    REQUIRE(checkpoint);
    REQUIRE(checkpoint->has_value());
    CHECK((**checkpoint).params.upload_limit == original_limit);
    fixture.handle.acknowledge_resume_data((**checkpoint).revision);
    auto next = fixture.capture(lt::torrent_handle::only_if_modified);
    REQUIRE(next);
    REQUIRE(next->has_value());
    CHECK((**next).params.upload_limit == 4321);
}

TEST_CASE("disk completion after capture remains dirty even when hashing finished earlier")
{
    bridge_tests::TemporaryDirectory directory;
    CheckpointFixture fixture(directory.path());
    SUBCASE("another piece is still missing") {}
    SUBCASE("the last outstanding piece passes its hash check") {
        fixture.write_piece(lt::piece_index_t{1});
        REQUIRE(fixture.capture());
    }
    auto entered = fixture.open_gate->entered.get_future();
    fixture.open_gate->armed = true;
    fixture.handle.add_piece(lt::piece_index_t{0}, std::vector<char>(16384, 'x'));
    REQUIRE(entered.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    fixture.wait_for_piece_hash();
    auto completion = fixture.handle.capture_resume_data(lt::torrent_handle::flush_disk_cache);
    // A synchronous getter drains earlier native commands without mutating
    // state, proving the prefix was captured before the write is released.
    static_cast<void>(fixture.handle.upload_limit());
    fixture.open_gate->release.set_value();
    REQUIRE(completion.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    auto checkpoint = completion.get();
    REQUIRE(checkpoint);
    REQUIRE(checkpoint->has_value());
    CHECK_FALSE((**checkpoint).params.have_pieces[lt::piece_index_t{0}]);
    fixture.wait_for_piece_write();
    fixture.handle.acknowledge_resume_data((**checkpoint).revision);
    auto next = fixture.capture(lt::torrent_handle::only_if_modified);
    REQUIRE(next);
    REQUIRE(next->has_value());
    CHECK((**next).params.have_pieces[lt::piece_index_t{0}]);
}

TEST_CASE("resume checkpoint propagates a partfile header write failure")
{
    bridge_tests::TemporaryDirectory directory;
    CheckpointFixture fixture(directory.path());
    auto entered = fixture.open_gate->entered.get_future();
    fixture.open_gate->armed = true;
    fixture.handle.add_piece(lt::piece_index_t{0}, std::vector<char>(16384, 'x'));
    auto completion = fixture.handle.capture_resume_data(lt::torrent_handle::flush_disk_cache);
    REQUIRE(entered.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    // The skipped fragment has reached disk, but the fenced write is held at
    // the following wanted fragment. Fail only the later partfile-header write.
    auto const path = fixture.part_path();
    fs::rename(path, path.string() + ".held");
    fs::create_directory(path);
    fixture.open_gate->release.set_value();
    REQUIRE(completion.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    auto checkpoint = completion.get();
    REQUIRE_FALSE(checkpoint);
    CHECK(fixture.handle.need_save_resume_data());
    fs::remove(path);
    fs::rename(path.string() + ".held", path);
    auto retry = fixture.capture();
    REQUIRE(retry);
    REQUIRE(retry->has_value());
    CHECK(fixture.persisted_part_is_readable());
}

TEST_CASE("last-piece checkpoints exclude a failed wanted write across restart")
{
    bridge_tests::TemporaryDirectory directory;
    CheckpointFixture fixture(directory.path());
    // The later extent is correct, but the first wanted extent is still zero.
    // Its full-sized file would pass the seed fast-resume size check.
    fixture.write_piece(lt::piece_index_t{1});
    REQUIRE(fixture.capture()); // Release cached descriptors before gating open.
    fixture.check_wanted_payload('\0');
    auto entered = fixture.open_gate->entered.get_future();
    fixture.open_gate->fail_write = true;
    fixture.open_gate->armed = true;
    fixture.handle.add_piece(lt::piece_index_t{0}, std::vector<char>(16384, 'x'));
    REQUIRE(entered.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    fixture.wait_for_piece_hash();
    REQUIRE(fixture.handle.status().is_seeding);
    auto completion = fixture.handle.capture_resume_data(lt::torrent_handle::save_info_dict);
    static_cast<void>(fixture.handle.upload_limit()); // Capture precedes failure.
    fixture.open_gate->release.set_value();
    REQUIRE(completion.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    auto checkpoint = completion.get();
    REQUIRE(checkpoint);
    REQUIRE(checkpoint->has_value());
    CHECK_FALSE((**checkpoint).params.have_pieces[lt::piece_index_t{0}]);
    CHECK((**checkpoint).params.have_pieces[lt::piece_index_t{1}]);
    fixture.wait_for_write_error();
    fixture.check_wanted_payload('\0');
    CHECK(fixture.persisted_part_is_readable()); // The release itself succeeded.
    auto retry = fixture.capture();
    REQUIRE(retry);
    REQUIRE(retry->has_value());
    CHECK_FALSE((**retry).params.have_pieces[lt::piece_index_t{0}]);

    fixture.restart((**checkpoint).params);
    REQUIRE_FALSE(fixture.handle.status().is_seeding);
    CHECK_FALSE(fixture.handle.have_piece(lt::piece_index_t{0}));
    CHECK(fixture.handle.have_piece(lt::piece_index_t{1}));
    fixture.check_wanted_payload('\0');
    fixture.write_piece();
    fixture.check_wanted_payload('x');
    auto repaired = fixture.capture();
    REQUIRE(repaired);
    REQUIRE(repaired->has_value());
    CHECK((**repaired).params.have_pieces.all_set());
    fixture.restart((**repaired).params);
    CHECK(fixture.handle.status().is_seeding);
}

TEST_CASE("an abandoned resume future owns no caller state when its queued callback runs")
{
    bridge_tests::TemporaryDirectory directory;
    CheckpointFixture fixture(directory.path());
    struct Gate {
        std::promise<void> entered;
        std::promise<void> release;
    };
    auto gate = std::make_shared<Gate>();
    auto entered = gate->entered.get_future();
    auto release = gate->release.get_future().share();
    boost::asio::post(fixture.context(), [gate, release]() noexcept {
        gate->entered.set_value();
        static_cast<void>(release.wait_for(std::chrono::seconds(5)));
    });
    REQUIRE(entered.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
    {
        auto abandoned = fixture.handle.capture_resume_data(lt::torrent_handle::flush_disk_cache);
        CHECK(abandoned.wait_for(std::chrono::seconds(0)) == std::future_status::timeout);
    }
    gate->release.set_value();
    auto next = fixture.capture(lt::torrent_handle::only_if_modified);
    REQUIRE(next);
    CHECK(next->has_value());
}

TEST_CASE("resume checkpoint crash writer" * doctest::skip())
{
    char const *directory = std::getenv("TORRENT7_CHECKPOINT_CRASH_DIRECTORY");
    REQUIRE(directory != nullptr);
    CheckpointFixture fixture(directory);
    fixture.write_piece();
    REQUIRE_FALSE(fixture.persisted_part_is_readable());
    auto checkpoint = fixture.capture();
    REQUIRE(checkpoint);
    REQUIRE(checkpoint->has_value());
    REQUIRE(fixture.persisted_part_is_readable());
    // Simulate abrupt helper loss: no session/partfile destructors or atexit
    // handlers are allowed to supply a flush missing from the checkpoint.
    std::_Exit(0);
}

TEST_CASE("private partfile mapping survives process exit without teardown")
{
    bridge_tests::TemporaryDirectory directory;
    CheckpointChild child(directory.path());
    int status = child.wait(); // Darwin's wait-status macros require a mutable int.
    REQUIRE(WIFEXITED(status));
    REQUIRE(WEXITSTATUS(status) == 0);
    std::vector<fs::path> parts;
    for (auto const &entry : fs::directory_iterator(directory.path() / "parts")) {
        if (entry.path().extension() == ".parts") parts.push_back(entry.path());
    }
    REQUIRE(parts.size() == 1U);
    lt::aux::part_file restored(parts.front().parent_path().string(), parts.front().filename().string(), 2, 16384);
    std::vector<char> bytes(8192);
    lt::error_code error;
    REQUIRE(restored.read(lt::span<char>{bytes}, lt::piece_index_t{0}, 0, error) == 8192);
    REQUIRE_FALSE(error);
    CHECK(std::ranges::all_of(bytes, [](char value) { return value == 'x'; }));
}
