# Workspace Instructions

Develop InkFlow toward the fastest and most intelligent IME. Use these goals to guide implementation choices.

- Prevent regressions in cold-start time, key-press latency and text-rendering latency.
- Aim for at least 97% first-choice accuracy in the long term. See the
  [current ranking targets and ship rule](docs/input-quality-metrics.md#the-first-choice-target).
- Keep offline Rime typing available independently of AI, downloads and telemetry. Keep network, disk and SQLite
  work off the key-event path.
- Try existing Rime capabilities and configuration first for dictionary, learning and ranking changes.
- Use quality telemetry to improve ranking and English mixing. Keep it observational and free of secrets.
  AI stays off by default.

## Code style

- Write one statement per line, with shell syntax such as `if …; then` and `do` allowed. Keep new and edited code
  within 120 columns. Leave untouched code formatting as it is.
- Use the [shell test assertion forms](macOS/TESTING.md#shell-test-assertions) in shell tests.
- CI rejects new code comments. Put decisions in the nearest project doc and track implementation shortcomings
  in GitHub issues. See [comment lint](docs/comment-cleanup.md#lint-and-inventory) and use `delete-comment` for
  cleanup batches.

## Build and verify

- For shared-core work, read the [portable runtime guide](Core/Portable/README.md). For new platforms, read the
  [migration design](docs/portable-core-migration.md).
- Follow the [macOS build guide](macOS/DEVELOPMENT.md#build-and-try-the-development-version) and
  [focused test matrix](macOS/TESTING.md#which-tests-to-run). See [known failures](macOS/DEBUGGING.md) when diagnosing.
  From Linux, read the [remote workflow](docs/remote-mac-baseline.md) before using or changing
  `scripts/mac-remote.py`. It sends committed revisions only.
- Verify changes to default input behavior with a user action and an observable result under default settings.
  The orchestrator verifies combined behavior when multiple PRs affect the same input path.
- The user checks typing, focus and Settings behavior. Give them one or two lines on what to try and leave
  follow-up to them. Installing or activating an input method requires explicit user approval.
- For releases, follow [`inkflow-release`](.agents/skills/inkflow-release/SKILL.md) and its single verification run.

## Git and GitHub

- Follow the `orchestrate` skill. The issue body is the spec. Use one issue, one branch `<N>-<slug>` from
  `origin/main` and one PR with the [PR template](.github/pull_request_template.md).
- Use `.worktrees/<name>/` for extra worktrees and run commands in the intended worktree. Stage files by name so
  untracked tool output stays out of commits.
- The Main Required Checks ruleset requires six CI checks on `main`. Repository admins can bypass it.
  Enable auto-merge with a merge commit after opening a PR. Check the run for its result.
- GitHub Issues hold the roadmap. Use `Fixes #N` if the PR completes the issue and `Refs #N` otherwise.
  Let GitHub move the Project item automatically.
