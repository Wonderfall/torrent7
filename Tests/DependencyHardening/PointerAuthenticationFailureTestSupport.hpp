#ifndef TORRENT7_POINTER_AUTHENTICATION_FAILURE_TEST_SUPPORT_HPP
#define TORRENT7_POINTER_AUTHENTICATION_FAILURE_TEST_SUPPORT_HPP

#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstdio>

namespace torrent7::test_support {

namespace detail {

inline constexpr int authentication_failure_status = 0;
inline constexpr int handler_setup_failure_status = 240;
inline constexpr int no_fault_status = 241;
// Darwin 25.5 reports AppleClang's PAC-failure brk with this kernel code;
// newer Darwin may report the standardized TRAP_BRKPT code instead.
inline constexpr int darwin_kernel_breakpoint_code = 0;

[[nodiscard]] constexpr bool is_kernel_authentication_fault(
    int const signal,
    int const code
) noexcept
{
    return (signal == SIGSEGV && (code == SEGV_MAPERR || code == SEGV_ACCERR))
        || (signal == SIGBUS && (code == BUS_ADRALN || code == BUS_ADRERR))
        || (signal == SIGTRAP
            && (code == darwin_kernel_breakpoint_code || code == TRAP_BRKPT));
}

static_assert(is_kernel_authentication_fault(SIGSEGV, SEGV_ACCERR));
static_assert(is_kernel_authentication_fault(SIGBUS, BUS_ADRALN));
static_assert(is_kernel_authentication_fault(SIGTRAP, darwin_kernel_breakpoint_code));
static_assert(is_kernel_authentication_fault(SIGTRAP, TRAP_BRKPT));
static_assert(!is_kernel_authentication_fault(SIGABRT, 0));
static_assert(!is_kernel_authentication_fault(SIGSEGV, SI_USER));

[[nodiscard]] constexpr int unexpected_fault_status(
    int const signal,
    int const code
) noexcept
{
    int const bounded_code = code >= 0 && code < 16 ? code : 15;
    return signal * 16 + bounded_code;
}

[[noreturn]] inline void report_authentication_fault(
    int const signal,
    siginfo_t *const info,
    void *
) noexcept
{
    // Darwin may surface an arm64e PAC failure as an access, alignment, or
    // compiler-inserted trap fault depending on the CPU and kernel. Accept
    // only kernel fault codes; user-generated signals have distinct si_codes.
    int const code = info != nullptr ? info->si_code : SI_USER;
    if (is_kernel_authentication_fault(signal, code)) {
        ::_exit(authentication_failure_status);
    }
    ::_exit(unexpected_fault_status(signal, code));
}

[[nodiscard]] inline bool install_authentication_fault_handlers() noexcept
{
    struct sigaction action {};
    action.sa_sigaction = report_authentication_fault;
    action.sa_flags = SA_SIGINFO;
    return sigemptyset(&action.sa_mask) == 0
        && ::sigaction(SIGSEGV, &action, nullptr) == 0
        && ::sigaction(SIGBUS, &action, nullptr) == 0
        && ::sigaction(SIGTRAP, &action, nullptr) == 0;
}

inline void report_child_failure(int child_status)
{
    if (WIFSIGNALED(child_status)) {
        std::fprintf(
            stderr,
            "pointer-authentication replay terminated with unexpected signal %d\n",
            WTERMSIG(child_status)
        );
        return;
    }
    if (!WIFEXITED(child_status)) {
        std::fprintf(stderr, "%s", "pointer-authentication replay has no terminal child status\n");
        return;
    }

    int const status = WEXITSTATUS(child_status);
    if (status == handler_setup_failure_status) {
        std::fprintf(
            stderr,
            "%s",
            "pointer-authentication replay could not install fault handlers\n"
        );
    } else if (status == no_fault_status) {
        std::fprintf(
            stderr,
            "%s",
            "pointer-authentication replay completed without a fault\n"
        );
    } else {
        std::fprintf(
            stderr,
            "pointer-authentication replay raised unexpected signal/code %d/%d\n",
            status / 16,
            status % 16
        );
    }
}

} // namespace detail

template <typename Operation>
[[nodiscard]] bool replay_triggers_pointer_authentication_failure(
    Operation const &operation
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
    bool const failed_authentication = WIFEXITED(child_status)
        && WEXITSTATUS(child_status) == detail::authentication_failure_status;
    if (!failed_authentication) {
        detail::report_child_failure(child_status);
    }
    return failed_authentication;
}

} // namespace torrent7::test_support

#endif
