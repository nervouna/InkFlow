---
name: inkflow-mixed-input-maintenance
description: Maintain InkFlow's Chinese-first mixed input, static English admission, personal English learning and ranking, and verified voice ASR correction learning. Use for related bad cases or policy changes, not unrelated voice UI, AI-polish, or input-method UI work.
---

# InkFlow mixed-input maintenance

InkFlow is a Chinese input method with a soft Chinese-first prior. Native Rime coverage is the hard boundary: language, context, and learning never promote a partial candidate over a complete one. For equivalent coverage, exactness, verified personal learning, and bounded technical context may place English at or above Chinese. Keep the public English dictionary, personal English dictionary, and voice-only ASR aliases as separate policy domains.

## Workflow

1. Start with [the implemented rules and override contract](references/rules.md) and the source that owns the suspected layer. Open a topic file only when the case touches it: [ranking leads](references/ranking-leads.md) for which candidate leads at equal coverage (rule 14), [forgetting](references/forgetting.md) for Shift+Backspace (rule 18), [keys](references/keys.md) for what each key does while composing. Code and configuration are authoritative; update the reference whenever implemented behavior changes.
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
   - equivalent-span ordering belongs in candidate metadata (`inkflow_input_coverage.lua`) and the Rust final ranker (`Core/Portable/src/ranking.rs`);
   - measurement remains observational and content-free.
   Do not use a static override to imitate personal learning, expose voice aliases to keyboard input, loosen the public gate for one user's correction, or add another persistent store without a separately accepted design change.
6. Verify the changed layer and its failure paths. Preserve the Chinese dictionary and `pinyin_simp.userdb`, native coverage, exact-before-completion behavior, custom phrase priority, display-to-native selection mapping, paging/editing, secure/unreadable-client fail-closed behavior, and offline input. The fixtures a change must keep are in [regression anchors](references/regression-anchors.md).

## Sources

Paths in the reference and commands are relative to the repository root.

| Responsibility | Source |
| --- | --- |
| Shared admission and dictionary generation | [prepare-rime.sh](../../../Core/scripts/prepare-rime.sh) |
| Configurable gate/scaling and exact-word corrections | [english.conf](../../../Core/config/english.conf), [english-overrides.tsv](../../../Core/config/english-overrides.tsv) |
| Spelling sources, frequency provenance, limits, regeneration and hashes | [Data/README.md](../../../Core/Data/README.md), [Data/TECHNOLOGY.md](../../../Core/Data/TECHNOLOGY.md), [snapshot-english-frequency.py](../../../macOS/scripts/snapshot-english-frequency.py) |
| Standalone lookup, canonical Rime learning, the named English and voice-alias user dictionaries, and the Lua side of forgetting | [inkflow_english.lua](../../../schemas/lua/inkflow_english.lua) |
| Public mixed decoding and native personal spans | [inkflow_mixed.lua](../../../schemas/lua/inkflow_mixed.lua), [InkFlowRimeNative.cpp](../../../Core/Sources/InkFlowRimeNative/InkFlowRimeNative.cpp) |
| Exact-English reachability and bounded short conflicts | [inkflow_short_conflict.lua](../../../schemas/lua/inkflow_short_conflict.lua) |
| Candidate metadata sent to the ranker | [inkflow_input_coverage.lua](../../../schemas/lua/inkflow_input_coverage.lua) |
| Equivalent-coverage final ranking and metadata parsing | [ranking.rs](../../../Core/Portable/src/ranking.rs) |
| Sessions, display-to-native order, selection, paging and forgetting; the app reaches them through the `IFEngine` facade | [engine.rs](../../../Core/Portable/src/engine.rs), [Engine.swift](../../../Core/Sources/InkFlowRime/Engine.swift) |
| Bounded preceding-text capture and the context index | [Context.swift](../../../macOS/Sources/Context.swift), [InputRankingContext.swift](../../../macOS/Sources/InputRankingContext.swift), [CandidateRanking.swift](../../../Core/Sources/InkFlowDomain/CandidateRanking.swift) |
| App side of learning: reset, voice-correction write, alias snapshot, Settings list/delete/restore | [EngineAI.swift](../../../Core/Sources/InkFlowRime/EngineAI.swift), [EnginePersonalLearning.swift](../../../Core/Sources/InkFlowRime/EnginePersonalLearning.swift), [PersonalLearningSettings.swift](../../../macOS/Sources/PersonalLearningSettings.swift) |
| Bridge to the ordinary Pinyin user dictionary: AI-adoption learning and readings, voice-lexicon read | [inkflow_ai_learning.lua](../../../schemas/lua/inkflow_ai_learning.lua) |
| Verified voice correction attribution and alias recall | [VoiceLearning.swift](../../../macOS/Sources/VoiceLearning.swift), [InputControllerVoice.swift](../../../macOS/Sources/InputControllerVoice.swift), [VoiceSession.swift](../../../macOS/Sources/VoiceSession.swift), [VoiceLearning.swift (core)](../../../Core/Sources/InkFlowDomain/VoiceLearning.swift), [VoiceLearningCoordinator.swift](../../../Core/Sources/InkFlowDomain/VoiceLearningCoordinator.swift) |
| Content-free effectiveness events | [QualityRecords.swift](../../../Core/Sources/InkFlowRime/QualityRecords.swift), [QualityStore.swift](../../../Core/Sources/InkFlowRime/QualityStore.swift) |
| Translator composition and compilation dependencies | [inkflow_pinyin.schema.yaml](../../../schemas/inkflow_pinyin.schema.yaml), [easy_en.schema.yaml](../../../schemas/easy_en.schema.yaml), [inkflow_mixed.schema.yaml](../../../schemas/inkflow_mixed.schema.yaml) |
| Pinned engine behavior and deployment pitfalls | [DEPENDENCIES.md](../../../macOS/DEPENDENCIES.md), [DEBUGGING.md](../../../macOS/DEBUGGING.md) |

## Verification

Run `bash macOS/scripts/test.sh quick` plus the units for the changed layer:

| Layer | Where to add or adjust cases |
| --- | --- |
| Static admission, generation | [test-prepare-rime.sh](../../../Core/scripts/test-prepare-rime.sh) (`preparation`), candidate behavior in [EngineRegression.swift](../../../Core/Tests/InkFlowEngineTestSupport/EngineRegression.swift) (`engine-english`); include prefixes and backspaces, not only completed sentences |
| Canonical or mixed personal learning | [test-ai-learning.sh](../../../macOS/scripts/test-ai-learning.sh) (`ai-learning`) |
| Equivalent-span ranking and leads | `EngineRegression.swift` through `engine-context` and `engine-basic`; Rust ranker and metadata parsing in [ranking.rs tests](../../../Core/Portable/tests/ranking.rs) (`portable`); keep page identity and native-span fail-closed behavior |
| Voice learning | `voice-session`, `apple-voice`, `voice-lexicon`, `voice-controller`, `ai-learning`, `settings`, `quality` |
| Dictionary deployment | [DeploymentTests.swift](../../../macOS/Tests/DeploymentTests.swift) (`deployment`): stale English caches replaced, unchanged tables reused, Chinese user data kept |
| Measurement | `quality`; inspect evidence with [inkflow-quality-analysis](../inkflow-quality-analysis/SKILL.md) |

Rime startup ([bridge.cpp](../../../Core/Portable/native/bridge.cpp)) uses `start_maintenance(1)` for content checks; don't rely on version/mtime changes or delete caches and user dictionaries.
