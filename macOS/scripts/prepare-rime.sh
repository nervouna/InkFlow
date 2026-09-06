#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: prepare-rime.sh DESTINATION}
mkdir -p "$destination/lua"
cp schemas/*.yaml "$destination/"
cp schemas/lua/*.lua "$destination/lua/"
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml "$destination/"
cp build/deps/rime-easy-en-*/easy_en.dict.yaml "$destination/"
# Keep the upstream standalone lexicon intact. The derived mixed lexicon uses
# common literal words only: aliases and tiny/unknown words are poor evidence
# for switching languages inside an unfinished Pinyin composition.
LC_ALL=C awk '
BEGIN {
  FS=OFS="\t"
  print "# Generated from rime-easy-en (LGPL-3.0); see bundled Licenses."
  print "# Original pinyin_simp remains an independent translator/user dictionary."
  print "---\nname: inkflow_mixed\nversion: '\''1.1'\''\nsort: by_weight"
  print "use_preset_vocabulary: false\nimport_tables: [pinyin_simp]\n..."
}
$1 == $2 && $1 ~ /^[A-Za-z]+$/ && length($1) >= 4 {
  if ($3 < 990000 && $1 !~ /^[Ee]mails?$/) next
  weight=int($3/100)
  # Easy English assigns zero to this common word and its regular plural.
  # Correct only mixed admission/decoding; do not admit all zero-weight entries.
  if ($1 ~ /^[Ee]mails?$/) weight=9900
  print $1,$2,weight
}' "$destination/easy_en.dict.yaml" > "$destination/inkflow_mixed.dict.yaml"
