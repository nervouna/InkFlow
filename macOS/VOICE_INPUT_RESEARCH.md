# Apple ASR experiment: 2026-09-12

> Archived 2026-09-12: temporary experiment sources and generated artifacts were
> removed at the user's request. Commands and paths are historical evidence.
> See `VOICE_INPUT_HANDOFF.md` for current decisions and development scope.

## Environment and method

- M1 Pro, 32 GiB unified memory, macOS 26.6.2; baseline `7aab028`.
- `SpeechTranscriber.isAvailable == true`; `zh_CN` and `zh_TW` assets were
  already installed. No model download requested. Recognition used `zh_CN`.
- `say -v Tingting -r 190`, mono 22,050 Hz AIFF; 100 ms chunks paced at real
  time, converted to the analyzer-compatible format. Temporary experiment sources
  and generated artifacts were removed after recording these results.
- Default: `.volatileResults` + `.fastResults`. The control omits fast results.
- One observation per row, serial runs, shared system model service possibly
  warm. Not cold-start benchmarks, P95 measurements, or human accuracy scores.

## Observations

| Sample | Audio duration | Mode | Prepare | First nonempty result | Finish | Partial / final results |
| --- | ---: | --- | ---: | ---: | ---: | ---: |
| Plain Chinese | 8.389 s | Standard | 211 ms | 8,496 ms | 312 ms | 41 / 1 |
| Mixed Chinese/English | 9.062 s | Standard | 148 ms | 9,150 ms | 222 ms | 41 / 1 |
| Plain Chinese | 8.389 s | Fast | 139 ms | 1,133 ms | 72 ms | 40 / 1 |
| Mixed Chinese/English | 9.062 s | Fast | 117 ms | 1,138 ms | 59 ms | 46 / 1 |
| Numbers/dates | 8.268 s | Fast | 123 ms | 1,125 ms | 57 ms | 33 / 1 |
| Long Chinese | 50.127 s | Fast | 146 ms | 1,123 ms | 147 ms | 217 / 2 |

First-result time starts at audio feeding, including leading silence; finish
starts when the feed is ended. Neither includes IMK insertion. Standard mode
returned results only after these short recordings ended. With the same plain
audio, fast mode returned results during feeding. Apple's documented smaller
context window is consistent with the observed difference; this is not proof
that all workloads or cold starts have these timings.

Accuracy observations from synthetic inputs:

- Plain: `最后一句` became `最后依据` in both modes.
- Fast mixed: `SwiftUI` became `swift youI`, `GitHub` became `Gathop`,
  `pull request` became `plorequest`, `API key` became `APIP`.
  Standard mode also had several English errors. Tingting's English pronunciation
  is a confounder; these rows do not isolate the human ASR error rate.
- Numbers: output included `9月 12日下午 3点半`, `1234元五角`, and `0.3.2`.
  Currency/spacing normalization was incomplete.
- Long: two final segments, the ending `现在这段实验就到这里谢谢大家` survived.
  Punctuation was sparse, and some `再` became `在`. No buffer-overflow failure
  occurred. This does not quantify CPU, memory, or backlog over longer sessions.

## Verification and remaining acceptance

- Transcript assembly test first failed with missing `Transcript`, then passed
  after implementation: volatile replacement, finalization, multiple segments.
- Swift 6 optimized build with warnings as errors passed; shell syntax and
  whitespace checked. Ad-hoc signature integrity verified; no Developer ID,
  notarization, production install, or input-source registration performed.
- Native window launched and its idle layout visually inspected. This is not
  microphone or input-method acceptance. The probe does not start recording
  until the user clicks Start.
- `test-affected.sh --from main` classified the new isolated experiment path as
  unknown and conservatively selected all production tests. That suite was not
  run: no production target, dependency, resource, or build entry changed. The
  standalone test/build and real Speech pipeline are the relevant evidence.
- After the callback fix, the user completed a real microphone trial and judged
  the result usable with minor recognition flaws. In several long utterances,
  punctuation appeared predominantly as periods, with few/no commas. This is an
  observation of this configuration, not proof that Apple cannot emit commas.
- Simultaneous development load, total system memory pressure, 16 GiB systems,
  broader permission/device failure handling, global shortcuts, real
  marked text, focus changes, LLM, and insertion remain unverified.

Decision: proceed to formal development planning with Apple ASR as the first
implementation route. The user considers the real trial promising. The observed
1.1 s first-result time is slightly above the initial one-second aspiration;
it is a baseline, not a guaranteed latency. Minor recognition errors and weak
punctuation remain known limitations. Optional BYOK polishing should improve
punctuation/readability without being treated as reliable ASR error correction.

## Microphone callback correction

The user's first microphone attempt crashed. The 16:56:14 and 16:56:32 crash
reports showed `EXC_BREAKPOINT` / `_dispatch_assert_queue_fail`, with
`Probe.startMicrophone`'s tap closure on `RealtimeMessenger.mServiceQueue`.
The closure was constructed in MainActor code and inherited its isolation;
the audio thread could not invoke it. This was an experiment bug, not evidence
of ASR model failure or insufficient M1 Pro performance.

The tap now comes from a nonisolated `AudioFeed.makeTap()` factory with an
explicit `@Sendable` closure. A regression check invokes that exact callback on
a detached executor, asserts it is off the main queue, and verifies 48 kHz to
16 kHz conversion. This tests the crash boundary without opening the microphone;
the user subsequently reported an acceptable real-device trial. This does not
validate production InputMethodKit focus or insertion behavior.

No microphone recordings or user transcripts are retained. At the user's request,
the disposable `experiments/apple-asr/` sources and ignored `build/apple-asr/`
outputs were removed after preserving this record. Apple's pre-existing shared
language assets, the installed InkFlow app, and OS crash reports are not cleanup
targets.

## Implementation lessons to retain

- Use volatile plus fast results for the initial live path. Apple's documented
  responsiveness/accuracy tradeoff must remain explicit.
- Replace the current volatile segment; append finalized segments once. On stop,
  finish audio input, finalize the analyzer, and await its result sequence before
  polishing or inserting. A partial result is not a final commit.
- Construct the audio callback outside MainActor with an explicit Sendable
  boundary. Test that exact callback on a background queue, not only file input.
- The experiment's 60-second recording and 15-second finalization limits were
  protective prototype choices, not accepted product requirements.
- App-local transcript display does not prove marked-text ownership or cross-app
  insertion. Validate those on the real input-method path during development.

References: [SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/),
[fastResults](https://developer.apple.com/documentation/speech/speechtranscriber/reportingoption/fastresults).
