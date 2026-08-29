#include "PointerAuthenticationFailureTestSupport.hpp"

#include <libtorrent/assert.hpp>
#include <libtorrent/aux_/buffer.hpp>
#include <libtorrent/aux_/debug.hpp>
#include <libtorrent/aux_/throw.hpp>
#include <libtorrent/config.hpp>

#include <boost/asio/buffer.hpp>

#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <type_traits>
#include <utility>
#include <vector>

// This white-box harness needs the authenticated fields' real storage
// addresses without adding test hooks to libtorrent's production headers.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wkeyword-macro"
#define private public
#include <libtorrent/aux_/chained_buffer.hpp>
#include <libtorrent/aux_/heterogeneous_queue.hpp>
#undef private
#pragma clang diagnostic pop

namespace {

struct queue_base {
  virtual ~queue_base() = default;
};

struct queue_item final : queue_base {
  queue_item() = default;
  queue_item(queue_item&&) noexcept = default;
  queue_item& operator=(queue_item&&) noexcept = default;
};

__attribute__((noinline)) void replay_object_bytes(
    void* destination, void const* source, std::size_t size)
{
  std::memcpy(destination, source, size);
}

} // namespace

extern "C" __attribute__((noinline)) void torrent7_invoke_chained_buffer_destructor(
    libtorrent::aux::chained_buffer::buffer_t* entry)
{
  entry->destruct_holder(&entry->holder);
}

extern "C" __attribute__((noinline)) void torrent7_invoke_heterogeneous_queue_move(
    libtorrent::heterogeneous_queue<queue_base>::header_t* header,
    char* destination, char* source)
{
  header->move(destination, source);
}

int main()
{
  {
    libtorrent::aux::chained_buffer buffer;
    buffer.append_buffer(std::vector<char>(4), 4);
    buffer.clear();
  }

  {
    using queue_type = libtorrent::heterogeneous_queue<queue_base>;
    queue_type queue;
    static_cast<void>(queue.emplace_back<queue_item>());
    auto* const header = reinterpret_cast<queue_type::header_t*>(queue.m_storage.get());
    alignas(queue_item) std::array<char, sizeof(queue_item)> source_item{};
    alignas(queue_item) std::array<char, sizeof(queue_item)> destination_item{};
    new (source_item.data()) queue_item;
    torrent7_invoke_heterogeneous_queue_move(
        header, destination_item.data(), source_item.data());
    reinterpret_cast<queue_item*>(destination_item.data())->~queue_item();
  }

  using torrent7::test_support::complete_replay_without_authentication_fault;
  using torrent7::test_support::replay_triggers_pointer_authentication_failure;

  if (!replay_triggers_pointer_authentication_failure([](std::size_t attempt) {
        std::vector<std::unique_ptr<libtorrent::aux::chained_buffer>> decoys;
        decoys.reserve(attempt);
        for (std::size_t index = 0; index < attempt; ++index) {
          auto decoy = std::make_unique<libtorrent::aux::chained_buffer>();
          decoy->append_buffer(std::vector<char>(4), 4);
          decoys.push_back(std::move(decoy));
        }
        libtorrent::aux::chained_buffer source;
        libtorrent::aux::chained_buffer destination;
        source.append_buffer(std::vector<char>(4), 4);
        destination.append_buffer(std::vector<char>(4), 4);
        replay_object_bytes(
            &destination.m_vec.front(),
            &source.m_vec.front(),
            sizeof(source.m_vec.front()));
        torrent7_invoke_chained_buffer_destructor(&destination.m_vec.front());
        complete_replay_without_authentication_fault();
      }))
  {
    std::fputs("chained-buffer destructor callback replay was accepted\n", stderr);
    return 1;
  }

  if (!replay_triggers_pointer_authentication_failure([](std::size_t attempt) {
        using queue_type = libtorrent::heterogeneous_queue<queue_base>;
        std::vector<std::unique_ptr<queue_type>> decoys;
        decoys.reserve(attempt);
        for (std::size_t index = 0; index < attempt; ++index) {
          auto decoy = std::make_unique<queue_type>();
          static_cast<void>(decoy->emplace_back<queue_item>());
          decoys.push_back(std::move(decoy));
        }
        queue_type source;
        queue_type destination;
        static_cast<void>(source.emplace_back<queue_item>());
        static_cast<void>(destination.emplace_back<queue_item>());
        replay_object_bytes(
            destination.m_storage.get(),
            source.m_storage.get(),
            sizeof(queue_type::header_t));

        auto* const header = reinterpret_cast<queue_type::header_t*>(destination.m_storage.get());
        alignas(queue_item) std::array<char, sizeof(queue_item)> source_item{};
        alignas(queue_item) std::array<char, sizeof(queue_item)> destination_item{};
        new (source_item.data()) queue_item;
        torrent7_invoke_heterogeneous_queue_move(
            header, destination_item.data(), source_item.data());
        complete_replay_without_authentication_fault();
      }))
  {
    std::fputs("heterogeneous-queue move callback replay was accepted\n", stderr);
    return 1;
  }

  return 0;
}
