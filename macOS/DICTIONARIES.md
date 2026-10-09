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
unchanged. Recipe 3 removed the rime-selected Sogou conversion (3,975 unique
weight-1 pairs); the quality baseline was re-frozen with no candidate-order change. English, custom phrases and
learned entries are not part of that count.

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
calibration and rejection; the `deployment` and `engine-*` units cover default first
candidates such as `xiehouyu` → 歇后语 and `suranqijing` → 肃然起敬. With clean
learning, the pinned Frost weights deliberately rank `beijing` as 背景 and
`shanghai` as 伤害.

License notices are in `macOS/Licenses/chinese-dictionaries-NOTICE.txt` and the
per-source files. No Sogou-derived source remains; the fourteen curated terms in
`chinese-overrides.tsv` carry InkFlow readings and weights (see the notice and
[the distribution review](../Core/Portable/licenses.md)). Each release attaches the
corresponding source for the GPL/LGPL inputs as
`InkFlow-<version>-<build>-dictionary-source.tar.gz`, built by
`macOS/scripts/dictionary-source-bundle.sh` and checked by `test.sh source-bundle`.

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

## Verified update preparation

`IFDictionarySourceClient` checks only the fixed Frost and Ice repositories. A
branch check resolves a commit and its complete Git tree; only allowlisted regular
file paths, Git blob identifiers and sizes are accepted. Unrelated upstream
commits do not offer an update. Downloads bind the checked immutable commit,
reject unapproved HTTPS redirects, and validate byte count, Git blob and SHA-256
before the shared generator parses text. The ephemeral transport has no cookies,
credential storage or authentication header and bounds bytes during reception.
The transport is injectable for deterministic offline tests.

`InkFlowDictionaryWorker` is a bundled Foundation/CryptoKit executable using the
pinned Rime C API. It copies current application-owned schema, Lua, English and
emoji resources, generates the Chinese dictionary from verified inputs, then
compiles in an isolated user directory. A second clean user directory loads only
the prepared cache and probes the two required first choices plus mixed English,
standalone English and emoji candidates. Native deployment notifications report
compilation failures separately from verification failures. No real learning or
custom-phrase data enters the helper.

The runner calls the local helper through `sandbox-exec`, without a shell or
inherited credentials. Its profile denies network access and real-user-directory
access, allowing writes only to the explicitly configured candidate UUID
subtree. Both pipes drain concurrently; diagnostic retention and execution time
are bounded. Cancellation or timeout terminates the child, escalating to KILL if
necessary. `sandbox-exec` is deprecated by macOS; inability to start this sandbox
is a preparation error, never a reason to run the helper unsandboxed.

`IFDictionaryStore` keeps confirmed current, previous and pending versions in an
atomic journal. Each artifact combines the reproducible content version, the
current resource/library/helper fingerprint and a build UUID, so a fresh rebuild
never overwrites an active artifact. Checksums cover prepared resources and
cache files. A pending activation does not change the confirmed pointer or its
date; confirmation advances them only after the caller verifies the engine and
all sessions. Interrupted pending work is abandoned without an automatic retry.
The caller serializes mutations and owns live-engine activation and rollback.

Cache compatibility fingerprints include current schemas, Lua, English, emoji,
corrections, helper and libraries. Rebuilding consumes inert dictionary data and
current application resources. Downloaded artifacts retain verified raw sources
so changed correction policy can regenerate offline. A flat-only artifact whose
correction policy changed must fall back to the current bundled dictionary.
Proven same-content source receipts are stored separately, bound to that active
content version; merely checking or downloading never suppresses a future retry.
Manifests from an older recipe fall back to the bundled dictionary through normal
recovery. Bounded housekeeping removes unreferenced compiled artifacts, keeping
current, previous and pending ones and ignoring unknown names and symlinks.

Diagnostic errors carry a Chinese stage summary and bounded technical fields and
can be logged through an injected sink. The journal, manifest and observations
never contain error payloads. Settings error presentation and its close/reopen
lifetime are owned by the UI coordinator, independently from background work.

After `build.sh`, the `dictionary-*` units cover fake-network failures, transaction
boundaries, cache integrity, subprocess isolation and helper preparation.

## Live activation and Settings

`main.swift` retains one `IFDictionaryCoordinator` for the process and injects it
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
collapsed disclosure.

Every live native session must be free of composition, native/buffered commits
and client-delivery callbacks before replacement. The coordinator prepares the
context index off the main actor; existing input continues on the old engine.
The final main-actor transaction restarts the engine, restores all sessions and
their options, then confirms the journal. Failure restores the last working
engine; failure of that rollback explicitly leaves the engine unavailable.
Retry remains available even after a displayed diagnostic has been dismissed.

A displayed error clears when the Settings window closes or the next operation
starts; it is never persisted. Sanitized diagnostics go to the unified log (see
[DEBUGGING.md](DEBUGGING.md#logs-and-incident-archives)).

Startup discards interrupted pending work, validates the last confirmed cache,
and rebuilds incompatible caches using current application resources. Recovery
tries the previous version and finally the bundled dictionary. Learning keeps
the existing `pinyin_simp.userdb` identity and location across these switches.

## Manual checks

After an authorized install, try `xiehouyu`/`suranqijing`, a mixed phrase and an emoji code in two clients, then 设置 → 词库 → 检查更新 while a composition stays open in one client: activation should wait until it ends.

## Resource cost

One prepared version occupied about 137 MiB (30 MiB shared resources, 61 MiB compiled cache, 46 MiB retained raw data). Building the context index took about 3.5 s at ~181 MiB peak RSS; old and new indexes coexist during background preparation.
