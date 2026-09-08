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
function emit(word, code, effective, pair) {
  pair=word SUBSEP code
  if (pair in emitted) return
  if (word in overrides) effective=overrides[word]
  else if (word in observed) effective=observed[word]
  else return
  if (effective <= 0 || effective < min_zipf) return
  emitted[pair]=1
  printf "%s\t%s\t%d\n", word,code,int(effective*weight_scale+0.5)
}
BEGIN {
  FS=OFS="\t"
  if (!zipf(min_zipf)) fail("ENGLISH_MIN_ZIPF must be between 0 and 9")
  if (weight_scale !~ /^[0-9]+$/ || weight_scale+0 <= 0 || weight_scale+0 > 238609294)
    fail("ENGLISH_WEIGHT_SCALE must be a positive integer <= 238609294")
  if (weight_divisor !~ /^[0-9]+([.][0-9]+)?$/ || weight_divisor+0 <= 0)
    fail("MIXED_ENGLISH_WEIGHT_DIVISOR must be positive")
  print "# Generated from rime-easy-en (LGPL-3.0), curated rime-ice (GPL-3.0) and InkFlow technology entries."
  print "# Reweighted with wordfreq (CC BY-SA 4.0) and explicit InkFlow admission policy."
  print "# See bundled Licenses for source attribution and modification details."
  print "---\nname: easy_en\nversion: '\''0.5-inkflow'\''\nsort: by_weight"
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
FILENAME == ARGV[4] {
  if ($0 ~ /^[[:space:]]*(#|$)/) next
  if (NF != 3 || $1 !~ /[^[:space:]]/ || $1 ~ /[^ -~]/ || $1 ~ /^ | $/ ||
      $2 !~ /^[a-z]+$/ || ($3 != "rime-ice-en-ext" && $3 != "inkflow-maintained"))
    fail("invalid english-technology.tsv record at line " FNR ": expected display text, lowercase ASCII code, and source")
  pair=$1 SUBSEP $2
  if (pair in supplemental) fail("duplicate english-technology.tsv pair at line " FNR)
  supplemental[pair]=1
  emit($1,$2)
  next
}
$0 == "..." { entries=1; next }
entries && $0 !~ /^[[:space:]]*(#|$)/ && NF >= 2 {
  emit($1,$2)
}' macOS/Data/english-wordfreq.tsv macOS/config/english-overrides.tsv \
  build/deps/rime-easy-en-*/easy_en.dict.yaml macOS/Data/english-technology.tsv > "$staging/easy_en.dict.yaml"
# Mixed composition adds only its existing structural restrictions and scaling.
LC_ALL=C awk -v weight_divisor="$MIXED_ENGLISH_WEIGHT_DIVISOR" '
BEGIN {
  FS=OFS="\t"
  print "# Derived from the shared admitted English dictionary; see easy_en.dict.yaml for source attribution."
  print "# See bundled Licenses; original pinyin_simp remains an independent translator/user dictionary."
  print "---\nname: inkflow_mixed\nversion: '\''1.2'\''\nsort: by_weight"
  print "use_preset_vocabulary: false\nimport_tables: [pinyin_simp]\n..."
}
$1 == $2 && $1 ~ /^[A-Za-z]+$/ && length($1) >= 4 {
  printf "%s\t%s\t%d\n", $1,$2,int($3/weight_divisor)
}' "$staging/easy_en.dict.yaml" > "$staging/inkflow_mixed.dict.yaml"
mkdir -p "$destination/lua"
cp schemas/*.yaml "$destination/"
bash macOS/scripts/prepare-spelling.sh "$destination"
cp schemas/lua/*.lua "$destination/lua/"
mkdir -p "$destination/opencc"
cp schemas/opencc/* build/deps/emoji.txt "$destination/opencc/"
bash macOS/scripts/prepare-chinese.sh "$staging/chinese"
cp "$staging/chinese/"* "$destination/"
mv "$staging/easy_en.dict.yaml" "$staging/inkflow_mixed.dict.yaml" "$destination/"
