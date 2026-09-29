# Apple speech punctuation experiment — 2026-09-12

> Archived 2026-09-12: temporary experiment sources and generated artifacts were
> removed at the user's request. Commands and paths are historical evidence.
> See `VOICE_INPUT_HANDOFF.md` for current decisions and development scope.

## Question and method

The user observed mostly periods and few/no commas in long microphone transcripts.
This follow-up tests whether commas are supported, whether low-latency reporting
changes punctuation, and whether pauses or spoken punctuation reliably help.

Same M1 Pro / 32 GiB / macOS 26.6.2; `SpeechTranscriber` with `zh_CN`. Fixed
synthetic audio from `say -v Tingting -r 170`. Only audio was provided to ASR;
the TTS source text and its punctuation were not supplied as ASR hints.
No LLM or dictionary postprocessing. Counts and text come directly from finalized
`result.text`, concatenated without trimming or punctuation rewriting.

Modes: all enable `.volatileResults`; fast also enables `.fastResults`.
For the first three samples, each mode was also repeated with
`.alternativeTranscriptions`. Natural speech was additionally streamed in 100 ms
real-time-paced chunks in both modes, using explicit end-of-input finalization.
The long sample used file input. Total: 16 runs, one observation per configuration.

## Fixed samples

- Natural, 8.876 s: `如果明天下雨，我们就留在家里，看书、喝茶，等雨停了再出门。你觉得这样安排可以吗？`
- Explicit pauses, 9.398 s: same words, replacing written punctuation with
  `[[slnc 350]]` after 下雨/家里/喝茶, 200 ms after 看书, and 700 ms after 出门.
- Spoken punctuation, 6.960 s: `如果明天下雨，逗号，我们就留在家里，句号，你觉得可以吗，问号。`
- Long, 28.635 s: `今天上午我们先检查了项目的进度，发现设置页面还有两个问题，所以决定暂缓发布。吃过午饭以后，小王负责修复界面，小李负责补充测试，我来整理用户反馈。如果这些工作能在下午完成，我们明天就安排一次内部试用；如果来不及，就把演示推迟到下周。你觉得这个计划合理吗？`

## Final primary punctuation counts

| Sample | Mode | Commas | Periods | Question marks |
| --- | --- | ---: | ---: | ---: |
| Natural | Standard | 2 | 0 | 1 |
| Natural | Fast | 2 | 0 | 0 |
| Explicit pauses | Standard | 2 | 0 | 1 |
| Explicit pauses | Fast | 2 | 0 | 0 |
| Spoken punctuation | Standard | 1 | 1 | 1 |
| Spoken punctuation | Fast | 1 | 1 | 1 |
| Natural, real-time pacing | Standard | 2 | 0 | 1 |
| Natural, real-time pacing | Fast | 2 | 0 | 0 |
| Long | Standard | 3 | 1 | 1 |
| Long | Fast | 2 | 0 | 0 |

Enabling alternatives did not change primary text or these counts for any of the
six paired natural/pauses/spoken mode cases. Real-time-paced natural text exactly
matched file-mode natural text in each configuration. JSON assertions checked
these equalities and nonzero comma counts.

Natural fast output:

> 如果明天下雨 ，我们就留在家里看书喝茶等雨停了再出门 ，你觉得这样安排可以吗

Standard added ` ？` at the end, but neither supplied all desired internal sentence
boundaries. The added explicit pauses produced the same text as natural TTS in
each mode; longer pauses cannot be assumed to force comma placement.

Spoken-punctuation standard output:

> 如果明天下雨 ，我们就留在家里句号你觉得可以吗 ？问号。

Fast left `号` instead of `句号`. Some punctuation words were transcribed literally;
speaking punctuation names is not a reliable command mechanism on this tested path.

Long fast output contained two commas near the beginning and no final question
mark. Long standard had more marks, but inserted a period inside `修复`, producing
`小王负责修。复见面`. More punctuation was not necessarily better punctuation.

## Conclusions and limits

1. **Apple can emit Chinese commas**, including in the actual fast/volatile
   configuration under real-time pacing. Do not describe it as comma-incapable.
2. Chinese paragraph punctuation is sparse/inconsistent in these samples. Fast
   reporting dropped the final question mark in the natural and long cases;
   standard reporting did not solve all punctuation and introduced an incorrect
   internal period in the long case.
3. Alternatives, artificial pauses and spoken punctuation did not provide a
   reliable punctuation repair. No dedicated punctuation switch is exposed in
   the checked SpeechTranscriber transcription options; its only documented
   transcription option is etiquette replacement.
4. The user microphone observations remain valid, but these synthetic tests do
   not isolate their exact cause. Voice prosody, text and reporting mode differ;
   neither a universal failure rate nor a general quality ranking follows.

Keep the low-latency path for continued development evaluation. Do not switch the
entire live pipeline to standard reporting merely to obtain punctuation. With
polishing off, preserve available ASR punctuation and accept this known limitation
unless a separate local punctuation solution is validated. With polishing on,
include punctuation/readability in BYOK acceptance. A second ASR pass is not yet
justified by these results and has not been added to the plan.

## Artifacts and verification

Temporary source: `experiments/voice-lexicon/Punctuation.swift`.
Build with Swift 6, warnings as errors, optimized; compilation passed.
Invocation: `probe AUDIO.aiff zh_CN standard|fast|standard-alternatives|fast-alternatives
[--paced]`. Synthetic audio and raw JSON live under ignored
`build/voice-punctuation/` and are disposable after review. Shared compiler cache
remains in the prior experiment's `build/voice-lexicon/modules/`.
No microphone recording, live userdb changes, production code changes, installation
or broad production regression tests were performed.

References: [TranscriptionOption](https://developer.apple.com/documentation/speech/speechtranscriber/transcriptionoption),
[fastResults](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/fastresults).
Apple documents fast results as a smaller-context tradeoff favoring responsiveness.
