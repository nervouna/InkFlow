#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: prepare-rime.sh DESTINATION}
source macOS/config/english.conf
mkdir -p "$destination"
staging=$(mktemp -d "$destination/.english.XXXXXX")
trap 'rm -rf "$staging"' EXIT
# Admit source records once, including every case and code alias. Both runtime
# dictionaries use this result; the complete upstream lexicon is build input only.
LC_ALL=C awk -v min_source_weight="$ENGLISH_MIN_SOURCE_WEIGHT" \
  -v weight_divisor="$MIXED_ENGLISH_WEIGHT_DIVISOR" '
function fail(message) {
  print "prepare-rime.sh: " message > "/dev/stderr"
  exit 1
}
BEGIN {
  FS=OFS="\t"
  if (min_source_weight !~ /^[0-9]+$/)
    fail("ENGLISH_MIN_SOURCE_WEIGHT must be a nonnegative integer")
  if (weight_divisor !~ /^[0-9]+([.][0-9]+)?$/ || weight_divisor+0 <= 0)
    fail("MIXED_ENGLISH_WEIGHT_DIVISOR must be positive")
  print "# Generated from rime-easy-en (LGPL-3.0); see bundled Licenses."
  print "# InkFlow admission policy applied; the full upstream source is a build dependency."
  print "---\nname: easy_en\nversion: '\''0.3-inkflow'\''\nsort: by_weight"
  print "use_preset_vocabulary: false\n..."
}
FILENAME == ARGV[1] {
  if ($0 ~ /^[[:space:]]*(#|$)/) next
  if (NF != 3 || $1 !~ /^[A-Za-z]+$/ || $2 !~ /^[0-9]+$/ || $2+0 <= 0 || $3 !~ /[^[:space:]]/)
    fail("invalid english-boosts.tsv record at line " FNR ": expected word, positive source weight, and reason")
  if ($1 in boosts)
    fail("duplicate english-boosts.tsv word at line " FNR ": " $1)
  boosts[$1]=$2+0
  next
}
$0 == "..." { entries=1; next }
entries && $0 !~ /^[[:space:]]*(#|$)/ && NF >= 2 {
  source_weight=$3+0
  if (source_weight == 0 && ($1 in boosts)) source_weight=boosts[$1]
  if (source_weight < min_source_weight) next
  print $1,$2,source_weight
}' macOS/config/english-boosts.tsv build/deps/rime-easy-en-*/easy_en.dict.yaml \
  > "$staging/easy_en.dict.yaml"
# Mixed composition adds only its existing structural restrictions and scaling.
LC_ALL=C awk -v weight_divisor="$MIXED_ENGLISH_WEIGHT_DIVISOR" '
BEGIN {
  FS=OFS="\t"
  print "# Generated from rime-easy-en (LGPL-3.0); see bundled Licenses."
  print "# Original pinyin_simp remains an independent translator/user dictionary."
  print "---\nname: inkflow_mixed\nversion: '\''1.1'\''\nsort: by_weight"
  print "use_preset_vocabulary: false\nimport_tables: [pinyin_simp]\n..."
}
$1 == $2 && $1 ~ /^[A-Za-z]+$/ && length($1) >= 4 {
  print $1,$2,int($3/weight_divisor)
}' "$staging/easy_en.dict.yaml" > "$staging/inkflow_mixed.dict.yaml"
mkdir -p "$destination/lua"
cp schemas/*.yaml "$destination/"
cp schemas/lua/*.lua "$destination/lua/"
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml "$destination/"
mv "$staging/easy_en.dict.yaml" "$staging/inkflow_mixed.dict.yaml" "$destination/"
