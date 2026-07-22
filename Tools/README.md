# Developer Tools

Developer-only utilities that are useful for security, diagnostics, or release
engineering, but are not part of the shipped app product.

`BridgeFuzzing/` contains the TorrentBridge libFuzzer suite. Keeping it here lets
the fuzz harnesses own their scripts, corpora, fuzz-only dependencies, and
generated artifacts without changing app targets or production build settings.

`XPCIntegrationHost/` contains the executable harness packaged by
`Scripts/test-enhanced-security-extension.zsh` to exercise the Enhanced Security
extension through its real ExtensionFoundation and XPC boundary. The script is
the supported entry point: it assembles, signs, and registers a temporary host
and extension fixture, then runs automated lifecycle recovery checks or
interactive dataset and scale checks with an explicitly authorized folder.

`DependencyCheck/` contains the read-only upstream dependency monitor for pinned
third-party source dependencies.
