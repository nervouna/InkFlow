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

GitHub Actions runs `test.sh quick` on a `macos-26` runner for every pull request and push to `main` (docs-only changes skip it). The ubuntu jobs run the shared-core boundary check, the portable `cargo test` and the remote-runner tests.

## What the units cover

- `engine-*`: editing, candidate indexes, exact-once commit, English admission/ranking, context reranking, input options, custom phrases.
- `controller`, `voice-controller`: IMK controller delivery, focus/recovery paths, voice insertion through the real controller.
- `quality-*`: telemetry store migration/atomicity/retention, timing, build identity, and real capture → query.
- `ai-*`: credentials (random Keychain service), transport, runtime debounce/invalidation, native learning, headless pipeline. No paid API calls.
- `dictionary-*`, `preparation`, `deployment`: source validation, transactional store, worker sandbox, activation/recovery.
- `settings`, `personal-data`, `startup-diagnostics`, `local-diagnostics`, `diagnostic-archive`, `termination`, `installer-core`, `workflow`.

GUI harnesses (`test-settings-ui.sh`, `test-installer-window.sh`, AI native/live scripts) are manual diagnostics only; live AI scripts cost money and need explicit approval.

## Python query checks

`test-quality-query.sh` uses `python3` from `PATH` (override with `INKFLOW_PYTHON`) and only the standard library.
