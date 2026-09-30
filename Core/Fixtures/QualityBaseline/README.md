# Fixed input-quality baseline

Issue [#9](https://github.com/nervouna/InkFlow/issues/9) belongs to the v0.7.0 quality milestone. This harness is delivered early as v0.6.1 support. It measures the shared core independently of the macOS application, without changing dictionary weights, ranking or input policy.

## Run and review

From the repository root:

```sh
bash Core/scripts/test-quality-baseline.sh
# Equivalent focused macOS test unit:
bash macOS/scripts/test.sh quality-baseline
```

The standalone Swift package compiles `quality-baseline` with `InkFlowDomain` and `InkFlowRime`, with no application or UI dependency. Existing dependency and dictionary preparation scripts verify pinned downloads and generate the same dictionaries, schemas and Lua resources used by the application. On this host the package helper targets arm64 macOS 26; running this harness on other hosts requires their existing native Rime/toolchain adaptation. This result does not certify iOS or another platform.

Each run creates temporary Rime resources and one absent user directory per sample. The script removes these directories on exit. It never reads or modifies the installed input method's preferences, user dictionaries, quality database or downloaded dictionaries. Dependencies, build caches and the report stay under the ignored `build/` directory. Normal reports are written to `build/quality-baseline/actual.json`, including when comparison fails.

The check compares all per-sample observations, training counts, the corpus and the complete input-option snapshot against `baseline.json`. Any candidate, rank, selection result or operation-count change fails, including an improvement that needs review. Provenance differences are printed and retained in the report; a new source revision by itself does not fail the behavior comparison.

After reviewing an intentional change, capture a proposed replacement into a separate file:

```sh
bash Core/scripts/test-quality-baseline.sh capture /tmp/proposed-quality-baseline.json
```

Review the old/new candidate results and provenance, then explicitly replace the checked-in baseline. `capture` never replaces it automatically. Corpus changes require a reviewed replacement too.

## Corpus and state

`corpus.json` contains stable IDs, exact ASCII key sequences, intended text, categories and sample origins. Ordinary Chinese is a separate control group. Other groups cover long sentences, abbreviation, technical words and mixed Chinese/English. Existing engine regressions and documented input incidents supply representative problematic boundaries; curated examples supply ordinary and homophone controls. These are repository-backed, sanitized examples, not a claim of newly collected user telemetry or incident frequency.

The initial dictionary state is the complete freshly prepared bundled resource tree, with an absent user directory, empty preceding-text context, no custom phrases, default input options and nine candidates per page. The existing packaged-cache tool compiles and verifies one cache shared by all samples, as in the application; it contains no user learning. The report records every input option rather than relying on undocumented defaults. AI and quality recording are not enabled by the harness.

For each sample, the first observation types the input, records the first candidate and first three candidates, searches for the exact target, and selects it through `IFEngine`. This successful selection is learning selection 1. The runner repeats the same target until exactly five successful commits have occurred, destroys its session and stops Rime, then restarts Rime with that sample's user directory and observes the persisted learned state. The learned observation's commit occurs after the five-selection state has been measured. Other samples use separate user directories, so corpus order does not train later samples.

A target missing from the bounded search has no successful total-operation count and no training commits. `searchExhausted` distinguishes reaching the final candidate page from reaching the 20-page search limit. The learned observation then uses the unchanged user state. Missing targets are recorded as baseline limitations, never treated as successful learning. An exact candidate that leaves residual input or commits another text fails the run rather than producing a misleading operation count.

Learning uses normal Rime candidate selection and its existing user dictionary. No synthetic learned dictionary, custom phrase, AI adoption or test-only production API is injected. This fixes a reproducible learning recipe, not timestamp-dependent user-database bytes. It does not assert that every target should move upward after learning.

## Measurements and traceability

Both states record:

- `first` and `topThree`: the displayed first page before selection;
- `targetRank`: one-based position across displayed pages, when found;
- `inputOperations`: one shared-core key call per input character;
- `pagingOperations`: successful Page Down calls while finding the target;
- `selectionOperations`: one direct candidate-selection call on success;
- `totalOperations`: input + paging + selection, present only for a verified complete target commit;
- `committedText` and `searchExhausted`: the selection and search evidence.

These counts use a fixed scripted selection policy, not physical keyboard effort, latency, corrections or real-session telemetry. No arrow-key navigation or cursor edits are simulated. Uppercase letters carry the Shift modifier through the core API. First-choice and top-three hit rates can be derived by comparing `target` with `first`/`topThree`; the raw results preserve cases where Chinese-first mixed input deliberately keeps another candidate ahead.

The JSON report contains the corpus itself, format version, application source version, Git revision (marked `dirty` when applicable), host OS, SHA-256 fingerprints of the fixture, full generated resource tree, Rime, Lua and runner binaries, compiled resources, core sources, schemas, dictionary/configuration inputs and relevant runner/preparation scripts. A revision plus the content hashes distinguishes a source snapshot from a published release. The actual generated resource hash binds the initial dictionary and configuration even when the application version has not changed. The fixture hash and stable sample IDs bind every result to its exact input and target.

The test owns fixed, stateful candidate-order/operation baselines; existing engine tests continue to own feature-specific input and selection correctness. It introduces no production seams.

## Integration and remaining acceptance

The #31 export/analysis work can join by `sample.id`, `sample.category`, `sample.input` and `sample.target`, compare `initial`/`learned`, and use `provenance` plus `inputOptions` to keep incompatible snapshots separate. This file format is synthetic regression evidence; do not combine its scripted operation counts with live quality-record actions as though they were the same measurement. No production export UI, storage interface or quality-analysis tool is changed here.

A week of samples from multiple devices has not yet been accumulated. Collect, sanitize and classify those samples later; then add stable cases and recapture a reviewed baseline. This corpus does not establish current real-use failure rates or week-over-week quality. macOS typing, focus and Settings acceptance remain user checks; this harness only verifies shared-core behavior.

The initial capture on this source snapshot contains 21 samples. Nineteen targets are reachable and commit completely. In the homophone control, `shanghai` → `上海` moves from rank 3 to rank 1 after the fixed learning recipe and restart. The paging control `shi` → `誓` moves from rank 36 to rank 1, with scripted operations decreasing from 7 to 4. `wofaleemail` and the long mixed `offer` example remain rank 2 in both states. Literal standalone `API` and `SwiftUI` have no candidate in this configuration; the existing lookup forms `Api` and `swiftui` do reach the intended display text. The baseline preserves both behaviors. These observations apply only to the checked-in corpus and recorded provenance.
