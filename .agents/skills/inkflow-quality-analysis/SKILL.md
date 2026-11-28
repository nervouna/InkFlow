---
name: inkflow-quality-analysis
description: Review InkFlow's recorded input quality with calendar trends, version annotations, charts and evidence from prior compositions. Use for recorded quality, including scoring a ranking change on recorded decisions; not for live input diagnosis or designing ranking changes.
---

# InkFlow Quality Analysis

Run [quality.py](scripts/quality.py) with `python3` from the repository root or use its absolute path.
It uses the standard library and defaults to `~/Library/Application Support/InkFlow/quality.sqlite3`.
It reads macOS records only. Linux has its own reporter, `Linux/scripts/quality.py`, whose aggregate export this script rejects:
see the [Linux README](../../../Linux/README.md#local-chinese-selection-quality).

## Routine review

Use 7 days for a short check and 28 days for a broader review. Example for 7 days:

```sh
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
charts=$(mktemp -d)
python3 "$query" trend --days 7 --chart "$charts"/inkflow-quality-7d.svg --format json
```

Present the SVG and daily, 7-day rolling and 28-day rolling Top1 and Top3 selection rates. Use the task's
temporary directory for charts unless the user requests a durable artifact. Report the time scope, valid and
unknown evidence, the known-display-rank denominator shared by both rates, and version markers. Top3 covers
display ranks 1–3. Report a bucket with fewer than 200 units using only its Wilson interval.

Use calendar date as the primary axis and app versions as annotations. The routine series uses the applicable
measurement fingerprint and never pools rates across fingerprints. Call it “统计口径” in user-facing reports.
Read [interpretation](references/interpretation.md) before reporting rates or comparing configurations.
The [metric scorecard](../../../docs/input-quality-metrics.md#scorecard) and
[query contract](references/query-contract.md#cli-and-output) define the additional counters.

## Other questions

| Task | Command and evidence |
| --- | --- |
| Check coverage or measurement identities | `summary`. See [units and filters](references/interpretation.md#units-filters-and-the-calendar). |
| Investigate recurring alternatives to first-page Top1 | `ranking-issues`. Use `--min-count 1` for individual cases, then `inspect COMPOSITION_ID` with the returned IDs. Check compositions before calling a pair a ranking issue. |
| Measure key intervals, last-edit waits or candidate visibility | `timing`. Read the [timing contract](references/query-contract.md#input-timing) first. |
| Check how quickly learning takes effect and how long it lasts | `learning --days 28` on one device. Check `pair_coverage` before trusting rates. |
| Score an offline ranking change | `replay-cases --output FILE` writes typed text for the offline [replay scorer](../../../Core/Portable/replay.md#replay). Read the [file rules](../../../Core/Portable/replay.md#replay-files). Report `reverted_relabelled` and `reverted_excluded` beside the ship-rule result. |
| Analyze one or more devices' exports | Use repeatable `--input` with a file or a folder of weekly exports. Add `--exports-only` to analyze those files alone, and always on the exporting Mac when reading its own weekly folder: with the local database the overlap is refused (exit 2). See [cross-device analysis](../../../macOS/QUALITY-EXPORT.md#analyze-on-another-computer). |

Use `--format json` for inspectable results. See the [query contract](references/query-contract.md#cli-and-output)
before changing a query or looking up output fields. Missing evidence stays unknown. Disclose text-free coverage
when `coverage.text_free` is nonzero. Results from a test database describe the fixture.

`export --output NEW.json` can write raw input history from records with text capture enabled. Run it only
when explicitly asked. See [text-free evidence](references/interpretation.md#text-free-records) and
[export and transfer](../../../macOS/QUALITY-EXPORT.md#export-and-transfer).
