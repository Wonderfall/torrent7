# AGENTS.md

Project overview is available in `README.md`.

This project aims to be clean, elegant, modern, with security as a first-class principle.

## General guidelines

- Make changes carefully with security hardening in mind.
- Do not add unnecessary features or useless/redundant code.
- We always target the latest software/system, e.g. macOS 26 on Apple Silicon, latest tools.
- Therefore: no need to keep compatibility paths with older platforms.
- Generally when doing changes or refactors, no need to keep older unused paths (remove them).
- Avoid piling up hacks: always prefer a clean systemic fix.
- When asked to review, never make changes without explicit approval.

## GUI (Swift 6)

Always prefer pure SwiftUI for UI with Apple's latest guidance on UI design in mind. Use pure SwiftUI where SwiftUI is strong, tiny AppKit adapters where macOS behavior still needs.

Use the most modern APIs provided by the target Swift version. There is no need to consider older systems.

You should always consider accessibility when making UI changes, so the app is nice to use both for AI agents and disabled people (who may for example rely on a screen reader like VoiceOver). SwiftUI mostly handles the semantics, but sometimes you may need to add accessibility properties.

Run tests after each Swift-related change. To run the Swift Testing suite:

```sh
Scripts/test-swift.zsh
```

## Bridge (C++23)

C++23, `std::span`, RAII, `std::jthread`, `std::stop_token`, strict warnings.

After any change related to the C++ bridge, always run the following script first for static analysis:

```sh
Scripts/analyze-bridge.zsh
```

Any warning/error from this script or the compiler in general must be carefully reviewed.

Furthermore, run tests after each bridge-related change. To run the bridge testing suite:

```sh
Scripts/test-bridge.zsh
```
