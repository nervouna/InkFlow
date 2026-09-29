# Project guidance

Solo project. Keep changes small and direct; prefer deleting code over adding guards, layers or process.

## Product rules

- Offline Rime typing is the baseline. AI, downloads and telemetry must never block or break it; keep network, disk and SQLite work off the key-event path.
- For dictionary, learning and ranking work, try existing Rime capabilities and configuration before writing custom mechanisms.
- Quality telemetry exists to iterate ranking and English mixing. It must not change ranking or input, and must not log secrets. AI stays default-off.

## Workflow

- Build: `bash macOS/scripts/build.sh`. Build numbers increase on every build by design; don't comment on them.
- Test only what you touched: `bash macOS/scripts/test.sh quick` for logic changes, or name units (`test.sh engine controller`). UI-only changes (SwiftUI views, layout, copy): build and stop — the user checks them in the app.
- Run `test.sh all` only for releases or when explicitly asked. If one unit fails, fix it and rerun that unit.
- Typing, focus and Settings behavior are checked by the user. List what they should try in one or two lines; don't track it further.
- `iconutil` fails inside the sandbox; run builds outside it from the first attempt.
- Extra worktrees go under `.worktrees/<name>/`.
- Roadmap lives in GitHub Issues. Reference the issue in the PR (`Fixes #N`); GitHub moves the Project item. Don't update Project fields by hand.
- Release: use the `inkflow-release` skill. It runs the full suite once; don't add extra verification rounds.
- Known failures: see [macOS/DEBUGGING.md](macOS/DEBUGGING.md).
