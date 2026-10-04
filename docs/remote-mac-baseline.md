# Remote Mac builds and migration baseline

This workflow supports [#33](https://github.com/nervouna/InkFlow/issues/33). It builds and tests committed revisions without installing, registering, enabling, or activating InkFlow.

## Run from Linux

From the `portable-core` worktree:

```sh
python3 scripts/mac-remote.py build
python3 scripts/mac-remote.py test engine controller
python3 scripts/mac-remote.py baseline
```

`--revision COMMIT` defaults to `HEAD`. Local uncommitted changes are never sent. The runner prints the resolved commit and evidence directory. Use `--host ALIAS` and `--remote-root PATH` to override the defaults, `tanaris` and `~/Develop/Projects/inkflow-remote`.

The Mac needs key-based SSH, Git, Python 3, the selected Xcode toolchain, Rust 1.98.1, and the existing build scripts' command-line dependencies. Commands run through a fresh Zsh login/interactive shell so the Mac's development environment is available. Shell initialization must not print banners to stdout. Rust is pinned by `rust-toolchain.toml`; install it with `rustup toolchain install 1.98.1 --profile minimal` if absent. Native dependencies retain the exact versions and archive checksums in `macOS/scripts/dependencies.sh`; this phase does not select a new engine release.

The runner transfers a Git bundle, including unpublished commits, into a temporary directory on the Mac. Its own small driver is transferred separately and hashed in `run.json`. It creates an owned checkout at `REMOTE_ROOT/checkout`, fetches the bundle, and checks out the exact requested commit in detached-HEAD mode. It never uses or modifies `~/Develop/Projects/InkFlow`.

Build caches stay under the dedicated checkout's ignored `build/`. Do not share compiled outputs with another checkout. Verified source/download archives may be copied into its dependency cache to avoid downloading them again; the normal preparation scripts still verify their checksums.

## Safety and evidence

- An unowned or dirty remote checkout is rejected. This includes untracked, non-ignored files. The runner does not reset, clean, or stash someone else's changes.
- A directory lock prevents overlapping runner operations on the same checkout. Do not run builds manually in that checkout while the runner owns it.
- The runner allows only build, baseline, and a small set of focused test units. It has no install or arbitrary-command action and rejects `test all`.
- Build runs the ordinary build script and one fast bundle check. No sudo or signing-key transfer is needed.
- Each action records exact commands, elapsed time, exit status, host/toolchain details, and stdout/stderr logs. Failed actions retain evidence and stop before later steps.
- Results are copied to `build/mac-remote/RUN_ID/` on Linux. The remote transfer directory is removed only after evidence is retrieved.
- If SSH is interrupted, inspect the printed remote transfer directory and `REMOTE_ROOT/run.lock`. Check the recorded process and its children before removing a stale lock; do not assume a disconnected command has stopped. If only stdout disconnects, the worker continues saving logs and records `stdoutDisconnected` along with the command\'s eventual exit status.

A dirty local checkout is allowed because only the explicitly resolved committed revision is transferred. Commit changes before expecting them in a remote result. A nonzero exit status means the action or its evidence transfer failed; partial reports are not a passing baseline.

## Baseline recipe

`baseline` runs `Core/scripts/capture-migration-baseline.sh` in a clean checkout. It:

1. Verifies pinned dependencies and standalone Core boundaries.
2. Builds the quality harness, performance harness, and cache tool in release mode for `arm64-apple-macosx26.0`. Ranking regressions use debug mode because their existing support module imports the domain with `@testable`.
3. Prepares one resource tree and compiled cache, reused by both observational harnesses.
4. Runs the existing quality corpus and compares it with the checked-in expected results. Its normal five-selection training and restart recipe is unchanged.
5. Runs five fresh performance processes with absent user directories. Each types the same corpus five times without committing or training. Pass zero and subsequent passes are reported separately.
6. Runs the existing focused `engine`, `ai-learning`, and `voice-lexicon` units. These use their ordinary test configurations; their run times are not performance measurements.

All user state is synthetic and temporary. The recipe does not read installed learning data, credentials, preferences, or quality records.

### Report files

- `run.json`: source revision, driver hash, machine/toolchains, commands, timing, and final exit status.
- `00-baseline.log`: build, regression, and harness output, including failures.
- `behavior.json`: corpus, options, initial/persisted learned observations, and hashes of resources, native binaries, source inputs, and runner.
- `performance-1.json` through `performance-5.json`: startup, process peak RSS, and individual key-operation measurements.
- `summary.json`: validated operation coverage, input/provenance identity, report/binary hashes, per-process and pooled distributions, and slow cases.

Keep complete evidence directories under ignored `build/`. Commit a compact reviewed reference report when establishing the migration baseline, rather than committing build logs or user databases. Results generated before a later failing regression remain diagnostic evidence, not a completed baseline.

### Measurement boundaries

Startup measures prepared-cache descriptor validation, context-index construction, Rime initialization, session creation, and default configuration. It excludes process launch, dictionary compilation, and app/UI startup. Processes are fresh, but filesystem caches are not flushed; these are not disk-cold startup measurements.

A key sample includes synchronous `IFEngine.input`, `takeCommit`, and `snapshot`. It excludes platform delivery, UI rendering, queued actor work, and telemetry. Input is the checked-in ASCII-letter corpus with uppercase modifiers, empty preceding context, no custom phrases, and nine candidates. It does not measure deletion, candidate selection, learned-user latency, or full application typing latency.

Memory is Darwin `getrusage().ru_maxrss` in bytes, sampled after startup and after input. It is the process's peak resident set, not current resident memory, physical footprint, or the installed app's memory. Raw timing records are retained in memory and contribute to the final peak.

Percentiles use nearest rank; median uses the midpoint average for even counts. Compare release builds on the same hardware, OS/toolchain, resource hashes, options, and workload. Investigate first-pass and repeated-pass distributions separately. No performance budget is enforced until the measured reference and proposed limits are approved.

## Focused tooling checks

```sh
python3 -B scripts/tests/test_mac_remote.py
bash -n Core/scripts/capture-migration-baseline.sh
```

Tests cover exact detached revisions, checkout ownership, preservation of dirty files, locking, command restrictions, failed-run evidence/status, and summary statistics. Mac execution verifies the Swift harness and the real SSH/build path.

Actual typing, focus, and Settings remain user checks when the frontend changes. A remote baseline does not certify installed input behavior.
