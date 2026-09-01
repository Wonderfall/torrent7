# Unsafe boundary lint

This package implements the repository policy that explicit Swift ownership
and concurrency escape hatches require a nearby `SAFETY:` explanation. It
parses Swift with the SwiftSyntax version pinned for the repository's Swift 6.3
toolchain, so spellings in comments and string literals are not treated as
code.

The lint covers:

- every explicit `unsafe` expression and `for unsafe` iteration;
- `@unchecked Sendable`, `nonisolated(unsafe)`, `unowned(unsafe)`,
  `@preconcurrency`, `@unsafe`, and unsafe conformances or imports;
- explicit `Unmanaged` references; and
- known C allocation functions plus Swift raw-pointer `allocate` and
  `deallocate` calls.

Declaration escape hatches require an explanation leading that exact
declaration or import. Executable operations may inherit an explanation from
the containing statement, the first statement of an enclosing code block, or
the owning callable or property declaration. Comments on an enclosing type do
not silently cover its methods. Multiple boundaries in one proof scope produce
one diagnostic, with specialized ownership diagnostics preferred over the
generic `unsafe` diagnostic.

Run the repository-wide check from the project root:

```sh
Scripts/lint-unsafe-boundaries.zsh
```

Run the rule fixtures directly with:

```sh
swift test \
    --package-path Tools/UnsafeBoundaryLint \
    --scratch-path .build/unsafe-boundary-lint \
    --only-use-versions-from-resolved-file
```

The shell wrapper scans tracked and untracked, nonignored Swift files. It does
not use a baseline or path-based source exemptions.
