# Project guidance

After every successful app build, include the full Markdown table from `bash macOS/scripts/build-summary.sh APP`. Build success proves neither installation, launch nor notarization. Every `build.sh` invocation allocates a fresh build number, including release verification; use the artifact's identity, not the source floor.

1. For known failures, start with [macOS/DEBUGGING.md](macOS/DEBUGGING.md); distinguish source, configuration, InkFlow, platform and test-environment evidence.
2. Run `iconutil` build paths in a suitable non-restricted environment on the first attempt; investigate resources only if the unchanged command still fails there. API names, simulated clients and timing alone prove neither behavior nor cause.
3. Preserve offline Rime as baseline. Optional AI, downloads, telemetry and recovery must not block or corrupt it; keep network, disk, SQLite/JSON and long preparation off the key-event path.
4. For dictionary, learning, candidate selection, ranking and related strategies, evaluate existing Rime capabilities and configuration first. Prefer reuse; add custom mechanisms or abstractions only when necessary.
5. Candidate/dictionary consumers share one reproducible generated-data contract with explicit admission, ranking, deduplication and source priority. Missing evidence is `unknown`, never zero or success.
6. Telemetry must not change ranking or input. Multi-stage/module/network features retain correlation IDs, stages, timing and skip/cancel/failure reasons while suppressing repeats. Log no secrets or user content; store only minimal, bounded local data with explicit retention; keep AI default-off.
7. Distinguish released-DMG installation, Developer ID development trials, Debug diagnosis and release; record visible typing only after user confirmation.
8. Keep auxiliary worktrees under the main checkout's ignored `.worktrees/<name>/`. Test the exact prospective integration tree; remove only proven task-owned artifacts.
9. Follow [DEVELOPMENT.md](macOS/DEVELOPMENT.md#verification) and [TESTING.md](macOS/TESTING.md#daily-use). Use `test-affected.sh`; extend impact rules when dependencies change. Real typing, focus and cross-App acceptance belong to the user; report daily pending checks. GUI harnesses are explicit diagnostics only. For release, follow [human/release checks](macOS/TESTING.md#human-and-release-checks): affected input/Settings interaction is assumed manually accepted; change-based installation/upgrade still requires confirmation before publication.
