# macOS migration reference

[macos-arm64.json](macos-arm64.json) is the compact performance/provenance report of the Swift engine from the phase-0 baseline.

## Capture and validation

- Source revision: `c918273edf1341199cf2b5a6bd84f98c5e473b79` (#53: prepared context-ranking index, bounded resource hashing).
- Host: Apple M5 Pro, 24 GiB RAM, macOS 27.0, Xcode 27.0, Swift 6.4, SDK 27.0, no Rust toolchain.
- Measurement build: release, `arm64-apple-macosx26.0`.
- Command: `bash Core/scripts/capture-migration-baseline.sh OUTPUT` run locally on the worktree.
- Outcome: exit 0. Standalone boundaries, packaged-cache probe, ranking assertions, quality-baseline comparison, performance capture, and all seven selected regression units passed. `preparation`, `dictionary-generator`, `dictionary-store`, `dictionary-worker`, `dictionary-activation` and `check-bundle.sh` also passed on the PR branch.
- Regression units: `voice-lexicon`, `ai-learning`, `engine-basic`, `engine-options`, `engine-english`, `engine-context`, `engine-custom-phrases`.

All 21 behavioral observations match [the existing quality baseline](../QualityBaseline/baseline.json). Nineteen samples complete the five-selection learning recipe. `technical-api` and `technical-swiftui` remain unreachable, as in that baseline. First-choice matches: 15/21 initial, 17/21 after learning.

The compact report includes raw report hashes, resource identities, native binary hashes, build-input fingerprints, and per-process distributions.

## Measurements

Five fresh processes each type 247 keys over the 21-sample corpus, then repeat that corpus four times without committing or training. This yields 1,235 first-pass and 4,940 repeated-pass key samples.

| Measurement | Median | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Headless startup, ms (5 processes) | 252.91 | 258.15 | 258.15 | 258.15 |
| First-pass key operation, ms | 0.346 | 1.190 | 1.571 | 10.526 |
| Repeated-pass key operation, ms | 0.317 | 1.066 | 1.375 | 2.450 |
| Peak RSS after input, MiB (5 processes) | 57.92 | 58.14 | 58.14 | 58.14 |

The five slowest samples are the first key of the first composition in each process, ranging from 9.62 to 10.53 ms. Aggregate p99 does not describe that first-key cost. With five processes, startup/memory p95/p99 equal the maximum.

Measurement boundaries are defined in [the remote workflow](../../../docs/remote-mac-baseline.md#measurement-boundaries). Recapture a Swift reference alongside the new core if the OS or toolchain changes substantially.

### Before and after #53

Same host, same protocol, same session. "Before" is `b128128` with the previous `IFContextRanker` that parsed the whole dictionary at startup; "after" is this capture. The earlier phase-0 numbers (startup 1,995.86 ms, peak RSS 311.84 MiB, first key 16.76–20.08 ms) were taken on an M1 Pro and are not directly comparable to either column.

| Measurement | Before (`b128128`) | After (`c918273`) |
| --- | ---: | ---: |
| Headless startup median, ms | 1,225.01 | 252.91 |
| Peak RSS after startup, max MiB | 289.95 | 37.23 |
| Peak RSS after input, max MiB | 310.70 | 58.14 |
| First key of each process, ms | 8.68–10.15 | 9.62–10.53 |
| First-pass key p95 / p99, ms | 1.125 / 1.393 | 1.190 / 1.571 |
| Repeated-pass key median / p95, ms | 0.293 / 1.005 | 0.317 / 1.066 |

Where the memory went: the old ranker alone peaked at 181 MiB and took about 960 ms to build its Swift dictionary. The remaining 123 MiB peak was `IFPackagedCache.descriptor` hashing bundled resources through autoreleased `FileHandle` chunks that stayed resident until the pool drained. The prepared index (`pinyin_simp.context.bin`, 18 MB) is read whole into memory when the ranker loads, so lookups never fault pages in from disk on the key-event path; that is the 18 MiB difference between the two RSS rows. First-key cost is Rime's first composition and varies by about 1 ms between runs; a mapped variant of the same index measured 7.0–7.8 ms on one run and 8.4–10.5 ms on another.

## Approved review limits

Approved for #33 as regression-review thresholds for this headless protocol.

| Metric | Approved limit |
| --- | ---: |
| Median startup across five processes | 2,300 ms |
| Maximum peak RSS after input across five processes | 344 MiB |
| Repeated-pass key p95 | 1.8 ms |
| Repeated-pass key p99 | 2.3 ms |
| First-pass key p99 | 2.6 ms |
| Maximum first-key latency across five processes | 25 ms |

A breach calls for a focused repeat on the same machine. Also investigate new stalls that percentiles hide. The capture script reports; it does not fail on thresholds.
