# Recorded quality query contract

## CLI and output

The entrypoint is `scripts/quality.py`, relative to this skill. It uses stdlib
`sqlite3`, opens an encoded file URI with `mode=ro`, enables `query_only`, and
closes a single command's consistent read transaction before rendering. It never
creates or migrates a local database. Joint analysis of `--input` exports builds
only an ephemeral in-memory database and indexes; it never writes the daily database. Queries aggregate
history in SQLite; `inspect` reads only one composition's records. A busy or damaged
database returns a diagnostic and exit 2. Success, including an empty compatible
database or empty filter result, exits 0. Help is available at each command.

- `summary`: pooled raw coverage counts, separate ranking-fingerprint/measurement-
  fingerprint/text-kind/presentation groups, exact displayed-rank counts, identity
  coverage, and separately scoped recorder statistics. `coverage` carries the composition and commit counters of
  `trend`, their rates without intervals, `unknown_fingerprint_compositions` and `composition_rate_status` (below);
  `coverage` and every group carry the decision counters and rates of the scorecard.
- `trend`: the primary routine-report command. It returns a continuous local-calendar
  series, recomputed 7-day and 28-day rolling metrics, output-kind series, version
  markers and identity coverage. `--days` defaults to 28. `--chart PATH` writes a
  self-contained SVG without modifying the database. Every daily and rolling point also carries
  the 95% Wilson score interval of its top-1, top-3 and paged rates (`top1_wilson_low`,
  `top1_wilson_high` and so on; null when the rate is null), `paged_selected` and `paged_rate`
  (known-rank decisions whose snapshot `page` is above 0, over `known_rank`), and
  `by_selection_length`: the same counters, rates and intervals for selected texts of 1, 2 and
  3 or more characters (Unicode scalar values), in either text mode. A decision written by schema v4
  or later has `selected_character_count`; an older text-mode decision falls back to the length of
  its selected text. `length_unavailable` counts the known-rank decisions with no length (an older
  text-free decision, or a zero count) beside the buckets, so the bucket `known_rank` values plus
  `length_unavailable` equal `known_rank`. `text_free` counts the known-rank text-free decisions.
  The scorecard of `docs/input-quality-metrics.md` rides the same points as summed counters, each rate with its exact
  denominator (see the tables below), a rate in [0,1] and null for a zero denominator. On every point and in every
  `by_selection_length` bucket: `onekey_selected`, `onekey_rate` (E-onekey); `misses`, `learned_misses`,
  `misses_with_provenance`, `learned_miss_share` (the L-avoid interim proxy); `learned_leader`,
  `learned_leader_missed`, `learned_leader_miss_rate`, `dictionary_leader`, `dictionary_leader_missed`,
  `dictionary_leader_miss_rate` (L-over); and the 95% Wilson interval of each of those proportions as
  `onekey_wilson_low` / `_high`, `learned_miss_wilson_*`, `learned_leader_miss_wilson_*` and
  `dictionary_leader_miss_wilson_*`. On every point and in no bucket: `code_compositions`, `cancelled_compositions`,
  `edited_compositions`, `regular_committed_compositions`, `regular_decisions`, `kspc_compositions`,
  `kspc_keypresses`, `kspc_characters`, `kspc_text_free_compositions`, `candidate_commits`, `raw_return_commits`,
  `commits_with_window`, `reverted_commits`, and the rates `cancel_rate` (C-cancel), `preedit_edit_rate` (C-pre),
  `raw_commit_rate` (C-raw) and `revert_rate` (C-rev), each with `cancel_wilson_*`, `preedit_edit_wilson_*`,
  `raw_commit_wilson_*` and `revert_wilson_*`, `decisions_per_composition` (E-dec, a mean) and `kspc` (E-kspc, keys per
  committed character), which have no interval.
  Composition and commit counters are grouped by the local day of the composition's `started_at`, the composition kind
  and its measurement fingerprint, and the trend keeps the latest fingerprint as it does for decisions. The three
  rates over compositions without a kind, `cancel_rate`, `preedit_edit_rate` and `raw_commit_rate`, are computed in the
  `overall` series only and are null in every kind series; with `--kind` every composition and commit rate but
  `revert_rate` is null and the counters stay (the filter keeps compositions with a matching decision, so cancels and
  raw Returns drop out). `revert_rate` is reported in `overall`, in every kind series and under `--kind`, because a
  `candidate` commit always belongs to a composition with decisions, so its kind is known and the filter keeps the
  whole population of C-rev; it is null only for a status that is not available or a zero denominator.
  `metric_scope` also reports `included_compositions`, `excluded_compositions` and `excluded_unknown_compositions`.
- `ranking-issues`: coverage plus recurring chosen-text/first-page-top1 differences.
  Defaults `--min-count 3 --limit 50`; both accept positive integers.
- `inspect COMPOSITION_ID`: composition, selected decisions, all its commits, the
  post-commit `windows` of those commits, and
  all four layered identities plus the legacy fingerprint, decoded applied
  configuration, raw build metadata, engine version and metric-rule version for
  those decisions and every referenced
  first/visited page, even when that page uses a different configuration. Stored `*_json` fields
  become decoded objects without that suffix. Candidate source and consumed spans
  remain absent/null when unavailable. It does not infer them.
- `replay-cases --output FILE`: one JSON Lines case per regular committed decision (the `regular_committed` cohort
  of `observations`) in the filter window, `--kind` defaulting to `chinese`, with the shared filters and `--input`.
  The first line is a header with `generated_at`, `window`, `kind` and the counts `cases`, `text_free_excluded`
  (decisions recorded without text), `without_evidence` (cases with a candidate that lacks its `evidence` row, as
  every record from before the candidate facts) and `without_first_page` (paged decisions whose first page is
  missing or of another generation, which have no list to replay). A case takes its candidates from
  `snapshot_json` when the snapshot `page` is 0 and from the same-generation `first_page_json` when the user
  paged (`candidates_from`); `selected_display_index` always indexes the snapshot. `selected_text` is the segment
  gold and `committed_text` the text of the decision's linked commit. The file holds typed text: the path must be
  outside the repository and new, and the file is owner-only. The `replay` binary scores it; see
  [Replay and the first-choice target](../../../../Core/Portable/README.md#replay-and-the-first-choice-target).
- `learning`: the L family over pair identities (design: `docs/input-quality-metrics.md` section 6), for
  known-rank regular committed decisions that carry a `pair_id`, ordered by composition start, decision time and
  sequence. It takes the shared filters (`--kind` defaults to all kinds), `--input` and `--days` (default 28, a window
  derived like `trend`, so `--since` is refused), selects the latest known measurement cohort as `trend` does and
  reports the exclusions: `metric_scope` (`excluded_decisions`, `excluded_unknown_decisions`) and `pair_coverage`
  (`pair_identity` and `pair_unavailable` inside the cohort, and `text_without_hash`, the text-mode rows among them
  with a literal pair but no hash, which is every text record written before pair hashes existed). Hashes are keyed per
  device and never link across devices, so `learning` never pools sources: with more than one source among the combined
  inputs and no `--source` it fails with exit 2. A **miss** is `display_rank > 1` (every paged choice included), a **hit**
  is `display_rank = 1`; truth T1. Every rate carries `numerator`, `denominator`, `rate`, a 95% Wilson interval and a
  `status`: `no_verdict_below_200_units` under 200 units, else `available`; the rate is null for an empty denominator.
  - `l_ttl` (unit pair): over pairs whose first decision in the window is a miss, `histogram` of the selections before
    the pair's first hit (`1`, `2`, `3+`, and `never` for pairs with no hit in the window, right-censored),
    `median_selections_to_learn` over the learned pairs and `learned_after_one_rate`.
  - `l_futile` (pair): `futile_rate`, pairs with at least 3 decisions that are all misses over pairs with at least 3.
  - `l_util` (pair): over pairs with a hit, the run of consecutive hits from the first hit to the next miss
    (`median_hits_until_regression` over regressed pairs; pairs still at rank 1 at the window end are counted in
    `pairs_censored_at_window_end`) and `regression_rate`.
  - `l_avoid` (decision): `avoidable_miss_rate`, misses whose pair has an earlier decision in the window at any rank,
    and beside it the interim proxy `learned_provenance_miss_rate`, misses whose selected candidate has learned
    provenance, `type = 'user_phrase' OR type LIKE 'english_personal_%' OR type LIKE 'mixed_personal_%'`.
  - `l_reuse` (word, identified by `selected_text_hash`): `reuse_rate`, words first chosen in days 1-14 of the window
    that are chosen again in days 15-28; null with `status: needs_28_day_window` unless `--days` is 28.
  - `first_seen_within_7_days_share` (pairs whose first decision is in the first 7 days of the window, over pairs)
    sits in `l_ttl` and `l_avoid`: a pair first seen early may have been learned before the window. Nothing is excluded.
  - `instrument_constants` lists what the rule versions: 28-day window, 7-day censoring margin, 3 selections for
    futile, 14 + 14 day reuse split, the 200-unit minimum, the learned-provenance predicate, the code normalization, the
    128-bit truncation with the `code:` and `text:` prefixes and the `pair_id` composition.
- `timing`: composition-level timing coverage, retained adjacent-key intervals,
  ended/unfinished wait and visible-duration distributions, plus identity coverage,
  without raw typed text.

`--db PATH` defaults to the current user's existing InkFlow data directory,
`~/Library/Application Support/InkFlow/quality.sqlite3`. `--app` is an exact bundle
ID, `--ranking-config` an exact ranking fingerprint, `--config` the exact legacy
full fingerprint, and `--kind` a decision's recorded text kind: chinese, english,
emoji, mixed, symbol, number, other or unknown. `--config` retains its historical
meaning and does not silently alias the ranking fingerprint. All filter values are
bound SQL parameters; no prefix/substring matching is implied.

`--since` is inclusive and `--until` exclusive, both on **composition.started_at**.
`YYYY-MM-DD` means midnight in the process's local timezone, including that date's
DST rules. Timestamp input must have `Z` or an explicit offset, e.g.
`2026-09-07T00:00:00+08:00`. The writer stores UTC ISO timestamps to milliseconds.
Finer boundaries are rounded upward to the next stored millisecond, preserving
inclusive/exclusive comparisons against that storage precision. All-time is the
default; `--until 2026-09-08` includes local September 7.

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
metric definitions into its rates. User-facing reports call this the statistical
rule or `统计口径`; the underlying measurement fingerprint is diagnostic metadata.

JSON is a nested object with `command`, `filters` and command data. Table output is
a vertical `FIELD | VALUE` table, retaining complete fingerprints and escaped
text without truncation. CSV is a lossless long form with `path,value` columns;
paths identify nested fields/array positions and each value is a JSON scalar or
empty collection. Null is `null` in JSON/CSV and `N/A` in tables. Rates are fractions
in [0,1], not percentages. Empty groups/lists are valid. Pooled coverage is a
whole-filter description; configuration or text-kind comparisons use the separate
groups rather than treating the pooled rate as a causal quality score. Pooled raw
counts remain available, but `top1_rate`, `top3_rate` and `top1_match_rate` are null unless the
entire pooled cohort has exactly one known measurement fingerprint. The adjacent
`quality_rate_status` says whether rates are available, cross-measurement,
unknown-measurement, or without measurement evidence. Each known single-measurement
group computes its own rates; an `unknown` measurement group never does.

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

A zero denominator yields null/N/A, never 0%. `rank_counts` enumerates each exact
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

## Storage, identity and coverage limits

Schema v4 has application ID `0x49465131` (IFQ1). The query requires v4, checks the
identity, required columns and exact six table names, and accepts measurement
cohorts distinguished by their persisted fingerprints. A v1 database must first be
migrated by the writer; v2 is migrated by the writer by adding the effectiveness
table, and v3 by adding two columns, `commits.character_count` and
`candidate_decisions.selected_character_count`, which stay NULL on rows written before v4. The query never creates or migrates a database. Foreign, malformed
or unknown schemas are not repaired or reset. The canonical writer/models are
`Core/Sources/InkFlowRime/QualityStore.swift` and `QualityRecords.swift`; query fixture tests
extract their current DDL and full acceptance verifies actual engine-written DDL.

| Table | Role |
| --- | --- |
| compositions | Separate ID, run, start/end, app/client, outcome/reason, full operation totals, history truncation |
| candidate_decisions | ID and sequence, composition/config/commit links, trigger/outcome, selected text/index/kind, selected character count, custom flag, unknown/path reasons, operations, pre-action/first-page/visited-page JSON |
| commits | Separate ID, same-composition link, time, text, character count, kind, insertion issuance and client |
| config_revisions | Capture UUID, legacy stable fingerprint, ranking/settings/measurement/build identities, applied config, build/resource metadata, engine and metric-rule versions |
| recording_runs | Writer lifetime, engine/build identity, status/error and best-effort cumulative counters |
| effectiveness_events | Content-free time, closed source/event/rejection labels (`candidate_learning` for learning acts), bounded count and optional bounded milliseconds; no input, transcript, correction, candidate or document text |

Summary reports these events under `learning_effectiveness`, separate from candidate
accuracy. Voice finalized sessions are the correction-detection denominator, detected
corrections are the learning denominator, exact alias matches are the alias-reuse
denominator, and deduplicated personal-exact opportunities are the canonical-reuse
denominator. Rejection counts are grouped only by the closed reason label.
Learning acts are plain counts under `candidate_learning`, with no rate: `forgotten`
for Shift+Backspace on shown candidates, and `deleted` and `restored` for English
entries in Settings. Voice-alias deletions are not recorded.
Unavailable denominators return `null`; candidate-specific filters make this section
unavailable because effectiveness events deliberately carry no candidate identity.

New page JSON stores `configurationRevisionID` and omits the repeated
`configuration` payload. `configurations` in inspect resolves every retained page
reference. Legacy full page JSON remains readable after its database is migrated to v4;
compact Swift decoding requires an explicit revision map and fails for missing or
conflicting configuration evidence. No defaults or database migration are used.

Capture snapshots preserve raw code/caret, validated selected prefix, used preceding
context, generation, applied settings, actual page size/page, display/native
candidate mapping and highlight before mutation. Generation survives navigation
but changes with input/caret/prefix/context/applied configuration. Only visited
pages and decision snapshots are retained; unseen candidates are not enumerated.
Tentative segments become committed only through verified final paths. Undo can
mark a decision reverted; ambiguous edits and interruptions remain explicit.
Candidate text kind describes output, and matches_custom_phrase is equality with
the applied custom-phrase configuration, not translator/source provenance. The
engine records provenance itself, per candidate, from the ranking evidence row it
computed for the page: `type` (Rime's candidate type of the genuine candidate, such
as `phrase`, `user_phrase`, `sentence`, `completion`, `user_table` or the personal
English and mixed types such as `english_personal_2`; empty when it is not lowercase
letters, digits and underscores starting with a letter or underscore, at most 32
bytes), `corrected` (the dictionary syllables of the candidate's own code, joined,
differ from the letters typed for its span with spaces and apostrophes removed, so a
fuzzy or algebra rule reached it; an abbreviation such as `nh` for 你好 counts; there
is no syllable-count limit; always false for `completion` and for candidates that are
not Rime phrases of the pinyin dictionary, such as the English and mixed modules' own)
and `evidence` (the row `start,end,class,exact,personal,source,type,corrected`, which
`parse_metadata` reads, with the covered span in raw-input bytes). These fields are
content-free, so text-free records keep them. They exist only on candidates the
engine ranked: no selected prefix, no custom-phrase code match, at most nine
candidates and a readable reply. Records from before they were added, and
other candidates, omit all three. `source` and the consumed-input span stay limited
to learned English and mixed candidates. The engine reads no candidate comment for
these facts and writes no spelling comment, so text-captured records carry none.

Pair identity: a decision whose selected index points at a candidate and whose snapshot has no selected prefix also
carries `snapshot.codeHash` and, on that selected candidate only, `textHash`, in both text modes (no schema change).
Each is the first 128 bits (32 lowercase hex characters) of HMAC-SHA256 under the device key, over `code:` plus the
code, or `text:` plus the candidate text. The code is the span the selected candidate consumed, the raw-input bytes
`[start, end)` named by the first two fields of its `evidence` row, lowercased with apostrophes removed; a custom phrase
chosen without an `evidence` row uses the whole input. Any other decision without an `evidence` row has no known span
and no hash. The key is 32 bytes in `quality-pair-key` beside the database and is never exported, backed up or recorded,
so hashes from different devices never match and exports carry only opaque values. Clearing the records replaces the
key; older records then no longer match newer ones. Records written before this field existed, in either mode, have none.

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

Every command returns `identity_coverage`. Each layer reports known references,
unknown references, distinct known identities, and a complete lexically ordered
identity/count list whose `unknown` entry represents NULL. For `summary` and
`ranking-issues`, the unit is each filtered decision. For `timing`, it is every
decision in the selected timing-composition cohort because timing itself is read
once for each whole selected composition. For `inspect`, it is each unique returned
configuration revision, including revisions referenced only by retained pages.

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

## Input timing

`timing` uses `compositions.operations_json.timing` once per matching composition,
never the copies in decision snapshots. Existing date/app/config/ranking-config/kind filter
semantics apply: decision filters select compositions with at least one matching
decision, then the whole matching composition's timing is included. No timing
field or unsupported version means unavailable evidence, not a zero duration.
Coverage reports missing/unsupported timing, ended versus unfinished snapshots,
truncated compositions, dropped keys and retained key counts. Existing commands
retain their result-format contract, while database compatibility is strictly v4.

All timing units are **seconds**. `key_intervals.all` and category/repeat groups
use the stored interval of each retained key, including navigation and finishing
keys such as AI Tab. The first interval is null. Capture retains the first 255
keys and latest key (maximum 256); after truncation the latest interval still uses
the actual preceding physical key, not the preceding array element. Distributions
are explicitly retained-samples-only and do not reconstruct omitted keys.

`postEditWait` spans the last actual edit through the captured end. Continued
typing, backspace and effective caret edits restart it; navigation does not.
`observedVisibleDuration` accumulates only observed visible intervals after that
edit, excluding hidden time. Partial selection starts a remaining-input phase:
`phaseWait` and `phaseObservedVisibleDuration` measure that phase without resetting
the whole-last-edit metrics. Ended snapshots have `endedOffset`; unfinished
snapshots are reported separately as observations, not final selection waits.
Missing visibility evidence stays null independently of a known wait.

P50/P95 use sorted known observations with linear interpolation at `(n-1)*p`,
reporting known and unknown counts. Timing uses controller keyDown callback entry
and a monotonic clock, not hardware event timestamps. Native visibility is observed
at key/refresh boundaries and nominal 100 ms polling. The recorded observation
interval is precision context, not an exact render timestamp or human attention.
Direct engine fixtures may record key timing without any visibility observations.
Individual `inspect` already exposes the persisted timing object for detailed
evidence. The AI sample expiry policy does not change ordinary quality retention.


## Manual exchange

Exporting and cross-device joint analysis (export file format v1, the repeatable `--input`, `--exports-only` and `--source` flags, source identity and validation rules) are specified in [quality export and joint-analysis contract](../../../../macOS/QUALITY-EXPORT.md).
