# Static English frequency snapshot

`english-wordfreq.tsv` records observed wordfreq 3.1.1 `en/large` Zipf values for the
spellings of the ESDB (formerly SCOWL) 2026.02.25 Hunspell dictionaries `en_US-large` and
`en_GB-large`: 111,004 mappings from 173,442 unique spellings. Prefixes, suffixes and
their cross products are expanded; `ONLYINCOMPOUND` forms are skipped and `NOSUGGEST`
forms kept. Only forms made of ASCII letters, apostrophes, hyphens and periods are
considered. Spellings without an observed key are omitted, not stored as zero. Technical
spellings come from the separate [technical vocabulary source](TECHNOLOGY.md).

The regeneration script uses `preprocess_text(text, "en")` and direct frequency-key
lookup, not the multi-token `zipf_frequency` estimator. Zipf is
`log10(probability) + 9`, stored to two decimals. Input SHA-256 values are pinned in
the script and snapshot header.
Snapshot SHA-256: `b895a78a67b77fb281bffef9553ea29f623889613371980fd8283609783ccd06`.

To regenerate, which needs network once for the two ESDB zips (downloaded into the ignored
`build/esdb`):

```sh
uv run --no-project --with wordfreq==3.1.1 python macOS/scripts/snapshot-english-frequency.py
```

Ordinary builds read the committed TSV with AWK; they need neither Python nor a
download. wordfreq data runs to about 2021 and is
[no longer updated](https://github.com/rspeer/wordfreq/blob/master/SUNSET.md); it
folds case, so `US/us` are indistinguishable. Attribution and CC BY-SA 4.0 terms are
in [`macOS/Licenses/wordfreq.txt`](../../macOS/Licenses/wordfreq.txt); the ESDB notice is
[`macOS/Licenses/esdb.txt`](../../macOS/Licenses/esdb.txt).
