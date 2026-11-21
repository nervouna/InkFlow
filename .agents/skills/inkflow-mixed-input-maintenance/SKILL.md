---
name: inkflow-mixed-input-maintenance
description: Maintain InkFlow's Chinese-first mixed input, static English admission, personal English learning and ranking, and verified voice ASR correction learning. Use for related candidate cases or policy changes.
---

# InkFlow mixed-input maintenance

Native Rime coverage takes precedence. At equivalent coverage, exactness, verified personal learning and
bounded technical context can move English ahead of Chinese. Keep public English, canonical personal English
and voice-only ASR aliases as separate policy domains.

## Find the owner

Use the row for the observed behavior. Code and configuration are authoritative. Update
[the implemented rules](references/rules.md) when behavior changes.

| Task | First place to look |
| --- | --- |
| Public spelling, frequency or admission | [Data and admission rules](references/rules.md#data-admission-and-weights), then the [override contract](references/rules.md#override-table-editing-rules) for exact corrections. |
| Standalone English, learned words or mixed spans | [Candidate ownership](references/rules.md#candidate-behavior-and-ownership), especially rules 3–9 and 11. Canonical learning uses `inkflow_shared_english.userdb`. |
| Which candidate leads, selection or paging | [Ranking leads](references/ranking-leads.md) for equal coverage, [key behavior](references/keys.md) for selection and editing. |
| Forgetting, reset or Settings learning management | [Forgetting](references/forgetting.md) for Shift+Backspace and [rules 17–18](references/rules.md#candidate-behavior-and-ownership) for personal data. |
| Verified voice correction or alias recall | [Rule 16](references/rules.md#candidate-behavior-and-ownership). Wrong-to-right ASR mappings live only in `inkflow_voice_alias.userdb`. |
| Measurement or stale installed resources | Use [quality analysis](../inkflow-quality-analysis/SKILL.md) for recorded evidence and the [deployment references](references/rules.md#deployment-evidence) for resource preparation. |

Use the [source map](references/rules.md#source-map) to trace the responsible implementation.

## Diagnose and verify

- For typing, capture the keystrokes, spelling and case, preceding context, candidate pages, selection,
  edit position and restart state. For voice, distinguish final ASR, inserted text, later edit, immediate
  undo, client/session continuity and subsequent reuse. Keep user text out of logs and durable diagnostics.
- Check the actual failure boundary, including source membership, admission, native span, personal record,
  metadata, attribution, alias ambiguity and resource freshness. Change the smallest responsible layer.
  Keep the public gate independent of personal corrections and aliases out of keyboard candidates. A new
  persistent store requires its own accepted design. Measurement stays observational and content-free.
- Follow the [focused test matrix](../../../macOS/TESTING.md#which-tests-to-run). For engine and ranking
  changes, `quick` includes `engine-basic`, `engine-context` and `engine-english`. Add only relevant units
  outside the chosen group. See [layer-specific checks](references/rules.md#layer-specific-checks) and
  [regression anchors](references/regression-anchors.md).
- Preserve native coverage, exact-before-completion behavior, custom phrase priority, display-to-native
  selection mapping, paging and edits, the Chinese dictionary and `pinyin_simp.userdb`, secure or unreadable
  client fail-closed behavior and offline input.
