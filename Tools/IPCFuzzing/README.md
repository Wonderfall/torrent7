# TorrentEngineIPC JSON Fuzzing

Developer-only coverage-guided fuzzing for the bounded JSON allocation
preflight used on the XPC trust boundary.

The target builds the production `TorrentEngineIPC` scanner with Swift
sanitizer coverage and AddressSanitizer, then links a small C++ libFuzzer
harness with Homebrew LLVM's libFuzzer runtime. It exercises both the smallest
common operation profile and the absolute protocol profile for every input.

The latest project Xcode and Homebrew LLVM are required:

```sh
brew install llvm
Scripts/verify-xcode.zsh
```

## Run

```sh
Tools/IPCFuzzing/run-libfuzzer.sh
```

Useful overrides:

```sh
RUNS=1000000 Tools/IPCFuzzing/run-libfuzzer.sh
MAX_LEN=4194304 LIBFUZZER_ARGS="-timeout=10" \
  Tools/IPCFuzzing/run-libfuzzer.sh
```

Crash artifacts and the learned corpus are written below
`Tools/IPCFuzzing/libfuzzer-artifacts`. The checked-in corpus is seed input
only. The fuzz support dynamic library is a developer tool product and is not
linked into any shipped app or extension.
