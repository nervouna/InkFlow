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
charts=$(mktemp -d)
python3 "$query" trend --days 7 --chart "$charts"/inkflow-quality-7d.svg --format json
python3 "$query" trend --days 28 --chart "$charts"/inkflow-quality-28d.svg --format json
python3 "$query" summary --format json
python3 "$query" ranking-issues --format json
python3 "$query" inspect COMPOSITION_ID --format json
python3 "$query" timing --format json
```

For a routine quality review, use `trend`. Default to 7 days for a short operational
check and 28 days for a broader review. Present the SVG chart and summarize Top1 and
Top3 selection rates for daily, 7-day rolling and 28-day rolling windows. Both rates
share the same validated known-display-rank denominator; Top3 means display rank 1–3.
The same `trend` output carries the scorecard rates of
[the metric design](../../../docs/input-quality-metrics.md#scorecard); their fields and the series that carry
them are under `trend` in [the query contract](references/query-contract.md) and in the
[counter tables](references/interpretation.md#denominators-and-ranking-evidence).
Report a bucket under 200 units with its Wilson interval only.
Charts go to `$charts`, a task-owned temporary directory, unless the user requests a durable artifact.

Calendar date is the primary axis; app versions are annotations, not cohorts. Don't
split routine metrics by fingerprint. In user-facing reports call the measurement
fingerprint the “统计口径”.

Use `summary` for detailed coverage or forensic identity inspection. For repeatedly choosing another
candidate over first-page top1, use `ranking-issues`; pass `--min-count 1` when the user requests individual cases.
For a concrete example, use an issue's `composition_ids` with `inspect`. Read
[the interpretation](references/interpretation.md) before interpreting rates, comparing configurations or
investigating incomplete evidence, and [the query contract](references/query-contract.md) before changing queries
or looking up an output field.

Use `timing` for key intervals, last-edit waits and candidate visibility; read
[input timing](references/query-contract.md#input-timing) first.

Use `learning` (one device, `--days 28`) for how fast and how long corrections take effect: time to learn, futile pairs, retention, avoidable misses and word reuse over the keyed pair hashes; read its `pair_coverage` before trusting a rate.

Use `replay-cases --output FILE` to export decisions as replay cases for the offline `replay` scorer. The export
rules are under `replay-cases` in the query contract; scoring and the
[replay file rules](../../../Core/Portable/README.md#replay-files) (the file holds typed text) are in the
[replay README](../../../Core/Portable/README.md#replay). Report the header's `reverted_relabelled` and
`reverted_excluded` beside a ship-rule result.

Records are text-free by default: see [what that leaves out](references/interpretation.md#text-free-records), and say
so in the report when `coverage.text_free` is nonzero.

For cross-device analysis, add repeatable `--input /path/to/export.json`; see
[export and joint analysis](../../../macOS/QUALITY-EXPORT.md). Export itself
(`python3 "$query" export --output NEW.json --format json`) writes the user's raw
input history to a file: run it only when explicitly asked.

Report the time scope, valid and unknown evidence, Top1/Top3 denominators and
version markers. Never combine rates across measurement fingerprints. Inspect
supporting compositions before calling a recurring pair a ranking problem; missing
evidence stays unknown. Results from a supplied test database are synthetic, not the
user's input quality.
