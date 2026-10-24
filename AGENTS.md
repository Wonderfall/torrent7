# Agent instructions

Shared contributor requirements apply to agents in full. This file covers
agent workflow and required reading; engineering policy lives in the shared
documentation.

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
  focused on agent workflow and reading instructions rather than duplicating
  engineering requirements.
