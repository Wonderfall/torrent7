# Unsafe boundary lint

This package implements the repository policy that explicit Swift ownership
and concurrency escape hatches require a nearby `SAFETY:` explanation. It
parses Swift with the SwiftSyntax version pinned for the repository's Swift 6.3
toolchain, so spellings in comments and string literals are not treated as
code.

The lint covers:

- `@unchecked Sendable` conformances;
- explicit `Unmanaged` references; and
- known C allocation functions plus Swift raw-pointer `allocate` and
  `deallocate` calls.

For `@unchecked Sendable`, the explanation must lead that exact declaration.
For ownership operations, an explanation may lead the containing statement,
the first statement of an enclosing code block, or the owning callable or
property declaration. Comments on an enclosing type do not silently cover its
methods.

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
