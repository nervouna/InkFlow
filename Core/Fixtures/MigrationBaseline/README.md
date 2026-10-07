# macOS migration reference

[macos-arm64.json](macos-arm64.json) is the compact performance/provenance report of the Swift engine from the phase-0 baseline.

## Capture and validation

- Source revision: `774bb557b57512ef0d74ce73cc3bf8a604bec75e`.
- Run ID: `20261004T185457Z-bd0a20b1`.
- Host: Apple M1 Pro, 32 GiB RAM, macOS 27.0.1, Xcode 27.0, Swift 6.4, SDK 27.0, Rust 1.98.1.
- Measurement build: release, `arm64-apple-macosx26.0`.
- Command: `python3 scripts/mac-remote.py baseline --revision 774bb557b57512ef0d74ce73cc3bf8a604bec75e`.
- Outcome: exit 0. Standalone boundaries, packaged-cache probe, ranking assertions, quality-baseline comparison, performance capture, and all seven selected regression units passed.
- Regression units: `voice-lexicon`, `ai-learning`, `engine-basic`, `engine-options`, `engine-english`, `engine-context`, `engine-custom-phrases`.

All 21 behavioral observations match [the existing quality baseline](../QualityBaseline/baseline.json). Nineteen samples complete the five-selection learning recipe. `technical-api` and `technical-swiftui` remain unreachable, as in that baseline. First-choice matches: 15/21 initial, 17/21 after learning.

The compact report includes raw report hashes, resource identities, native binary hashes, build-input fingerprints, and per-process distributions.

## Measurements

Five fresh processes each type 247 keys over the 21-sample corpus, then repeat that corpus four times without committing or training. This yields 1,235 first-pass and 4,940 repeated-pass key samples.

| Measurement | Median | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Headless startup, ms (5 processes) | 1,995.86 | 2,023.50 | 2,023.50 | 2,023.50 |
| First-pass key operation, ms | 0.538 | 1.809 | 2.238 | 20.081 |
| Repeated-pass key operation, ms | 0.487 | 1.542 | 1.946 | 2.429 |
| Peak RSS after input, MiB (5 processes) | 311.84 | 311.97 | 311.97 | 311.97 |

The five slowest samples are the first key of the first composition in each process, ranging from 16.76 to 20.08 ms. Aggregate p99 does not describe that first-key cost. With five processes, startup/memory p95/p99 equal the maximum.

Measurement boundaries are defined in [the remote workflow](../../../docs/remote-mac-baseline.md#measurement-boundaries). Recapture a Swift reference alongside the new core if the OS or toolchain changes substantially.

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
