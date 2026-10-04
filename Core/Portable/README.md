# Desktop Rust/Rime probe

This is the minimal runtime for [#34](https://github.com/nervouna/InkFlow/issues/34). It does not replace the Swift engine or migrate ranking, learning policy, dictionary generation, or a frontend.

## Build and test

Requirements: the repository's Rust 1.98.1 toolchain, a C/C++17 compiler, Python 3, CMake 3.31, Ninja, curl, tar, and a POSIX shell. CMake 3.31.6 and Ninja 1.11.1.4 can be installed without root using `uv tool install`. The Mac runner's login shell must find these tools.

From the checkout root:

```sh
bash Core/Portable/test.sh
# Send a committed revision to the dedicated Mac checkout:
python3 scripts/mac-remote.py portable
```

The first build downloads checksum-verified source archives. Subsequent builds reuse them under `build/portable/`; native outputs and Cargo artifacts stay there too. Nothing installs into system directories or activates an input method. Set `CMAKE_BUILD_PARALLEL_LEVEL` to change the native build parallelism (default 4). Do not run two builds in the same checkout. Remove `build/portable/` for a clean rebuild or after changing compiler/SDK/architecture.

`native-sources.lock.json` pins source commits, URLs, and SHA-256 hashes. librime is the shipping 1.17.0 revision. Its glog, LevelDB, marisa, OpenCC, and yaml-cpp pins follow that revision's submodules; Boost remains 1.89.0. The Lua plugin is pinned to its last upstream commit before the 1.17.0 release, with Lua 5.4.8 from its pinned thirdparty tree. This does not establish that the plugin source is byte-for-byte identical to the prebuilt shipping plugin.

Both desktops build the same source graph. The build links static dependencies and the Lua plugin into a shared librime, then compiles both existing `InkFlowRimeNative` source files against that build's installed headers and generated configuration. External plugin discovery is disabled. The narrow C++ bridge registers `inkflow_mixed_personal` after every initialization and checks its presence. No host librime or Homebrew C++ headers are used for the native extension.

OpenCC 1.1.9 requests C++14, but the pinned marisa headers require C++17. The build changes only OpenCC's language-standard declarations to C++17 and explicitly includes `cstdint` for GCC 15. OpenCC uses the same pinned marisa library as librime. Optional gflags, libunwind, Snappy, crc32c, and tcmalloc dependencies are disabled to avoid host-dependent linkage. Toolchains and platform C/C++ libraries remain host prerequisites; this is a source-reproducible build recipe, not a promise of bit-identical binaries.

The test copies the tiny checked-in source fixture into a fresh temporary directory, compiles it using the target runtime, and removes the directory after runtime teardown. It never copies a macOS cache to Linux or accesses installed personal data. It checks Chinese composition and one-shot commits, a Lua filter with non-ASCII output, snapshot ownership, multiple serialized sessions on separate threads, runtime/session lifetime, and restart. This fixture does not establish production-dictionary parity or performance.

## Interface contract

`native/bridge.h` is the experimental internal C ABI between Rust and the native runtime. It uses Rime's public C API for lifecycle, deployment, input, context, and commits. C++ internals are confined to the existing extension and its registration check. The Rust library exposes safe `Runtime` and `Session` handles; a stable frontend-facing exported Rust C ABI is deferred until session policy is migrated.

- One process-wide Rust mutex serializes **all** Rime calls, including initialization, deployment, reads, destruction, and finalization. Sessions can move between threads. No GUI event loop, Swift actor, or thread affinity is required. Another engine must not call librime outside this lock in the same process; old/new comparisons need separate processes.
- There is at most one runtime. A second initialization returns `AlreadyRunning`. Sessions retain an `Arc` to the runtime, so dropping its public handle cannot finalize live sessions. The last session/runtime owner finalizes Rime. A poisoned lock fails subsequent normal operations; destructors still attempt cleanup without panicking.
- Callers supply existing shared-resource and writable user directories. Initialization, source deployment, and session creation are setup work. Deployment is rejected while sessions exist. The wrapper does not prepare resources, download, access SQLite, or record telemetry from `process_key`. Rime's own synchronous lookup and persistence behavior is retained; this does not claim that upstream Rime performs no disk I/O.
- All text and paths crossing this ABI are NUL-terminated UTF-8. Embedded NUL and non-UTF-8 paths are rejected. Snapshot caret/selection offsets count **bytes in the returned UTF-8 preedit**. Rust validates character boundaries; frontends must convert to UTF-16 or other platform units. Candidate text and comments are independent strings.
- Keys are Rime/X11 keysyms with Rime modifier masks, not macOS virtual key codes or Linux hardware scan codes. `process_key` returns whether Rime handled the event. There is no surrounding-text, mobile editing, or candidate-selection API yet. A later selection API must identify its snapshot generation before it can accept delayed UI actions.
- Snapshots are copied into Rust-owned strings and vectors while the lock is held. They remain valid after another event, another snapshot, session destruction, and runtime teardown. Page and highlighted indices are zero-based native menu metadata; an empty menu has no selectable entry regardless of those fields.
- `take_commit` consumes Rime's pending commit once and returns `None` when empty. Call it after each key before processing the next one. The prototype does not queue multiple uncollected commits. On an allocation or UTF-8 conversion error, a retrieved commit may already have been consumed; stop the session rather than replaying the key.
- Internal C callers must pass valid borrowed pointers and zero-initialized outputs. Status 0 is success, -1 native failure, -2 invalid session/schema, and -3 a caught C++ exception. A false/unhandled key is not an error. Native snapshots and commit buffers must be freed with their matching ABI functions, never Rust's allocator. Snapshot free clears the struct; it also accepts a zeroed snapshot.
- Every throwing C++ entry point catches exceptions before returning to Rust. The ABI has no callbacks into Rust, so Rust unwinding cannot cross it. Invalid pointers remain programmer errors, and allocator aborts/native crashes are not recoverable status codes. A native exception can leave engine state partially changed; callers must stop using the runtime and restart it. The interface is not a sandbox for untrusted Lua or schemas.

Mobile and Windows are not enabled by this build. Lifecycle ownership avoids dependence on a permanent app process, but mobile memory limits, platform key adapters, static-link packaging, and device behavior remain unvalidated.

The [desktop verification record](verification.md) identifies the tested revision, toolchains, and retained evidence. The separate [dictionary generator comparison](dictionary/README.md) ports Chinese source generation and spelling profiles without changing this runtime or the shipping preparation path. See [the distribution review](licenses.md) before packaging binaries or production dictionaries.
