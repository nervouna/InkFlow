# Static English frequency snapshot

`english-wordfreq.tsv` records the observed wordfreq 3.1.1 `en/large` Zipf values
for existing rime-easy-en display text. It contains 406,195 mappings from 719,041
unique source spellings. The other 312,846 spellings have no observed key and
are omitted, not assigned measured zero. This snapshot cannot add words. Spelling
and code inputs come from rime-easy-en plus the separate, bounded
[technical vocabulary source](TECHNOLOGY.md).

The regeneration script uses `preprocess_text(text, "en")` and direct frequency
key lookup. It does not use the multi-token estimator in `zipf_frequency` or
`word_frequency`. Zipf is `log10(probability) + 9`, stored to two decimals,
matching the source's precision. Capitalization is folded by the provider;
exact-case overrides can intentionally distinguish existing displayed spellings.

Both input file SHA256 values are pinned in the script and snapshot header.
Snapshot SHA256: `7d81963156997d7cccf83fbdab230259cfd74b5b293a0f15de39bcf3c53c03b0`.

To regenerate after preparing the pinned repository dependencies:

```sh
uv run --no-project --with wordfreq==3.1.1 python macOS/scripts/snapshot-english-frequency.py
```

Use the project's supported Python environment; dependencies are needed only
for this deliberate data maintenance step. A regular build reads the committed
TSV with AWK, does not run Python, and does not download frequency data.

This is a static common-word baseline, not a word-validity model or a current
new-word list. The provider's data is approximately through 2021 and is no
longer updated. It does not distinguish `US/us`, repair upstream display forms,
or estimate frequency specifically for English words inserted into Chinese.
The configurable gate and exact-word overrides live in `macOS/config`; broad
cleaning and new-word policy remain outside this snapshot.

Sources: [wordfreq 3.1.1](https://pypi.org/project/wordfreq/3.1.1/),
[upstream maintenance statement](https://github.com/rspeer/wordfreq/blob/master/SUNSET.md).
Attribution, adaptation notice and CC BY-SA 4.0 terms are in
[`macOS/Licenses/wordfreq.txt`](../Licenses/wordfreq.txt), also shipped in the app.
