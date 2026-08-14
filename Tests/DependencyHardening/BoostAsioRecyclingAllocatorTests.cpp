#include <boost/asio/cancellation_signal.hpp>
#include <boost/asio/detail/recycling_allocator.hpp>
#include <boost/asio/detail/thread_context.hpp>
#include <boost/asio/detail/thread_info_base.hpp>

#include <malloc/malloc.h>

#include <cstddef>
#include <cstdio>

#if !defined(_MALLOC_TYPE_ENABLED) || !_MALLOC_TYPE_ENABLED
# error "This test requires typed memory operations"
#endif

namespace {

struct pointer_rich_operation
{
  void* object;
  const int* state;
};

struct pointer_rich_peer
{
  void* context;
  int* result;
};

struct cancellation_handler_one
{
  bool* called;

  void operator()(boost::asio::cancellation_type_t) const
  {
    *called = true;
  }
};

struct cancellation_handler_two
{
  const void* context;
  bool* called;

  void operator()(boost::asio::cancellation_type_t) const
  {
    *called = context != nullptr;
  }
};

static_assert(sizeof(pointer_rich_operation) == sizeof(pointer_rich_peer));
static_assert(alignof(pointer_rich_operation) == alignof(pointer_rich_peer));

constexpr malloc_type_id_t operation_type =
    __builtin_tmo_get_type_descriptor(pointer_rich_operation);
constexpr malloc_type_id_t peer_type =
    __builtin_tmo_get_type_descriptor(pointer_rich_peer);

static_assert(operation_type != peer_type);
static_assert((operation_type >> 48) != 0);
static_assert((peer_type >> 48) != 0);

class thread_context_probe : public boost::asio::detail::thread_context
{
public:
  using call_stack_type = thread_call_stack;
};

} // namespace

int main()
{
  thread_context_probe owner;
  boost::asio::detail::thread_info_base thread_info;
  thread_context_probe::call_stack_type::context active_context(
      &owner, thread_info);

  boost::asio::detail::recycling_allocator<pointer_rich_operation>
      operation_allocator;
  boost::asio::detail::recycling_allocator<pointer_rich_peer>
      peer_allocator;

  pointer_rich_operation* const first_operation =
      operation_allocator.allocate(1);
  operation_allocator.deallocate(first_operation, 1);

  pointer_rich_peer* const peer = peer_allocator.allocate(1);
  if (static_cast<void*>(peer) == static_cast<void*>(first_operation))
  {
    std::fputs(
        "Asio recycler reused storage with a different type descriptor\n",
        stderr);
    return 1;
  }
  peer_allocator.deallocate(peer, 1);

  pointer_rich_operation* const second_operation =
      operation_allocator.allocate(1);
  if (second_operation != first_operation)
  {
    std::fputs(
        "Asio recycler did not retain the matching typed cache entry\n",
        stderr);
    return 1;
  }
  operation_allocator.deallocate(second_operation, 1);

  // Asio destroys cancellation handlers through an erased void pointer. The
  // descriptor carried alongside that pointer must still prevent the block
  // from crossing type classes without consulting adjacent object bytes.
  using thread_info_type = boost::asio::detail::thread_info_base;
  thread_info_type::cancellation_signal_tag cancellation_cache;
  pointer_rich_operation* const erased_operation =
      thread_info_type::allocate<pointer_rich_operation>(cancellation_cache,
          thread_context_probe::top_of_thread_call_stack(),
          sizeof(pointer_rich_operation), alignof(pointer_rich_operation));
  thread_info_type::deallocate(cancellation_cache,
      thread_context_probe::top_of_thread_call_stack(),
      static_cast<void*>(erased_operation), sizeof(pointer_rich_operation),
      operation_type);

  pointer_rich_peer* const erased_peer =
      thread_info_type::allocate<pointer_rich_peer>(cancellation_cache,
          thread_context_probe::top_of_thread_call_stack(),
          sizeof(pointer_rich_peer), alignof(pointer_rich_peer));
  if (static_cast<void*>(erased_peer) == static_cast<void*>(erased_operation))
  {
    std::fputs(
        "Asio recycler lost the descriptor during erased deallocation\n",
        stderr);
    return 1;
  }
  thread_info_type::deallocate(cancellation_cache,
      thread_context_probe::top_of_thread_call_stack(),
      static_cast<void*>(erased_peer), sizeof(pointer_rich_peer), peer_type);

  pointer_rich_operation* const recovered_operation =
      thread_info_type::allocate<pointer_rich_operation>(cancellation_cache,
          thread_context_probe::top_of_thread_call_stack(),
          sizeof(pointer_rich_operation), alignof(pointer_rich_operation));
  if (recovered_operation != erased_operation)
  {
    std::fputs(
        "Asio recycler did not retain the erased allocation descriptor\n",
        stderr);
    return 1;
  }
  thread_info_type::deallocate(cancellation_cache,
      thread_context_probe::top_of_thread_call_stack(),
      static_cast<void*>(recovered_operation), sizeof(pointer_rich_operation),
      operation_type);

  bool cancellation_called = false;
  boost::asio::cancellation_signal signal;
  signal.slot().emplace<cancellation_handler_one>(&cancellation_called);
  signal.emit(boost::asio::cancellation_type::terminal);
  if (!cancellation_called)
  {
    std::fputs("First cancellation handler did not run\n", stderr);
    return 1;
  }

  cancellation_called = false;
  signal.slot().emplace<cancellation_handler_two>(
      &signal, &cancellation_called);
  signal.emit(boost::asio::cancellation_type::terminal);
  if (!cancellation_called)
  {
    std::fputs("Replacement cancellation handler did not run\n", stderr);
    return 1;
  }
  signal.slot().clear();

  return 0;
}
