---
name: inkflow-quality-analysis
description: Review InkFlow's locally recorded input quality with 7-day or 28-day calendar trends, rolling metrics, version annotations, charts, recurring candidate choices, and composition evidence. Use for recorded quality evidence, not ranking changes or live input diagnosis.
---

# InkFlow Quality Analysis

Use the [query script](scripts/quality.py). It uses Python's standard
library and defaults to `~/Library/Application Support/InkFlow/quality.sqlite3`.
Use `python3` from `PATH`; no dependency setup is needed. Run commands from this
repository root, or use the script's absolute path.

```sh
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
python3 "$query" trend --days 7 --chart /tmp/inkflow-quality-7d.svg --format json
python3 "$query" trend --days 28 --chart /tmp/inkflow-quality-28d.svg --format json
python3 "$query" summary --format json
python3 "$query" ranking-issues --format json
python3 "$query" inspect COMPOSITION_ID --format json
python3 "$query" timing --format json
```

For a routine quality review, use `trend`. Default to 7 days for a short operational
check and 28 days for a broader review. Present the SVG chart and summarize Top1 and
Top3 selection rates for daily, 7-day rolling and 28-day rolling windows. Both rates
share the same validated known-display-rank denominator; Top3 means display rank 1–3.
Keep generated charts in a task-owned
temporary directory unless the user requests a durable artifact.

Calendar date is the primary statistical axis. App versions are annotations at
their first observed input time and are attribution clues, not cohort boundaries or
causal proof. Do not split routine metrics by ranking, settings or build fingerprint.
Use fingerprints only for forensic filtering or integrity diagnosis. A measurement
fingerprint is the internal identifier for a statistical-rule version and remains a
hard compatibility boundary because the denominator meaning may change. In user-facing
reports call this the “metric definition” or “统计口径”, not “measurement identity”;
never publish a combined rate across measurement fingerprints.

Use `summary` for detailed coverage or forensic identity inspection. For repeatedly choosing another
candidate over first-page top1, use `ranking-issues` (default at least 3 occurrences,
50 groups). For a concrete example, use an issue's `composition_ids` with `inspect`;
use `--min-count 1` when the user requests individual cases. Read
[the query contract](references/query-contract.md) before interpreting rates,
comparing configurations, investigating incomplete evidence, or changing queries.

Use `timing` for composition-level key intervals, last-edit waits and observed
candidate visibility. It has no raw input text and does not multiply timing by
decision count. Old or suppressed timing remains unknown; bounded key distributions
cover retained samples only.

For manual cross-device analysis, add repeatable `--input /path/to/export.json` to
any analysis command. Local records participate by default; `--exports-only` uses
only the supplied files. Use `--source UUID` to isolate one device. Joint results
include deduplicated `sources` and `by_source` results with the same metric rules.
`inspect` uses the namespaced composition IDs returned by `ranking-issues`.
Imports remain in memory and never enter the local quality database. Reject
incompatible/damaged or conflicting inputs; never report partial pooled counts.
Read [export and joint-analysis usage](../../../macOS/QUALITY-EXPORT.md) for the
versioned file contract, privacy scope, retention and two-device acceptance.

Most commands accept `--db`, `--since`, `--until`, `--app`, `--config`,
`--ranking-config`, `--kind` and `--format table|json|csv` after the command. Time
defaults to all saved history. `trend` derives `--since` from `--days` (default 28),
accepts an optional exclusive local-date `--until`, and can write an SVG with
`--chart PATH`. `--ranking-config` requires an exact ranking
fingerprint. The compatibility option `--config` still requires the exact legacy
full fingerprint; its meaning has not changed. Revision UUIDs and shortened
prefixes do not match. Dates mean local midnight; `--until` is exclusive. Use
explicit offsets for timestamp precision.

Report the database/time scope, valid and unknown evidence, daily and rolling Top1/Top3
denominators, version markers, output-kind coverage and all four identity coverage
sections. Never combine quality rates across measurement fingerprints; an unknown
measurement fingerprint is its own unavailable cohort. Inspect supporting compositions before
attributing a recurring pair to a ranking problem. `insertText` issuance and
candidate-list requests are recorded facts; they do not prove document acceptance
or that the user saw a panel. Missing first-page evidence, unknown ranks, candidate
sources and consumed spans must remain unknown. Missing targets do not establish
recall failure. Configuration fingerprints do not freeze learned dictionaries.

The analysis commands read evidence. They do not modify the local database, tune ranking, install
InkFlow or create monitoring. Missing/incompatible databases produce an error and
remain untouched. For a supplied test database, identify its results as synthetic
test evidence, not the user's production input quality.

Manual export is a separate explicitly requested operation:
`python3 "$query" export --output /path/to/new.json --format json`.
It exports all retained records, including legacy rows, assigns the file a stable
random source UUID, and creates only the adjacent `quality-source-id` metadata
marker on first export. It does not change the quality database or retention.
The file may contain input/candidate/preceding text; the user chooses the path and
transfers it. CLI export refuses to overwrite files. Do not export the user's raw
input history as an incidental part of a read-only review.
