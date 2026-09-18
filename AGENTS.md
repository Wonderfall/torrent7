# AGENTS.md

Project overview is available in `README.md` and under `Documentation/`.

This project aims to be clean, elegant, modern, with security as a first-class
principle.

## General guidelines

- Make changes carefully with security hardening in mind.
- Do not add unnecessary features or useless/redundant code.
- We always target the latest software/system, e.g. macOS 27 on Apple Silicon,
  latest tools.
- Do not preserve backward compatibility; ignore older platforms, toolchains and APIs.
- Compatibility and migrations for persisted user data must be considered case by case
  with explicit approval. Any retained migration must be narrow, documented, and tested.
- Remove obsolete paths instead of adding compatibility layers, fallbacks, or
  migrations.
- Choose the simplest and cleanest implementation that fully meets the current
  requirements.
- Make architectural decisions for the long term. Do not accept a stopgap that
  only works for now.
- Avoid piling up hacks: always prefer a clean systemic fix.
- When asked to review, never make changes without explicit approval.

Exceptions to the following rules must be narrow, documented, and tested.

## Swift 6.4 and SwiftUI

These rules apply to all first-party Swift targets, including product source,
tests, tools, benchmarks, and fuzz support. Package manifests, generated source,
and third-party dependencies are out of scope.

### Baseline and target isolation

- Target the repository's latest Swift, Xcode, SDK, and deployment target.
  Do not add backward-compatibility branches, availability fallbacks, or retain
  obsolete implementations unless a current SDK defect requires a documented
  workaround.
- Use Swift 6 language mode, complete concurrency checking, Strict Memory
  Safety, and warnings as errors in every first-party Swift target.
- Enable `InferIsolatedConformances`, `NonisolatedNonsendingByDefault`,
  `MemberImportVisibility`, `InternalImportsByDefault`, `ExistentialAny`, and
  `ImmutableWeakCaptures` in every first-party Swift target. Give imports only
  the access level required by declarations that expose their types.
- UI and application-composition targets default to `MainActor`.
  Infrastructure, model, parser, service, IPC, interop, tool, and test targets
  default to `nonisolated`.
- Do not weaken compiler checks or add warning suppressions to make code build.
  Fix the isolation, ownership, or API boundary instead.

### Architecture and ordinary Swift

- Keep SwiftUI and application presentation in `TorrentApp`. Put persistence,
  filesystem work, parsing, services, and reusable non-UI logic in
  nonisolated infrastructure or domain targets.
- Do not scatter `nonisolated` through the UI target to compensate for misplaced
  infrastructure. Move substantial non-UI code to the appropriate target.
- Prefer `struct`, `enum`, immutable `let` state, and explicit typed state
  machines. Classes should be `final` unless a framework requires inheritance.
- Represent invalid states structurally. Avoid Boolean state combinations,
  magic strings, `[String: Any]`, `Any`, and force-cast-driven designs.
- Inject mutable services and factories from the composition root. A private
  static cache or coordinator is acceptable only when it represents a genuinely
  process-wide resource, carries no hidden application authority, and is
  protected by an actor or lock.
- Avoid `!`, `as!`, and `try!` in production. In tests or fuzz oracles, prefer
  `#require`, explicit preconditions, or a deliberate crash helper.

### Concurrency

- Treat actor isolation as state ownership:
  - UI state and UI-facing observable models belong to `MainActor`;
  - independently mutable asynchronous subsystems belong to their own actor;
  - immutable and pure computation remains nonisolated.
- `async` means that a function can suspend; it does not mean that work leaves
  the current actor.
- Use `@concurrent` only when meaningful synchronous work must not begin on the
  caller's actor, such as substantial parsing, filesystem traversal,
  cryptography, or potentially large transformations. Do not use it for simple
  delegation or merely to silence isolation diagnostics.
- Prefer structured concurrency: direct `await`, `async let`, and task groups.
- Use `Task {}` only as a small synchronous-to-async bridge or when the
  surrounding object explicitly owns the operation.
- Every unstructured task must have explicit lifecycle semantics:
  - retain and cancel replaceable or externally owned tasks;
  - observe throwing task results;
  - cancel owned tasks during teardown;
  - self-owning terminal-cleanup tasks are allowed only when bounded and
    documented.
- `Task.detached` is exceptional. Use it only when isolation, priority,
  task-local values, and cancellation must not be inherited. Its lifetime and
  termination must be evident from structure—such as immediate awaiting,
  registration with an owner, or retained cancellation—or explained by a
  nearby lifecycle comment.
- Use actors for asynchronously accessed mutable state. Use `Mutex` only for
  short, synchronous, non-suspending critical sections. Never hold a lock
  across `await`, and do not protect one invariant with both an actor and
  unrelated locks.
- Do not use GCD as an actor substitute. GCD remains appropriate for framework
  queue contracts, deliberate next-run-loop deferral, and non-cooperative
  watchdogs that must work when Swift task progress is stuck.
- Values crossing actors or concurrent task boundaries must be `Sendable` or
  transferred using supported sending semantics. Never use
  `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency` merely to
  suppress the compiler.
- Propagate cancellation. Check it in long loops and expensive synchronous work,
  and preserve `CancellationError` rather than translating it into an ordinary
  failure.
- Checked continuations must resume exactly once on every success, failure,
  cancellation, and early-callback path.
- Use `Duration` and `Clock` APIs for cooperative Swift-concurrency timing.
  Inject a clock or scheduler when timing affects observable policy and
  deterministic unit testing is practical. GCD and `DispatchTime` remain
  appropriate for documented non-cooperative watchdogs and framework queue
  contracts.

### SwiftUI

- Use Observation for new code:
  - `@Observable` for observable models;
  - `@State` when the view owns the value or model lifetime;
  - `@Environment` for ambient dependencies;
  - `@Bindable` only when bindings are required;
  - a plain stored property otherwise.
- Do not introduce `ObservableObject`, `@Published`, `@StateObject`,
  `@ObservedObject`, or `@EnvironmentObject` unless an external API requires
  them.
- Keep `body` pure, cheap, synchronous, and free of I/O, parsing, task creation,
  database access, or substantial transformations.
- Use `.task(id:)` for asynchronous work owned by a view's lifetime. A button or
  synchronous callback may create a tiny `Task` bridge, but business logic
  belongs in an async model or service API.
- Use stable domain identity in `ForEach`. Do not use mutable array indices or
  generate identity from `body`.
- Prefer typed `NavigationStack` or `NavigationSplitView`, generic views,
  `some View`, and `@ViewBuilder`. Use `AnyView` only for genuinely
  runtime-heterogeneous storage.
- Preserve accessibility semantics, keyboard behavior, focus behavior, and
  deterministic previews whenever UI code changes.
- Prefer pure SwiftUI. Add the smallest AppKit adapter necessary when SwiftUI
  does not expose the required macOS behavior.

### Swift interop and unsafe boundaries

- Confine foreign-language types, raw pointers, and generated interfaces to
  dedicated interop targets. Expose Swift-native values, errors, actors, and
  asynchronous APIs to the rest of the project.
- Choose the smallest safe foreign boundary. Direct C++ interoperability is
  appropriate for controlled supported value APIs; an annotated C facade is
  appropriate when it provides a narrower ABI, explicit ownership, exception
  containment, or a stronger trust boundary.
- Prefer `Span`, `MutableSpan`, `RawSpan`, `MutableRawSpan`, and `OutputSpan`
  for bounded borrowed storage. Use `Array`, `ContiguousArray`, or `Data` when
  data must be owned or escape.
- Annotate C and C++ buffers and lifetimes with `__counted_by`, `__sized_by`,
  `__noescape`, `__lifetimebound`, or API Notes as appropriate.
- Never allow a C++ exception to cross into Swift. Catch it in the C++ facade
  and convert it to an explicit status or result.
- Use supported `@c` or `@c @implementation` exports. Do not add underscored
  interoperability attributes such as `@_cdecl` or `@_silgen_name`.
- Use Swift 6.4's standard safe-interoperability parameter imports. Do not
  enable experimental return-lifetime imports unless the bridge needs them.
  Pin the toolchain, and compile and exercise the imported safe signatures in CI.
- Minimize unsafe code and replace repeated unsafe patterns with a reviewed
  safe wrapper.
- Every explicit unsafe proof scope requires a nearby `SAFETY:` explanation.
  This includes unsafe expressions and iteration, `@unchecked Sendable`,
  `nonisolated(unsafe)`, `unowned(unsafe)`, `@preconcurrency` or `@unsafe`
  imports, unsafe conformances, `Unmanaged`, and manual allocation.
- A `SAFETY:` explanation must state the concrete invariant that makes the code
  valid. Discuss lifetime, ownership, bounds, initialization, alignment,
  synchronization, and cleanup only where relevant. Do not write empty or
  formulaic boilerplate.
- One explanation may cover multiple unsafe operations only when they share one
  concrete invariant and are contained in the same statement, an explicitly
  documented `do` scope, or a focused property or callable declaration. Do not
  use file-wide, type-wide, or arbitrary large-block safety claims. The lint
  enforces syntactic placement; reviewers must still reject overbroad scopes
  and incomplete invariants.
- Nontrivial safe abstractions built over unsafe implementation, and invariants
  asserted by `@unchecked Sendable` or unsafe isolation, require focused tests
  where the invariant has observable behavior.

### Performance and testing

- Do not add forced optimization or ownership annotations such as
  `@inline(__always)`, `@_specialize`, or other underscored attributes to
  production code without measured evidence and a nearby `PERF:` explanation.
  Benchmark-only anti-optimization controls such as `@inline(never)` are
  permitted when their measurement purpose is clear at the use site.
  `@concurrent` is an executor decision and follows the concurrency rule above.
- Use Swift Testing for unit, integration, async, parameterized, and failure
  tests. Retain XCTest only where Apple tooling still requires it.
- Test cancellation, teardown, reentrancy, stale results, duplicate completion,
  and races directly. Prefer controlled continuations, barriers, fake clocks,
  and injected schedulers over polling or arbitrary sleeps. Bounded real-time
  waits are acceptable when an integration test specifically exercises real
  deadline or cancellation behavior.
- Treat parser, IPC, filesystem, and interop inputs as hostile. Test empty,
  malformed, oversized, boundary-sized, concurrent, cancelled, and partially
  completed cases.

## C++ (C++23 / Apple Clang) and Bridge

These rules apply to first-party bridge implementation, public ABI, native
tests, benchmarks, and fuzz harnesses. Third-party source is out of scope, but
repository-owned adapters, patches, build flags, and dependency hardening remain
in scope.

The compiler and static analyzer are your best friends. Exceptions must be
narrow, documented, and tested.

### Language and toolchain

Use C++23 with the repository’s current Apple Clang and Xcode toolchain. Do not
add compatibility paths for older language modes, compilers, operating systems,
or architectures. Prefer standard C++; Apple and Clang extensions are allowed
only for a documented security, platform, or interoperability requirement.

### Diagnostics

Project code must compile without warnings and pass the configured static
analysis. Warnings are errors. Do not disable diagnostics globally or use broad
suppressions. A local suppression must cover the smallest possible region,
explain why the operation is correct, and receive verification appropriate to
its risk.

### Toolchain hardening

Do not weaken the repository’s configured libc++ hardening, Fortify checks,
undefined-behavior sanitization, pointer authentication,
straight-line-speculation protection, typed allocation, or sanitizer profiles.
Any necessary change to these protections requires an explicit rationale and
targeted analysis, tests, or sanitizer coverage.

### Ownership

Use values and RAII. Every resource must have explicit ownership and
deterministic cleanup. Do not introduce direct `new` or `delete`, owning raw
pointers, or mutable process-global state in ordinary project code. Prefer
`std::unique_ptr`; use `std::shared_ptr` only for genuinely shared lifetime.

Opaque ABI handles and callback contexts may transfer ownership through raw
pointers when the ABI requires it. Document the transfer, retention, and release
contract, and convert back to an RAII owner at the exact ownership boundary.
Tiny callback adapters may centralize allocation and final release when their
lifetime protocol is explicit and tested.

### Borrowing

Use references for required objects, pointers for nullable single objects,
`std::span` for project-owned buffer APIs, and `std::string_view` only for
borrowed text. Never retain a borrowed pointer or view beyond its documented
lifetime. Adapt pointer/count pairs and third-party buffer types into bounded
views immediately.

### Buffer safety

Outside an audited boundary, do not index or perform arithmetic on raw buffer
pointers. C arrays and raw memory operations are permitted only at narrow C ABI,
serialization, system, or third-party boundaries.

Validate pointer/count consistency and checked size arithmetic before
constructing a bounded view. Isolate unavoidable operations in the smallest
possible `__unsafe_buffer_usage_begin` and `__unsafe_buffer_usage_end` region,
then use bounded containers or views afterward.

### Untrusted input

Treat network, disk, IPC, C ABI, callback, and dependency output as untrusted.
Apply hard limits before allocation. Validate pointer/count consistency,
versions, enums, identifiers, conversions, offsets, lengths, and all size
arithmetic.

Reject invalid input before mutating published state. For unavoidable multistep
operations, stage complete owned state first or provide explicit rollback or
fault containment so partial state never becomes externally visible. Invalid
input fails closed: do not introduce permissive coercion, fallback parsers, or
partial mutation.

### Types

Use fixed-width integers for ABI, wire, and persistent formats. Internally
prefer strong semantic types, `enum class`, `std::chrono`, `const`, `constexpr`,
and checked conversions such as `std::in_range`.

Mark significant results `[[nodiscard]]`. Avoid undocumented sentinels, C-style
casts, implicit narrowing, and unchecked conversions.

### Errors and exceptions

Use `std::expected<T, E>` or typed error codes for expected failure. Exceptions
may be contained internally where required, but none may cross an `extern "C"`,
Swift callback, thread-entry, or destructor boundary.

Every production bridge ABI entry point callable by Swift or C must be
`noexcept` on the C++ side. Result-bearing exports must translate every failure
into their documented result. Void callback and teardown paths may use
documented best-effort handling or latch an internal fault when they cannot
report failure, but they must preserve ownership and state invariants.

### C and Swift ABI

Keep the public ABI small, versioned, and limited to fixed-width,
standard-layout records; bounded pointer/count pairs; callback tables; and
opaque handles. State ownership, nullability, count, and lifetime semantics
explicitly.

Assert relevant sizes, alignments, offsets, layout properties, and trivial-copy
requirements. Do not expose STL or libtorrent types, references, exceptions, or
C++ object layouts. Revalidate every incoming field and callback table.

### Concurrency

Every ordinary worker thread must have an owning object. Use `std::jthread` for
long-lived workers and propagate `std::stop_token` through their loops and
waits. Do not ordinarily detach threads.

A self-owning detached terminal-cleanup operation is permitted only when it
captures all required state by value, never accesses the former owner, and
documents why joining or `std::jthread` ownership would violate the required
nonblocking teardown contract.

Operational waits require a deadline or stop-aware cancellation. Lifetime joins
and callback-quiescence waits may remain unbounded when timing out would destroy
state that is still borrowed or executing; this invariant must be documented
and tested.

Shared state must be owner-confined or protected and annotated for Clang
thread-safety analysis where applicable. Do not hold shared-state locks across
external callbacks or potentially unbounded blocking work.

### Scope and clarity

Keep native code small and single-purpose. Do not duplicate policy or
application state owned by Swift, or add a native parser where the bounded typed
Swift path is authoritative.

Prefer functions and types over macros except for build configuration and
compiler or ABI annotations. Comments should document invariants, ownership,
lifetime, fault containment, and lock ordering rather than restate the code.

## Required verification (testing)

Any warning/error from testing scripts or the compiler in general must be
carefully reviewed.

After changing Swift source or Swift target settings, run:

```sh
Scripts/test-swift.zsh
```

After changing first-party C/C++, the bridge ABI, or an imported interface, run
static analysis first, followed by the bridge tests:

```sh
Scripts/analyze-bridge.zsh
Scripts/test-bridge.zsh
```

If an imported Swift surface may have changed, also run the Swift checks above.
Review every compiler, analyzer, and test warning or error; do not suppress it
merely to obtain a passing run.

Also run the relevant ASan, TSan, fuzz (see relevant documentation under
`Tools/`), and replay suites for changes involving memory, concurrency, parsers,
ABI contracts, or untrusted input.
