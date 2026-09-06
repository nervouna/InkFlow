---
name: inkflow-quality-analysis
description: Query InkFlow's locally recorded input quality, summarize candidate ranking coverage, find recurring first-choice versus chosen pairs, and inspect composition evidence. Use for recorded evidence questions, not ranking changes or live input diagnosis.
---

# InkFlow Quality Analysis

Use the read-only [query script](scripts/quality.py). It uses Python's standard
library and defaults to `~/Library/Application Support/InkFlow/quality.sqlite3`.
Resolve the existing interpreter with `mise which python`; no dependency setup is
needed. Run commands from this repository root, or use the script's absolute path.

```sh
python_bin=$(mise which python)
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
"$python_bin" "$query" summary --format json
"$python_bin" "$query" ranking-issues --format json
"$python_bin" "$query" inspect COMPOSITION_ID --format json
```

For a quick quality overview, use `summary`. For repeatedly choosing another
candidate over first-page top1, use `ranking-issues` (default at least 3 occurrences,
50 groups). For a concrete example, use an issue's `composition_ids` with `inspect`;
use `--min-count 1` when the user requests individual cases. Read
[the query contract](references/query-contract.md) before interpreting rates,
comparing configurations, investigating incomplete evidence, or changing queries.

All commands accept `--db`, `--since`, `--until`, `--app`, `--config`, `--kind` and
`--format table|json|csv` after the command. Time defaults to all saved history.
`--config` requires a **full stable fingerprint**, available in every output format;
a revision UUID or shortened prefix does not match. Dates mean local midnight;
`--until` is exclusive. Use explicit offsets for timestamp precision.

Report the database/time scope, valid and unknown coverage, configuration and
output-kind groups with the result. Inspect supporting compositions before
attributing a recurring pair to a ranking problem. `insertText` issuance and
candidate-list requests are recorded facts; they do not prove document acceptance
or that the user saw a panel. Missing first-page evidence, unknown ranks, candidate
sources and consumed spans must remain unknown. Missing targets do not establish
recall failure. Configuration fingerprints do not freeze learned dictionaries.

This skill reads evidence. It does not modify the database, tune ranking, install
InkFlow or create monitoring. Missing/incompatible databases produce an error and
remain untouched. For a supplied test database, identify its results as synthetic
test evidence, not the user's production input quality.
