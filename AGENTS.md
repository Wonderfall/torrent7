# Agent instructions

Shared contributor requirements apply to agents in full. This file describes
the project's character, agent workflow, and required reading; detailed
engineering policy lives in the shared documentation.

## Project character and taste

Torrent 7 is a focused torrent client for modern macOS on Apple silicon.
It should feel fast, compact, and native. Adding a magnet, choosing files,
and inspecting a transfer should be straightforward, even when the underlying
protocol and storage work is complicated. Security is a first-class part of
that product quality.

Use these preferences when making decisions:

- Make the interface feel at home on macOS. Prefer native SwiftUI controls and
  familiar interactions. Scrolling, selection, focus, spacing, and accurate
  status deserve the same care as the feature itself.
- Keep the product focused. Features should serve concrete workflows; settings,
  dependencies, and abstractions should justify their ongoing complexity.
- Use the current Apple platform and compiler capabilities to make code smaller
  and safer. Treat strict diagnostics as design feedback.
- Choose the simplest complete solution, with clear ownership and lifecycle.
  Solve problems at the responsible boundary, choose fixes that hold up over
  time, and remove obsolete paths as part of the work.
- Keep security architectural. User-file authority stays explicit and narrow;
  untrusted protocol work stays contained. Preserve user data when an outcome
  is uncertain and make that uncertainty visible.
- Base performance policies on measurements and safety claims on focused
  verification. Make tradeoffs and remaining uncertainty explicit.

## Required reading before starting work

Before investigating, reviewing, or changing the project, read:

1. [README.md](README.md) for product scope, architecture, and build entry points.
2. [CONTRIBUTING.md](CONTRIBUTING.md) for design policy, the task reading map,
   required verification, and documentation responsibilities.
3. [Coding standards](Documentation/CodingStandards.md) for Swift, SwiftUI,
   concurrency, C++, and unsafe-boundary requirements.
4. [Toolchain baseline](Documentation/Toolchain.md) for the supported compiler,
   SDK, deployment target, and build-specific hardening details.
5. The opening overview and
   [non-negotiable invariants](Documentation/Architecture.md#non-negotiable-invariants)
   in the architecture document.

Then read the documents for the affected area in the
[task reading map](CONTRIBUTING.md#task-reading-map), along with relevant code,
tests, and local invariant comments. Read these before working in that area,
not only when preparing the final verification.

## Agent workflow

- When asked to review, never make changes without explicit approval.
- Preserve unrelated work and keep changes within the authorized scope.
- Run the [required verification](CONTRIBUTING.md#required-verification) for
  the change. Report the checks actually run, their results, and any required
  checks that remain unperformed or blocked.
- Update shared policies in their authoritative documentation. Keep this file
  focused on project character, agent workflow, and reading instructions;
  link to detailed engineering requirements in the shared documents.
