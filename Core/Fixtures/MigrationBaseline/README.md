# macOS migration reference

[macos-arm64.json](macos-arm64.json) is the compact performance/provenance report of the Swift engine from the phase-0 baseline.

## Capture and validation

- Source revision: `75e5c70e85164bfd9fd67e3e0f9dc1829dcd48f0` (#53: mapped context-ranking index, bounded resource hashing).
- Host: Apple M5 Pro, 24 GiB RAM, macOS 27.0, Xcode 27.0, Swift 6.4, SDK 27.0, no Rust toolchain.
- Measurement build: release, `arm64-apple-macosx26.0`.
- Command: `bash Core/scripts/capture-migration-baseline.sh OUTPUT` run locally on the worktree.
- Outcome: standalone boundaries, packaged-cache probe, ranking assertions, quality-baseline comparison and performance capture passed. The regression units ran separately on the same revision: `preparation`, `dictionary-generator`, `dictionary-store`, `dictionary-worker`, `dictionary-activation`, `engine-*`, `ai-learning`, `voice-lexicon`, plus `check-bundle.sh`.

All 21 behavioral observations match [the existing quality baseline](../QualityBaseline/baseline.json). Nineteen samples complete the five-selection learning recipe. `technical-api` and `technical-swiftui` remain unreachable, as in that baseline. First-choice matches: 15/21 initial, 17/21 after learning.

The compact report includes raw report hashes, resource identities, native binary hashes, build-input fingerprints, and per-process distributions.

## Measurements

Five fresh processes each type 247 keys over the 21-sample corpus, then repeat that corpus four times without committing or training. This yields 1,235 first-pass and 4,940 repeated-pass key samples.

| Measurement | Median | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Headless startup, ms (5 processes) | 237.91 | 248.33 | 248.33 | 248.33 |
| First-pass key operation, ms | 0.321 | 1.107 | 1.473 | 7.786 |
| Repeated-pass key operation, ms | 0.312 | 1.058 | 1.324 | 1.917 |
| Peak RSS after input, MiB (5 processes) | 40.63 | 42.56 | 42.56 | 42.56 |

The five slowest samples are the first key of the first composition in each process, ranging from 7.01 to 7.79 ms. Aggregate p99 does not describe that first-key cost. With five processes, startup/memory p95/p99 equal the maximum.

Measurement boundaries are defined in [the remote workflow](../../../docs/remote-mac-baseline.md#measurement-boundaries). Recapture a Swift reference alongside the new core if the OS or toolchain changes substantially.

### Before and after #53

Same host, same protocol, same session. "Before" is `b128128` with the previous `IFContextRanker` that parsed the whole dictionary at startup; "after" is this capture. The earlier phase-0 numbers (startup 1,995.86 ms, peak RSS 311.84 MiB, first key 16.76–20.08 ms) were taken on an M1 Pro and are not directly comparable to either column.

| Measurement | Before (`b128128`) | After (`75e5c70`) |
| --- | ---: | ---: |
| Headless startup median, ms | 1,225.01 | 237.91 |
| Peak RSS after startup, max MiB | 289.95 | 21.81 |
| Peak RSS after input, max MiB | 310.70 | 42.56 |
| First key of each process, ms | 8.68–10.15 | 7.01–7.79 |
| First-pass key p95 / p99, ms | 1.125 / 1.393 | 1.107 / 1.473 |
| Repeated-pass key median / p95, ms | 0.293 / 1.005 | 0.312 / 1.058 |

Where the memory went: the old ranker alone peaked at 181 MiB and took about 960 ms to build its Swift dictionary. The remaining 123 MiB peak was `IFPackagedCache.descriptor` hashing bundled resources through autoreleased `FileHandle` chunks that stayed resident until the pool drained. The mapped index (`pinyin_simp.context.bin`, 18 MB on disk) adds about 1 MiB of resident pages after input.

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
