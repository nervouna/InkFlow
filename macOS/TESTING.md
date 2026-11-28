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
failing unit. Fix it and rerun that unit. `dictionary-worker`, `dictionary-activation`, `personal-data` and
`termination` need a current `build.sh` app.

Every unit that builds Swift also builds the Rust core and its librime first (`Core/scripts/build-portable.sh`, once per `test.sh` run; the first run takes about 4 minutes longer and needs CMake and Ninja). GitHub Actions restores `build/portable` from the cache it shares with the portable job, runs `test.sh quick` and, in a second job, `test.sh portable` on `macos-26` runners for every pull request and push to `main` (docs-only changes skip them). The ubuntu jobs run the shared-core boundary check, the portable and dictionary `cargo test`, the Fcitx5 build and the script tests with the comment lint.

## What the units cover

- `engine-*`: editing, candidate indexes, exact-once commit, English admission/ranking, context reranking, input options, custom phrases.
- `controller`, `voice-controller`: IMK controller delivery, focus/recovery paths, voice insertion through the real controller.
- `quality-*`: telemetry store migration/atomicity/retention, timing, build identity, and real capture → query.
- `ai-*`: credentials (random Keychain service), transport, runtime debounce/invalidation, native learning, headless pipeline. No paid API calls.
- `dictionary-*`, `preparation`, `deployment`: source validation, transactional store, worker sandbox, activation/recovery.
- `input-source-lifecycle`: the `Shared/` code behind `register-input-source`: process stop and exit observation, update prepare/finish state (first install, declined or timed-out quit, restored selection) and atomic app replacement. Uses fake input sources and child processes; it never touches the desktop.
- `workflow`: fixtures for the release receipt and release resume, Developer ID identity checks, `install.sh`, the installer package (including `--sign` wiring) and staged builds. Stand-in tools only: no keychain, desktop or notarization.
- `portable`: not in `quick`. Runs the Rust tests, old/new parity on freshly prepared production resources, the notices check and a Swift binary linking both Rust staticlibs, on the librime and release Rust core that every unit now uses. The first run builds librime from source (about 4 minutes, then about 2.5 minutes with `build/portable` reused); CI caches that directory.
- `settings`, `personal-data`, `startup-diagnostics`, `local-diagnostics`, `diagnostic-archive`, `termination`.

GUI harnesses (`test-controller-initialization.sh`, `test-settings-ui.sh`, AI native/live scripts) are manual diagnostics only, declared in `manual_harnesses` in `test.sh`; live AI scripts cost money and need explicit approval.

## Python query checks

`test-quality-query.sh` uses `python3` from `PATH` (override with `INKFLOW_PYTHON`) and only the standard library.

## Test fixture constraints

Fixture rules for the full runner, Rime learning, package, controller and build metadata tests are in [test harness contracts](Docs/TestHarnessContracts.md#test-fixture-constraints).

## Shell test assertions

Define `fail` in each script and write assertions as `[[ ... ]] || fail` or `! cmd || fail`. macOS Bash 3.2
can continue past a bare failed `[[ ... ]]` under `set -e`. A negated command is exempt from `set -e`.
