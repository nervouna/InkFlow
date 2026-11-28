# Chinese dictionary generation

## Dictionary composition

InkFlow combines the following sources into one always-on Chinese dictionary. The
Settings window intentionally shows only whether that dictionary is ready, its entry
count and update actions; provenance and generation details live here.

| Source | Included material | Upstream or local source |
| --- | --- | --- |
| Frost | Character table, base, extended, idioms and poems, computer terms, Internet terms | [`gaboolic/rime-frost`](https://github.com/gaboolic/rime-frost) |
| Rime Ice | Base and extended Chinese vocabulary | [`iDvel/rime-ice`](https://github.com/iDvel/rime-ice) |
| Legacy Pinyin | Compatibility additions retained from the former baseline | [`rime/rime-pinyin-simp`](https://github.com/rime/rime-pinyin-simp) |
| InkFlow additions | Curated technology and Internet terms plus explicit corrections | [`Core/config/chinese-overrides.tsv`](../Core/config/chinese-overrides.tsv) |
| English spellings | Spellings and capitalization of the `en_US-large` and `en_GB-large` word lists, weighted by wordfreq | [`Core/Data/README.md`](../Core/Data/README.md) |
| Technical English | Admitted technology terms and abbreviations | [`Core/Data/TECHNOLOGY.md`](../Core/Data/TECHNOLOGY.md) |

`Core/config/chinese-sources.json` is the source of truth for source commits, file paths, byte
sizes, Git blob IDs and SHA-256 values. `prepare-chinese.sh` downloads only these explicit
text files into ignored `build/dictionary-sources`. The CLI and the worker's
`IFDictionaryGenerator.generate` wrapper call the same Rust implementation.

The baseline merge order is Frost `8105`, `base`, `ext`, `idiom`, then Ice `base`,
`ext`, then the fixed legacy `pinyin_simp` source. Specialty sources then fill
missing pairs: Frost `computer` and `exthot`. The catalog keeps legacy last for the existing worker protocol;
merge groups, rather than catalog position, enforce baseline-before-specialty
precedence. Entries are identified by displayed
text plus explicitly supplied Pinyin, after whitespace/case normalization and
ü-to-v conversion. No pronunciation is guessed, and no script conversion occurs.
Duplicate pairs retain the first source's weight; alternate readings remain.
The pinned domain dictionary contains 965,919 unique pairs, including 1,941
additions to the original 963,978-pair baseline. Original pair weights remain
unchanged. English, custom phrases and learned entries are not part of that count.

Baseline Frost weights remain unchanged. For the Ice and legacy groups, positive
weights on overlapping pairs are compared to Frost using
`exp(median(log(frostWeight / sourceWeight)))`. Syllable buckets are 1, 2, 3, 4,
and 5 or more. A bucket with fewer than 100 overlapping pairs uses that source's
overall multiplier; a source without positive overlaps fails generation. New
positive weights are rounded, bounded to `1...Int32.max`, and original zero
weights remain zero. `Core/config/chinese-overrides.tsv` applies explicit
term/reading replacement weights last and requires a reason for every row.
It also supplies a small curated technology and Internet supplement with explicit
readings and conservative weights. Specialty pairs use their own numeric weight and
do not participate in baseline calibration. The curated `命令行用户交互` entry
uses the `hang` reading for command-line.

The parser reads only the tab-separated body following the Rime `---`/`...`
header. Imports and all other upstream YAML fields are ignored. It requires
valid UTF-8, nonempty explicit readings, nonnegative integer
weights, bounded files/lines/record counts, and rejects partial or malformed
sources. All sources must pass Git blob and SHA-256 verification before merging.
Once complete byte count and both digests are verified, a missing final newline
is accepted (the pinned Frost computer file has none). Missing or empty weight fields, extra columns and malformed final rows are errors.

Canonical rows are sorted by UTF-8 text, then reading. The content version is
SHA-256 over the recipe version and canonical weighted rows. The generated
`pinyin_simp.dict.yaml` and `dictionary-manifest.json` are deterministic; source
commit/comment changes alone cannot change the content version. The manifest
records the distinct count, output and content digests, source receipts and
calibration factors. It contains no activation date, user data or diagnostics.
The installed legacy compatibility source stays fixed for online updates.

The Chinese translator, mixed translator import and context ranker all consume
the same flat `pinyin_simp.dict.yaml`. `pinyin_simp.userdb` keeps its existing name
and location. English admission, emoji data, schemas and Lua remain application
resources with separate release rules.

Tests: `bash macOS/scripts/test.sh dictionary-generator` for normalization, union,
calibration and rejection (after an intended generator change, re-record the fixtures as
[the generator README](../Core/Portable/dictionary/README.md#re-record-the-fixtures) describes); after `build.sh`, the
`dictionary-*` units cover fake-network failures, transaction boundaries, cache integrity, subprocess isolation and
helper preparation; the `deployment` and `engine-*` units cover default first
candidates such as `xiehouyu` → 歇后语 and `suranqijing` → 肃然起敬. With clean
learning, the pinned Frost weights deliberately rank `beijing` as 背景 and
`shanghai` as 伤害.

License notices are in `macOS/Licenses/chinese-dictionaries-NOTICE.txt` and the per-source files.
No Sogou-derived source remains; its history, the fourteen curated terms and the source bundle that each release
attaches for the GPL/LGPL inputs are in [the distribution review](../Core/Portable/licenses.md).

THUOCL is an optional coverage audit, never a pronunciation or weight source.
For the pinned corpus below, all 8,519 distinct listed words are present. To
repeat the audit after generating `build/test-chinese`:

```sh
curl --fail --location https://raw.githubusercontent.com/thunlp/THUOCL/a30ce79d895d01ab5132a5c74c29703ff7efb4cc/data/THUOCL_chengyu.txt -o build/thu-idiom.txt
printf '%s  %s\n' c339d5d6e37d4f8ecdcb82f2a02b7fdfc66796f0a5215155f2aff8a77e89a7eb build/thu-idiom.txt | shasum -a 256 -c -
awk -F '\t' '
  NR == FNR { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); expected[$1]=1; next }
  NF == 3 { present[$1]=1 }
  END {
    for (word in expected) { total++; if (!(word in present)) { missing++; print word } }
    printf "THUOCL coverage: %d/%d words\n", total-missing, total
    exit(missing > 0)
  }
' build/thu-idiom.txt build/test-chinese/pinyin_simp.dict.yaml
```

## Update preparation and activation

Source verification, the sandboxed worker, the store journal, activation and recovery are described in
[the dictionary lifecycle](../Core/Docs/dictionary-lifecycle.md).

## Settings

`ApplicationBootstrap.swift` creates one `IFDictionaryCoordinator` for the process and injects it
into the native Settings window. The Dictionary pane only observes that service.
Checking is manual and never downloads; a changed source offers a separate
download/update action. There is no scheduled check. One operation runs at a
time, including the wait for input to become idle. Closing Settings leaves work
running and reopening resumes its current progress.

The pane has no source switches. It reports whether the combined dictionary is ready,
its Chinese term/reading count and one context-sensitive action: check, update, retry
or restore. Busy states expose no duplicate action. Internal content versions, source
commits and immutable URLs remain in this document and the shared source catalog, not
in Settings. Recoverable failures state that current input remains available; engine
failure instead offers restoration. Both retain selectable technical detail behind a
collapsed disclosure. Retry remains available after a displayed diagnostic has been
dismissed, and a displayed error clears when the Settings window closes or the next
operation starts.

## Manual checks

After an authorized install, try `xiehouyu`/`suranqijing`, a mixed phrase and an emoji code in two clients, then 设置 → 词库 → 检查更新 while a composition stays open in one client: activation should wait until it ends.

## Resource cost

One prepared version occupied about 137 MiB (30 MiB shared resources, 61 MiB compiled cache, 46 MiB retained raw data).
