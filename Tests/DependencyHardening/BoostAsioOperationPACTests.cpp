#include "PointerAuthenticationFailureTestSupport.hpp"

#include <boost/asio/detail/executor_function.hpp>
#include <boost/asio/detail/reactor_op.hpp>
#include <boost/asio/detail/scheduler_operation.hpp>

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <memory>
#include <type_traits>
#include <utility>

namespace {

class scheduler_probe final : public boost::asio::detail::scheduler_operation
{
public:
  scheduler_probe()
    : scheduler_operation(&scheduler_probe::finish)
  {
  }

private:
  static void finish(void* owner, scheduler_operation*,
      const boost::system::error_code&, std::size_t)
  {
    if (owner != nullptr)
      *static_cast<bool*>(owner) = true;
  }
};

class reactor_probe final : public boost::asio::detail::reactor_op
{
public:
  reactor_probe()
    : reactor_op(boost::system::error_code(),
        &reactor_probe::perform_impl, &reactor_probe::finish)
  {
  }

private:
  static status perform_impl(reactor_op*)
  {
    return done;
  }

  static void finish(void*, scheduler_operation*,
      const boost::system::error_code&, std::size_t)
  {
  }
};

struct executor_probe
{
  bool* called;

  void operator()() const
  {
    if (called != nullptr)
      *called = true;
  }
};

void* executor_implementation(
    const boost::asio::detail::executor_function& function)
{
  static_assert(std::is_standard_layout_v<
      boost::asio::detail::executor_function>);
  static_assert(sizeof(function) == sizeof(void*));
  void* implementation = nullptr;
  std::memcpy(&implementation, &function, sizeof(implementation));
  return implementation;
}

__attribute__((noinline)) void replay_object_bytes(
    void* destination, const void* source, std::size_t size)
{
  std::memcpy(destination, source, size);
}

} // namespace

extern "C" __attribute__((noinline)) void torrent7_invoke_scheduler(
    scheduler_probe* operation)
{
  operation->complete(nullptr, boost::system::error_code(), 0);
}

extern "C" __attribute__((noinline)) boost::asio::detail::reactor_op::status
torrent7_invoke_reactor(reactor_probe* operation)
{
  return operation->perform();
}

extern "C" __attribute__((noinline)) void torrent7_invoke_executor(
    boost::asio::detail::executor_function* function)
{
  (*function)();
}

extern "C" __attribute__((noinline)) void torrent7_destroy_executor(
    boost::asio::detail::executor_function* function)
{
  function->~executor_function();
}

int main()
{
  scheduler_probe scheduler;
  bool scheduler_called = false;
  scheduler.complete(&scheduler_called, boost::system::error_code(), 0);
  if (!scheduler_called)
  {
    std::fputs("scheduler callback did not run normally\n", stderr);
    return 1;
  }

  reactor_probe reactor;
  if (reactor.perform() != boost::asio::detail::reactor_op::done)
  {
    std::fputs("reactor callback did not run normally\n", stderr);
    return 1;
  }

  std::allocator<std::byte> allocator;
  bool executor_called = false;
  boost::asio::detail::executor_function executor(
      executor_probe{&executor_called}, allocator);
  boost::asio::detail::executor_function moved_executor(std::move(executor));
  moved_executor();
  if (!executor_called)
  {
    std::fputs("executor callback did not run normally after a move\n", stderr);
    return 1;
  }

  std::weak_ptr<int> executor_lifetime;
  {
    std::shared_ptr<int> owner = std::make_shared<int>(7);
    executor_lifetime = owner;
    boost::asio::detail::executor_function pending(
        [owner] {}, allocator);
    owner.reset();
    if (executor_lifetime.expired())
    {
      std::fputs("executor callback state was released prematurely\n", stderr);
      return 1;
    }
  }
  if (!executor_lifetime.expired())
  {
    std::fputs("executor destruction did not release callback state\n", stderr);
    return 1;
  }

  using torrent7::test_support::replay_triggers_pointer_authentication_failure;

  if (!replay_triggers_pointer_authentication_failure([] {
        scheduler_probe source;
        scheduler_probe destination;
        replay_object_bytes(&destination, &source, sizeof(source));
        destination.complete(nullptr, boost::system::error_code(), 0);
      }))
  {
    std::fputs("scheduler callback replay was accepted\n", stderr);
    return 1;
  }

  if (!replay_triggers_pointer_authentication_failure([] {
        reactor_probe source;
        reactor_probe destination;
        replay_object_bytes(&destination, &source, sizeof(source));
        static_cast<void>(destination.perform());
      }))
  {
    std::fputs("reactor callback replay was accepted\n", stderr);
    return 1;
  }

  if (!replay_triggers_pointer_authentication_failure([] {
        std::allocator<std::byte> child_allocator;
        bool source_called = false;
        bool destination_called = false;
        boost::asio::detail::executor_function source(
            executor_probe{&source_called}, child_allocator);
        boost::asio::detail::executor_function destination(
            executor_probe{&destination_called}, child_allocator);
        replay_object_bytes(
            executor_implementation(destination),
            executor_implementation(source),
            sizeof(void*));
        destination();
      }))
  {
    std::fputs("executor invocation callback replay was accepted\n", stderr);
    return 1;
  }

  if (!replay_triggers_pointer_authentication_failure([] {
        std::allocator<std::byte> child_allocator;
        bool source_called = false;
        bool destination_called = false;
        auto source = std::make_unique<boost::asio::detail::executor_function>(
            executor_probe{&source_called}, child_allocator);
        auto destination = std::make_unique<boost::asio::detail::executor_function>(
            executor_probe{&destination_called}, child_allocator);
        replay_object_bytes(
            executor_implementation(*destination),
            executor_implementation(*source),
            sizeof(void*));
        destination.reset();
      }))
  {
    std::fputs("executor destruction callback replay was accepted\n", stderr);
    return 1;
  }

  return 0;
}
