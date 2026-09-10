# Recorded quality query contract

## CLI and output

The entrypoint is `scripts/quality.py`, relative to this skill. It uses stdlib
`sqlite3`, opens an encoded file URI with `mode=ro`, enables `query_only`, and
closes a single command's consistent read transaction before rendering. It never
creates a database, migrates schemas, or writes analysis indexes. Queries aggregate
history in SQLite; `inspect` reads only one composition's records. A busy or damaged
database returns a diagnostic and exit 2. Success, including an empty compatible
database or empty filter result, exits 0. Help is available at each command.

- `summary`: pooled raw coverage counts, separate ranking-fingerprint/measurement-
  fingerprint/text-kind/presentation groups, exact displayed-rank counts, identity
  coverage, and separately scoped recorder statistics.
- `ranking-issues`: coverage plus recurring chosen-text/first-page-top1 differences.
  Defaults `--min-count 3 --limit 50`; both accept positive integers.
- `inspect COMPOSITION_ID`: composition, selected decisions, all its commits, and
  all four layered identities plus the legacy fingerprint, decoded applied
  configuration, raw build metadata, engine version and metric-rule version for
  those decisions and every referenced
  first/visited page, even when that page uses a different configuration. Stored `*_json` fields
  become decoded objects without that suffix. Candidate source and consumed spans
  remain absent/null when unavailable. It does not infer them.
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

JSON is a nested object with `command`, `filters` and command data. Table output is
a vertical `FIELD | VALUE` table, retaining complete fingerprints and escaped
text without truncation. CSV is a lossless long form with `path,value` columns;
paths identify nested fields/array positions and each value is a JSON scalar or
empty collection. Null is `null` in JSON/CSV and `N/A` in tables. Rates are fractions
in [0,1], not percentages. Empty groups/lists are valid. Pooled coverage is a
whole-filter description; configuration or text-kind comparisons use the separate
groups rather than treating the pooled rate as a causal quality score. Pooled raw
counts remain available, but `top1_rate` and `top1_match_rate` are null unless the
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
| known_rank | valid with selected_display_index pointing to the exact matching selected text and consistent global display rank |
| unknown_rank | valid minus known_rank; missing/ambiguous/mismatched rank evidence |
| comparable | known_rank with validated selected prefix and a matching-generation first-page snapshot with actual first candidate |
| first_page_unavailable | known_rank minus comparable; absent, mismatched or invalid-prefix first-page evidence |
| top1_selected / top1_rate | Known displayed rank 1 count / known_rank |
| top1_matches / top1_match_rate | Selected text equals actual first-page top1 count / comparable |
| mean_display_rank | Mean among known_rank |
| mean_native_rank | Mean of available, internally consistent native ranks among known_rank |
| truncated / dropped_page_count | Filtered decision history flags and removed snapshot-history entries |

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
together. Only comparable choices differing from first-page top1 enter the list.
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

## Storage, identity and coverage limits

Schema v2 has application ID `0x49465131` (IFQ1). The query requires v2, checks the
identity, required columns and exact five table names, and accepts measurement
cohorts distinguished by their persisted fingerprints. A v1 database must first be
migrated by the writer; the query never creates or migrates it. Foreign, malformed
or unknown schemas are not repaired or reset. The canonical writer/models are
`macOS/Sources/QualityStore.swift` and `QualityRecords.swift`; query fixture tests
extract their current DDL and full acceptance verifies actual engine-written DDL.

| Table | Role |
| --- | --- |
| compositions | Separate ID, run, start/end, app/client, outcome/reason, full operation totals, history truncation |
| candidate_decisions | ID and sequence, composition/config/commit links, trigger/outcome, selected text/index/kind, custom flag, unknown/path reasons, operations, pre-action/first-page/visited-page JSON |
| commits | Separate ID, same-composition link, time, text, kind, insertion issuance and client |
| config_revisions | Capture UUID, legacy stable fingerprint, ranking/settings/measurement/build identities, applied config, build/resource metadata, engine and metric-rule versions |
| recording_runs | Writer lifetime, engine/build identity, status/error and best-effort cumulative counters |

New page JSON stores `configurationRevisionID` and omits the repeated
`configuration` payload. `configurations` in inspect resolves every retained page
reference. Legacy full page JSON remains readable after its database is migrated to v2;
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
the applied custom-phrase configuration, not translator/source provenance. The raw
engine API does not provide reliable candidate source or consumed-input spans.

The worker persists four independent identities. `ranking_fingerprint` covers the
engine, audited offline ranking source/resources, and ranking-affecting applied
settings; it is the default quality grouping key. `settings_fingerprint` covers the
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
retain their result-format contract, while database compatibility is strictly v2.

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
