# Chinese dictionary generation

`DictionaryModels.swift` pins the initial source commits, file paths, byte sizes,
Git blob IDs and SHA-256 values. `prepare-chinese.sh` downloads only these explicit
text files into ignored `build/dictionary-sources`. It runs the same
`IFDictionaryGenerator.generate` used by the dictionary preparation worker.

The source order is Frost `8105`, `base`, `ext`, `idiom`, then Ice `base`, `ext`,
then the fixed legacy `pinyin_simp` source. Entries are identified by displayed
text plus explicitly supplied Pinyin, after whitespace/case normalization and
ü-to-v conversion. No pronunciation is guessed, and no script conversion occurs.
Duplicate pairs retain the first source's weight; alternate readings remain.
The pinned baseline contains 963,978 unique pairs. English, custom phrases and
learned entries are not part of that count.

Frost weights remain unchanged. For each supplemental source group, positive
weights on overlapping pairs are compared to Frost using
`exp(median(log(frostWeight / sourceWeight)))`. Syllable buckets are 1, 2, 3, 4,
and 5 or more. A bucket with fewer than 100 overlapping pairs uses that source's
overall multiplier; a source without positive overlaps fails generation. New
positive weights are rounded, bounded to `1...Int32.max`, and original zero
weights remain zero. `macOS/config/chinese-overrides.tsv` applies explicit
term/reading replacement weights last and requires a reason for every row.
Its default contains no active corrections.

The parser reads only the tab-separated body following the Rime `---`/`...`
header. Imports and all other upstream YAML fields are ignored. It requires
valid UTF-8, a final newline, nonempty explicit readings, nonnegative integer
weights, bounded files/lines/record counts, and rejects partial or malformed
sources. All sources must pass Git blob and SHA-256 verification before merging.

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

Run `bash macOS/scripts/test-dictionary-generator.sh` after dependency setup for
normalization, union, calibration, rejection and deterministic build/runtime
parity. `bash macOS/scripts/test.sh` also runs deployment and engine regressions,
including default first candidates for `xiehouyu` and `suranqijing`, poems,
incremental Chinese, mixed English, context, custom phrases and emoji. These
isolated probes do not replace real-client typing acceptance.

Licenses and source notices are in `macOS/Licenses/chinese-dictionaries-NOTICE.txt`,
`rime-frost.txt`, `rime-ice.txt`, and `pinyin-simp.txt` and ship in the app bundle.

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

Diagnostic errors carry a Chinese stage summary and bounded technical fields and
can be logged through an injected sink. The journal, manifest and observations
never contain error payloads. Settings error presentation and its close/reopen
lifetime are owned by the UI coordinator, independently from background work.

After building the app, run `bash macOS/scripts/test-dictionary-updates.sh` for
fake-network failures, transaction boundaries, fingerprint/cache integrity,
subprocess isolation and full generated-dictionary helper preparation. The helper
is included in build, bundle dependency checks and inner-before-outer signing;
these checks do not install the input method or imply real-client acceptance.
