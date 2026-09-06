---
name: inkflow-mixed-input-maintenance
description: Maintain InkFlow's Chinese-first mixed Chinese/English input, English frequency admission and ranking, and exact-word correction table. Use for related bad cases or policy changes, not unrelated input-method UI work.
---

# InkFlow mixed-input maintenance

InkFlow is a Chinese input method. English supports occasional words inserted into Chinese. Preserve that boundary when diagnosing a bad case; English writing assistance, broad vocabulary cleaning, new-word synthesis, and contextual English ranking are separate product decisions.

## Workflow

1. Read [current rules and override contract](references/rules.md) and the relevant sources below. Code/configuration is authoritative; update this reference when behavior changes.
2. Record the raw keystrokes, displayed candidate spelling/case, expected result, and whether the issue occurs while typing, editing, selecting, or paging. Preedit spacing alone does not identify the raw input.
3. Locate the failing layer: original spelling/code absent; frequency observation missing; effective value below admission; mixed structural restriction; admitted candidate behind Chinese or on a later page; or stale installed/compiled resources. Search all relevant pages before declaring a candidate absent.
4. Choose the smallest change for the accepted outcome. A word correction belongs in the override table; a global threshold changes the whole vocabulary. Frequency cannot repair an absent source spelling, unwanted display case, or a Chinese-priority collision. Do not add runtime admission bypasses.
5. Verify at the affected layer using the checks below. Preserve Chinese input, the existing Chinese user dictionary, and the shared gate. Stop when the accepted case and applicable regressions pass; do not turn a local correction into a new English subsystem.

## Sources

Paths in the reference and commands are relative to the repository root.

| Responsibility | Source |
| --- | --- |
| Shared admission and dictionary generation | [prepare-rime.sh](../../../macOS/scripts/prepare-rime.sh) |
| Configurable gate/scaling and exact-word corrections | [english.conf](../../../macOS/config/english.conf), [english-overrides.tsv](../../../macOS/config/english-overrides.tsv) |
| Frequency provenance, limits, regeneration and hashes | [Data/README.md](../../../macOS/Data/README.md), [snapshot-english-frequency.py](../../../macOS/scripts/snapshot-english-frequency.py) |
| Standalone English lookup/sorting and mixed filtering | [inkflow_english.lua](../../../schemas/lua/inkflow_english.lua), [inkflow_mixed.lua](../../../schemas/lua/inkflow_mixed.lua) |
| Translator composition and compilation dependencies | [inkflow_pinyin.schema.yaml](../../../schemas/inkflow_pinyin.schema.yaml), [easy_en.schema.yaml](../../../schemas/easy_en.schema.yaml), [inkflow_mixed.schema.yaml](../../../schemas/inkflow_mixed.schema.yaml) |
| Pinned engine behavior and deployment pitfalls | [DEPENDENCIES.md](../../../macOS/DEPENDENCIES.md), [DEBUGGING.md](../../../macOS/DEBUGGING.md), [Engine.swift](../../../macOS/Sources/Engine.swift) |

## Verification and delivery

- For ordinary override/config/generation changes, run `bash macOS/scripts/test.sh`. It includes the focused `test-prepare-rime.sh` fixtures, engine transcripts and deployment regression. During development, run the focused fixture script separately as useful; avoid redundant reruns after the full suite passes.
- Add or adjust a regression for the actual changed behavior in [EngineTests.swift](../../../macOS/Tests/EngineTests.swift) or [test-prepare-rime.sh](../../../macOS/scripts/test-prepare-rime.sh). Check prefixes and backspaces, case/code aliases, exact and completion paths, later pages, selection/re-entry, and Chinese before/after the English word as relevant. A complete final sentence alone misses unfinished-Pinyin regressions.
- For generation semantics, cover the inclusive boundary, missing evidence, positive replacement, zero exclusion, case/alias scope, scaling isolation, malformed/duplicate records and preservation of previous dictionaries on validation failure. Reuse existing fixtures rather than creating another harness.
- For dictionary deployment changes, retain [DeploymentTests.swift](../../../macOS/Tests/DeploymentTests.swift): older bundled timestamps must still replace obsolete full-English caches, unchanged compiled tables must be reused, and Chinese user data must remain.
- For runtime delivery, build with `bash macOS/scripts/build.sh`, then run `bash macOS/scripts/check-bundle.sh`. It compares packaged resources with regenerated sources and runs the engine transcript against the packaged library. Install/update only within the user's authorization and follow the applicable Apple signing instructions.
- After an authorized update, verify the installed resources and restarted input-method process. Rime startup uses `start_maintenance(1)` for content checks; do not rely on version/mtime changes or routinely delete caches/user dictionaries. Package and engine checks are distinct from real-client typing acceptance. Report the latter only if actually observed.
- For documentation-only changes, validate the skill frontmatter, relative links and consistency with current source. Rebuilding or reinstalling the input method is unnecessary.
