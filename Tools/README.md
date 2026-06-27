# Developer Tools

Developer-only utilities that are useful for security, diagnostics, or release
engineering, but are not part of the app product or normal Swift package graph.

`Fuzzing/` currently contains the TorrentBridge libFuzzer suite. Keeping it here
lets the fuzz harnesses own their scripts, corpora, fuzz-only dependencies, and
generated artifacts without changing app targets or production build settings.
