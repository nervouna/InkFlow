# Local voice correction latency experiment

> Archived 2026-09-12: temporary experiment sources and generated artifacts were
> removed at the user's request. Commands and paths are historical evidence.
> See `VOICE_INPUT_HANDOFF.md` for current decisions and development scope.

Date: 2026-09-12. Scope: automated synthetic audio and local Qwen 3.5 4B
correction; no production implementation or real microphone acceptance.

## Method

- User-supplied Internet Archive / Grok / Reddit passage, reproduced below.
- Three inputs: first sentence, first paragraph, entire passage.
- `say -v Tingting -r 170 -f INPUT.txt -o OUTPUT.aiff`; audio lengths were
  9.827, 17.281, and 41.952 seconds respectively.
- Existing `Punctuation.swift` probe: Apple SpeechTranscriber zh_CN,
  volatile + fast results, file-fed (not paced), final text only. ASR was run
  once per audio. Each corresponding final text was reused for LLM comparisons.
- Only `qwen3.5:4b-mlx` (installed nvfp4 variant), localhost Ollama chat API.
  Same prompt as `OllamaCorrection.swift`; think false, temperature 0,
  num_predict 2048, keep_alive 5m. No dictionary hints or source transcript
  supplied to the LLM.
- One separately recorded warmup, then three rounds per length and transport
  mode (18 measured requests). Round 2 reverses length and mode order.
  Calls are sequential. No forced unload or server configuration changes.
- Client wall clock includes request/response transport and parsing. Streaming
  first-visible time means receipt of the first nonempty content chunk, not a
  rendered screen frame. Nonstreaming first-visible time is full response time.
- Repeated inputs benefit from prompt caching. This is not a fully balanced
  cache-controlled benchmark, nor a measurement of concurrent ASR/LLM execution.

## Results

Medians of three requests per cell; durations in seconds. Character counts are
Swift Character counts of ASR text, including English letters and spaces.

| ASR input | Characters | Output tokens (nonstream median) | Nonstream full | Stream first content | Stream full |
|---|---:|---:|---:|---:|---:|
| First sentence | 51 | 27 | 0.740 | 0.064 | 0.746 |
| First paragraph | 82 | 47 | 1.301 | 0.099 | 1.294 |
| Full passage | 187 | 111 | 2.937 | 0.105 | 2.952 |

Full passage nonstream total range: 2.918–3.288 s. Streaming total range:
2.919–2.955 s. Median full-passage nonstream loading was 0.027 s, input
processing 0.040 s, output generation 2.850 s. Output generation dominated
these repeat requests. Component medians need not sum to the wall median.

Cache caveat: full-passage streaming requests reported 213 cached input tokens
out of 217. First full-passage nonstream request reported only 115 cached tokens,
input processing 0.399 s and total 3.288 s. Consequently the 0.105 s first-content
median must not be promised for novel speech. Warmup took 2.819 s including
1.528 s loading and 0.903 s input processing; it is excluded from the table.

## Quality observations

Full ASR output had zero commas, periods, or question marks. It contained
`Internetrtime`, `grock`, `redit`, `视立障碍`, and `不得以`.
The full-passage corrected output was identical in all six requests:

> 前几日在 Internet 上找到一本想看的书，结果发现读不了，提示只能视障人士才能阅读。问了一下 Grok，原来是最近查得严，网站为了规避法律风险不得以而为之，又让 Grok 去 Reddit 搜搜解决办法。他帮我找到一个表格，说如果我有视力障碍就去填个申请碰碰运气。想到我最近的确看手机久了就会眼花，应该算是视力障碍的一种，就填了申请。今天收到人工审核通过的邮件，登录一看，的确可以读书了。

Punctuation and several names improved. However, Archive was omitted,
`不得以` remained uncorrected, and the first/second paragraph boundary was
joined with a comma. The short input restored Internet Archive but the paragraph
and full inputs did not; this does not establish a general length/quality rule.
Short-output variants occurred even with temperature 0, so deterministic output
must not be assumed.

## Implications and boundaries

Text/output length materially affected these measurements. Streaming provided
much earlier content but did not reduce full-output time. For the agreed final
commit-after-polish flow, streaming could update a preview/marked text while
waiting; this experiment did not implement that UI. Reducing post-speech full
completion time likely requires reducing generation or overlapping correction
with speech, which remains untested. Prompt shortening and concurrent sentence
correction were not tested. Cold-load and cache effects are distinct.

Reproduce: build `Latency.swift` and `OllamaCorrection.swift` together with
Swift 6, warnings as errors, optimized. Run `latency build/voice-latency` after
creating `{short,paragraph,full}.asr.json` with the existing Speech probe.
Generated fixture text, audio, binaries and raw JSONL are ignored under
`build/voice-latency/`; retain during the investigation, remove after acceptance.
Keep this report. No private microphone recordings or transcripts were saved.
Official protocol reference: https://docs.ollama.com/api/chat and
https://docs.ollama.com/api/streaming.

## Source fixture

前几日，在 Internet Archive 上找到一本想看的书，结果发现读不了，提示只能视力障碍人士才能阅读。问了一下 Grok，原来是最近查的严，网站为了规避法律风险，不得已而为之。
又让 Grok 去 Reddit 搜搜解决办法，它帮我找到一个表格，说如果我有视力障碍，就去填个申请碰碰运气。想到我最近的确看手机久了就会眼花，应该算是视力障碍的一种，就填了申请。
今天收到人工审核通过的邮件，登录一看，的确可以读书了。
