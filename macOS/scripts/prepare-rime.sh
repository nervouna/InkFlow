#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: prepare-rime.sh DESTINATION}
source macOS/config/mixed-english.conf
mkdir -p "$destination/lua"
cp schemas/*.yaml "$destination/"
cp schemas/lua/*.lua "$destination/lua/"
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml "$destination/"
cp build/deps/rime-easy-en-*/easy_en.dict.yaml "$destination/"
# Keep the upstream standalone lexicon intact. The derived mixed lexicon uses
# common literal words only: aliases and tiny/unknown words are poor evidence
# for switching languages inside an unfinished Pinyin composition.
LC_ALL=C awk -v min_source_weight="$MIXED_ENGLISH_MIN_SOURCE_WEIGHT" \
  -v weight_divisor="$MIXED_ENGLISH_WEIGHT_DIVISOR" '
function fail(message) {
  print "prepare-rime.sh: " message > "/dev/stderr"
  exit 1
}
BEGIN {
  FS=OFS="\t"
  if (min_source_weight !~ /^[0-9]+$/)
    fail("MIXED_ENGLISH_MIN_SOURCE_WEIGHT must be a nonnegative integer")
  if (weight_divisor !~ /^[0-9]+([.][0-9]+)?$/ || weight_divisor+0 <= 0)
    fail("MIXED_ENGLISH_WEIGHT_DIVISOR must be positive")
  print "# Generated from rime-easy-en (LGPL-3.0); see bundled Licenses."
  print "# Original pinyin_simp remains an independent translator/user dictionary."
  print "---\nname: inkflow_mixed\nversion: '\''1.1'\''\nsort: by_weight"
  print "use_preset_vocabulary: false\nimport_tables: [pinyin_simp]\n..."
}
FILENAME == ARGV[1] {
  if ($0 ~ /^[[:space:]]*(#|$)/) next
  if (NF != 3 || $1 !~ /^[A-Za-z]+$/ || $2 !~ /^[0-9]+$/ || $2+0 <= 0 || $3 !~ /[^[:space:]]/)
    fail("invalid mixed-english-boosts.tsv record at line " FNR ": expected word, positive source weight, and reason")
  if ($1 in boosts)
    fail("duplicate mixed-english-boosts.tsv word at line " FNR ": " $1)
  boosts[$1]=$2+0
  next
}
$1 == $2 && $1 ~ /^[A-Za-z]+$/ && length($1) >= 4 {
  source_weight=$3+0
  if (source_weight == 0 && ($1 in boosts)) source_weight=boosts[$1]
  if (source_weight < min_source_weight) next
  print $1,$2,int(source_weight/weight_divisor)
}' macOS/config/mixed-english-boosts.tsv "$destination/easy_en.dict.yaml" \
  > "$destination/inkflow_mixed.dict.yaml"
