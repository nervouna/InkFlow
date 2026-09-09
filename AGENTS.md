# Project guidance

1. Separate first-time installation from routine updates.
2. Before finishing, remove unsuccessful experimental changes and leave a reproducible working version.
3. When debugging, check [macOS/DEBUGGING.md](macOS/DEBUGGING.md) for similar cases first.
4. For mixed Chinese/English input, English admission/ranking, or frequency overrides, use [inkflow-mixed-input-maintenance](.agents/skills/inkflow-mixed-input-maintenance/SKILL.md).
5. For recorded input-quality summaries, recurring ranking evidence, or composition inspection, use [inkflow-quality-analysis](.agents/skills/inkflow-quality-analysis/SKILL.md).
6. For a GitHub release or resuming an interrupted publication, use [inkflow-release](.agents/skills/inkflow-release/SKILL.md).
7. Create all additional Git worktrees under the main checkout's `.worktrees/<name>/` directory, and keep `/.worktrees/` in the root `.gitignore`.
8. For daily development, commits, and local merges, run affected unit tests and necessary related-module/integration checks; build and check packaged resources when affected. Do not default to full regression or complete GUI suites. Changes to native windows, candidate panels, focus, or input interactions require targeted GUI/native interaction verification. Documentation-only changes need scoped review and diff checks, not application tests.
9. Before a release or formal installation (replacing the input method used day to day, regardless of signing mode), require the full regression and GUI verification in [macOS/DEVELOPMENT.md](macOS/DEVELOPMENT.md#verification). Keep release-specific checks and valid GUI-evidence reuse rules. Report verification scope and missing/failed checks; automated checks do not establish real typing acceptance. Temporary diagnostic installations are not formal acceptance.
10. For features spanning multiple modules or involving network interactions, design observability before implementation. Trace the important stages with correlation IDs, explicit skip/cancel/failure reasons, and status/timing metadata; verify that a failed real run can be diagnosed from retained logs. Keep secrets and user content out of logs, suppress repeated unchanged events, and include log inspection in acceptance checks.
