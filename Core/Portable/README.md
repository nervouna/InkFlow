# Desktop Rust/Rime runtime

Rust runtime over librime for [#34](https://github.com/nervouna/InkFlow/issues/34) and the shared session policy for [#35](https://github.com/nervouna/InkFlow/issues/35). The Swift engine still ships on macOS; the Rust engine is compared against it here.

## Build and test

Requirements: the repository's Rust 1.98.1 toolchain, a C/C++17 compiler, Python 3, CMake 3.31, Ninja, curl, tar, and a POSIX shell. CMake 3.31.6 and Ninja 1.11.1.4 can be installed without root using `uv tool install`. The Mac runner's login shell must find these tools.

From the checkout root:

```sh
bash Core/Portable/test.sh
# Send a committed revision to the dedicated Mac checkout:
python3 scripts/mac-remote.py portable
# Compile and smoke-test full production resources in isolated directories:
bash Core/Portable/prepare-resources.sh
python3 scripts/mac-remote.py resources
# Compare the Rust engine with the recorded Swift behavior on those resources:
bash Core/Portable/parity.sh [build/portable/resources.XXXXXX]
```

The first build downloads checksum-verified source archives. Subsequent builds reuse them under `build/portable/`; native outputs and Cargo artifacts stay there too. Set `CMAKE_BUILD_PARALLEL_LEVEL` to change the native build parallelism (default 4). Do not run two builds in the same checkout. Remove `build/portable/` for a clean rebuild or after changing compiler/SDK/architecture.

`native-sources.lock.json` pins source commits, URLs, and SHA-256 hashes. librime is the shipping 1.17.0 revision. Its glog, LevelDB, marisa, OpenCC, and yaml-cpp pins follow that revision's submodules; Boost remains 1.89.0. The Lua plugin is pinned to its last upstream commit before the 1.17.0 release, with Lua 5.4.8 from its pinned thirdparty tree.

Both desktops build the same source graph. The build links static dependencies and the Lua plugin into a shared librime, then compiles both existing `InkFlowRimeNative` source files against that build's installed headers and generated configuration. External plugin discovery is disabled. The narrow C++ bridge registers `inkflow_mixed_personal` after every initialization and checks its presence. No host librime or Homebrew C++ headers are used for the native extension.

OpenCC 1.1.9 requests C++14, but the pinned marisa headers require C++17. The build changes only OpenCC's language-standard declarations to C++17 and explicitly includes `cstdint` for GCC 15. OpenCC uses the same pinned marisa library as librime. Optional gflags, libunwind, Snappy, crc32c, and tcmalloc dependencies are disabled to avoid host-dependent linkage.

The test copies the tiny checked-in source fixture into a fresh temporary directory, compiles it using the target runtime, and removes the directory after runtime teardown. It checks Chinese composition, one-shot commits, a non-ASCII Lua filter, snapshot ownership, serialized sessions across threads, runtime/session lifetime, and restart.

## Session policy and old/new comparison

`src/engine.rs` ports `IFEngine`: `Engine` owns one runtime, the prepared context index and the custom-phrase file; `InputSession` owns one input context. Rime keeps editing, segmentation, lookup, paging and its own learning. The engine adds equivalent-span ordering and selection by displayed index, digit and Up/Down policy, the preceding-text context, custom phrases through Rime's native `custom_phrase.txt` (written on settings changes, reloaded by every session at a shared idle), input preferences and candidate counts applied by replacing schema nodes at a composition boundary, ASCII mode, and commit text preserved across a settings reload. `src/preferences.rs`, `src/phrases.rs` and `src/channel.rs` port the matching Swift domain code.

`src/ranking.rs` ports the Swift equivalent-span ranker, including strict metadata parsing, Han phrase context, personal-strength limits, custom-source priority, and native-order fallback; it reads the prepared `pinyin_simp.context.bin` whole into memory and never touches storage from a key event. Its 291 synthetic cases compare against the unchanged Swift source. Mac runtime tests regenerate the reference before checking Rust; Linux tests use the recorded results.

`tests/parity.rs` compares the Rust engine with the Swift engine on prepared production resources and isolated user directories (`parity.sh`; the tests skip without `INKFLOW_PORTABLE_RESOURCES`):

- The 21 samples of [the quality baseline](../Fixtures/QualityBaseline/README.md) reproduce `baseline.json` exactly: first page, target rank, paging, selection, one-shot commits, five learning commits, and the learned state after the runtime restarts on the same user directory.
- `swift_engine_regressions` carries the expectations of the Swift engine regressions for basic cases, context ranking, custom phrases, input settings and ASCII boundaries, plus the stale-selection and observer contracts.

Quality recording stays outside the engine. `Engine::set_observer` installs a callback that receives every completed mutation with the displayed snapshots before and after, delivered after the policy lock is released; it cannot change input or hold a key event. The engine itself performs no telemetry, network, SQLite or disk work from a key event other than the phrase-file reload at a shared idle. Personal-learning management and portable personal-data import are not ported yet.

## Interface contract

`native/bridge.h` is the experimental internal C ABI between Rust and the native runtime. It uses Rime's public C API for lifecycle, deployment, input, context, and commits. C++ internals are confined to the existing extension and its registration check. The Rust library exposes safe `Runtime` and `Session` handles; a stable frontend-facing exported Rust C ABI is deferred until session policy is migrated.

- One process-wide Rust mutex serializes **all** Rime calls, including initialization, deployment, reads, destruction, and finalization. The engine's policy lock serializes every `InputSession` of an `Engine` and nests outside that mutex. Sessions can move between threads. No GUI event loop, Swift actor, or thread affinity is required. Another engine must not call librime outside this lock in the same process; old/new comparisons need separate processes.
- There is at most one runtime. A second initialization returns `AlreadyRunning`. Sessions retain an `Arc` to the runtime, so dropping its public handle cannot finalize live sessions. The last session/runtime owner finalizes Rime. A poisoned lock fails subsequent normal operations; destructors still attempt cleanup without panicking.
- Callers supply existing shared-resource and writable user directories. Initialization, source deployment, and session creation are setup work. `Runtime::with_cache` separates target-native cache files from personal data. `prepare` runs Rime's schema-list maintenance and checks its completion notification. Preparation and deployment are rejected while sessions exist. The wrapper does not prepare resources, download, access SQLite, or record telemetry from `process_key`.
- All text and paths crossing this ABI are NUL-terminated UTF-8. Embedded NUL and non-UTF-8 paths are rejected. Snapshot caret/selection offsets count **bytes in the returned UTF-8 preedit**. Rust validates character boundaries; frontends must convert to UTF-16 or other platform units. Candidate text and comments are independent strings.
- Keys are Rime/X11 keysyms with Rime modifier masks, not macOS virtual key codes or Linux hardware scan codes. `process_key` returns whether Rime handled the event. There is no surrounding-text or mobile editing API yet. `change_page` delegates paging to Rime. `select_candidate` accepts a zero-based current-page index and the latest snapshot from that session. It rejects snapshots from other sessions, superseded snapshots, and out-of-range indices before calling Rime. Keys, clears, native selection attempts, and page changes invalidate selection tokens even if Rime does not handle the operation. Cloned snapshots retain their token; changing public display fields cannot change the native candidate count used for validation. `InputSession::select` and `highlight` apply the same rule to displayed indices: the snapshot must be the session's latest ordered page, and any mutation supersedes it, while repeated reads keep one identity.
- Snapshots are copied into Rust-owned strings and vectors while the lock is held. They remain valid after another event, another snapshot, session destruction, and runtime teardown. Page and highlighted indices are zero-based native menu metadata; an empty menu has no selectable entry regardless of those fields.
- `take_commit` consumes Rime's pending commit once and returns `None` when empty. Call it after each key or candidate selection before processing the next action. The prototype does not queue multiple uncollected commits. On an allocation or UTF-8 conversion error, a retrieved commit may already have been consumed; stop the session rather than replaying the key.
- Internal C callers must pass valid borrowed pointers and zero-initialized outputs. Status 0 is success, -1 native failure, -2 invalid session/schema, and -3 a caught C++ exception. A false/unhandled key is not an error. Native snapshots and commit buffers must be freed with their matching ABI functions, never Rust's allocator. Snapshot free clears the struct; it also accepts a zeroed snapshot.
- Every throwing C++ entry point catches exceptions before returning to Rust. The ABI has no callbacks into Rust, so Rust unwinding cannot cross it. Invalid pointers remain programmer errors, and allocator aborts/native crashes are not recoverable status codes. A native exception can leave engine state partially changed; callers must stop using the runtime and restart it.

See also the [shared dictionary generator](dictionary/README.md), which supplies Chinese source generation and spelling profiles for build preparation and the Swift update worker, and, before packaging, [the distribution review](licenses.md).
