#ifndef TORRENT7_POINTER_AUTHENTICATION_FAILURE_TEST_SUPPORT_HPP
#define TORRENT7_POINTER_AUTHENTICATION_FAILURE_TEST_SUPPORT_HPP

#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <type_traits>

namespace torrent7::test_support {

namespace detail {

inline constexpr int authentication_failure_status = 0;
inline constexpr int handler_setup_failure_status = 240;
inline constexpr int no_fault_status = 241;
inline constexpr int attempt_setup_failure_status = 242;
inline constexpr std::size_t replay_attempt_count = 4;
inline constexpr std::size_t permitted_collision_count = 1;
inline constexpr std::size_t required_authentication_failure_count =
    replay_attempt_count - permitted_collision_count;
inline constexpr std::size_t stack_layout_stride = 257;
// Darwin 25.5 reports AppleClang's PAC-failure brk with this kernel code;
// newer Darwin may report the standardized TRAP_BRKPT code instead.
inline constexpr int darwin_kernel_breakpoint_code = 0;

static_assert(replay_attempt_count > permitted_collision_count);

[[nodiscard]] constexpr bool has_sufficient_authentication_failures(
    std::size_t const count
) noexcept
{
    return count >= required_authentication_failure_count;
}

static_assert(!has_sufficient_authentication_failures(2));
static_assert(has_sufficient_authentication_failures(3));

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

template <typename Operation>
__attribute__((noinline)) void invoke_with_distinct_stack_layout(
    Operation const &operation,
    std::size_t const remaining_depth,
    std::size_t const attempt
)
{
    volatile std::uint8_t stack_layout[stack_layout_stride];
    stack_layout[0] = static_cast<std::uint8_t>(attempt + 1);
    stack_layout[stack_layout_stride - 1] =
        static_cast<std::uint8_t>(attempt + 2);

    if (remaining_depth == 0) {
        if constexpr (std::is_invocable_v<Operation const &, std::size_t>) {
            operation(attempt);
        } else {
            static_assert(std::is_invocable_v<Operation const &>);
            operation();
        }
    } else {
        invoke_with_distinct_stack_layout(
            operation,
            remaining_depth - 1,
            attempt
        );
    }

    // Volatile reads after the call keep every recursion frame live and
    // prevent tail-call folding from collapsing the distinct stack layouts.
    std::uint8_t const first = stack_layout[0];
    std::uint8_t const last = stack_layout[stack_layout_stride - 1];
    if (first == 0 && last == 0) {
        ::_exit(attempt_setup_failure_status);
    }
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
    } else if (status == attempt_setup_failure_status) {
        std::fprintf(
            stderr,
            "%s",
            "pointer-authentication replay could not prepare a storage-diverse attempt\n"
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

[[noreturn]] inline void fail_replay_attempt_setup() noexcept
{
    ::_exit(detail::attempt_setup_failure_status);
}

[[noreturn]] inline void complete_replay_without_authentication_fault() noexcept
{
    ::_exit(detail::no_fault_status);
}

template <typename Operation>
[[nodiscard]] bool replay_triggers_pointer_authentication_failure(
    Operation const &operation
)
{
    // PACs are intentionally truncated authentication codes, so one correct
    // address-diversified replay can very rarely collide. Forked children
    // inherit the parent's PAC keys and address space, making an unchanged
    // retry useless. Exercise four distinct storage layouts instead, tolerate
    // one isolated collision, and reject any systematic acceptance. The
    // stack trampoline varies stack-backed probes; heap-backed operations use
    // the supplied attempt index to retain same-type decoy allocations.
    std::size_t authentication_failure_count = 0;
    for (std::size_t attempt = 0;
         attempt < detail::replay_attempt_count;
         ++attempt) {
        // Do not let sanitizer runtimes flush a copied parent buffer from
        // every child when an authentication fault terminates the attempt.
        if (std::fflush(nullptr) != 0) {
            std::perror("fflush");
            return false;
        }
        pid_t const child = ::fork();
        if (child == -1) {
            std::perror("fork");
            return false;
        }
        if (child == 0) {
            if (!detail::install_authentication_fault_handlers()) {
                ::_exit(detail::handler_setup_failure_status);
            }
            detail::invoke_with_distinct_stack_layout(
                operation,
                attempt,
                attempt
            );
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
        if (WIFEXITED(child_status)
            && WEXITSTATUS(child_status)
                == detail::authentication_failure_status) {
            ++authentication_failure_count;
            continue;
        }
        if (WIFEXITED(child_status)
            && WEXITSTATUS(child_status) == detail::no_fault_status) {
            continue;
        }
        detail::report_child_failure(child_status);
        return false;
    }

    if (!detail::has_sufficient_authentication_failures(
            authentication_failure_count)) {
        std::fprintf(
            stderr,
            "pointer-authentication replay faulted in %zu of %zu "
            "storage-diverse attempts; expected at least %zu\n",
            authentication_failure_count,
            detail::replay_attempt_count,
            detail::required_authentication_failure_count
        );
        return false;
    }
    return true;
}

} // namespace torrent7::test_support

#endif
