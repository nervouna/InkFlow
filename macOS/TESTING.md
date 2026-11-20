# Testing

Tests are standalone executables driven by `macOS/scripts/test.sh`. They use synthetic data, temporary Rime user roots and random defaults suites; they never read production learning data, credentials or telemetry.

## Which tests to run

| Change | Run |
| --- | --- |
| SwiftUI views, layout, copy | Build only; check it in the app |
| Engine, ranking, English mixing, controller | `test.sh quick` (about 3 min), plus the specific unit if it isn't in quick |
| One subsystem | Name it: `test.sh quality`, `test.sh ai`, `test.sh voice`, `test.sh dictionary`, or a single unit |
| Release | `test.sh all` once, through `release-verification.sh` |

```sh
bash macOS/scripts/test.sh quick
bash macOS/scripts/test.sh engine-english controller
bash macOS/scripts/test.sh --help     # lists every unit
bash Core/scripts/test.sh             # standalone Core package, no app build
```

`dictionary-worker`, `dictionary-activation`, `personal-data` and `termination` need a current `build.sh` app. The runner stops at the first failing unit; fix it and rerun that unit.

Every unit that builds Swift also builds the Rust core and its librime first (`Core/scripts/build-portable.sh`, once per `test.sh` run; the first run takes about 4 minutes longer and needs CMake and Ninja). GitHub Actions restores `build/portable` from the cache it shares with the portable job, runs `test.sh quick` and, in a second job, `test.sh portable` on `macos-26` runners for every pull request and push to `main` (docs-only changes skip them). The ubuntu jobs run the shared-core boundary check, the portable `cargo test` and the remote-runner tests.

## What the units cover

- `engine-*`: editing, candidate indexes, exact-once commit, English admission/ranking, context reranking, input options, custom phrases.
- `controller`, `voice-controller`: IMK controller delivery, focus/recovery paths, voice insertion through the real controller.
- `quality-*`: telemetry store migration/atomicity/retention, timing, build identity, and real capture → query.
- `ai-*`: credentials (random Keychain service), transport, runtime debounce/invalidation, native learning, headless pipeline. No paid API calls.
- `dictionary-*`, `preparation`, `deployment`: source validation, transactional store, worker sandbox, activation/recovery.
- `input-source-lifecycle`: the `Shared/` code behind `register-input-source`: process stop and exit observation, update prepare/finish state (first install, declined or timed-out quit, restored selection) and atomic app replacement. Uses fake input sources and child processes; it never touches the desktop.
- `workflow`: fixtures for the release receipt and release resume, Developer ID identity checks, `install.sh`, the installer package (including `--sign` wiring), staged builds and cleanup. Stand-in tools only: no keychain, desktop or notarization.
- `portable`: not in `quick`. Runs the Rust tests, old/new parity on freshly prepared production resources, the notices check and a Swift binary linking both Rust staticlibs, on the librime and release Rust core that every unit now uses. The first run builds librime from source (about 4 minutes, then about 2.5 minutes with `build/portable` reused); CI caches that directory.
- `settings`, `personal-data`, `startup-diagnostics`, `local-diagnostics`, `diagnostic-archive`, `termination`.

GUI harnesses (`test-settings-ui.sh`, AI native/live scripts) are manual diagnostics only; live AI scripts cost money and need explicit approval.

## Python query checks

`test-quality-query.sh` uses `python3` from `PATH` (override with `INKFLOW_PYTHON`) and only the standard library.

## Test fixture constraints

- The full runner prebuilds the two long-running Swift units before launching them as background
  process groups. It keeps other units serial and stops the whole group on failure. The wrapper
  invokes the unit outside a shell conditional so `set -e` applies inside inherited functions.
  The shared-core run skips units already covered by the full runner. Its old-English-cache fixture
  includes every inventory row with a lowercase code and no Zipf gate.
- The Rime learning fixture is a test-only observer for `learning_contract` using the versioned
  property channel. It demonstrates trailing-space termination for custom codes, durability only
  after the write transaction closes, and learning only from the namespace owning a selected
  Phrase. Compiled Phrase learning needs the compiled entry code. Explicit arbitrary-code writes
  use `custom_code`. The shell comparison selects the C locale because macOS awk can collate
  distinct CJK strings as equal under UTF-8 locales.
- The package tests avoid a real installation with a temporary home, minimal ad-hoc signed fixture,
  and stand-in lifecycle tool and signing processes. They exercise both stages, missing parent
  directories, a failed preflight and failures before and after swapping. Signing and restoration
  checks isolate individual failures. The local install fixture separately covers recovery after
  an unconfirmed update and runs read-only desktop preflight diagnostics through stand-ins.
- Release workflow fixtures use a real receipt, fake platform commands and synthetic extracted
  package layouts. This lets the resume tests cover both Keychain and owner-only key-file signing
  without submitting a notarization. Configuration lookup lets the fixture's explicit environment
  override a developer's private configuration.
- Quality build metadata tests isolate executable byte changes, resource drift and signed bundle
  checks. Re-signing can change the bundle's canonical byte layout, so a synthetic digest change
  tests that signing-dependent boundary deterministically. Framework symlinks contribute their
  relative targets, and both lexical and resolved destinations must stay within the framework.
  The build closure covers new untracked helpers before the commit.
- Controller initialization and black-box benchmarks use a logged-in GUI session. The benchmark
  wrapper uses `exec` so the driver receives signals and restores its input source. The IMK lifetime
  probe builds a temporary diagnostic only. It reads pointer identity without retaining or messaging
  the possibly freed object. Match the probe's outcome, since LLDB can exit successfully after a
  deliberate diagnostic breakpoint. The private framework probe is outside the shipping link.
- The microphone diagnostic runs through LaunchServices to get its own TCC identity. Running its
  executable directly can inherit the terminal's permissions. The harness retains the production
  background/agent plist flags while using its own bundle identity.
