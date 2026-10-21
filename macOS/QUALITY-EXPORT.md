# Quality data export and cross-device analysis

Manual quality exports let you analyze the records retained on several computers together. They do not transfer personal learning or change candidate ranking.

## Export and transfer

In InkFlow Settings, open 「备份与恢复」 and choose 「导出质量数据」 under 「输入质量记录」. Choose a JSON file location. The result reports the saved path, composition and learning-event counts, and the earliest/latest retained record time in UTC. An empty database exports an explicit empty range and zero counts.

The file includes candidate ranks and indices, selections by index, text kinds, app/client identifiers, operations/timing, content-free learning-effectiveness events, build/version metadata, statistical fingerprints, and record timestamps. Each candidate the engine ranked also carries three content-free facts, kept in text-free records too: `type`, Rime's candidate type of the genuine candidate (for example `phrase`, `user_phrase`, `sentence`, `completion`, `user_table`, `english_personal_2`; empty when it is not lowercase letters, digits and underscores, starting with a letter or underscore); `corrected`, true when the dictionary syllables of the candidate's code differ from the letters typed for its span, so a fuzzy or algebra rule reached it (an abbreviation counts; completions and the English and mixed modules' own candidates are always false); and `evidence`, the engine's ranking row `start,end,class,exact,personal,source,type,corrected` that `parse_metadata` reads. They are absent from older records and from candidates without evidence (a selected prefix, a matching custom-phrase code). Each decision with a known pair also carries two keyed hashes, kept in text-free records too: `codeHash` on its page, the HMAC-SHA256 (128 bits, 32 hex characters) of the code the selected candidate consumed (lowercase, apostrophes removed), and `textHash` on the selected candidate, the same for its text. They are keyed with a per-device key that is never exported, so they identify a recurring pair on that device only and never link across devices. A decision with a selected prefix, or whose consumed span is unknown, has neither. Each commit and each selection also carries its length, `character_count` and `selected_character_count`: the number of Unicode scalar values of the text (`❤️` is 2), kept in text-free records too and null in records written before schema v4. Each commit also has a post-commit window, a content-free fact carried in the operations of the composition that follows it: counts of Backspace, Forward Delete, Cmd+Z, direct-text and Cmd+V keys until the next code, a client change, deactivation or 10 seconds, and how the window ended; a commit that was not observed has none. Input codes/text, input before the first deletion, candidate text, committed text, preceding text and custom-phrase codes/text in the stored applied configuration are present only in records saved while 「同时保存输入文本」 was on; by default those strings are empty or null, each page carries `textCaptured: false`, and the configuration revision ID ends in `/text-free`. Full applied settings, custom-phrase configuration copies, personal dictionaries, AI service configuration and credentials are excluded. Transfer the file yourself; InkFlow does not upload it.

Only records still present in the local quality database are included: composition records retain 28 days; learning-effectiveness events retain 90 days, capped at 4,096. Turning text recording off removes every stored record that still carries text. In-progress input and unwritten records are not included. Local cleanup does not delete exported copies, nor the replay case files that `quality.py replay-cases` writes (typed text, kept outside the repository and deleted after the run; see [Replay and the first-choice target](../Core/Portable/README.md#replay-and-the-first-choice-target)).

## Storage protection

`quality.sqlite3` is a plain SQLite file under `~/Library/Application Support/InkFlow/` with `0600` file mode and `secure_delete` on. The directory is created `0700`, but an existing directory keeps its mode and can be `0755`, so the file mode is what protects the records. It is not encrypted, by decision:

- macOS Data Protection classes (`FileProtectionType`) only take effect on Apple silicon and protect data while the Mac is locked or off. FileVault already covers the home directory in that state, and the strictest class would make the background writer fail while the screen is locked, which disables recording for the session.
- Application-level encryption (SQLCipher or encrypted columns keyed from the Keychain) would guard against other processes of the same user, but an input method cannot prompt for Keychain access at startup, re-signed developer builds would silently lose the key, and the export, the analysis script and `sqlite3` inspection would all need a decryption path.
- The default record contains no text, including custom-phrase codes and text in the applied configuration (phrase IDs remain so the phrase set still shapes the ranking fingerprint). It does hold ranks, indices, timings, bundle identifiers, applied-setting fingerprints and, per decision, the keyed pair hashes described below. The text mode is an explicit, reversible opt-in bounded to 28 days.

The pair hashes (`codeHash`, `textHash`) trade part of the text-free guarantee for the learning metrics (`quality.py learning`). Three states exist:

- Without the key (an exported file, another device, a backup) the hashes are opaque 128-bit strings.
- With the key, which any process running as the same user can read from `~/Library/Application Support/InkFlow/quality-pair-key`, the hashes are a per-decision timeline of which word was chosen when and in which app. Words and codes are short and the code is pinyin, so anyone holding the key can recover nearly every pair by enumerating a dictionary. The same user can already read `pinyin_simp.userdb/` (the Rime user dictionary, every learned word and its code in plaintext) and `quality.sqlite3` itself, so the hash adds the timeline, not the vocabulary.
- Text mode: the same timeline in plaintext, plus candidates, preceding context and deleted input, for 28 days, as an explicit opt-in.

`quality-pair-key` is 32 random bytes in a file created `0600` (whatever the directory's mode), generated once per device. It is never exported, never part of the personal-data backup and never in a record or log, and both exports refuse it as a destination. 「清除记录」 deletes it and generates a new one, so cleared records cannot be linked to later ones; turning text recording on or off leaves it alone. Deleting the file by hand has the same effect from the next start. It is not stored in the Keychain, for the reason above.

Revisit this if the text mode becomes the default again or the database gains other personal content.

A command-line alternative uses the same file contract (Python standard library only):

```sh
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
python3 "$query" export --output /path/to/InkFlow-quality-work.json --format json
```

CLI export requires a new path and refuses to overwrite files. `--db PATH` selects another local v4 database. Exports always include all retained records; apply date and other filters during analysis.

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
| `schema_version` | Integer `4`, the underlying IFQ1 quality schema |
| `source_id` | Random device/source UUID, not hostname, account name or hardware serial |
| `exported_at` | UTC timestamp of this snapshot |
| `range.first`, `range.last` | Earliest/latest composition start or learning-event time, or both null when empty |
| `tables` | Arrays of records for the six quality tables described in the query contract |

The first export creates `quality-source-id` beside `quality.sqlite3`; later exports reuse it. This marker is source metadata, not a quality-database migration. All retained records, including those collected before this feature, acquire the file's source ID during export/analysis. No backfill into the local database is needed. Keep this marker on its original device and do not copy it to another device; deleting it creates a new identity on the next export, preventing deduplication with older exports. It is outside personal-data backup/restore and quality-record clearing. The pair-hash key `quality-pair-key` sits beside it, is also outside backup/restore and is never exported, but 「清除记录」 replaces it.

Record timestamps use the writer's UTC millisecond form (`YYYY-MM-DDTHH:MM:SS.sssZ`). Rows keep their original IDs, timestamps, version/build metadata and statistical fingerprints in the file. `config_revisions.applied_config_json` is replaced with `{}`; legacy page `configuration` objects are removed. `configurationRevisionID` links and recorded fingerprints remain. This deliberate omission prevents exporting full settings or custom-phrase inventories; it limits configuration-detail inspection to identities and metadata.

Deduplication keys are `(source_id, table, original_id)`. Learning-effectiveness events additionally use `run_id` and `occurred_at`, because their integer IDs may be reused after retention cleanup. Identical repeated files and overlapping exports count each record once. Records from different devices remain separate even if their original IDs match. Different JSON key order/whitespace does not change equality. A recording run's cumulative counters/status come from its latest snapshot and are never summed repeatedly. Conflicting immutable records with the same identity reject the whole command instead of choosing silently.

Each file is limited to 256 MiB. Unknown format/schema versions, broken JSON, duplicate keys/IDs, missing required fields, invalid types/timestamps, broken parent/page links and conflicting overlapping records fail with a diagnostic and exit status 2. Empty compatible files are valid and report zero coverage and unavailable rates.

## Tests

`test.sh quality-capture-query` covers the Settings exporter, roundtrips, deduplication across sources and overlapping files, and rejected corruption.
