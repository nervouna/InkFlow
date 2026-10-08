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
# Capture key latency and memory with the recorded macOS headless protocol:
bash Core/Portable/performance.sh build/portable/resources.XXXXXX [OUTPUT_DIRECTORY]
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
- `swift_personal_learning_and_data` covers learning management at the idle boundary, export/import between isolated user directories, a macOS-format document with disclosed unsupported preferences, and rejected snapshots rolling back.

Quality recording stays outside the engine. `Engine::set_observer` installs a callback that receives every completed mutation with the displayed snapshots before and after, delivered after the policy lock is released; it cannot change input or hold a key event. The engine itself performs no telemetry, network, SQLite or disk work from a key event other than the phrase-file reload at a shared idle.

## Performance

`performance.sh` runs `src/bin/performance-baseline.rs`, the Rust counterpart of `Core/Tests/PerformanceBaseline/PerformanceBaseline.swift`: five fresh release processes, an absent user directory each, the 21-sample quality corpus typed five times with nine candidates, no commits, context and custom phrases empty. Each key operation is `key` + `take_commit` + `snapshot`; startup covers engine creation (prepared cache, context index, Rime start) and the first configured session. Memory is `getrusage` peak RSS. The summary prints the distributions beside the [approved review limits](../Fixtures/MigrationBaseline/README.md#approved-review-limits) without failing on them.

Same host (Apple M1 Pro, 32 GiB, macOS 27.0.1), same protocol, both engines on freshly prepared production resources, at faee8df. The Swift column ran `performance-baseline` in release from this checkout; the recorded M5 Pro baseline is not comparable to either.

| Measurement | Swift engine | Rust engine | Approved limit |
| --- | ---: | ---: | ---: |
| Headless startup median, ms | 304.61 | 150.58 | 2,300 |
| Peak RSS after input max, MiB | 58.95 | 51.69 | 344 |
| First-pass key median / p95 / p99, ms | 0.609 / 1.952 / 2.543 | 0.585 / 1.856 / 2.309 | p99 2.6 |
| Repeated-pass key median / p95 / p99, ms | 0.582 / 1.879 / 2.289 | 0.547 / 1.759 / 2.153 | p95 1.8, p99 2.3 |
| First key of each process, ms | 13.35–15.33 | 14.19–20.24 | 25 |

Key latency is the same Rime work in both engines; the Rust engine's lower startup and RSS come from mapping no Swift runtime and reading only the prepared index. The one 20 ms first key was the first process after a rebuild (cold file cache); the other four match Swift. Recapture both columns on the same machine after toolchain or OS changes.

## Personal learning and portable personal data

`Engine::personal_learning_entries`, `delete_personal_learning` and `undo_personal_learning` port `EnginePersonalLearning.swift` over the same Lua `learning_manage` channel: they run only when every session is idle and Rime's native undo window (4 s after the last commit) has passed, otherwise `Busy`; entries and undo tokens carry a learning revision that any commit, Backspace/Delete, new session or invalidation supersedes (`Conflict`). As on macOS, the newest commit may still be in Rime's pending transaction until the next transaction or teardown, and a native restore revives a deleted count with one confirmation. Never call this API from a key callback.

`src/personal.rs` defines the portable backup: `Backup::from_json`/`to_json` read and write the macOS format-1 document (`format`, `rime`, `settings`, `dictionaries`). Supported data are the three Rime user dictionaries (`pinyin_simp`, `inkflow_shared_english`, `inkflow_voice_alias`), custom phrases, the candidate count and the input options. macOS-only preferences (shortcuts, font size, layout, thunder mode, voice rules) are skipped and listed in `Backup::unsupported`; unknown fields are rejected like on macOS. Written documents carry neutral values for those fields; macOS additionally requires the three fuzzy options to agree and exactly one paging pair. `personal::export` snapshots closed dictionaries through the existing native helper on a copy; `personal::import` restores snapshots into a staging directory, then moves originals aside and installs the new databases, restoring the originals on any failure; `personal::recover` finishes an interrupted import. `None` in a backup is explicit absence and removes the local dictionary. None of this runs while an engine is initialized in the process (`EngineActive`); frontends stop the engine first and apply the returned settings through `set_configuration` afterwards. Backups never imply that live databases can be shared between engines.

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
