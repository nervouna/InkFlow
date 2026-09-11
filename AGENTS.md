# Project guidance

1. For known failures, start with [macOS/DEBUGGING.md](macOS/DEBUGGING.md) and classify evidence as source, configuration, InkFlow, platform, or test-environment behavior.
2. Run build paths that invoke `iconutil` in an appropriate non-restricted environment on the first attempt; investigate icon resources only if the unchanged command still fails there. API names, simulated clients, and timing correlation prove neither behavior nor cause.
3. Preserve offline Rime as baseline. Optional AI, downloads, telemetry, and recovery must not block or corrupt it; keep network, disk, SQLite/JSON, and long preparation off the key-event path.
4. Candidate/dictionary consumers share one reproducible generated-data contract with explicit admission, ranking, deduplication, and source priority. Missing evidence is `unknown`, never zero or success.
5. Telemetry must not change ranking or input. Multi-stage/module/network features retain correlation IDs, stages, timing, and skip/cancel/failure reasons while suppressing repeats. Log no secrets or user content; store only minimal, bounded local data with explicit retention; keep AI default-off.
6. Distinguish first install, update, temporary diagnosis, formal daily-use installation, and release; record visible typing only after user confirmation.
7. Keep auxiliary worktrees under the main checkout's ignored `.worktrees/<name>/`. Test the exact prospective integration tree and remove only proven task-owned artifacts.
8. Follow [macOS/DEVELOPMENT.md](macOS/DEVELOPMENT.md#verification) for verification selection, prerequisites, and evidence boundaries.
