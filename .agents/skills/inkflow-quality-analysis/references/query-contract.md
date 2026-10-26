# Recorded quality query contract

Commands, filters, output fields, the stored record format and the exchange files of `scripts/quality.py`. How to read
a result (denominators, cohorts, measurement fingerprints, unavailable evidence, coverage limits) is in
[interpretation](interpretation.md).

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
  `trend`, their rates without intervals, `unknown_fingerprint_compositions` and `composition_rate_status` (see [composition and commit counters](interpretation.md#composition-and-commit-counters));
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
  denominator (exact cohorts: [interpretation](interpretation.md#denominators-and-ranking-evidence)), a rate in [0,1] and null for a zero denominator. On every point and in every
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
  Grouping and caveats: [interpretation](interpretation.md#denominators-and-ranking-evidence).
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
  every record from before the candidate facts (#129) does), `without_first_page` (paged decisions whose first page is
  missing or of another generation, which have no list to replay), `reverted_relabelled` and `reverted_excluded`
  (below). A case carries `composition_id`, `decision_id`, `occurred_at`, `raw_input`, `preceding_context`, `page`,
  `candidates_from`, `candidates` in displayed order (each with `text`, `display_index`, `native_index`, `native_rank`,
  `type`, `corrected`, `evidence` and `source`), `selected_display_index`, `selected_text`, `committed_text` and
  `relabelled`. A case takes its candidates from `snapshot_json` when the snapshot `page` is 0 and from the
  same-generation `first_page_json` when the user paged (`candidates_from`); `selected_display_index` always indexes
  the snapshot. `selected_text` is the segment gold, conditioned on the list the user saw, and `committed_text` the
  text of the decision's linked commit, the gold for the whole input. A decision whose commit is reverted by the
  C-rev rule (see `revert_rate` in [composition and commit counters](interpretation.md#composition-and-commit-counters))
  is no gold: it is relabelled with its retype when all of these hold, and
  counted in `reverted_excluded` and left out otherwise. The revert is exact and alone: no Cmd+Z,
  `leading_deletions = character_count`, no other key in the window, which ended `next_code`. The decision is the
  only one linked to its commit. The retype is the composition that carries the window: it has one decision and one
  commit, the decision is regular and committed and its commit is not reverted in turn. Its raw input equals or
  extends the reverted one (a shorter one may be half of a split retype), and its `selected_text` is on the case's
  candidate list. A relabelled case (`relabelled: true`, counted in `reverted_relabelled`) takes the retype's
  `selected_text`, its commit text as `committed_text` and its index on the case's list as
  `selected_display_index`; it keeps its own raw input and list. Decisions without a window are kept as recorded,
  so the rule only reaches records with post-commit windows (v0.7.3 on): a reverted choice in older records still
  counts as gold. `without_evidence` counts exported cases only. The file holds typed text: the path must be
  outside the repository and new, and the file is owner-only. The `replay` binary scores it; see
  [Replay](../../../../Core/Portable/README.md#replay), and its
  [replay files](../../../../Core/Portable/README.md#replay-files) for how to handle the file.
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
  without raw typed text. Scope and units: [Input timing](#input-timing).

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

JSON is a nested object with `command`, `filters` and command data. Table output is
a vertical `FIELD | VALUE` table, retaining complete fingerprints and escaped
text without truncation. CSV is a lossless long form with `path,value` columns;
paths identify nested fields/array positions and each value is a JSON scalar or
empty collection. Null is `null` in JSON/CSV and `N/A` in tables. Rates are fractions
in [0,1], not percentages. Empty groups/lists are valid.

Every command returns `identity_coverage`. Each layer reports known references,
unknown references, distinct known identities, and a complete lexically ordered
identity/count list whose `unknown` entry represents NULL. For `summary` and
`ranking-issues`, the unit is each filtered decision. For `timing`, it is every
decision in the selected timing-composition cohort because timing itself is read
once for each whole selected composition. For `inspect`, it is each unique returned
configuration revision, including revisions referenced only by retained pages.

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

## Storage and record format

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

New page JSON stores `configurationRevisionID` and omits the repeated
`configuration` payload. `configurations` in inspect resolves every retained page
reference. Legacy full page JSON remains readable after its database is migrated to v4;
compact Swift decoding requires an explicit revision map and fails for missing or
conflicting configuration evidence. No defaults or database migration are used.

Capture snapshots preserve raw code/caret, validated selected prefix, used preceding
context, generation, applied settings, actual page size/page, display/native
candidate mapping and highlight before mutation. Generation survives navigation
but changes with input/caret/prefix/context/applied configuration.
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

Pair identity: a decision with a known pair carries `snapshot.codeHash` and, on that selected candidate only,
`textHash`, in both text modes (no schema change). Derivation, device key and privacy trade-off:
[Pair hashes](../../../../macOS/QUALITY-EXPORT.md#pair-hashes).

## Manual exchange

Exporting and cross-device joint analysis (export file format v1, the repeatable `--input`, `--exports-only` and `--source` flags, source identity and validation rules) are specified in [quality export and joint-analysis contract](../../../../macOS/QUALITY-EXPORT.md).
