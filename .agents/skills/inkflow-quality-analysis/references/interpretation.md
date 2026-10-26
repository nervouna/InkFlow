# Interpreting recorded quality

How to read `scripts/quality.py` results: units, measurement fingerprints, denominators and cohorts, what is
unavailable, what text-free records can and cannot show, and the coverage limits. Commands, output fields, the record
format and the exchange files are in [the query contract](query-contract.md).

## Units, filters and the calendar

Legacy-config/ranking-config/kind filters select matching decisions and compositions containing at
least one such decision. Composition and commit counts then cover those matching
compositions in full; a mixed composition's other decisions are excluded from
decision aggregates. Inspect follows the same rule and explicitly returns all
commits for context. Multiple decisions may link to one commit, so decision,
composition and commit totals have different units.

`trend --days N` derives an inclusive start from an exclusive local-calendar
`--until`; without `--until`, it includes today as the final partial day. It emits
empty calendar days instead of dropping them. Rolling rates are ratios of summed
numerators and denominators, never averages of daily percentages. App version,
build and source revision are traceability metadata. The chart annotates each app
version at its first observed decision time. Versions do not partition the statistical
series and markers do not prove causality.
The trend selects the latest known compatible metric definition in the window,
reports included and excluded decision counts, and does not mix older or unknown
metric definitions into its rates. This metric definition is the statistical rule;
the underlying measurement fingerprint is diagnostic metadata.

## Measurement fingerprints and pooled rates

The worker persists four independent identities. `ranking_fingerprint` covers the
engine, audited offline ranking source/resources, and ranking-affecting applied
settings. It is forensic provenance, not the primary time-series dimension; generated
resource bytes can change without establishing a semantic ranking-policy change.
`settings_fingerprint` covers the
complete applied configuration. `measurement_fingerprint` covers database schema,
metric and collection rule versions. `build_identity` covers the complete build
metadata and is traceability context only. The legacy `fingerprint` remains
available for exact `--config` filtering and inspection. Revision UUIDs are
capture-time identity, not a ranking version. Build metadata records source
revision/tree digest/dirty state, bundle/resource digests and app versions.
Migrated v1 rows keep all four layered columns NULL. Query output labels NULL
identities as the separate string `unknown` for grouping and coverage, never as a
known fingerprint; `inspect` preserves the stored null values.
Personalization/user dictionaries remain mutable and are not frozen by a
fingerprint, so identical fingerprints do not establish identical learned state.

Pooled coverage is a whole-filter description; configuration or text-kind comparisons use the separate
groups rather than treating the pooled rate as a causal quality score. Pooled raw
counts remain available, but `top1_rate`, `top3_rate` and `top1_match_rate` are null unless the
entire pooled cohort has exactly one known measurement fingerprint. The adjacent
`quality_rate_status` says whether rates are available, cross-measurement,
unknown-measurement, or without measurement evidence. Each known single-measurement
group computes its own rates; an `unknown` measurement group never does. The composition and
commit rates have the same rule under `composition_rate_status` (below).

## Unavailable is not zero

A zero denominator yields null/N/A, never 0%. Missing evidence is unavailable, not zero: see the rate statuses above,
[deletions and post-commit windows](#deletions-and-post-commit-windows), [input timing](query-contract.md#input-timing)
and the `unknown` identities.

## Denominators and ranking evidence

The following counts are available overall and per ranking fingerprint,
measurement fingerprint, text kind and current pre-decision presentation. Outcome counts include every
filtered decision, including committed, tentative, unknown, reverted, edited,
cancelled and interrupted. Unknown paths never become successful choices.

| Field | Exact cohort or meaning |
| --- | --- |
| regular_issued | `regular_ranked_selection=1`, trigger space/digit/panel, outcome committed, linked same-composition commit with insertion_issued=1 |
| regular_not_issued | Same proven regular commit with insertion_issued=0; outside adoption denominators |
| regular_insertion_unknown | Same regular committed path without available insertion evidence |
| valid | regular_issued with candidates_requested or panel_show_issued presentation |
| known_rank | valid with selected_display_index pointing to the exact matching selected text (or, in a text-free record, a null selected text) and consistent global display rank |
| unknown_rank | valid minus known_rank; missing/ambiguous/mismatched rank evidence |
| comparable | known_rank with validated selected prefix and a matching-generation first-page snapshot with actual first candidate |
| first_page_unavailable | known_rank minus comparable; absent, mismatched or invalid-prefix first-page evidence |
| top1_selected / top1_rate | Known displayed rank 1 count / known_rank |
| top3_selected / top3_rate | Known displayed rank 1–3 count / known_rank; shares the Top1 denominator |
| top1_matches / top1_match_rate | Selected text equals actual first-page top1 count / comparable; a text-free record matches when its chosen display rank is 1 |
| mean_display_rank | Mean among known_rank |
| mean_native_rank | Mean of available, internally consistent native ranks among known_rank |
| truncated / dropped_page_count | Filtered decision history flags and removed snapshot-history entries |
| text_free | Decisions whose pages carry `textCaptured: false`; outside ranking-issues and without inspectable text |
| length_unavailable | known_rank without a selected length: no `selected_character_count` and no selected text (an older text-free record), or a zero count; outside the length buckets |
| pair_identity | known_rank whose snapshot has a `codeHash` and whose selected candidate has a `textHash`; `pair_id` is `code_hash \|\| '\|' \|\| selected_text_hash` |
| pair_unavailable | known_rank without `pair_id`: records from before pair hashes, decisions with a selected prefix, decisions whose consumed span is unknown (no `evidence` row and no custom-phrase match), envelopes submitted before the key was loaded, and records written while the key file could not be kept; `pair_identity + pair_unavailable = known_rank` |
| onekey_selected / onekey_rate | `valid` with trigger `space`, snapshot `page` 0, and `pageTurns` 0 and `candidateMoves` 0 in the decision's own operations (E-onekey; `valid` is the design's regular decisions); rate over `valid` |
| misses | `valid` with display rank above 1; a paged choice has a rank above the page size, so it is a miss |
| learned_misses / learned_miss_share | misses whose selected candidate `type` is `user_phrase`, `english_personal_1` to `english_personal_3` or `mixed_personal_0` to `mixed_personal_3` (the learned set); share over `misses`, the interim L-avoid proxy, which undercounts because a learned word can also be a first-time dictionary miss |
| misses_with_provenance | misses whose selected candidate has a non-empty `type`: the evidence coverage of the share. Records from before candidate types (#129) and candidates without evidence carry none, so the share undercounts until they leave retention |
| learned_leader / learned_leader_missed / learned_leader_miss_rate | `comparable` decisions whose first-page candidate 0 has a learned `type`; missed adds `NOT top1_match`; rate is missed over leader (L-over) |
| dictionary_leader / dictionary_leader_missed / dictionary_leader_miss_rate | the same for first-page candidate 0 of `type` `phrase` or `user_table` (the dictionary set), reported beside the learned rate |

`rank_counts` enumerates each exact
global display rank for known_rank in each group. Page and index are zero-based;
rank is one-based: `page * actual_page_size + index + 1`. Native rank is separate
from display order. Duplicate candidate text without a proven selected index does
not establish rank. First-page validation matches generation, raw input, caret,
selected prefix and its validity, preceding context, capture revision and page size;
it requires page 0 / first candidate rank 1. A later page's first candidate is
never substituted for unknown first-page top1.

Presentation is delivery evidence: `not_shown` means engine-only observation;
`candidates_requested` means controller candidate-list refresh, including headless
tests; `panel_show_issued` additionally means a panel.show call. None proves visual
exposure. Issued insertion is the existing controller insertText call, not document
readback. Return/raw, punctuation, forced flush, mode toggle, ASCII and direct
symbols stay outside the regular cohort. Commits without decisions are retained.

Issue groups use the ranking fingerprint, measurement fingerprint, raw input **and
caret**, selected prefix and validity, preceding context actually used, first-page
top1, chosen text, text kind and custom-phrase-match flag. Distinct revision UUIDs
and build identities with the same ranking and measurement fingerprints can group
together. Only comparable choices differing from first-page top1 enter the list;
text-free records never do, because their chosen and top1 texts are unavailable.
Occurrences count decisions, with mean display/native ranks and separate
actual operation totals. Sort by page-turn total descending, then occurrences
descending, then grouping fields for deterministic ties. At most five distinct,
lexically ordered composition IDs per group support bounded `inspect` follow-up.
These pairs are evidence for investigation, not proof the first candidate is wrong.

Operation counters are keypresses, page requests, actual page turns, candidate moves
and preedit edits. Summary totals cover valid decisions and count operations since
the previous decision. Inspect also exposes full composition totals. Arrow movement
across a page may increment both page turns and candidate moves; never add them
into a distinct-operation count. Dropped page counts are removed history entries,
possibly including copies across decisions, not unique pages or unseen candidates.

### Deletions and post-commit windows

`operations_json.inputBeforeDeletion`, on a decision and on its composition, is the
raw input just before the first Backspace, Delete or Escape that removed input in
that span. On a decision the span starts after the previous decision; compare it
with that decision's `snapshot.rawInput` and selected text to see what was retyped.
A cancelled composition keeps it only at composition level; its retyped input, if
any, is in the next composition. It is typed text: present only in text-mode
records, absent when nothing was deleted, and absent in records written before the
field existed, so absence alone is not evidence of no deletion. No command
aggregates it yet; `inspect` shows it.

`operations_json.postCommitWindows`, on a composition only, holds the post-commit
windows closed since the recorder last submitted a record. The carrier is the
recorder's next composition, not the commit's own, so read a window by its commit:
`inspect` lists the `windows` of its own commits, and `observations` carries
`window_end`, `window_elapsed_ms` and the counts below as `window_*` on the decision
that made the commit. A window counts the keys that reached InkFlow while no
composition was active, from the commit until it ended: Backspace (`deletions`),
Forward Delete (`forward_deletions`), Cmd+Z (`undo`), pass-through printable ASCII
keys (`direct_text`) and Cmd+V (`paste`). The three `leading_*` counts are the
deletions, forward deletions and undo before the first direct-text or paste key.
`end` is `next_code` (a code started or another commit was made), `client_changed`,
`deactivated` or `timeout`. `W` is 10 seconds (`QualityLimits.postCommitWindowSeconds`);
there is no timer, so the first event after `W` closes the window as `timeout` or
another end with `elapsed_ms` clamped to 10000, and a key past `W` is never counted.
Arrows, Home, End, Return, Tab, Escape, mode toggles and other chords, Option or
Command with Backspace among them, are not counted and do not end it. A commit with
no window was not observed, which is not zero deletions: records written before the
field existed, a commit without an insertion, secure input, engine teardown and a
record the store dropped all leave none. `coverage.commit_windows` counts the
windows whose commit belongs to a selected composition, and `windows_by_end` splits
them by `end`. Each is one more fact on the existing schema, so no cohort changes.

### Composition and commit counters

One row per selected composition, read in `trend` and `summary` `coverage` (the groups carry decision counters only).
A composition's decisions are the filtered ones, as for every decision aggregate; its `keypresses` and `preeditEdits`
are the whole composition's totals.

- **Kind** is the `text_kind` all its decisions share, `mixed` when they differ and `unknown` when it has no decision;
  a commit takes its composition's kind. `chinese` is Han without Latin (`mixed` is Han with Latin).
- **Measurement fingerprint** is the decisions' fingerprint (`unknown` when they disagree); a composition without a
  decision takes the fingerprint of the decisions of its `run_id` (any filter, `unknown` when the run has none or they
  disagree), because the versions that make it are build constants of a process. In `trend` a day or point of
  compositions without a decision still has a status and rates; it is `unavailable_without_measurement_evidence` only
  with neither decisions nor compositions. `summary` pools the fingerprints of decisions and compositions into
  `composition_rate_status` by the rule of `quality_rate_status`: `available_within_measurement_fingerprint` when they
  share exactly one known fingerprint and none is `unknown`, `unavailable_without_measurement_evidence` when there are
  none, else `unavailable_unknown_measurement_fingerprint` or `unavailable_across_measurement_fingerprints`; the
  composition and commit rates are null unless it is available. `quality_rate_status` and the decision rates keep
  the decisions-only rule. `unknown_fingerprint_compositions` counts compositions with fingerprint `unknown`.

| Field | Exact cohort or meaning |
| --- | --- |
| code_compositions | compositions with at least one decision, or outcome `cancelled` or `interrupted`, or a commit of kind `candidate`, `raw_return`, `ascii` or `forced_flush`. Not: a composition without a decision whose commits are only `direct_symbol`, `punctuation`, `mode_toggle` or `unknown` (a symbol key opens and closes a record that types no code), and a committed composition with no commit (`outcome_reason` `ai_adopted`) |
| cancelled_compositions / cancel_rate | `code_compositions` with outcome `cancelled` over `code_compositions` (C-cancel); `interrupted` is in the denominator and is not a cancel |
| edited_compositions / preedit_edit_rate | `code_compositions` with `preeditEdits` above 0 over `code_compositions` (C-pre) |
| regular_committed_compositions / regular_decisions / decisions_per_composition | compositions with outcome `committed` and at least one `valid` decision, and the `valid` decisions they hold; the mean is `regular_decisions / regular_committed_compositions` (E-dec) |
| kspc_compositions / kspc_keypresses / kspc_characters / kspc | regular committed compositions whose decisions are all text-captured; their summed `keypresses` (letters, edits, paging, moves, selection) and the summed `length(text)` of their `candidate` commits (Unicode scalars); `kspc` is keys over characters, null when there are no characters (E-kspc). Overall pools every kind; the scorecard's Chinese E-kspc is the `chinese` series |
| kspc_text_free_compositions | regular committed compositions with a text-free decision: counted and left out of E-kspc, whose characters come from the commit text (the commit `character_count` is recorded in either mode, but the cohort is unchanged) |
| candidate_commits / raw_return_commits / raw_commit_rate | commits of those kinds in the selected compositions; `raw_commit_rate` is `raw_return_commits / (candidate_commits + raw_return_commits)` (C-raw). The design's "commits of Chinese-kind compositions" cannot be read: a Return on raw pinyin records a decision with trigger `return_raw` and kind `unknown`, or none, so the denominator is the commits of pinyin compositions of every kind. `ascii`, `punctuation`, `direct_symbol`, `forced_flush` and `mode_toggle` commits are in neither term |
| commits_with_window / reverted_commits / revert_rate | C-rev (unit commit, truth T2 against T3). `commits_with_window` is the denominator: `candidate` commits of the selected compositions that have a post-commit window (a `windows` row) of any end reason; a window that ended `client_changed` or `timeout` with every count 0 was observed, and that commit was kept. `reverted_commits` is those with `leading_undo >= 1` (Cmd+Z), or with `character_count > 0` and `leading_deletions >= character_count` (Backspaces); the `leading_*` counts stop at the first direct-text or paste key, so they already mean "before other typing". Forward Delete never counts, and a commit whose `character_count` is NULL or 0 can only be reverted by Cmd+Z, so a zero threshold never makes every commit a revert. `revert_rate = reverted_commits / commits_with_window`, null for a zero denominator and never 0%, with `revert_wilson_low` / `revert_wilson_high` in `trend`. A commit is counted once, from `commits` and `windows`, whatever the number of decisions that link to it; `observations` is not used because it repeats a commit's window on every decision that links to it. The window rides the composition that follows its commit, which may start after `--until` and is still read. The instrument constants of C-rev, versioned with it, are `W` (`QualityLimits.postCommitWindowSeconds`, 10 s) and the deletion threshold, the commit's `character_count`. `commit_windows` and `windows_by_end` of `summary` count the windows of every kind of commit and are not this denominator |

### Learning effectiveness

`summary` reports the `effectiveness_events` under `learning_effectiveness`, separate from candidate
accuracy. Voice finalized sessions are the correction-detection denominator, detected
corrections are the learning denominator, exact alias matches are the alias-reuse
denominator, and deduplicated personal-exact opportunities are the canonical-reuse
denominator. Rejection counts are grouped only by the closed reason label.
Learning acts are plain counts under `candidate_learning`, with no rate: `forgotten`
for Shift+Backspace on shown candidates, and `deleted` and `restored` for English
entries in Settings. Voice-alias deletions are not recorded.
Unavailable denominators return `null`; candidate-specific filters make this section
unavailable because effectiveness events deliberately carry no candidate identity.

## Text-free records

Records are text-free by default. Ranks, indices, text kinds, timing, the character counts of the chosen and committed
text, the candidate facts (`type`, `corrected`, `evidence`) and the keyed pair hashes (`codeHash`, `textHash`) are kept;
raw input, input before deletion, candidate text, chosen text and preceding context are empty or null, and each page
carries `textCaptured: false`.

- `trend`, `summary` and `timing` work unchanged: Top1 match uses the chosen display rank, and the selected-length
  buckets use the kept counts of records written by schema v4, so only older text-free records land in
  `length_unavailable`.
- `ranking-issues` and the text fields of `inspect` only cover records saved while 「同时保存输入文本」 was on.
  `coverage.text_free` counts the excluded decisions.

## Coverage limits

Only visited pages and decision snapshots are retained; unseen candidates are not enumerated.
Tentative segments become committed only through verified final paths. Undo can
mark a decision reverted; ambiguous edits and interruptions remain explicit.

One serialized utility worker writes SQLite using DELETE rollback journaling.
The event path only submits bounded in-memory envelopes; it performs no SQL,
filesystem I/O, JSON encoding or disk waiting. Event data has a 64 KiB budget;
unique applied configurations within each envelope have a separate 256 KiB budget,
including input options and configurations carried by reference-only pages. Equal
values under the same revision ID share Swift copy-on-write storage after validation.
These are conservative logical retained-byte limits, not measurements of process RSS.
At most 128 envelopes and 8 MiB of total logical bytes may be pending or in flight;
the accepted byte charge is released only when its batch finishes or fails.
Configuration overflow is checked before history trimming; conflicts are invalid
evidence. Event overflow removes history first, then drops an oversized core. The
worker separately checks compact event and unique configuration encoded-byte limits
before persistence, including JSON escaping growth. Batches contain at most 16 envelopes
or flush on a 1-second timer, atomically writing referenced revisions/composition/
decisions/commits. Busy writes wait up to 250 ms on the worker, then roll back/drop.
Fatal FULL/CORRUPT/IO errors disable recording for that run; persistence of the
error itself is best effort. Abrupt exit can lose the asynchronous tail.

`recording_runs.scope=whole_db_lifetime_unfiltered` applies to every recorder
counter/status displayed by summary, regardless of date/app/config/kind filters.
The totals combine persisted cumulative counters from **all runs in the DB**.
They cannot allocate drops to a filtered event cohort, prove complete capture, or
provide an exact filtered drop denominator. A fatal failure may leave the last
durable status as running. Recorder statistics are coverage context, not a monitor.
