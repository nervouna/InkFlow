---
name: inkflow-mixed-input-maintenance
description: Maintain InkFlow's Chinese-first mixed input, static English admission, personal English learning and ranking, and verified voice ASR correction learning. Use for related bad cases or policy changes, not unrelated voice UI, AI-polish, or input-method UI work.
---

# InkFlow mixed-input maintenance

InkFlow is a Chinese input method with a soft Chinese-first prior. Native Rime coverage is the hard boundary: language, context, and learning never promote a partial candidate over a complete one. For equivalent coverage, exactness, verified personal learning, and bounded technical context may place English at or above Chinese. Keep the public English dictionary, personal English dictionary, and voice-only ASR aliases as separate policy domains.

## Workflow

1. Read [the implemented rules and override contract](references/rules.md) plus the source that owns the suspected layer. Code and configuration are authoritative; update the reference whenever implemented behavior changes.
2. Classify the case before changing policy:
   - public spelling, frequency evidence, or admission;
   - standalone English lookup or selection learning;
   - exact personal English inside mixed composition;
   - equivalent-coverage Chinese/English ranking;
   - verified post-ASR correction or voice-alias recall;
   - quality measurement, reset, packaging, or installed-runtime delivery.
3. Capture evidence appropriate to that layer. For keyboard input, record raw keystrokes, displayed spelling/case, preceding context, candidate pages, selection method, edit position, and restart state. For voice learning, distinguish raw final ASR, inserted text, the later user edit, immediate undo, client/session continuity, and subsequent reuse. Never add user text to logs or durable diagnostics.
4. Trace the owner instead of treating every miss as a frequency problem. Search all relevant pages and distinguish absent source code, public-gate rejection, missing personal record, mixed-boundary rejection, incomplete/stale metadata, failed attribution, alias ambiguity, and stale compiled or installed resources.
5. Make the smallest owner-correct change:
   - public word policy belongs in the source data, exact override table, or shared build-time gate;
   - canonical personal words belong in `inkflow_shared_english.userdb` through verified Rime learning;
   - ASR wrong-token to correct-token mappings belong only in `inkflow_voice_alias.userdb`;
   - equivalent-span ordering belongs in candidate metadata and the Swift final ranker;
   - measurement remains observational and content-free.
   Do not use a static override to imitate personal learning, expose voice aliases to keyboard input, loosen the public gate for one user's correction, or add another persistent store without a separately accepted design change.
6. Verify the changed layer and its failure paths. Preserve the Chinese dictionary and `pinyin_simp.userdb`, native coverage, exact-before-completion behavior, custom phrase priority, display-to-native selection mapping, paging/editing, secure/unreadable-client fail-closed behavior, and offline input.

## Sources

Paths in the reference and commands are relative to the repository root.

| Responsibility | Source |
| --- | --- |
| Shared admission and dictionary generation | [prepare-rime.sh](../../../Core/scripts/prepare-rime.sh) |
| Configurable gate/scaling and exact-word corrections | [english.conf](../../../Core/config/english.conf), [english-overrides.tsv](../../../Core/config/english-overrides.tsv) |
| Frequency provenance, limits, regeneration and hashes | [Data/README.md](../../../Core/Data/README.md), [snapshot-english-frequency.py](../../../macOS/scripts/snapshot-english-frequency.py) |
| Standalone lookup and canonical Rime learning | [inkflow_english.lua](../../../schemas/lua/inkflow_english.lua) |
| Public mixed decoding and native personal spans | [inkflow_mixed.lua](../../../schemas/lua/inkflow_mixed.lua), [InkFlowRimeNative.cpp](../../../Core/Sources/InkFlowRimeNative/InkFlowRimeNative.cpp) |
| Exact-English reachability and bounded short conflicts | [inkflow_short_conflict.lua](../../../schemas/lua/inkflow_short_conflict.lua) |
| Candidate metadata and equivalent-coverage final ranking | [inkflow_input_coverage.lua](../../../schemas/lua/inkflow_input_coverage.lua), [Context.swift](../../../macOS/Sources/Context.swift), [Engine.swift](../../../Core/Sources/InkFlowRime/Engine.swift), [InputRankingContext.swift](../../../macOS/Sources/InputRankingContext.swift) |
| Native learning bridge and named user dictionaries | [inkflow_ai_learning.lua](../../../schemas/lua/inkflow_ai_learning.lua), [EngineAI.swift](../../../Core/Sources/InkFlowRime/EngineAI.swift) |
| Verified voice correction attribution and alias recall | [VoiceLearning.swift](../../../macOS/Sources/VoiceLearning.swift), [InputControllerVoice.swift](../../../macOS/Sources/InputControllerVoice.swift), [VoiceSession.swift](../../../macOS/Sources/VoiceSession.swift) |
| Content-free effectiveness events and reset lifecycle | [QualityRecords.swift](../../../Core/Sources/InkFlowRime/QualityRecords.swift), [QualityStore.swift](../../../Core/Sources/InkFlowRime/QualityStore.swift), [DictionarySettings.swift](../../../macOS/Sources/DictionarySettings.swift) |
| Translator composition and compilation dependencies | [inkflow_pinyin.schema.yaml](../../../schemas/inkflow_pinyin.schema.yaml), [easy_en.schema.yaml](../../../schemas/easy_en.schema.yaml), [inkflow_mixed.schema.yaml](../../../schemas/inkflow_mixed.schema.yaml) |
| Pinned engine behavior and deployment pitfalls | [DEPENDENCIES.md](../../../macOS/DEPENDENCIES.md), [DEBUGGING.md](../../../macOS/DEBUGGING.md) |

## Verification

Run `bash macOS/scripts/test.sh quick` plus the units for the changed layer:

| Layer | Where to add or adjust cases |
| --- | --- |
| Static admission, generation | [test-prepare-rime.sh](../../../Core/scripts/test-prepare-rime.sh), candidate behavior in [EngineTests.swift](../../../macOS/Tests/EngineTests.swift); include prefixes and backspaces, not only completed sentences |
| Canonical or mixed personal learning | [test-ai-learning.sh](../../../macOS/scripts/test-ai-learning.sh) |
| Equivalent-span ranking | Engine tests; keep page identity and native-span fail-closed behavior |
| Voice learning | `voice-session`, `apple-voice`, `voice-lexicon`, `voice-controller`, `ai-learning`, `settings`, `quality` |
| Dictionary deployment | [DeploymentTests.swift](../../../macOS/Tests/DeploymentTests.swift): stale English caches replaced, unchanged tables reused, Chinese user data kept |
| Measurement | `quality`; inspect evidence with [inkflow-quality-analysis](../inkflow-quality-analysis/SKILL.md) |

Rime startup uses `start_maintenance(1)` for content checks; don't rely on version/mtime changes or delete caches and user dictionaries.
