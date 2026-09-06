#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: prepare-rime.sh DESTINATION}
source macOS/config/english.conf
mkdir -p "$destination"
staging=$(mktemp -d "$destination/.english.XXXXXX")
trap 'rm -rf "$staging"' EXIT
# Join observed frequencies and explicit overrides by exact displayed text. Never
# estimate an unknown word or fall back to the upstream dictionary ordinal weight.
LC_ALL=C awk -v min_zipf="$ENGLISH_MIN_ZIPF" -v weight_scale="$ENGLISH_WEIGHT_SCALE" \
  -v weight_divisor="$MIXED_ENGLISH_WEIGHT_DIVISOR" '
function fail(message) {
  print "prepare-rime.sh: " message > "/dev/stderr"
  exit 1
}
function zipf(value) {
  return value ~ /^[0-9]+([.][0-9]+)?$/ && value+0 >= 0 && value+0 <= 9
}
BEGIN {
  FS=OFS="\t"
  if (!zipf(min_zipf)) fail("ENGLISH_MIN_ZIPF must be between 0 and 9")
  if (weight_scale !~ /^[0-9]+$/ || weight_scale+0 <= 0 || weight_scale+0 > 238609294)
    fail("ENGLISH_WEIGHT_SCALE must be a positive integer <= 238609294")
  if (weight_divisor !~ /^[0-9]+([.][0-9]+)?$/ || weight_divisor+0 <= 0)
    fail("MIXED_ENGLISH_WEIGHT_DIVISOR must be positive")
  print "# Generated from rime-easy-en (LGPL-3.0), reweighted with wordfreq (CC BY-SA 4.0)."
  print "# See bundled Licenses for source attribution and modification details."
  print "---\nname: easy_en\nversion: '\''0.4-inkflow'\''\nsort: by_weight"
  print "use_preset_vocabulary: false\n..."
}
FILENAME == ARGV[1] {
  if ($0 ~ /^[[:space:]]*(#|$)/) next
  if (NF != 2 || $1 !~ /[^[:space:]]/ || !zipf($2) || $2+0 == 0)
    fail("invalid english-wordfreq.tsv record at line " FNR)
  if ($1 in observed) fail("duplicate english-wordfreq.tsv word at line " FNR ": " $1)
  observed[$1]=$2+0
  next
}
FILENAME == ARGV[2] {
  if ($0 ~ /^[[:space:]]*(#|$)/) next
  if (NF != 3 || $1 !~ /[^[:space:]]/ || !zipf($2) || $3 !~ /[^[:space:]]/)
    fail("invalid english-overrides.tsv record at line " FNR ": expected word, Zipf 0..9, and reason")
  if ($1 in overrides) fail("duplicate english-overrides.tsv word at line " FNR ": " $1)
  overrides[$1]=$2+0
  next
}
$0 == "..." { entries=1; next }
entries && $0 !~ /^[[:space:]]*(#|$)/ && NF >= 2 {
  if ($1 in overrides) effective=overrides[$1]
  else if ($1 in observed) effective=observed[$1]
  else next
  # Zero means explicit exclusion, even when the configured gate is zero.
  if (effective <= 0 || effective < min_zipf) next
  printf "%s\t%s\t%d\n", $1,$2,int(effective*weight_scale+0.5)
}' macOS/Data/english-wordfreq.tsv macOS/config/english-overrides.tsv \
  build/deps/rime-easy-en-*/easy_en.dict.yaml > "$staging/easy_en.dict.yaml"
# Mixed composition adds only its existing structural restrictions and scaling.
LC_ALL=C awk -v weight_divisor="$MIXED_ENGLISH_WEIGHT_DIVISOR" '
BEGIN {
  FS=OFS="\t"
  print "# Generated from rime-easy-en (LGPL-3.0), reweighted with wordfreq (CC BY-SA 4.0)."
  print "# See bundled Licenses; original pinyin_simp remains an independent translator/user dictionary."
  print "---\nname: inkflow_mixed\nversion: '\''1.2'\''\nsort: by_weight"
  print "use_preset_vocabulary: false\nimport_tables: [pinyin_simp]\n..."
}
$1 == $2 && $1 ~ /^[A-Za-z]+$/ && length($1) >= 4 {
  printf "%s\t%s\t%d\n", $1,$2,int($3/weight_divisor)
}' "$staging/easy_en.dict.yaml" > "$staging/inkflow_mixed.dict.yaml"
mkdir -p "$destination/lua"
cp schemas/*.yaml "$destination/"
cp schemas/lua/*.lua "$destination/lua/"
mkdir -p "$destination/opencc"
cp schemas/opencc/inkflow_emoji.json build/deps/emoji.txt "$destination/opencc/"
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml "$destination/"
mv "$staging/easy_en.dict.yaml" "$staging/inkflow_mixed.dict.yaml" "$destination/"
