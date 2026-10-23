#include "BridgeTestSupport.hpp"

#include <doctest.h>
#include <libtorrent/aux_/file_pool.hpp>
#include <libtorrent/aux_/payload_file_provider.hpp>
#include <libtorrent/aux_/pread_storage.hpp>
#include <libtorrent/aux_/session_settings.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/pread_disk_io.hpp>

namespace {

// Real descriptors and native storage, with the same content/stat distinction
// as the GUI broker. Tests mutate availability only between disk operations.
class RestrictivePayloadProvider final : public lt::aux::payload_file_provider {
public:
    explicit RestrictivePayloadProvider(fs::path const &root)
        : paths{root / "skip.bin", root / "wanted.bin"} {}

    int open_payload(lt::file_index_t file, bool write, lt::error_code &error) override
    {
        auto const index = static_cast<std::size_t>(static_cast<int>(file));
        if (!available.at(index).load()) {
            ++denied_opens;
            error = make_error_code(boost::system::errc::permission_denied);
            return -1;
        }
        int const descriptor = ::open(paths.at(index).c_str(),
            (write ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor < 0) error.assign(errno, lt::system_category());
        last_descriptor.at(index) = descriptor;
        return descriptor;
    }

    std::int64_t payload_size(lt::file_index_t file, lt::error_code &error) override
    {
        if (gate_armed.exchange(false)) {
            gate_entered.set_value();
            if (gate_release.get_future().wait_for(std::chrono::seconds(5)) != std::future_status::ready) {
                error = make_error_code(boost::system::errc::timed_out);
                return -1;
            }
        }
        if (reject_stat.load()) {
            error = make_error_code(boost::system::errc::permission_denied);
            return -1;
        }
        std::error_code filesystem_error;
        auto const size = fs::file_size(paths.at(static_cast<std::size_t>(static_cast<int>(file))), filesystem_error);
        if (filesystem_error) {
            error.assign(filesystem_error.value(), lt::system_category());
            return -1;
        }
        return static_cast<std::int64_t>(size);
    }

    std::array<fs::path, 2> paths;
    std::array<std::atomic_bool, 2> available{true, true};
    std::array<std::atomic_int, 2> last_descriptor{-1, -1};
    std::atomic_int denied_opens{0};
    std::atomic_bool gate_armed{false};
    std::atomic_bool reject_stat{false};
    std::promise<void> gate_entered;
    std::promise<void> gate_release;
};

struct SharedPieceStorage {
    bridge_tests::TemporaryDirectory directory;
    lt::file_storage files;
    lt::renamed_files renamed;
    lt::aux::file_pool pool;
    lt::aux::session_settings settings;
    std::shared_ptr<RestrictivePayloadProvider> provider;
    lt::aux::vector<lt::download_priority_t, lt::file_index_t> priorities;
    lt::sha1_hash const hash = bridge_tests::sha1_hash_from_seed(31U);
    std::unique_ptr<lt::aux::pread_storage> storage;

    explicit SharedPieceStorage(bool skipped, std::size_t initial_size, int file_size = 8192)
        : provider(std::make_shared<RestrictivePayloadProvider>(directory.path()))
        , priorities{skipped ? lt::dont_download : lt::default_priority, lt::default_priority}
    {
        files.add_file("bundle/skip.bin", file_size);
        files.add_file("bundle/wanted.bin", file_size);
        files.set_piece_length(16 * 1024);
        files.set_num_pieces((file_size * 2 + 16383) / 16384);
        bridge_tests::write_text_file(provider->paths[0], std::string(initial_size, 's'));
        bridge_tests::write_text_file(provider->paths[1], "");
        provider->available[0] = !skipped;
        reopen();
    }

    void reopen()
    {
        storage.reset();
        storage = std::make_unique<lt::aux::pread_storage>(lt::storage_params{
            files, renamed, directory.path().string(), "", lt::storage_mode_sparse,
            priorities, hash, true, false, provider}, pool);
        lt::storage_error error;
        static_cast<void>(storage->initialize(settings, error));
        REQUIRE_FALSE(error);
    }

    void write_piece()
    {
        for (auto piece : files.piece_range()) {
            std::string const bytes(static_cast<std::size_t>(files.piece_size(piece)), 'x');
            lt::storage_error error;
            CHECK(storage->write(settings, lt::span<char const>{bytes}, piece, 0,
                lt::aux::open_mode::write, {}, error) == static_cast<int>(bytes.size()));
            REQUIRE_FALSE(error);
        }
    }

    void check_piece(bool wanted_only = false)
    {
        for (auto piece : files.piece_range()) {
            if (wanted_only && (static_cast<int>(piece) + 1) * files.piece_length() <= files.file_size(lt::file_index_t{0})) continue;
            std::vector<char> bytes(static_cast<std::size_t>(files.piece_size(piece)));
            lt::storage_error error;
            CHECK(storage->read(settings, lt::span<char>{bytes}, piece, 0,
                lt::aux::open_mode::read_only, {}, error) == static_cast<int>(bytes.size()));
            REQUIRE_FALSE(error);
            CHECK(std::ranges::all_of(bytes, [](char value) { return value == 'x'; }));
        }
    }

    void change_priority(lt::download_priority_t priority)
    {
        priorities[lt::file_index_t{0}] = priority;
        lt::storage_error error;
        storage->set_file_priority(settings, priorities, error);
        REQUIRE_FALSE(error);
    }
};

}

TEST_CASE("initial skipped payloads never receive content descriptors, including nonempty imports")
{
    for (std::size_t const size : {0U, 1U, 8192U}) {
        CAPTURE(size);
        SharedPieceStorage fixture(true, size);
        fixture.write_piece();
        fixture.pool.release();
        fixture.check_piece();
        fixture.reopen();
        fixture.check_piece();
        CHECK(fixture.provider->denied_opens.load() == 0);
        CHECK(fs::file_size(fixture.provider->paths[0]) == size);
    }
}

TEST_CASE("dynamic skip preserves shared pieces through revocation, eviction, restart and unskip")
{
    for (bool const downloaded : {false, true}) {
        SharedPieceStorage fixture(false, 0);
        if (downloaded) fixture.write_piece();
        int const previous_descriptor = fixture.provider->last_descriptor[0].load();
        fixture.change_priority(lt::dont_download);
        if (downloaded) {
            CHECK(::fcntl(previous_descriptor, F_GETFD) == -1);
            CHECK(errno == EBADF);
        }
        fixture.provider->available[0] = false;
        fixture.pool.release();
        if (!downloaded) fixture.write_piece();
        fixture.check_piece();
        fixture.reopen();
        fixture.check_piece();
        CHECK(fixture.provider->denied_opens.load() == 0);
        fixture.provider->available[0] = true;
        fixture.change_priority(lt::default_priority);
        fixture.pool.release();
        fixture.check_piece();
        fixture.change_priority(lt::dont_download);
        fixture.provider->available[0] = false;
        fixture.pool.release();
        fixture.check_piece();
        CHECK(fixture.provider->denied_opens.load() == 0);
    }
}

TEST_CASE("failed skip keeps the original priority and readable payload")
{
    SharedPieceStorage fixture(false, 8192);
    fixture.write_piece();
    fixture.pool.release();
    // A directory occupying the private partfile path deterministically fails
    // its write without depending on filesystem capacity or permissions.
    fs::create_directory(fixture.directory.path() / ("." + lt::aux::to_hex(fixture.hash) + ".parts"));
    fixture.priorities[lt::file_index_t{0}] = lt::dont_download;
    lt::storage_error error;
    fixture.storage->set_file_priority(fixture.settings, fixture.priorities, error);
    REQUIRE(error);
    CHECK(fixture.priorities[lt::file_index_t{0}] == lt::default_priority);
    fixture.pool.release();
    fixture.check_piece();
}

TEST_CASE("a cancelled copy retains priority, closes its handle and preserves data")
{
    SharedPieceStorage fixture(false, 8192);
    fixture.write_piece();
    int const descriptor = fixture.provider->last_descriptor[0].load();
    fixture.priorities[lt::file_index_t{0}] = lt::dont_download;
    lt::storage_error error;
    std::stop_source cancellation;
    cancellation.request_stop();
    fixture.storage->set_file_priority(fixture.settings, fixture.priorities, error, cancellation.get_token());
    CHECK(error.ec == boost::asio::error::operation_aborted);
    CHECK(fixture.priorities[lt::file_index_t{0}] == lt::default_priority);
    CHECK(::fcntl(descriptor, F_GETFD) == -1);
    CHECK(errno == EBADF);
    fixture.check_piece();
}

TEST_CASE("checked native priority completion waits for the disk transition")
{
    for (bool const cancelled : {false, true}) {
        CAPTURE(cancelled);
        SharedPieceStorage fixture(false, 8192);
        fixture.write_piece();
        fixture.storage.reset();
        std::vector<lt::create_file_entry> entries;
        entries.emplace_back("bundle/skip.bin", 8192);
        entries.emplace_back("bundle/wanted.bin", 8192);
        lt::create_torrent creator(std::move(entries), 16384, lt::create_torrent::v1_only);
        std::string const bytes(16384, 'x');
        creator.set_hash(lt::piece_index_t{0}, lt::hasher(lt::span<char const>{bytes}).final());
        auto params = bridge_tests::load_torrent_params(creator.generate_buf(), "shared piece");
        params.save_path = fixture.directory.path().string();
        params.file_provider = fixture.provider;
        params.flags = lt::torrent_flags::paused | lt::torrent_flags::seed_mode;
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces, "");
        settings.set_bool(lt::settings_pack::enable_dht, false);
        settings.set_bool(lt::settings_pack::enable_lsd, false);
        settings.set_bool(lt::settings_pack::enable_upnp, false);
        settings.set_bool(lt::settings_pack::enable_natpmp, false);
        lt::session_params session_params(settings);
        session_params.disk_io_constructor = lt::pread_disk_io_constructor;
        lt::session session(std::move(session_params));
        auto handle = session.add_torrent(params);
        auto entered = fixture.provider->gate_entered.get_future();
        fixture.provider->gate_armed = true;
        std::stop_source cancellation;
        auto completion = handle.set_file_priorities_checked({{lt::file_index_t{0}, lt::dont_download}}, cancellation.get_token());
        REQUIRE(entered.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
        CHECK(completion.wait_for(std::chrono::seconds(0)) == std::future_status::timeout);
        CHECK_THROWS_AS(static_cast<void>(handle.set_file_priorities_checked(
            {{lt::file_index_t{0}, lt::default_priority}}, {})), lt::system_error);
        if (cancelled) cancellation.request_stop();
        fixture.provider->gate_release.set_value();
        REQUIRE(completion.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
        if (cancelled) {
            CHECK(completion.get() == boost::asio::error::operation_aborted);
            CHECK(handle.file_priority(lt::file_index_t{0}) == lt::default_priority);
        } else {
            CHECK_FALSE(completion.get());
            CHECK(handle.file_priority(lt::file_index_t{0}) == lt::dont_download);
            fixture.provider->available[0] = false;
        }
        CHECK(fixture.provider->denied_opens.load() == 0);
    }
}

TEST_CASE("failed partfile export retains every complete slot")
{
    bridge_tests::TemporaryDirectory directory;
    lt::aux::part_file part(directory.path().string(), "test.parts", 3, 16384);
    std::string const bytes(16384, 'x');
    lt::error_code error;
    for (int index = 0; index < 3; ++index) {
        REQUIRE(part.write(lt::span<char const>{bytes}, lt::piece_index_t{index}, 0, error) == 16384);
        REQUIRE_FALSE(error);
    }
    int copied = 0;
    CHECK_THROWS_AS(part.export_file([&copied](std::int64_t, lt::span<char>) {
        if (++copied == 2) throw std::runtime_error("injected export write failure");
    }, 0, 3 * 16384, error), std::runtime_error);
    for (int index = 0; index < 3; ++index) {
        std::vector<char> restored(16384);
        REQUIRE(part.read(lt::span<char>{restored}, lt::piece_index_t{index}, 0, error) == 16384);
        REQUIRE_FALSE(error);
        CHECK(std::ranges::all_of(restored, [](char value) { return value == 'x'; }));
    }
}

TEST_CASE("skipping a larger file copies only its wanted boundary fragment")
{
    SharedPieceStorage fixture(false, 40960, 40960);
    fixture.write_piece();
    fixture.change_priority(lt::dont_download);
    CHECK(fs::file_size(fixture.directory.path() / ("." + lt::aux::to_hex(fixture.hash) + ".parts")) < 2 * 16384);
    fixture.provider->available[0] = false;
    fixture.pool.release();
    fixture.check_piece(true);
    fixture.reopen();
    fixture.check_piece(true);
    fixture.provider->available[0] = true;
    fixture.change_priority(lt::default_priority);
    fixture.pool.release();
    fixture.check_piece();
    CHECK(fixture.provider->denied_opens.load() == 0);
}

TEST_CASE("private storage retains boundary pieces and physically reclaims unused slots")
{
    bridge_tests::TemporaryDirectory directory;
    auto const path = directory.path() / "test.parts";
    lt::aux::part_file part(directory.path().string(), "test.parts", 256, 16384);
    std::string const bytes(16384, 'x');
    lt::error_code error;
    for (int index = 0; index < 256; ++index) {
        REQUIRE(part.write(lt::span<char const>{bytes}, lt::piece_index_t{index}, 0, error) == 16384);
        REQUIRE_FALSE(error);
    }
    part.flush_metadata(error);
    REQUIRE_FALSE(error);
    auto const original_size = fs::file_size(path);
    lt::typed_bitfield<lt::piece_index_t> keep(256, false);
    keep.set_bit(lt::piece_index_t{127});
    std::stop_source stop;
    stop.request_stop();
    part.retain_pieces(keep, stop.get_token(), error);
    CHECK(error == boost::asio::error::operation_aborted);
    CHECK(fs::file_size(path) == original_size);
    CHECK_FALSE(fs::exists(directory.path() / "test.parts.compact"));

    error.clear();
    part.retain_pieces(keep, {}, error);
    REQUIRE_FALSE(error);
    CHECK(fs::file_size(path) < 2 * 16384);
    std::array<char, 16384> restored{};
    CHECK(part.read(restored, lt::piece_index_t{127}, 0, error) == 16384);
    REQUIRE_FALSE(error);
    CHECK(std::ranges::all_of(restored, [](char value) { return value == 'x'; }));
    keep.clear_all();
    part.retain_pieces(keep, {}, error);
    REQUIRE_FALSE(error);
    CHECK_FALSE(fs::exists(path));
}

TEST_CASE("a whole-folder skip allocates no private copy, even for large sparse files")
{
    SharedPieceStorage fixture(false, 0, 512 * 1024 * 1024);
    fs::resize_file(fixture.provider->paths[0], 512 * 1024 * 1024);
    fs::resize_file(fixture.provider->paths[1], 512 * 1024 * 1024);
    fixture.priorities.assign(2, lt::dont_download);
    lt::storage_error error;
    fixture.storage->set_file_priority(fixture.settings, fixture.priorities, error);
    REQUIRE_FALSE(error);
    CHECK(fixture.provider->last_descriptor[0].load() == -1);
    CHECK(fixture.provider->last_descriptor[1].load() == -1);
    CHECK_FALSE(fs::exists(fixture.directory.path() / ("." + lt::aux::to_hex(fixture.hash) + ".parts")));
    CHECK(fs::file_size(fixture.provider->paths[0]) == 512 * 1024 * 1024);
}

TEST_CASE("selection forgets skipped-only availability and reuses re-enabled payloads")
{
    enum class Format { v1, hybrid, v2_metadata };
    for (auto const format : {Format::v1, Format::hybrid, Format::v2_metadata}) {
        CAPTURE(static_cast<int>(format));
        SharedPieceStorage fixture(false, 32768, 32768);
        fixture.write_piece();
        fixture.storage.reset();
        std::vector<lt::create_file_entry> entries;
        entries.emplace_back("bundle/skip.bin", 32768);
        entries.emplace_back("bundle/wanted.bin", 32768);
        lt::create_torrent creator(std::move(entries), 16384,
            format == Format::v1 ? lt::create_torrent::v1_only
                : format == Format::hybrid ? lt::create_flags_t{} : lt::create_torrent::v2_only);
        std::string const bytes(16384, 'x');
        if (format != Format::v2_metadata) {
            for (int index = 0; index < 4; ++index)
                creator.set_hash(lt::piece_index_t{index}, lt::hasher(lt::span<char const>{bytes}).final());
        }
        if (format != Format::v1) {
            for (int file = 0; file < 2; ++file)
                for (int piece = 0; piece < 2; ++piece)
                    creator.set_hash2(lt::file_index_t{file}, lt::piece_index_t::diff_type{piece},
                        lt::hasher256(lt::span<char const>{bytes}).final());
        }
        auto params = bridge_tests::load_torrent_params(creator.generate_buf(), "selective pieces");
        if (format == Format::v2_metadata) {
            // A v2 magnet has file roots without the optional piece layers.
            params.merkle_trees.clear();
            params.merkle_tree_mask.clear();
            params.verified_leaf_hashes.clear();
        }
        params.save_path = fixture.directory.path().string();
        params.file_provider = fixture.provider;
        params.flags = lt::torrent_flags::paused | lt::torrent_flags::seed_mode;
        lt::settings_pack settings;
        settings.set_str(lt::settings_pack::listen_interfaces, "");
        settings.set_bool(lt::settings_pack::enable_dht, false);
        settings.set_bool(lt::settings_pack::enable_lsd, false);
        settings.set_bool(lt::settings_pack::enable_upnp, false);
        settings.set_bool(lt::settings_pack::enable_natpmp, false);
        lt::session_params session_params(settings);
        session_params.disk_io_constructor = lt::pread_disk_io_constructor;
        lt::session session(std::move(session_params));
        auto handle = session.add_torrent(params);
        auto skipped = handle.set_file_priorities_checked({{lt::file_index_t{0}, lt::dont_download}}, {});
        REQUIRE(skipped.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
        REQUIRE_FALSE(skipped.get());
        fixture.provider->available[0] = false;
        auto const status = handle.status(lt::torrent_handle::query_pieces);
        REQUIRE(status.pieces.size() == 4);
        CHECK_FALSE(status.pieces[lt::piece_index_t{0}]);
        CHECK_FALSE(status.pieces[lt::piece_index_t{1}]);
        CHECK(status.pieces[lt::piece_index_t{2}]);
        CHECK(status.pieces[lt::piece_index_t{3}]);
        CHECK(status.total_wanted_done == 32768);
        CHECK(static_cast<bool>(status.flags & lt::torrent_flags::paused));
        auto capture = handle.capture_resume_data(lt::torrent_handle::save_info_dict);
        REQUIRE(capture.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
        auto checkpoint = capture.get();
        REQUIRE(checkpoint.has_value());
        REQUIRE(checkpoint->has_value());
        CHECK((**checkpoint).params.have_pieces == status.pieces);
        REQUIRE((**checkpoint).params.file_priorities.size() == 2);
        CHECK((**checkpoint).params.file_priorities.front() == lt::dont_download);
        fixture.provider->available[0] = true;
        auto enabled = handle.set_file_priorities_checked({{lt::file_index_t{0}, lt::default_priority}}, {});
        REQUIRE(enabled.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
        REQUIRE_FALSE(enabled.get());
        auto const restored = handle.status(lt::torrent_handle::query_pieces);
        CHECK(restored.total_wanted_done == 65536);
        CHECK(restored.is_seeding);
        CHECK(fixture.provider->denied_opens.load() == 0);
        handle.force_recheck();
        auto during_check = handle.set_file_priorities_checked({{lt::file_index_t{0}, lt::dont_download}}, {});
        REQUIRE(during_check.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
        REQUIRE_FALSE(during_check.get());
        CHECK(handle.file_priority(lt::file_index_t{0}) == lt::dont_download);
        CHECK(static_cast<bool>(handle.status().flags & lt::torrent_flags::paused));
        if (format == Format::v1) {
            auto entered = fixture.provider->gate_entered.get_future();
            fixture.provider->gate_armed = true;
            fixture.provider->reject_stat = true;
            handle.force_recheck();
            REQUIRE(entered.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
            auto rejected = handle.set_file_priorities_checked({{lt::file_index_t{0}, lt::default_priority}}, {});
            fixture.provider->gate_release.set_value();
            REQUIRE(rejected.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
            CHECK(rejected.get() == boost::system::errc::permission_denied);
            // An already failed check must also reject a later selection.
            rejected = handle.set_file_priorities_checked({{lt::file_index_t{0}, lt::default_priority}}, {});
            REQUIRE(rejected.wait_for(std::chrono::seconds(5)) == std::future_status::ready);
            CHECK(rejected.get() == boost::system::errc::permission_denied);
            CHECK(handle.file_priority(lt::file_index_t{0}) == lt::dont_download);
        }
    }
}
