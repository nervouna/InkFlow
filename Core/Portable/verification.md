# Desktop runtime verification

Both targets passed at revision `107b4910172d86b2cef7c6c9e189967e695f8209`, using identical native source pins and fixture hashes. Native libraries were built in Release mode; the Rust contract test used Cargo's debug test profile. These are functional results, not performance measurements or production dictionary comparisons.

| Target | Toolchain | Result |
| --- | --- | --- |
| Linux x86_64, kernel 7.0.0-38-generic | GCC 15.2.0, Rust 1.98.1, CMake 3.31.6 | `bash Core/Portable/test.sh` passed |
| macOS 27.0.1 arm64, Apple M1 Pro | Xcode 27.0, Apple clang 21.0.0, Rust 1.98.1, CMake 3.31.6 | `python3 scripts/mac-remote.py portable` returned 0 |

The contract test verified target-local dictionary compilation, native extension registration, Lua execution, `ni hao` composition with `你好` as the first candidate, commit consumption, cancellation, missing-schema rejection, UTF-8 byte offsets, owned snapshots, serialized sessions on two threads, retained runtime lifetime, and restart. The non-ASCII preedit `你` has caret and selection endpoints at byte 3 on both targets.

Linux `cargo clippy --all-targets -- -D warnings` and `cargo fmt --check` passed. The focused remote-runner suite passed all 18 tests. No installed input method or production personal data was used. `ldd` on Linux and `otool -L` on macOS showed only platform C/C++ runtime dependencies for the built librime; Lua and the pinned native dependencies are linked into it.

## Retained evidence

Paths are relative to the tested worktree and remain under ignored `build/`. The Mac receipt records its exact revision, command, machine/toolchains, and exit status. Both native manifests include the source pins and fixture hashes.

| File | SHA-256 |
| --- | --- |
| `build/portable/linux-final.log` | `f1e8135607885fd21eb8d7f5d704f9f3cef165e75a21bc3beefd14ec61a84a90` |
| `build/portable/native-build.json` | `232efcfc80bf583554117c5574929571db32def32fc5ac0d3885f75e56e18d92` |
| `build/mac-remote/20261004T200734Z-1359a0df/run.json` | `928c515d5ba39e75d1d4e3fdd0bb5aab34688237a46fa317ef324ebadf4d43f9` |
| `build/mac-remote/20261004T200734Z-1359a0df/native-build.json` | `aa87c5241e64cc429df482fd16bbbd383a30e848fd9f2c7c73bf6835b8aa918b` |
| `build/mac-remote/20261004T200734Z-1359a0df/00-portable.log` | `96fe0721ef868de8e96293c8f6441479a7030c9cc512b7d1eaa4cc20db5c70e8` |

The first Mac run failed on a warnings-as-errors diagnostic for Rime's C-style aggregate initialization macro in the new bridge. The passing revision uses C++ value initialization and retains the warning policy. No upstream engine behavior was changed to resolve it.
