# Black-box input method benchmark

Types the [quality corpus](../../../Core/Fixtures/QualityBaseline/corpus.json) through any other enabled input method into a plain text view and scores what the view reads back, so InkFlow and other input methods are compared on the same corpus, policy and state ([design, section 7](../../../docs/input-quality-metrics.md)). It runs outside the app, adds nothing to the key-event path, changes no ranking and reads no quality records.

## Run

From a logged-in GUI session, outside the sandbox, from the repository root:

1. Enable the input method by hand in System Settings > Keyboard > Text Input > Input Sources. The driver never enables, disables or registers an input source.
2. Reset its profile (learned words, user dictionary) and switch off its cloud features with the vendor's own steps. The driver cannot do either; it records only the flags you declare.
3. `bash macOS/scripts/probe-blackbox-benchmark.sh --list` prints the current input source first, then every installed source with its ID, bundle, enabled and select-capable flags. It switches nothing.
4. `bash macOS/scripts/probe-blackbox-benchmark.sh --input-source <ID> --fresh-profile yes|no --cloud off|on|unknown`. Optional: `--corpus PATH`, `--output PATH`, `--settle-ms 400`, `--timeout-ms 3000`.

The script builds `build/BlackBoxBenchmark.app` with `xcrun swiftc` and keeps every output under `build/blackbox-benchmark/`.

One window holds one text view with every automatic substitution, correction, completion and spell check off. The driver selects the requested source, then for each sample empties the view, posts one key event per ASCII byte (US virtual key code, Shift for uppercase) and one Space through `NSApp.sendEvent`, all inside its own process: no Accessibility grant, no CGEvent, nothing leaves the process. It reads the view once the text has not changed for `settleMs` and holds no marked text, or at `timeoutMs`: then it sends Escape, reads what remains and flags the row `uncommitted`.

Refusals, each before any input source is switched: an unknown source, a source that is not enabled or not select-capable (enable it by hand), and bundle `io.damao.inputmethod.inkflow` always, because the installed InkFlow would learn every sample into the live user dictionary and write synthetic decisions into `quality.sqlite3`; the white-box runner is InkFlow's number. The driver never reads or writes `quality.sqlite3`, a Rime user directory or InkFlow preferences.

The input source that was current at the start is selected again on every exit: normal, refusal, error, SIGINT and SIGTERM. A crash or SIGKILL cannot restore it; pick your keyboard from the menu bar then.

## Metrics

One sample is one composition: the full code, one Space, read back; the truth is the corpus target (T4).

| Metric | Black box | Definition here |
| --- | --- | --- |
| R1 on T0 | yes | samples whose read-back equals the target / samples typed, with a 95% Wilson interval |
| R-sent | yes | the same number: under this policy one composition is one decision, so it is printed under both names |
| R-char | yes | mean over samples of `1 - levenshtein(read-back, target) / scalars(target)`, raw and not clamped at 0 |
| E-kspc | yes | `sum(input bytes + 1) / sum(Han scalars of the read-back)`, a ratio of sums, for the Chinese series (targets entirely Han) and per category; `unavailable` where the read-back has no Han scalar; never overall, because the series are separate |
| R3, R-paged, R-mrr | no | need the candidate panel, which this driver does not read |

Read-back rule: exactly one trailing U+0020 is stripped from the read-back before `hit`, `charAccuracy` and `hanCount` are computed, and the row records `trailingSpace`. An input method that passes uppercase or non-pinyin letters through and inserts a literal Space (`API` reads back as `API `) is therefore not a miss by policy artifact. The driver and `--score` apply the same rule.

With 24 samples every bucket is under the 200-unit minimum of section 8, so reports show intervals and no verdict.

## Report and provenance

The report (`formatVersion: 1`) names the input source, bundle and version, the date, the system, the corpus path and SHA-256, the SHA-256 of `main.swift`, the policy, the declared state (`freshProfile`, `cloud`), the event path (`nsapp`), `settleMs`, `timeoutMs`, one row per sample (`id`, `category`, `input`, `target`, `committed` as read, `trailingSpace`, `keys`, `hit`, `charAccuracy`, `hanCount`, `uncommitted`, `elapsedMs`) and the aggregates. A result without provenance is not a benchmark. Numbers compare only when corpus hash, policy and state match, and benchmark counts are never pooled with field or replay counts.

## Score

`--score REPORT` recomputes the aggregates of a driver report (the table that a run prints) from `input`, `target` and `committed`. `--score Core/Fixtures/QualityBaseline/baseline.json` scores InkFlow's white-box run on the same four metrics, from `sample.input`, `sample.target` and `initial.first` (the shown-first, no Space typed, so `trailingSpace` is `false` throughout). The search variant (R-mrr and E-page from `targetRank` and `pagingOperations`) stays the baseline runner's own output.

Reference, `--score Core/Fixtures/QualityBaseline/baseline.json`: R1 on T0 = R-sent `20/24 = 83.3% [64.1, 93.3]`, misses `ordinary-homophone`, `ordinary-paging`, `mixed-email`, `mixed-offer`; mean R-char `0.878`; Chinese-series E-kspc `146 / 48 = 3.04`; hits per category `ordinary-control 4/6`, `long-sentence 3/3`, `abbreviation 3/3`, `technical 8/8`, `mixed 2/4`.

Example, `--score macOS/Experiments/BlackBoxBenchmark/example-report.json` (three hand-written rows with made-up committed values, nothing from an input method):

| id | category | input | target | committed | keys | trailingSpace | hit | charAccuracy | hanCount |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `example-hit` | `ordinary-control` | `zhongguo` | 中国 | `中国 ` | 9 | true | true | 1.000 | 2 |
| `example-partial` | `ordinary-control` | `shurufa` | 输入法 | 书入法 | 8 | false | false | 0.667 | 3 |
| `example-uncommitted` | `technical` | `API` | `API` | `""`, uncommitted | 4 | false | false | 0.000 | 0 |

Overall `1/3 = 33.3% [6.1, 79.2]`, mean R-char `0.556`. `ordinary-control 1/2 = 50.0% [9.5, 90.5]`, mean `0.833`. `technical 0/1 = 0.0% [0.0, 79.3]`, mean `0.000`, E-kspc `unavailable`. Chinese series hits `1/2 = 50.0% [9.5, 90.5]`, E-kspc `17 / 5 = 3.40`.

## Result: pending the first user run

Replace this section after the first real run, in the style of [the AI panel probe](../AINativePanel/README.md): the input method and version, the declared state, the date, whether the input method received the `NSApp.sendEvent` key events (a CGEvent/HID-tap path is a follow-up issue only if it did not), the table next to the `--score` reference above, and the decision.
