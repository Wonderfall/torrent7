#include "PointerAuthenticationFailureTestSupport.hpp"

#include <boost/asio/detail/executor_function.hpp>
#include <boost/asio/detail/reactor_op.hpp>
#include <boost/asio/detail/scheduler_operation.hpp>
#include <boost/asio/execution/any_executor.hpp>
#include <boost/asio/system_executor.hpp>

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

struct any_executor_probe
{
  bool* called;

  template <typename Function>
  void execute(Function&& function) const
  {
    if (called != nullptr)
      *called = true;
    static_cast<Function&&>(function)();
  }

  friend bool operator==(any_executor_probe const& left,
      any_executor_probe const& right) noexcept
  {
    return left.called == right.called;
  }
};

class any_executor_access final
  : public boost::asio::execution::detail::any_executor_base
{
public:
  template <typename Executor>
  explicit any_executor_access(Executor executor)
    : any_executor_base(static_cast<Executor&&>(executor),
        boost::asio::false_type())
  {
  }

  void invoke(boost::asio::detail::executor_function&& function) const
  {
    target_fns_->execute(*this,
        static_cast<boost::asio::detail::executor_function&&>(function));
  }

  void invoke_blocking(
      boost::asio::detail::executor_function_view function) const
  {
    target_fns_->blocking_execute(*this, function);
  }

  void invoke_from_replayed_table(
      boost::asio::detail::executor_function&& function)
  {
    target_fns replayed_functions{};
    std::memcpy(static_cast<void*>(&replayed_functions),
        static_cast<const void*>(target_fns_), sizeof(replayed_functions));
    target_fns_ = &replayed_functions;
    invoke(static_cast<boost::asio::detail::executor_function&&>(function));
  }

  void invoke_blocking_from_replayed_table(
      boost::asio::detail::executor_function_view function)
  {
    target_fns replayed_functions{};
    std::memcpy(static_cast<void*>(&replayed_functions),
        static_cast<const void*>(target_fns_), sizeof(replayed_functions));
    target_fns_ = &replayed_functions;
    invoke_blocking(function);
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

extern "C" __attribute__((noinline)) void torrent7_invoke_any_executor(
    any_executor_access* executor,
    boost::asio::detail::executor_function* function)
{
  executor->invoke(
      static_cast<boost::asio::detail::executor_function&&>(*function));
}

extern "C" __attribute__((noinline)) void torrent7_invoke_blocking_any_executor(
    any_executor_access* executor,
    boost::asio::detail::executor_function_view function)
{
  executor->invoke_blocking(function);
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
  bool any_executor_called = false;
  any_executor_access any_executor(any_executor_probe{&any_executor_called});
  boost::asio::detail::executor_function any_executor_function(
      executor_probe{nullptr}, allocator);
  torrent7_invoke_any_executor(&any_executor, &any_executor_function);
  if (!any_executor_called)
  {
    std::fputs("any_executor callback did not run normally\n", stderr);
    return 1;
  }

  bool blocking_function_called = false;
  executor_probe blocking_function{&blocking_function_called};
  auto blocking_system_executor = boost::asio::require(
      boost::asio::system_executor(), boost::asio::execution::blocking.always);
  any_executor_access blocking_executor{blocking_system_executor};
  torrent7_invoke_blocking_any_executor(
      &blocking_executor,
      boost::asio::detail::executor_function_view(blocking_function));
  if (!blocking_function_called)
  {
    std::fputs("blocking any_executor callback did not run normally\n", stderr);
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

  if (!replay_triggers_pointer_authentication_failure([] {
        std::allocator<std::byte> child_allocator;
        any_executor_access child_executor(any_executor_probe{nullptr});
        boost::asio::detail::executor_function child_function(
            executor_probe{nullptr}, child_allocator);
        child_executor.invoke_from_replayed_table(
            static_cast<boost::asio::detail::executor_function&&>(
              child_function));
      }))
  {
    std::fputs("any_executor dispatch-table replay was accepted\n", stderr);
    return 1;
  }

  if (!replay_triggers_pointer_authentication_failure([] {
        bool child_called = false;
        executor_probe child_function{&child_called};
        auto blocking_system_executor = boost::asio::require(
            boost::asio::system_executor(),
            boost::asio::execution::blocking.always);
        any_executor_access child_executor{blocking_system_executor};
        child_executor.invoke_blocking_from_replayed_table(
            boost::asio::detail::executor_function_view(child_function));
      }))
  {
    std::fputs(
        "blocking any_executor dispatch-table replay was accepted\n", stderr);
    return 1;
  }

  return 0;
}
