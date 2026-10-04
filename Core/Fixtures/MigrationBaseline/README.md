# macOS migration reference

[macos-arm64.json](macos-arm64.json) is the compact performance/provenance report from the successful phase-0 baseline. The engine remains the existing Swift/Rime implementation; no production input behavior was changed.

## Capture and validation

- Source revision: `774bb557b57512ef0d74ce73cc3bf8a604bec75e`.
- Run ID: `20261004T185457Z-bd0a20b1`.
- Host: Apple M1 Pro, 32 GiB RAM, macOS 27.0.1, Xcode 27.0, Swift 6.4, SDK 27.0, Rust 1.98.1.
- Measurement build: release, `arm64-apple-macosx26.0`.
- Command: `python3 scripts/mac-remote.py baseline --revision 774bb557b57512ef0d74ce73cc3bf8a604bec75e`.
- Outcome: exit 0. Standalone boundaries, packaged-cache probe, ranking assertions, quality-baseline comparison, performance capture, and all seven selected regression units passed.
- Regression units: `voice-lexicon`, `ai-learning`, `engine-basic`, `engine-options`, `engine-english`, `engine-context`, `engine-custom-phrases`.

All 21 behavioral observations match [the existing quality baseline](../QualityBaseline/baseline.json). Nineteen samples complete the five-selection learning recipe. The uppercase `technical-api` and `technical-swiftui` targets remain unavailable under that fixture's input recipe, as in the existing baseline; they are not counted as successful learning. Initial first-choice matches are 15/21 and persisted learned first-choice matches are 17/21. These corpus counts are not estimates of real-user accuracy.

Full logs, behavior observations, five raw performance reports, and the run receipt remain under `build/mac-remote/20261004T185457Z-bd0a20b1/` on the Linux development machine. The compact report includes raw report hashes, generated/compiled resource identities, native binary hashes, build-input fingerprints, and per-process distributions.

The remote app build and fast bundle check also passed at revision `bb91518d668ce10e30934c78a787a4edfbfbefe5`, run `20261004T190518Z-895768f6`. The final runner passes 12 local tooling tests. Live SSH checks rejected a concurrent request and preserved an intentionally dirty checkout without switching its revision. The original Mac checkout remained clean on `main` at `8669c48`; no installation or activation was performed.

Additional evidence hashes:

| File | SHA-256 |
| --- | --- |
| `run.json` | `5e0abf41773bdbada3940d28db77bed215c7327784b7e68c0ff12cdcbbfe281c` |
| `00-baseline.log` | `481c5a437e326839e70171e73ceb0f9118241c3d39d387aeb410f366d1b3217c` |
| `behavior.json` | `b9f8a573d0a68a5b0e02fb986fcc81483004f85f7100013d9ab9d9973ebb2710` |
| `macos-arm64.json` / captured `summary.json` | `c322477cd9317db54f6eb921d1e6937b1590d929dde337c26f8d13b3eb944cf3` |

## Measurements

Five fresh processes each type 247 keys over the 21-sample corpus, then repeat that corpus four times without committing or training. This yields 1,235 first-pass and 4,940 repeated-pass key samples.

| Measurement | Median | p95 | p99 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Headless startup, ms (5 processes) | 1,995.86 | 2,023.50 | 2,023.50 | 2,023.50 |
| First-pass key operation, ms | 0.538 | 1.809 | 2.238 | 20.081 |
| Repeated-pass key operation, ms | 0.487 | 1.542 | 1.946 | 2.429 |
| Peak RSS after input, MiB (5 processes) | 311.84 | 311.97 | 311.97 | 311.97 |

The five slowest samples are the first key of the first composition in each process, ranging from 16.76 to 20.08 ms. Aggregate p99 does not describe that first-key cost. With only five startup/memory observations, their p95/p99 values are simply the observed maximum, not reliable tail estimates.

Startup includes prepared-cache validation and a ready context index, but excludes process launch and compilation. The app can prepare its index asynchronously, so this number is not app-launch time. Key timings exclude platform delivery, UI, queued actor work, and telemetry. Memory is peak process RSS, not current resident memory or app footprint. Filesystem caches were not flushed; the capture did not impose machine-wide background-activity controls.

See [the remote workflow](../../../docs/remote-mac-baseline.md) for the complete protocol. Compare future implementations using the same work boundaries, options, corpus, resource identities, hardware, and build configuration. Recapture a Swift reference alongside the new core if the OS/toolchain or test conditions change substantially.

## Approved review limits

The user approved these limits for #33. They are migration regression-review thresholds for this headless protocol, not claims about installed typing latency or mobile requirements.

| Metric | Approved limit |
| --- | ---: |
| Median startup across five processes | 2,300 ms |
| Maximum peak RSS after input across five processes | 344 MiB |
| Repeated-pass key p95 | 1.8 ms |
| Repeated-pass key p99 | 2.3 ms |
| First-pass key p99 | 2.6 ms |
| Maximum first-key latency across five processes | 25 ms |

A breach calls for a focused repeat on the same machine and investigation of reproducible changes. Faster measurements do not compensate for behavioral drift or lost learning data. Keep raw maxima and slow-case identities even when percentile limits pass; investigate new stalls that the aggregate percentiles hide. These limits are enforced through review; the capture script reports measurements without automatically failing on a threshold.
