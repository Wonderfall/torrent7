#include "PointerAuthenticationFailureTestSupport.hpp"

#include <boost/asio/detail/reactor_op.hpp>
#include <boost/asio/detail/scheduler_operation.hpp>

#include <cstddef>
#include <cstdio>
#include <cstring>

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

  using torrent7::test_support::PointerAuthenticationFailure;
  using torrent7::test_support::replay_triggers_pointer_authentication_failure;

  if (!replay_triggers_pointer_authentication_failure([] {
        scheduler_probe source;
        scheduler_probe destination;
        replay_object_bytes(&destination, &source, sizeof(source));
        destination.complete(nullptr, boost::system::error_code(), 0);
      }, PointerAuthenticationFailure::code_pointer))
  {
    std::fputs("scheduler callback replay was accepted\n", stderr);
    return 1;
  }

  if (!replay_triggers_pointer_authentication_failure([] {
        reactor_probe source;
        reactor_probe destination;
        replay_object_bytes(&destination, &source, sizeof(source));
        static_cast<void>(destination.perform());
      }, PointerAuthenticationFailure::code_pointer))
  {
    std::fputs("reactor callback replay was accepted\n", stderr);
    return 1;
  }

  return 0;
}
