#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: prepare-chinese.sh DESTINATION}
bash macOS/scripts/build-dictionary-generator.sh
mkdir -p build/dictionary-sources "$destination"
legacy=(build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml)
[[ ${#legacy[@]} == 1 && -s "${legacy[0]}" ]] || { echo 'Expected one pinned legacy dictionary' >&2; exit 1; }
staging=$(mktemp -d build/.chinese.XXXXXX)
trap 'rm -rf "$staging"' EXIT
build/dictionary-generator sources > "$staging/sources.tsv"
while IFS=$'\t' read -r identifier sha bytes url; do
  source_file="build/dictionary-sources/$identifier.yaml"
  if [[ ! -f "$source_file" ]]; then
    curl --fail --location --proto '=https' --connect-timeout 20 --max-time 180 --retry 2 \
      --max-filesize "$bytes" "$url" -o "$staging/$identifier.yaml"
    printf '%s  %s\n' "$sha" "$staging/$identifier.yaml" | shasum -a 256 -c -
    [[ $(wc -c < "$staging/$identifier.yaml") -eq $bytes ]]
    mv "$staging/$identifier.yaml" "$source_file"
  fi
  printf '%s  %s\n' "$sha" "$source_file" | shasum -a 256 -c - > /dev/null
done < "$staging/sources.tsv"
# Cache is only a build optimization. Every raw input is verified above and the key
# includes the executable, exact legacy bytes and local correction rules.
shasum -a 256 build/dictionary-generator build/dictionary-sources/*.yaml "${legacy[0]}" \
  macOS/config/chinese-overrides.tsv > "$staging/inputs.sha256"
cache=build/generated-chinese
cache_valid=false
if [[ -s "$cache/outputs.sha256" ]]; then
  if (cd "$cache" && shasum -a 256 -c outputs.sha256 > /dev/null 2>&1); then cache_valid=true; fi
fi
if [[ ! -f "$cache/inputs.sha256" ]] || ! cmp -s "$staging/inputs.sha256" "$cache/inputs.sha256" \
   || ! $cache_valid; then
  build/dictionary-generator generate build/dictionary-sources "${legacy[0]}" macOS/config/chinese-overrides.tsv "$staging/generated"
  cp "$staging/inputs.sha256" "$staging/generated/inputs.sha256"
  (cd "$staging/generated" && shasum -a 256 pinyin_simp.dict.yaml dictionary-manifest.json > outputs.sha256)
  mkdir -p "$cache"
  cp "$staging/generated/"* "$cache/"
fi
cp "$cache/pinyin_simp.dict.yaml" "$cache/dictionary-manifest.json" "$destination/"
cp "${legacy[0]}" "$destination/legacy-pinyin-simp.dict.yaml"
cp macOS/config/chinese-overrides.tsv "$destination/"
