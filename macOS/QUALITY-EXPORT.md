# Quality data export and cross-device analysis

Manual quality exports let you analyze the records retained on several computers together. They do not transfer personal learning or change candidate ranking.

## Export and transfer

In InkFlow Settings, open 「备份与恢复」 and choose 「导出质量数据」 under 「输入质量记录」. Choose a JSON file location. The result reports the saved path, composition and learning-event counts, and the earliest/latest retained record time in UTC. An empty database exports an explicit empty range and zero counts.

The file includes input codes/text, candidates, selections, obtainable preceding text, app/client identifiers, operations/timing, content-free learning-effectiveness events, build/version metadata, statistical fingerprints, and record timestamps. Full applied settings, custom-phrase configuration copies, personal dictionaries, AI service configuration and credentials are excluded. Transfer the file yourself; InkFlow does not upload it.

Only records still present in the local quality database are included: text records retain the existing 28-day policy; learning-effectiveness events retain 90 days, capped at 4,096. In-progress input and unwritten records are not included. Local cleanup does not delete exported copies.

A command-line alternative uses the same file contract (Python standard library only):

```sh
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
python3 "$query" export --output /path/to/InkFlow-quality-work.json --format json
```

CLI export requires a new path and refuses to overwrite files. `--db PATH` selects another local v3 database. Exports always include all retained records; apply date and other filters during analysis.

## Analyze on another computer

Run these commands from the InkFlow repository. Use the analysis script and `macOS/Tools/quality_exchange.py` from this feature revision or a later version that supports export format v1.

```sh
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py

# Device A's export plus device B's local database.
python3 "$query" trend --days 28 --input /path/to/work.json --format json
python3 "$query" summary --input /path/to/work.json --format json

# Several exports, without reading the local database.
python3 "$query" summary --exports-only \
  --input /path/to/work.json --input /path/to/home.json --format json

# One device, selected by the source ID listed in the result.
python3 "$query" trend --exports-only --input /path/to/work.json \
  --input /path/to/home.json --source DEVICE_UUID --days 7 --format json

# Existing evidence investigation works with the same input flags.
python3 "$query" ranking-issues --input /path/to/work.json --format json
python3 "$query" inspect 'DEVICE_UUID:COMPOSITION_ID' \
  --input /path/to/work.json --format json
```

`--input` may be repeated on `summary`, `trend`, `ranking-issues`, `inspect` and `timing`. Unless `--exports-only` is present, the local database participates and must exist. The existing `--since`, exclusive `--until`, app, kind and fingerprint filters still apply. Calendar days use the analysis computer's local timezone; persisted record timestamps stay in UTC. Choose the same analysis timezone when comparing reports.

Combined output includes `sources` with each source's retained time range, input file paths, distinct version/build metadata and deduplicated record counts. `by_source` applies the same command and filters separately to each device. `--source` isolates one device. Inspection IDs are namespaced as `SOURCE_ID:ORIGINAL_ID`; use the IDs returned by `ranking-issues`. Local-only commands without exchange flags retain their original output and IDs. Before the first export, an unmarked local database is labeled `local` in joint analysis.

The combined and per-device results reuse the original query functions. Statistical-rule fingerprints remain compatibility boundaries: never pool quality rates across incompatible or unknown metric definitions. The existing trend command selects the latest known metric-definition cohort in each requested scope and reports exclusions. Different devices may have different available cohorts; consult their cohort/exclusion fields before comparing rates. App versions remain annotations, not causal evidence.

Imported records are loaded into an ephemeral in-memory SQLite database. No external rows, tables or migrations enter the local daily quality database. Export uses a [read-only committed snapshot](https://www.sqlite.org/lang_transaction.html) on a utility task; neither exporting nor analysis adds work to key-event handling.

## Format v1 and record identity

The UTF-8 JSON root contains:

| Field | Meaning |
| --- | --- |
| `format` | Literal `inkflow-quality` |
| `format_version` | Integer `1` |
| `schema_version` | Integer `3`, the underlying IFQ1 quality schema |
| `source_id` | Random device/source UUID, not hostname, account name or hardware serial |
| `exported_at` | UTC timestamp of this snapshot |
| `range.first`, `range.last` | Earliest/latest composition start or learning-event time, or both null when empty |
| `tables` | Arrays of records for the six quality tables described in the query contract |

The first export creates `quality-source-id` beside `quality.sqlite3`; later exports reuse it. This marker is source metadata, not a quality-database migration. All retained records, including those collected before this feature, acquire the file's source ID during export/analysis. No backfill into the local database is needed. Keep this marker on its original device and do not copy it to another device; deleting it creates a new identity on the next export, preventing deduplication with older exports. It is outside personal-data backup/restore and quality-record clearing.

Record timestamps use the writer's UTC millisecond form (`YYYY-MM-DDTHH:MM:SS.sssZ`). Rows keep their original IDs, timestamps, version/build metadata and statistical fingerprints in the file. `config_revisions.applied_config_json` is replaced with `{}`; legacy page `configuration` objects are removed. `configurationRevisionID` links and recorded fingerprints remain. This deliberate omission prevents exporting full settings or custom-phrase inventories; it limits configuration-detail inspection to identities and metadata.

Deduplication keys are `(source_id, table, original_id)`. Learning-effectiveness events additionally use `run_id` and `occurred_at`, because their integer IDs may be reused after retention cleanup. Identical repeated files and overlapping exports count each record once. Records from different devices remain separate even if their original IDs match. Different JSON key order/whitespace does not change equality. A recording run's cumulative counters/status come from its latest snapshot and are never summed repeatedly. Conflicting immutable records with the same identity reject the whole command instead of choosing silently.

Each file is limited to 256 MiB. Unknown format/schema versions, broken JSON, duplicate keys/IDs, missing required fields, invalid types/timestamps, broken parent/page links and conflicting overlapping records fail with a diagnostic and exit status 2. Empty compatible files are valid and report zero coverage and unavailable rates.

## Tests

`test.sh quality-capture-query` covers the Settings exporter, roundtrips, deduplication across sources and overlapping files, and rejected corruption.
