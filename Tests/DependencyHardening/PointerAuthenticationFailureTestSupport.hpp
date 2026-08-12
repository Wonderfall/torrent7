#ifndef TORRENT7_POINTER_AUTHENTICATION_FAILURE_TEST_SUPPORT_HPP
#define TORRENT7_POINTER_AUTHENTICATION_FAILURE_TEST_SUPPORT_HPP

#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstdio>

namespace torrent7::test_support {

enum class PointerAuthenticationFailure {
    code_pointer,
    data_pointer,
};

namespace detail {

inline constexpr int code_pointer_failure_status = 80;
inline constexpr int data_pointer_failure_status = 81;
inline constexpr int unexpected_fault_status = 82;
inline constexpr int handler_setup_failure_status = 83;
inline constexpr int no_fault_status = 84;

[[noreturn]] inline void report_authentication_fault(
    int const signal,
    siginfo_t *const info,
    void *
) noexcept
{
    // On the supported Darwin arm64e target, authenticated code-pointer
    // failures arrive as SEGV_ACCERR, while explicit data authentication
    // traps arrive as BUS_ADRALN. User-generated signals have different codes.
    if (info != nullptr && signal == SIGSEGV && info->si_code == SEGV_ACCERR) {
        ::_exit(code_pointer_failure_status);
    }
    if (info != nullptr && signal == SIGBUS && info->si_code == BUS_ADRALN) {
        ::_exit(data_pointer_failure_status);
    }
    ::_exit(unexpected_fault_status);
}

[[nodiscard]] inline bool install_authentication_fault_handlers() noexcept
{
    struct sigaction action {};
    action.sa_sigaction = report_authentication_fault;
    action.sa_flags = SA_SIGINFO;
    return sigemptyset(&action.sa_mask) == 0
        && ::sigaction(SIGSEGV, &action, nullptr) == 0
        && ::sigaction(SIGBUS, &action, nullptr) == 0
        && std::signal(SIGABRT, SIG_DFL) != SIG_ERR
        && std::signal(SIGILL, SIG_DFL) != SIG_ERR
        && std::signal(SIGTRAP, SIG_DFL) != SIG_ERR;
}

[[nodiscard]] constexpr int expected_failure_status(
    PointerAuthenticationFailure const failure
) noexcept
{
    return failure == PointerAuthenticationFailure::code_pointer
        ? code_pointer_failure_status
        : data_pointer_failure_status;
}

} // namespace detail

template <typename Operation>
[[nodiscard]] bool replay_triggers_pointer_authentication_failure(
    Operation const &operation,
    PointerAuthenticationFailure const expected_failure
)
{
    pid_t const child = ::fork();
    if (child == -1) {
        std::perror("fork");
        return false;
    }
    if (child == 0) {
        if (!detail::install_authentication_fault_handlers()) {
            ::_exit(detail::handler_setup_failure_status);
        }
        operation();
        ::_exit(detail::no_fault_status);
    }

    int child_status = 0;
    pid_t waited;
    do {
        waited = ::waitpid(child, &child_status, 0);
    } while (waited == -1 && errno == EINTR);

    if (waited == -1) {
        std::perror("waitpid");
        return false;
    }
    return WIFEXITED(child_status)
        && WEXITSTATUS(child_status) == detail::expected_failure_status(expected_failure);
}

} // namespace torrent7::test_support

#endif
