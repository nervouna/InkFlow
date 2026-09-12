# Voice and learned-dictionary experiments — 2026-09-12

> Archived 2026-09-12: temporary experiment sources and generated artifacts were
> removed at the user's request. Commands and paths are historical evidence.
> See `VOICE_INPUT_HANDOFF.md` for current decisions and development scope.

## Requirement and scope

The user now requires voice input to use InkFlow's learned vocabulary at minimum;
an isolated ASR frontend is insufficient. Bidirectional benefit is the desired
outcome. These experiments assess feasibility, not production implementation.

M1 Pro / 32 GiB / macOS 26.6.2. Seven fixed synthetic Mandarin utterances were
generated with `say -v Tingting -r 170`. Apple `SpeechTranscriber` used `zh_CN`,
`.fastResults` and `.alternativeTranscriptions`. File input was processed as fast
as possible: these are candidate/learning experiments, not streaming latency
benchmarks or human recognition accuracy measurements. No paid LLM calls.

The real Rime 1.17.0 runtime and prebuilt InkFlow resources came from the existing
`release-flow-ablation/build` artifacts. They were read as dependencies; no build,
deployment or maintenance was run against that checkout. The learning Lua file's
SHA-256 matched this branch: `d3709ae2e1ffb1ae85d6392a098e5ea4b7c9d49c35ef52e703c0858f203520ff`.
Every write went to a new isolated `build/voice-lexicon/user/pinyin_simp.userdb`.
The actual user's learned database was neither read nor changed.

## Round 1: genuine learned state changes voice selection

The existing Lua `Memory.update_userdict` bridge learned three controlled entries:
`墨流 / mo liu / 1`, `星墨蓝 / xing mo lan / 1`, `张玮 / zhang wei / 1`.
Separate Rime processes then recalled each as its first Pinyin candidate. The
native `rime_dict_manager` exported those entries and counts. The voice scorer
read that export directly, rather than an independently hardcoded glossary.

Apple emits alternatives for small audio ranges. For `请联系张玮确认时间`, its
primary concatenation was `请联系张伟确认时间`; the `伟` segment offered `伟/玮/炜`.
Scoring each range independently would miss the learned phrase `张玮`. A bounded
cross-segment combination (maximum 128 paths) allowed matching whole learned words.

The experimental selector permits only alternatives with the same normalized
Latin transcription as the Apple primary segment. It scores exact learned-word
occurrences with capped learning counts and preserves Apple order on ties. This
simple score demonstrates a data path; it is not a calibrated acoustic/language
probability model and is not ready to ship.

| Fixed synthetic utterance / intended term | Apple primary | With learned-candidate selection | Observation |
| --- | --- | --- | --- |
| 请打开墨流输入法。 | 请打开墨流输入法 | unchanged | Already correct; not counted as an improvement |
| 请把星墨蓝加入项目列表。 | 请把新莫兰加入项目列表 | unchanged | No 蓝 in alternatives; conservative xing/xin filtering also limits recovery |
| 请联系张玮确认时间。 | 请联系张伟确认时间 | 请联系张玮确认时间 | Learned preference changes selected spelling |
| 今天下午三点开会。 | 今天下午 3:00开会。 | unchanged | Ordinary control preserved |
| 他叫张伟，伟大的伟。 | 他叫张伟伟大的伟 | unchanged | Strict candidate selection preserves this explicit-spelling counterexample |
| 请检查末流的污染情况。 | 请检查墨流的污染情况 | unchanged | ASR already picked the learned homophone incorrectly; preference cannot establish meaning |
| 请记住星墨海这个项目。 | 请记住星木海这个项目 | unchanged | Unlearned novel-term probe; 木/慕/目/沐 alternatives did not include 墨 |

An empty learned export kept `张伟`. With the three-entry export, exactly the same
stored Apple output selected `张玮`. That isolates learned-state influence from
ASR nondeterminism. A single short-file scorer invocation took about 0.06 s
including process launch and file parsing; do not extrapolate to a large live db.

## Round 2: missing-candidate phonetic replacement fails a negative control

A separate experimental baseline tried same-length, all-Han homophone replacement
using learned canonical codes. It protects already-known spellings, chooses only
a unique highest-count match, and does not cascade replacements.

It nevertheless changed `他叫张伟伟大的伟` into `他叫张玮伟大的伟`. It also did
not recover `星墨蓝` from `新莫兰` or `星墨海` from `星木海`, whose pronunciations
are not exact matches. Relaxing phonetic distance without another source of
evidence would broaden this false-replacement risk.

Decision: **reject unconditional homophone substitution**. Correct terms missing
from Apple's alternatives remain an unresolved coverage problem, potentially
requiring explicit user correction or independently validated contextual handling.

During prototype checking, a regression also exposed repeated substitutions of an
already-known learned spelling. A failing self-test was added, the prototype was
changed to single-pass matching, and preservation/control tests passed. The
semantic negative-control failure above remains after that implementation fix;
it is not manufactured by the prototype bug.

## Round 3: contextualStrings did not alter SpeechTranscriber results here

The three exported learned terms were supplied through
`AnalysisContext.contextualStrings[.general]`. For the exact same `墨流`, `星墨蓝`
and `张玮` audio files, both primary results and alternatives matched the no-context
runs after canonical JSON comparison.

This is a three-sample observation, not proof that a parameter is always ignored.
Apple's documented custom-vocabulary support names `DictationTranscriber`, not
the currently selected `SpeechTranscriber`. Do not promise direct vocabulary
injection or model training from this API.

## Round 4: simulated confirmed speech choice feeds back into both paths

The `张伟/张玮/张炜` Apple alternatives were used as a controlled confirmation
fixture. The harness simulated explicitly choosing `张炜` on three separate
occasions, supplying its known canonical code `zhang wei` through the existing
learning bridge. This was not inferred consent from automatic insertion.

Native export then contained `张炜 / zhang wei / 3` and `张玮 / zhang wei / 1`.
A fresh Rime process returned `张炜` before `张玮` and `张伟`. Reusing the **same**
Apple transcript/alternatives with that updated export selected
`请联系张炜确认时间`. No new ASR inference was needed to demonstrate this change.

Thus the data path works: confirmed speech choice -> existing userdb -> ordinary
Pinyin preference and subsequent voice candidate selection. Unsolved parts are
automatic trustworthy term extraction, polyphone disambiguation without typed
Pinyin, correction capture in a real client, and safe handling of incidental text.
The novel `星墨海` probe was not automatically learned to make the experiment pass.

## Verification and proposed development decision

Swift 6 optimized compilation with warnings as errors passed. The Rime probe
compiled and exercised the existing writer and restart lookup. Assertions verified
empty-lexicon behavior, learned reranking, the negative-control failure, and the
updated preference's feedback. No production files, live userdb, IME registration
or installed app were changed. No production-wide tests were needed for isolated
probes. Real-user corpus coverage, scale, latency, focus, automatic learning and
overall quality gains remain unverified.

Proceed with a **learned-vocabulary-aware voice path**, not a standalone ASR path:

1. Read bounded, versioned views of the existing userdb outside key callbacks;
   share the learned source rather than creating a second independent dictionary.
2. Combine nearby ASR alternatives so learned multi-character words can influence
   selection. Preserve the model's primary result when dictionary evidence is weak.
3. Base new-word learning on explicit confirmation/correction with a resolved
   pronunciation. Automatic insertion or LLM output is not sufficient evidence.
4. Keep unconditional phonetic replacement disabled. Test candidate coverage on
   human speech before choosing more complex correction or another ASR backend.

This establishes a working controlled example of the user's minimum requirement,
not a claim that arbitrary learned vocabulary will be recognized correctly.

## Reproduction and retention

`experiments/voice-lexicon/` contains the small probes and a reproduction recipe.
All synthetic audio, JSON, exports, compiled binaries and isolated dbs are under
ignored `build/voice-lexicon/`. They are disposable after review; preserve this
document. Do not export the user's actual database for test logs, and do not
delete the shared dependency checkout, Apple assets or OS crash reports.

Sources: [Apple alternatives](https://developer.apple.com/documentation/speech/speechtranscriber/result/alternatives),
[contextual strings](https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings),
repository `schemas/lua/inkflow_ai_learning.lua` and `macOS/Sources/AIPronunciation.swift`.
