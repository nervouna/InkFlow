# Desktop Rust/Rime runtime

Rust runtime over librime for [#34](https://github.com/nervouna/InkFlow/issues/34) and the shared session policy for [#35](https://github.com/nervouna/InkFlow/issues/35). macOS reaches it through the `IFEngine` facade and Fcitx5 through the `ifr_*` C ABI. The [runtime contract](runtime-contract.md) defines the ABI, the lock model, the Lua channel and personal data. See also the [dictionary generator](dictionary/README.md), the [distribution review](licenses.md) and [replay](replay.md).

## Build and test

Requirements: the repository's Rust 1.98.1 toolchain, a C/C++17 compiler, Python 3, CMake 3.31, Ninja,
curl, tar, and a POSIX shell. CMake 3.31.6 and Ninja 1.11.1.4 can be installed without root using
`uv tool install`. Make these tools available on `PATH`.

From the checkout root:

```sh
bash Core/Portable/test.sh
# Compile and smoke-test full production resources in isolated directories:
bash Core/Portable/prepare-resources.sh [OUTPUT_DIRECTORY]
# Run the parity and replay suites and abi.sh on those resources:
bash Core/Portable/parity.sh [build/portable/resources.XXXXXX]
# Capture key latency and memory with the recorded macOS headless protocol:
bash Core/Portable/performance.sh build/portable/resources.XXXXXX [OUTPUT_DIRECTORY]
# macOS only: the native build plus the release libinkflow_rime.a that SwiftPM links
# (target InkFlowPortable), then test.sh, parity.sh, the notice check and the Swift link smoke test:
bash Core/scripts/build-portable.sh
bash macOS/scripts/test.sh portable
```

`abi.sh` builds the C-facing dynamic and static libraries and exercises the C consumer. By default it runs
the isolated probe and argument checks. Pass a directory from `prepare-resources.sh` to `abi.sh` or
`parity.sh` to reuse prepared production resources. The parity runner makes that path absolute because
Cargo starts the tests from the crate directory.

The first build downloads checksum-verified source archives. Subsequent builds reuse them under `build/portable/`. Set `CMAKE_BUILD_PARALLEL_LEVEL` to change the native build parallelism (default 4). Do not run two builds in the same checkout. Remove `build/portable/` for a clean rebuild or after changing compiler, SDK, architecture or the minimum macOS version in `macOS/Info.plist`.

## Native build

`native-sources.lock.json` pins every source archive. A changed pin in a reused build directory, such as a restored
CI cache, downloads the archive again and removes the install prefix and every CMake build directory: extracted
headers keep their archive dates, so Ninja would not recompile their includers. librime is the shipping 1.17.0
revision and its glog, LevelDB, marisa and yaml-cpp pins follow its submodules. OpenCC is pinned to 1.4.2 for the
out-of-bounds read fixes of GHSA-7fqq-q52p-2jjg, builds unmodified apart from an explicit `cstdint` include for
GCC 15, and runs its configuration with Git hidden so it does not take its version from this repository's tags.
Static dependencies and the Lua plugin link into one shared librime with external plugin discovery off and no host
librime or Homebrew headers. Boost.Regex builds without ICU, and optional gflags, libunwind, Snappy, crc32c and
tcmalloc are off, so the libraries take no host-dependent linkage.

## Modules

- `src/engine.rs`: `Engine` and `InputSession`, the session policy over Rime.
- `src/ranking.rs`: the equivalent-span ranker over the prepared context index.
- `src/resources.rs`: resource compilation and the smoke probe.
- `src/personal.rs`: the portable personal-data backup.
- `src/abi.rs`: the `ifr_*` C ABI declared in `include/inkflow_rime.h`.

## Frozen references

`fixtures/ranking-reference.json` and `fixtures/quality-evidence.json` are frozen references from the last Swift engine (revision 38eb53c; `quality-evidence.json` names its earlier recording revision, with the Swift engine sources unchanged between them). Their recorders were deleted with the Swift engine, so nothing can regenerate them: change a case only for a reasoned behavior change, by applying that rule to the recorded results, and never by re-recording from the Rust core.

## Performance

`performance.sh` runs `src/bin/performance-baseline.rs`: five fresh release processes, an absent user directory each, the 24-sample quality corpus typed five times with nine candidates, no commits, context and custom phrases empty. Each key operation is `key` + `take_commit` + `snapshot`; startup covers engine creation and the first configured session. Memory is `getrusage` peak RSS. The summary prints the distributions beside the [approved review limits](../Fixtures/MigrationBaseline/README.md#approved-review-limits) without failing on them. Recapture on the same machine after toolchain or OS changes.

Apple M1 Pro, 32 GiB, macOS 27.0.1, freshly prepared production resources, at faee8df:

| Measurement | Rust engine | Approved limit |
| --- | ---: | ---: |
| Headless startup median, ms | 150.58 | 2,300 |
| Peak RSS after input max, MiB | 51.69 | 344 |
| First-pass key median / p95 / p99, ms | 0.585 / 1.856 / 2.309 | p99 2.6 |
| Repeated-pass key median / p95 / p99, ms | 0.547 / 1.759 / 2.153 | p95 1.8, p99 2.3 |
| First key of each process, ms | 14.19–20.24 | 25 |
