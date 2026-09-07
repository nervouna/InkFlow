# Project guidance

1. Separate first-time installation from routine updates.
2. Before finishing, remove unsuccessful experimental changes and leave a reproducible working version.
3. When debugging, check [macOS/DEBUGGING.md](macOS/DEBUGGING.md) for similar cases first.
4. For mixed Chinese/English input, English admission/ranking, or frequency overrides, use [inkflow-mixed-input-maintenance](.agents/skills/inkflow-mixed-input-maintenance/SKILL.md).
5. For recorded input-quality summaries, recurring ranking evidence, or composition inspection, use [inkflow-quality-analysis](.agents/skills/inkflow-quality-analysis/SKILL.md).
6. For a GitHub release or resuming an interrupted publication, use [inkflow-release](.agents/skills/inkflow-release/SKILL.md).
7. Create all additional Git worktrees under the main checkout's `.worktrees/<name>/` directory, and keep `/.worktrees/` in the root `.gitignore`.
8. For features spanning multiple modules or involving network interactions, design observability before implementation. Trace the important stages with correlation IDs, explicit skip/cancel/failure reasons, and status/timing metadata; verify that a failed real run can be diagnosed from retained logs. Keep secrets and user content out of logs, suppress repeated unchanged events, and include log inspection in acceptance checks.
