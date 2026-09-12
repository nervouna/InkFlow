# Paced ASR and overlapping correction experiment

Date: 2026-09-12. Scope: automated assessment only; no input-method integration,
GUI changes, installation, commits, or microphone acceptance.

## Setup

Same `say -v Tingting -r 170` full-passage audio as
`VOICE_LLM_LATENCY_EXPERIMENT.md`, duration 41.952 s. Replay 100 ms chunks at
absolute audio-clock deadlines into Apple SpeechTranscriber zh_CN with
volatile + fast results. Each run warms the installed qwen3.5:4b-mlx model using
a short unrelated fixture before audio starts. Correction uses localhost Ollama,
think false, stream false, temperature 0, num_predict 2048, keep_alive 5m.

Run whole then segmented, repeated three times sequentially. Whole waits for
ASR completion, then corrects the concatenated transcript once. Segmented queues
every nonempty isFinal result immediately, one LLM request at a time, without
merging or artificial sentence splitting. Only the preceding raw ASR segment
is attached as read-only context. The added system instruction is:

> 用户消息包含只读前文和当前片段。前文只供理解，不输出、不改写前文，只输出当前片段的修正文。

The user message labels are `只读前文：` and `当前片段：`. First segment uses
the unchanged correction prompt without context. There is no second whole-text
pass or automatic duplicate removal. All final outputs are concatenated in order.
HTTP/model failure would fall back to the segment original and be marked false;
no such transport/completion failures occurred. This flag does NOT certify quality.

## Timing results

Seconds from final audio-buffer delivery to all correction jobs returned:

| Round | Whole | Segmented | Difference |
|---|---:|---:|---:|
| 1 | 6.133 | 4.827 | 1.306 |
| 2 | 5.066 | 3.190 | 1.877 |
| 3 | 5.106 | 3.312 | 1.794 |
| Median | 5.106 | 3.312 | 1.794 |

The median return delay decreased by approximately 35%, but the segmented output
failed quality acceptance. These are return latencies, NOT time to usable text.
The current whole baseline is slower than earlier cached file-fed tests; compare
within this six-run experiment, not across sessions. This run does not establish
the reason for the different generation speed. Warmup does not imply a cold
prompt cache, and execution order is not fully counterbalanced.

All six runs produced identical raw ASR text and three final segments of 103,
73 and 11 Swift Characters. Confirmation times were approximately 21.3 s,
39.6 s and 42.0 s. Audio delivery stopped near 41.95 s. Thus the second segment
had only about 2.4 s of overlap before speech ended. All segmented runs still
had that segment active at stop; the last segment was not yet confirmed.

Segmented ASR finalization was 0.096–0.100 s; whole 0.104–0.108 s. Maximum audio
feed lag was 0.010–0.016 s across runs. No ASR text degradation or tail-latency
regression was observed in this fixture; this is not proof for other speech or
machine loads. Final-segment queue waits were 3.657, 2.643 and 2.749 s.

## Quality failure

In all three segmented runs, the second model response repeated the entire
read-only preceding segment before correcting the current segment. Concatenation
therefore duplicated the beginning of the passage. Second responses generated
106 tokens; total segmented output was 174 tokens (60 + 106 + 8), versus 111
for the whole route. The extra generation contributed to the backlog.

The raw second segment began with the equivalent of “他帮我找到一个表格…”, but
its correction began with “前几日在 Internettime 上找到一本想看的书…”. The model
copied the labeled context despite the explicit instruction. English recognition
is excluded from acceptance per user direction; repetition is independently a
blocking defect. Segment punctuation also ends “收到人工审核通过的邮件。” before
the tail “登录一看，确实可以读书了。”, so boundaries need quality review even after
context repetition is fixed.

## Conclusion and next bounded experiment

Overlapping final-segment correction is technically operational and reduces return
latency here, but this exact design is not usable. No success claim for polished
text or subsecond end-to-end completion is warranted.

A useful next ablation would omit preceding context and repeat the segmented
route, holding audio/model/queue/boundaries constant. That separates the cost and
quality effect of context from overlapping execution. It is a proposed follow-up,
not performed in this experiment. Do not hide the defect with unverified string
trimming. ASR final confirmation timing remains an independent latency limit.

## Reproduction and retention

Build `experiments/voice-lexicon/Segmented.swift` with `OllamaCorrection.swift`
using Swift 6, warnings as errors, optimized, and an ignored module cache. Run:

```
build/voice-latency/segmented build/voice-latency/full.aiff whole
build/voice-latency/segmented build/voice-latency/full.aiff segmented
```

Raw results: ignored `build/voice-latency/overlap-{1,2,3}-{whole,segmented}.json`.
They contain only the user-authorized synthetic fixture. Keep generated artifacts
and temporary probe sources during investigation, remove after acceptance; retain
this report. No live microphone audio or private user dictionary was accessed.

## Follow-up: omit previous context

User authorized this ablation after reviewing the preceding results. Three
additional `no-context` runs use the same audio, pacing, model, serial queue,
ASR boundaries, and base correction prompt. Only the preceding-context payload
and its associated framing instruction are removed. The existing whole/context
runs are retained as earlier references, not rerun as interleaved controls.

| Round | Post-speech return delay | ASR tail | Confirmed jobs unfinished at stop |
|---|---:|---:|---:|
| 1 | 0.804 s | 0.096 s | 1 |
| 2 | 0.534 s | 0.105 s | 0 |
| 3 | 0.534 s | 0.099 s | 0 |

Median post-speech delay: 0.534 s. All three outputs were identical, with no
observed repetition of preceding segments. All requests completed successfully,
all ASR transcripts matched the earlier six runs, and maximum feed lag remained
0.010–0.011 s. Output token counts were 60 + 45 + 8 = 113, compared with 174
for the context route. The second segment no longer repeated the first segment.

First-segment request duration was 2.75–2.84 s and completed around 24 s of
recording. Second segment took 2.15–2.46 s, completing around 41.74–42.06 s.
Tail request took 0.49–0.70 s, with at most 0.061 s queue wait. Thus most
correction work completed before the audio ended; this does not mean full-text
LLM generation itself became subsecond.

Identical corrected output across the three runs:

> 前几日在 Internet 上找到一本想看的书，结果发现读不了。提示说“只能视障人士才能阅读”。问了一下 Grok，原来是最近查得严，网站为了规避法律风险不得以而为之，又让 Grok 去 Reddit 搜搜解决办法。他帮我找到一个表格，说如果我有视力障碍就去填个申请碰碰运气。想到我最近的确看手机久了就会眼花，应该算是视力障碍的一种，就填了申请。今天收到人工审核通过的邮件。登录一看，确实可以读书了。

Quality limits remain: `不得以` is still uncorrected; the final sentence boundary
is abrupt and `的确` becomes `确实`. English recognition remains excluded per
user direction. This ablation removes the observed duplication defect, but does
not establish cross-segment semantic quality for arbitrary speech.

Cache caveat: these are repeated, warm-model fixtures. First-segment prompt
processing was nearly zero, demonstrating substantial cache reuse. Tail input
processing decreased from 0.267 s in round 1 to approximately 0.066 s in later
rounds. Do not promise the 0.534 s median for novel speech. The explicit removal
of duplicated output and reduction from 106 to 45 second-segment output tokens
supports the mechanism independently of the absolute cache-sensitive latency.

Reproduction: `build/voice-latency/segmented build/voice-latency/full.aiff no-context`.
Raw results: `build/voice-latency/no-context-{1,2,3}.json`, under the same ignored
artifact retention policy. No GUI or production behavior was changed. Next useful
acceptance is live, novel speech with this no-context segmented route; not run here.

## Human microphone acceptance and cleanup

The separate no-context segmented microphone app was opened with fast ASR as
default. It corrected finalized segments serially while capture continued and
showed stop-to-completion timing. The user personally tested it and reported
“值得庆祝，效果拔群啊兄弟”. This confirms positive live experience for the
prototype. No exact human latency was supplied; no IMK insertion/focus/shortcut
acceptance is implied. The user then requested recording results, deleting
experiment artifacts, and handing off formal development to a new conversation.
The temporary sources, apps, audio, raw result files, caches and isolated userdb
were removed. Maintained conclusions and pending work are in
`VOICE_INPUT_HANDOFF.md`; historical reproduction paths below/above are archival.
