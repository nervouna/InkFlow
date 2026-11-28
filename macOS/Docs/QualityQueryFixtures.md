# Python quality query fixtures

`QualityQueryTests.py` creates fixtures with the SQLite schema of the Swift engine/controller
capture. The [query contract](../../.agents/skills/inkflow-quality-analysis/references/query-contract.md#storage-and-record-format) defines the record format. The observed
window belongs to the commit named by its ID even when its carrier is outside a selected date range.
The base fixture's four windows ride the `raw-only` composition and describe commits a–d.
Commit a reverts with two leading Backspaces for one character and d reverts with Cmd+Z.
The native capture proves content and timing through the controller and recorder but does not
observe panel visibility.

## Replay and learning cases

Replay uses the decision-time list for page-zero selections and the first page for a later-page
selection while keeping the selection's own page index. Without a usable first page, a paged
decision supplies no candidate list. Old candidate facts and character counts can be null.
The text-free pre-v4 case and the empty selection have unknown length, while text-bearing pre-v4
records can recover it from text. Unavailable measurements yield null. A measured zero is 0.

The delayed-correction fixture retains the reverted input, replaces the chosen text and commit
with a suitable later retype, and takes its rank from the reverted list. It accepts the same code
or a continued one when the corrected candidate was on that list. A shorter code, a missing
candidate, ambiguous segments, undo rather than deletion, a nonleading edit or an expired window
makes that inference ineligible. Retypes that are themselves reverted are not gold. Without a
window the ordinary historic decision still qualifies. Export joins namespace commit and
composition IDs by device. Independent devices deliberately reuse fixture IDs to validate the join.

Learning pairs use the normalized spelling span from the evidence row. A leading segment of
`nihaoshijie` can share the whole-code pair for `nihao`. Without a known span or valid selected
candidate the query counts the decision without guessing a pair identity. Legacy text-free rows,
prehash rows, a missing evidence row and a preceding selected prefix each exercise that rule.
Compatible text-mode and text-free rows share identities and hashes. Separate metric rules,
dates outside the selected window and non-regular decisions are excluded; within a cohort,
missing identity remains visible in coverage. The verdict fixture uses 210 pairs with one miss
each to clear the sample floor.

## Scorecard arithmetic

The scorecard's independent hand count uses these cases under measurement A on September 6,
2026, with `canc1` and `canc2` on September 5.

| Counter | Independently counted fixture inputs |
| --- | --- |
| Code compositions, 19 | Twelve with decisions (`one digit paged moved learnedmiss learnedlead dictkept english blend two edited free`), five without regular decisions (`raw1 raw2 ascii intr partial`), plus the two older cancels. Direct symbol `sym` and AI adoption `nocommit` are excluded. |
| Cancellations, 3 | `partial canc1 canc2`. Interrupted `intr` still counts as a code composition. |
| Edits, 2 | `edited canc1`. |
| Regular committed, 12 | The twelve compositions with regular commits contribute fourteen decisions because `blend` and `two` each have two. |
| KSPC | Eleven text-captured inputs give 67 keys / 24 characters. Nine Chinese compositions give 53 / 16. `free` contributes only to the text-free count. |
| Commits | Fifteen candidates across thirteen compositions and two raw returns. Direct ASCII and symbol commits are excluded. |
| Valid decisions, 15 | The one-key ones are `one`, `english`, both of `blend`, the first of `two`, `edited`, `free` and `partial`. Selection by digit, move or paging fails the one-key condition. |
| Misses, 5 | `digit paged moved learnedmiss learnedlead` all have a type; `learnedmiss` has learned provenance. |
| Learned/dictionary leaders | Learned leaders are `learnedlead` (missed) and `english` (kept). The ten dictionary leaders include `dictkept`'s user table and the first of `blend`, but not the second of `blend`, `moved` or `learnedmiss`. Only `digit` and `paged` miss in that set. |

Use the decision kind for decision series and composition kind for composition series. A Chinese
decision may belong to a mixed or cancelled composition. Selecting one kind narrows decisions
inside a mixed composition and can omit the no-decision cancels. This removes the denominator for
composition-wide rates. A known decision fingerprint still supports decision rates if an orphan
composition has no fingerprint. Unknown or mixed rules lack comparable rates. Mean and KSPC
ratios have no Wilson interval. The selected-length buckets count decisions, not compositions.

## Revert arithmetic

A window's commit kind comes from the composition. Count candidate commits once even when several
decisions selected segments for the same commit. Backspace evidence needs a known, positive
character count and enough leading deletions. Leading undo qualifies even with zero or unknown
length. A direct-text key or paste ends the leading run. Forward Delete, timeout and client-switch
windows with no earlier edit do not revert. Candidate commits without windows remain commits
with no observed revert rate. Other commit kinds' windows remain available for inspection.

| Day and series | In window | Reverted |
| --- | ---: | ---: |
| September 6 Chinese | 15 | 7 |
| September 6 English | 2 | 1 |
| September 5 | 2 | 1 |
| August 20 | 3 | 1 |

September 6 Chinese reverts are `full`, `over`, `undo`, `zero_undo`, `null_undo`, `twice` and
`late`. `twice` has two decisions and counts once. `late` survives an exclusive date filter that
excludes the window's carrier. The English decision `eng_rev` has two leading deletions for two
characters and `eng_kept` has four for five. August 15's `old1` belongs to the older measurement
rule. It produces a revert when only that rule is selected. The 28-day latest-rule count ending
September 7 is 22 observed and 10 reverted, and the seven-day count is 19 observed and 9 reverted.
Punctuation and raw Return would meet the window criterion but are excluded as non-candidate commits.

The SQLite concurrency cases cover readers coexisting with a reserved rollback-journal writer,
snapshot consistency across intervening writes, and safe failure when the database is busy.
Analysis leaves the source unchanged. Export and CLI fixtures use the same gzip document and
compare equivalent decoded values regardless of JSON key order. The Python and Swift writers match
the final gzip suffix case-insensitively. The Python reader also accepts plain JSON that earlier
CLI versions wrote under mixed-case gzip suffixes. Learning-event identities
include run and timestamp because retention can free a reused row ID.

## Native capture counts

The fixture built by `QualityCaptureTests.swift` includes one deferred-toggle selection,
five custom-phrase combinations and five candidate-fact cases. Each contributes one decision
and candidate commit. The post-commit cases add seventeen compositions and commits, and
sixteen decisions. A direct comma has no decision and a commit without a client has no window.
The learning fixture adds a committed learned pick and a cancelled composition that forgot a
candidate, for two compositions with one decision and one commit. The assertions require at
least the three explicit emoji selections because positional selections can also pick emoji.
Every known-rank decision either has a pair identity or is counted as missing one. Repeated
snapshots deliberately carry the same data. Use one complete snapshot per composition.
