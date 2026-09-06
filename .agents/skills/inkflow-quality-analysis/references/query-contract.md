# Recorded quality query contract

## CLI and output

The entrypoint is `scripts/quality.py`, relative to this skill. It uses stdlib
`sqlite3`, opens an encoded file URI with `mode=ro`, enables `query_only`, and
closes a single command's consistent read transaction before rendering. It never
creates a database, migrates schemas, or writes analysis indexes. Queries aggregate
history in SQLite; `inspect` reads only one composition's records. A busy or damaged
database returns a diagnostic and exit 2. Success, including an empty compatible
database or empty filter result, exits 0. Help is available at each command.

- `summary`: pooled coverage counts, separate fingerprint/text-kind/presentation
  groups, exact displayed-rank counts, and separately scoped recorder statistics.
- `ranking-issues`: coverage plus recurring chosen-text/first-page-top1 differences.
  Defaults `--min-count 3 --limit 50`; both accept positive integers.
- `inspect COMPOSITION_ID`: composition, selected decisions, all its commits, and
  applied configuration/build metadata for those decisions. Stored `*_json` fields
  become decoded objects without that suffix. Candidate source and consumed spans
  remain absent/null when unavailable. It does not infer them.

`--db PATH` defaults to the current user's existing InkFlow data directory,
`~/Library/Application Support/InkFlow/quality.sqlite3`. `--app` is an exact bundle
ID, `--config` an exact full fingerprint, and `--kind` a decision's recorded text
kind: chinese, english, emoji, mixed, symbol, number, other or unknown. All filter
values are bound SQL parameters; no prefix/substring matching is implied.

`--since` is inclusive and `--until` exclusive, both on **composition.started_at**.
`YYYY-MM-DD` means midnight in the process's local timezone, including that date's
DST rules. Timestamp input must have `Z` or an explicit offset, e.g.
`2026-09-07T00:00:00+08:00`. The writer stores UTC ISO timestamps to milliseconds.
Finer boundaries are rounded upward to the next stored millisecond, preserving
inclusive/exclusive comparisons against that storage precision. All-time is the
default; `--until 2026-09-08` includes local September 7.

Config/kind filters select matching decisions and compositions containing at
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
groups rather than treating the pooled rate as a causal quality score.

## Denominators and ranking evidence

The following counts are available overall and per full configuration fingerprint,
text kind and current pre-decision presentation. Outcome counts include every
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

Issue groups use the full fingerprint, raw input **and caret**, selected prefix and
validity, preceding context actually used, first-page top1, chosen text, text kind
and custom-phrase-match flag. Distinct revision UUIDs with the same fingerprint can
group together. Only comparable choices differing from first-page top1 enter the
list. Occurrences count decisions, with mean display/native ranks and separate
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

Schema v1 has application ID `0x49465131` (IFQ1). The query checks identity, required
columns, the five table names and metric rule v1. Foreign/malformed/unknown schemas
are not repaired or reset. The canonical writer/models are
`macOS/Sources/QualityStore.swift` and `QualityRecords.swift`; query fixture tests
extract their current DDL and full acceptance verifies actual engine-written DDL.

| Table | Role |
| --- | --- |
| compositions | Separate ID, run, start/end, app/client, outcome/reason, full operation totals, history truncation |
| candidate_decisions | ID and sequence, composition/config/commit links, trigger/outcome, selected text/index/kind, custom flag, unknown/path reasons, operations, pre-action/first-page/visited-page JSON |
| commits | Separate ID, same-composition link, time, text, kind, insertion issuance and client |
| config_revisions | Capture UUID, stable fingerprint, applied config, build/resource metadata, engine and metric-rule versions |
| recording_runs | Writer lifetime, engine/build identity, status/error and best-effort cumulative counters |

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

The worker fingerprints applied settings, actual build/source/resource identity,
engine version and metric-rule version. Revision UUIDs are capture-time identity,
not a ranking version. Build metadata records source revision/tree digest/dirty
state and actual bundled-resource digest; unavailable metadata stays unknown.
Personalization/user dictionaries remain mutable and are not frozen by a
fingerprint, so identical fingerprints do not establish identical learned state.

One serialized utility worker writes SQLite using DELETE rollback journaling.
The event path only submits bounded in-memory envelopes; it performs no SQL,
filesystem I/O, JSON encoding or disk waiting. Active and queued envelopes have a
64 KiB budget, with at most 128 including in-flight envelopes. History is removed
first; oversized core drops the entire record. Batches contain at most 16 envelopes
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
