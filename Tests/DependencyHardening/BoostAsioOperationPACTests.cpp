#include <boost/asio/detail/reactor_op.hpp>
#include <boost/asio/detail/scheduler_operation.hpp>

#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
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

template <typename Function>
bool replay_traps(Function function)
{
  const pid_t child = fork();
  if (child == -1)
  {
    std::perror("fork");
    return false;
  }
  if (child == 0)
  {
    function();
    _exit(90);
  }

  int child_status = 0;
  pid_t waited;
  do
  {
    waited = waitpid(child, &child_status, 0);
  }
  while (waited == -1 && errno == EINTR);

  if (waited == -1)
  {
    std::perror("waitpid");
    return false;
  }
  return WIFSIGNALED(child_status);
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

  if (!replay_traps([] {
        scheduler_probe source;
        scheduler_probe destination;
        replay_object_bytes(&destination, &source, sizeof(source));
        destination.complete(nullptr, boost::system::error_code(), 0);
      }))
  {
    std::fputs("scheduler callback replay was accepted\n", stderr);
    return 1;
  }

  if (!replay_traps([] {
        reactor_probe source;
        reactor_probe destination;
        replay_object_bytes(&destination, &source, sizeof(source));
        static_cast<void>(destination.perform());
      }))
  {
    std::fputs("reactor callback replay was accepted\n", stderr);
    return 1;
  }

  return 0;
}
