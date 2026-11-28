# Testing

Tests are standalone executables driven by `macOS/scripts/test.sh`. They use synthetic data, temporary Rime user roots and random defaults suites; they never read production learning data, credentials or telemetry.

## Which tests to run

| Change | Run |
| --- | --- |
| SwiftUI views, layout, copy | [Build only](DEVELOPMENT.md#build-and-try-the-development-version). The user checks it in the app. |
| Engine, ranking, English mixing, controller | `test.sh quick` (about 3 min), plus the specific unit if it isn't in quick |
| One subsystem | Name it: `test.sh quality`, `test.sh ai`, `test.sh voice`, `test.sh dictionary`, or a single unit |
| Release | `test.sh all` once, through `release-verification.sh` |

```sh
bash macOS/scripts/test.sh quick
bash macOS/scripts/test.sh engine-english controller
bash macOS/scripts/test.sh --help     # lists every unit
bash Core/scripts/test.sh             # standalone Core package, no app build
```

Run `test.sh all` only for a release or when the user explicitly asks for it. The runner stops at the first
failing unit. Fix it and rerun that unit.

Every unit that builds Swift also builds the Rust core and its librime first (`Core/scripts/build-portable.sh`, once per `test.sh` run). The first run needs CMake and Ninja and takes much longer; see the [portable build requirements](../Core/Portable/README.md#build-and-test).

## What the units cover

`test.sh --help` lists the units and groups. What it does not say:

- `dictionary-worker`, `dictionary-activation`, `personal-data` and `termination` need a current `build.sh` app. The other units build what they test.
- `portable` is not in `quick`. It runs the Rust tests, `Core/Portable/parity.sh` (the Rust core against the recorded Swift baseline on freshly prepared production resources, with replay and the C ABI check), the notices check and a Swift binary linking both Rust staticlibs. The first run builds librime from source; CI caches `build/portable`.
- `ai-*` use a random Keychain service and never call a paid API. `input-source-lifecycle` uses fake input sources and child processes, and `workflow` uses stand-in tools, so neither touches the desktop, keychain or notarization.

GUI harnesses (`test-controller-initialization.sh`, `test-settings-ui.sh`, AI native/live scripts) are manual diagnostics only, declared in `manual_harnesses` in `test.sh`; live AI scripts cost money and need explicit approval.

## Continuous integration

- **macOS** ([workflow](../.github/workflows/macos.yml)): `test.sh quick` and, in a second job, `test.sh portable` on `macos-26` for every pull request and push to `main`. The PR workflow always decides whether to run the two required jobs. It skips them for docs-only changes, which lets GitHub satisfy the required checks without allocating a Mac. The full suite is a release step. Runners use the same pinned CMake and Ninja versions as Linux and need the pipx bin directory added to the Actions path.
- **Caches:** the native cache retains dependencies, librime and the Cargo target directory; the quick and portable jobs share it. Prepared-resource directories are per-run. The resource cache keys follow the pinned dependencies and the preparation recipe. Inputs are verified by SHA-256, so a stale cache can require a download or rebuild.
- **CI** ([workflow](../.github/workflows/ci.yml)), on Ubuntu:
  - The shared-core boundary check dumps the root Swift manifest and checks it against the standalone Core manifest. Manifest evaluation avoids resolving Sparkle. The root products need the macOS SDK, CryptoKit, AppKit, InputMethodKit, the Sparkle framework and macOS librime.
  - The portable `cargo test` and the Fcitx5 build run on Ubuntu 26.04: the real CMake configure, build and link of the addon against the distribution's Fcitx5 headers, then CTest. The job reuses `Core/Portable/test.sh`'s debug Rust static library and pinned `librime.so` without a second build. The addon uses `Release` and CI adds `--no-undefined` so unresolved addon or ABI symbols fail the link. Ubuntu 24.04's Fcitx5 lacks `CandidateWord::setComment`, so the cache is scoped to 26.04. CTest runs only the pure bridge helpers; it does not load the addon or run a desktop session.
  - The dictionary job pairs the Rust checks with frozen Swift fixtures.
  - The script and helper job runs the installer, quality and bridge helper tests, the comment, style and documentation lints.
- **Linux Release** ([workflow](../.github/workflows/linux-release.yml)): its `package` job also runs on pull requests that touch `Linux/scripts/**`, `Linux/fcitx5/**` or the workflow. On a native ARM64 Arch container it runs the installer tests, builds the package and runs `Linux/scripts/check-release.sh`. The draft job runs only when the workflow is dispatched on `main`; see the [Linux release steps](../.agents/skills/inkflow-release/references/linux.md).

## Python query checks

`test-quality-query.sh` uses `python3` from `PATH` (override with `INKFLOW_PYTHON`) and only the standard library. Its scorecard and replay expectations are in [Python query fixtures](Docs/QualityQueryFixtures.md).

## Test fixture constraints

Fixture rules for the full runner, Rime learning, package, controller and build metadata tests are in [test harness contracts](Docs/TestHarnessContracts.md#test-fixture-constraints).

## Shell test assertions

Define `fail` in each script and write assertions as `[[ ... ]] || fail` or `! cmd || fail`. macOS Bash 3.2
can continue past a bare failed `[[ ... ]]` under `set -e`. A negated command is exempt from `set -e`.
