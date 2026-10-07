# Static English frequency snapshot

`english-wordfreq.tsv` records observed wordfreq 3.1.1 `en/large` Zipf values for
existing rime-easy-en display text: 406,195 mappings from 719,041 unique spellings.
Spellings without an observed key are omitted, not stored as zero. Technical
spellings come from the separate [technical vocabulary source](TECHNOLOGY.md).

The regeneration script uses `preprocess_text(text, "en")` and direct frequency-key
lookup, not the multi-token `zipf_frequency` estimator. Zipf is
`log10(probability) + 9`, stored to two decimals. Input SHA-256 values are pinned in
the script and snapshot header.
Snapshot SHA-256: `7d81963156997d7cccf83fbdab230259cfd74b5b293a0f15de39bcf3c53c03b0`.

To regenerate after preparing the pinned dependencies:

```sh
uv run --no-project --with wordfreq==3.1.1 python macOS/scripts/snapshot-english-frequency.py
```

Ordinary builds read the committed TSV with AWK; they need neither Python nor a
download. wordfreq data runs to about 2021 and is
[no longer updated](https://github.com/rspeer/wordfreq/blob/master/SUNSET.md); it
folds case, so `US/us` are indistinguishable. Attribution and CC BY-SA 4.0 terms are
in [`macOS/Licenses/wordfreq.txt`](../../macOS/Licenses/wordfreq.txt).
