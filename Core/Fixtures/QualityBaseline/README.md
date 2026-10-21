# Fixed input-quality baseline

Fixed candidate-order and learning baseline for the shared core ([#9](https://github.com/nervouna/InkFlow/issues/9)), independent of the macOS app.

## Run and review

From the repository root:

```sh
bash Core/scripts/test-quality-baseline.sh
# Equivalent focused macOS test unit:
bash macOS/scripts/test.sh quality-baseline
```

It uses the app's own dictionary preparation and a fresh temporary user directory per sample; installed data is never touched. The report goes to `build/quality-baseline/actual.json`, also on failure.

The check compares all per-sample observations (including the training and retention observations), training counts, the corpus and the complete input-option snapshot against `baseline.json`. Any candidate, rank, selection result or operation-count change fails, including an improvement that needs review. Provenance differences are printed and retained in the report; a new source revision by itself does not fail the behavior comparison.

After reviewing an intentional change, capture a proposed replacement into a separate file:

```sh
bash Core/scripts/test-quality-baseline.sh capture /tmp/proposed-quality-baseline.json
```

Review the old/new candidate results and provenance, then explicitly replace the checked-in baseline. `capture` never replaces it automatically. Corpus changes require a reviewed replacement too.

## Corpus and state

`corpus.json` contains stable IDs, exact ASCII key sequences, intended text, categories and sample origins. Ordinary Chinese is a separate control group. Other groups cover long sentences, abbreviation, technical words and mixed Chinese/English. Existing engine regressions and documented input incidents supply representative problematic boundaries; curated examples supply ordinary and homophone controls. These are repository-backed, sanitized examples, not a claim of newly collected user telemetry or incident frequency.

The initial dictionary state is the complete freshly prepared bundled resource tree, with an absent user directory, empty preceding-text context, no custom phrases, default input options and nine candidates per page. The existing packaged-cache tool compiles and verifies one cache shared by all samples, as in the application; it contains no user learning. The report records every input option rather than relying on undocumented defaults. AI and quality recording are not enabled by the harness.

For each sample, the first observation types the input, records the first candidate and first three candidates, searches for the exact target, and selects it through `IFEngine`. This successful selection is learning selection 1. The runner repeats the same target until exactly five successful commits have occurred and keeps the observations it takes before the repeated selections in `training` (`training[k-1]` is measured after `k` selections and performs selection `k + 1`). It then destroys its session and stops Rime, restarts Rime with that sample's user directory and observes the persisted learned state. The learned observation's commit (selection 6) occurs after the five-selection state has been measured.

In that same restarted engine the retention pass follows: the runner takes the corpus samples in corpus order starting after this sample and wrapping, keeps those whose target is entirely Han and differs from this sample's target, and for the first `retentionCommits` of them types the input with the same key loop and commits the shown-first candidate (`select(0)`, the one-Space policy). A commit that is empty or leaves residual input fails the run. The pool has 10, 11 or 12 members, so `M = 10` repeats nothing. `retained` is the observation taken after the pass. Other samples use separate user directories, so corpus order does not train later samples.

A target missing from the bounded search has no successful total-operation count and no training commits. `searchExhausted` distinguishes reaching the final candidate page from reaching the 20-page search limit. The learned observation then uses the unchanged user state. An exact candidate that leaves residual input or commits another text fails the run rather than producing a misleading operation count.

Learning uses normal Rime candidate selection and its existing user dictionary. No synthetic learned dictionary, custom phrase, AI adoption or test-only production API is injected.

## Measurements and traceability

Every observation (`initial`, each `training` entry, `learned`, `retained`) records:

- `first` and `topThree`: the displayed first page before selection;
- `targetRank`: one-based position across displayed pages, when found;
- `inputOperations`: one shared-core key call per input character;
- `pagingOperations`: successful Page Down calls while finding the target;
- `selectionOperations`: one direct candidate-selection call on success;
- `totalOperations`: input + paging + selection, present only for a verified complete target commit;
- `committedText` and `searchExhausted`: the selection and search evidence.

Beyond `initial` and `learned`, a result records `training` (four observations after 1 to 4 selections, empty when `initial` found no target), `retentionCommits` (the retention commits made) and `retained`.

Counts follow a fixed scripted policy with no arrow-key navigation or cursor edits. Uppercase letters carry the Shift modifier through the core API. First-choice and top-three hit rates can be derived by comparing `target` with `first`/`topThree`; the raw results preserve cases where Chinese-first mixed input deliberately keeps another candidate ahead.

The JSON report contains the corpus itself, format version, application source version, Git revision (marked `dirty` when applicable), host OS, SHA-256 fingerprints of the fixture, full generated resource tree, Rime, Lua and runner binaries, compiled resources, core sources, schemas, dictionary/configuration inputs and relevant runner/preparation scripts. A revision plus the content hashes distinguishes a source snapshot from a published release. The actual generated resource hash binds the initial dictionary and configuration even when the application version has not changed. The fixture hash and stable sample IDs bind every result to its exact input and target.

## Learning curve

The runner prints, per sample, the target's rank cold, after each of the four training observations, learned and retained, with Eb and U, and one summary line. These values are derived when printed and never stored in `baseline.json` (unit: sample; truth is the corpus target; the source is the benchmark fixture). `M = 10`, `pageLimit 20` and `learningSelections 5` are instrument constants and change only with the rule.

- **Eb, beneficial effort** (Jiang et al. 2011): the number of selections after which the target is first shown-first. 0 when `initial.targetRank == 1`, else the smallest `k` in 1..4 with `training[k-1].targetRank == 1`, else 5 when `learned.targetRank == 1`, else `unlearned`. The restart between selection 5 and `learned` is part of the instrument.
- **U, utility** (Jiang 2011, in its binary form at fixed `M`): among samples with `learned.targetRank == 1`, those with `retained.targetRank == 1`; `U = retained / reached`, `unavailable` when `reached` is 0. `M` unrelated commits advance the `pinyin_simp` tick `M` times, so the learned entry's `commits / tick` weight is diluted and its `dee` decays by about `exp(-M / 200)` (Rime `UserDictionary::UpdateEntry` and `CreateDictEntry`). Only the Chinese translator learns into `pinyin_simp.userdb`: the 8 technical and 4 mixed samples learn through `inkflow_shared_english`, which pure-Han commits never touch, so their `retained` equals `learned` by construction and the 24-sample total is inflated. The number to read is U over the Chinese series (the 12 samples whose target is entirely Han); U per category and for all 24 samples are printed beside it.
- **ER, error ratio** (Suzuki & Gao 2005) between the cold arm (`initial`) and the trained arm (`learned`): `fixed` counts samples with cold rank other than 1 and learned rank 1, `broken` counts cold rank 1 and learned rank other than 1, `ER = broken / fixed`, `unavailable` when `fixed` is 0.

The black-box counterpart that scores the same corpus through another input method is [the benchmark driver](../../../macOS/Experiments/BlackBoxBenchmark/README.md).

Scripted operation counts are synthetic; don't pool them with live quality-record actions.
