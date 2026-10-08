#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-source-bundle-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
bash macOS/scripts/dictionary-source-bundle.sh "$scratch/bundle.tar.gz" 123 >/dev/null
tar -xzf "$scratch/bundle.tar.gz" -C "$scratch"
root=$(printf '%s\n' "$scratch"/InkFlow-*-dictionary-source)
[[ -d "$root" ]]
(cd "$root" && shasum -a 256 -c SHA256SUMS >/dev/null)
# Every pinned Chinese catalog input is present with its catalog digest.
build/dictionary-generator sources | while IFS=$'\t' read -r id sha bytes url; do
  printf '%s  %s\n' "$sha" "$root/upstream/dictionary-sources/$id.yaml" | shasum -a 256 -c - >/dev/null
done
for file in upstream/deps/pinyin.tar.gz upstream/deps/english.tar.gz upstream/deps/emoji.txt \
  LICENSES/rime-frost.txt LICENSES/rime-ice.txt LICENSES/easy-en-LGPL-3.0.txt LICENSES/easy-en-GPL-3.0.txt \
  LICENSES/wordfreq.txt LICENSES/pinyin-simp.txt LICENSES/opencc.txt LICENSES/chinese-dictionaries-NOTICE.txt \
  inkflow/LICENSE inkflow/NOTICE inkflow/Core/Package.swift inkflow/Core/Sources/InkFlowDomain/DictionaryGenerator.swift \
  inkflow/Core/Sources/InkFlowDomain/DictionaryModels.swift inkflow/Core/config/chinese-overrides.tsv \
  inkflow/Core/config/english-overrides.tsv inkflow/Core/Data/english-wordfreq.tsv inkflow/Core/Data/english-technology.tsv \
  inkflow/schemas/opencc/STPhrases.txt inkflow/Core/scripts/prepare-rime.sh inkflow/macOS/scripts/dependencies.sh \
  generated/dictionary-manifest.json SOURCES.tsv README.md; do
  [[ -s "$root/$file" ]] || { echo "Missing $file" >&2; exit 1; }
done
grep -q "$(git rev-parse HEAD)" "$root/README.md"
grep -q 'build 123' "$root/README.md"
! grep -qi 'sogou\|rime-selected' "$root/SOURCES.tsv"
# The recorded manifest is the one the current recipe generates.
bash Core/scripts/prepare-chinese.sh "$scratch/chinese" >/dev/null
cmp "$scratch/chinese/dictionary-manifest.json" "$root/generated/dictionary-manifest.json"
# Every SOURCES.tsv row points at a bundled file with the recorded digest.
tail -n +2 "$root/SOURCES.tsv" | while IFS=$'\t' read -r component license origin path sha bytes; do
  printf '%s  %s\n' "$sha" "$root/$path" | shasum -a 256 -c - >/dev/null
done
echo 'PASS source bundle: verified upstream inputs, committed recipe, licenses, manifest parity and self-consistent SOURCES.tsv'
