#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-rime-policy.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/macOS/scripts" "$fixture/macOS/config" "$fixture/macOS/Data" "$fixture/schemas" \
  "$fixture/build/deps/rime-pinyin-simp-fixture" "$fixture/build/deps/rime-easy-en-fixture"
cp macOS/scripts/prepare-rime.sh "$fixture/macOS/scripts/"
cp -R schemas/. "$fixture/schemas/"
printf '中文\tzhong wen\t1000\n' > "$fixture/build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml"
printf '微笑\t微笑 😊\n' > "$fixture/build/deps/emoji.txt"
cat > "$fixture/build/deps/rime-easy-en-fixture/easy_en.dict.yaml" <<'DATA'
---
name: easy_en
version: '0.2'
sort: by_weight
use_preset_vocabulary: false
...
email	email	0
Email	Email	0
emails	emails	0
computer	computer	998830
compute	compute	981698
widget	widget	0
widget	Widget	1
Widget	Widget	999999
novel	novel	980000
boundary	boundary	1
above	above	1
below	below	999999
api	api	999999
Alias	alias	999999
foo-bar	foo-bar	999999
unknown	unknown	999999
unrated	unrated
DATA
cat > "$fixture/macOS/Data/english-wordfreq.tsv" <<'DATA'
# Exact source text and observed Zipf; absence means missing evidence.
email	4.68
Email	4.68
emails	4.24
computer	4.97
compute	3.41
Widget	2.00
novel	3.00
boundary	4.00
above	4.01
below	3.99
api	4.50
Alias	4.50
foo-bar	4.50
DATA
configure() {
  printf 'ENGLISH_MIN_ZIPF=%s\nENGLISH_WEIGHT_SCALE=%s\nMIXED_ENGLISH_WEIGHT_DIVISOR=%s\n' "$1" "$2" "$3" \
    > "$fixture/macOS/config/english.conf"
}
records() {
  awk -F '\t' '$0 == "..." { entries=1; next } entries && NF == 3' "$1"
}
generate() {
  bash "$fixture/macOS/scripts/prepare-rime.sh" "$fixture/output"
  records "$fixture/output/easy_en.dict.yaml" > "$fixture/english.tsv"
  records "$fixture/output/inkflow_mixed.dict.yaml" > "$fixture/mixed.tsv"
  cmp "$fixture/build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml" "$fixture/output/pinyin_simp.dict.yaml"
  cmp "$fixture/build/deps/emoji.txt" "$fixture/output/opencc/emoji.txt"
  cmp "$fixture/schemas/opencc/inkflow_emoji.json" "$fixture/output/opencc/inkflow_emoji.json"
}
expect_failure() {
  cp "$fixture/output/easy_en.dict.yaml" "$fixture/before-english.yaml"
  cp "$fixture/output/inkflow_mixed.dict.yaml" "$fixture/before-mixed.yaml"
  if bash "$fixture/macOS/scripts/prepare-rime.sh" "$fixture/output" > "$fixture/error.log" 2>&1; then
    echo "FAIL: invalid policy accepted ($1)" >&2; exit 1
  fi
  if ! grep -q "$2" "$fixture/error.log"; then
    cat "$fixture/error.log" >&2
    echo "FAIL: missing policy error ($1)" >&2; exit 1
  fi
  cmp "$fixture/before-english.yaml" "$fixture/output/easy_en.dict.yaml"
  cmp "$fixture/before-mixed.yaml" "$fixture/output/inkflow_mixed.dict.yaml"
}

configure 4.0 250000 100
: > "$fixture/macOS/config/english-overrides.tsv"
generate
cat > "$fixture/expected.tsv" <<'DATA'
email	email	1170000
Email	Email	1170000
emails	emails	1060000
computer	computer	1242500
boundary	boundary	1000000
above	above	1002500
api	api	1125000
Alias	alias	1125000
foo-bar	foo-bar	1125000
DATA
diff -u "$fixture/expected.tsv" "$fixture/english.tsv"
cat > "$fixture/expected-mixed.tsv" <<'DATA'
email	email	11700
Email	Email	11700
emails	emails	10600
computer	computer	12425
boundary	boundary	10000
above	above	10025
DATA
diff -u "$fixture/expected-mixed.tsv" "$fixture/mixed.tsv"

# The engine mapping is configurable independently of observed frequencies.
configure 4.0 100000 100
generate
awk -F '\t' 'BEGIN {OFS="\t"} {$3=$3/2.5; print}' "$fixture/expected.tsv" > "$fixture/rescaled.tsv"
diff -u "$fixture/rescaled.tsv" "$fixture/english.tsv"
configure 4.0 250000 100

# Overrides cover absent and nonzero evidence, exact text aliases, and exclusion.
cat > "$fixture/macOS/config/english-overrides.tsv" <<'DATA'
widget	4.50	Supply missing evidence to every existing code alias
novel	4.10	Replace a nonzero observed frequency
email	0	Explicit exclusion even at a zero gate
unrated	4.001	Source weights are not used, including absent weights
ghost	9	Never create a missing source word
DATA
generate
cat > "$fixture/expected-overrides.tsv" <<'DATA'
Email	Email	1170000
emails	emails	1060000
computer	computer	1242500
widget	widget	1125000
widget	Widget	1125000
novel	novel	1025000
boundary	boundary	1000000
above	above	1002500
api	api	1125000
Alias	alias	1125000
foo-bar	foo-bar	1125000
unrated	unrated	1000250
DATA
diff -u "$fixture/expected-overrides.tsv" "$fixture/english.tsv"
# Only mixed scaling changes; its structural constraints remain independent.
cp "$fixture/mixed.tsv" "$fixture/mixed-before.tsv"
configure 4.0 250000 10
generate
diff -u "$fixture/expected-overrides.tsv" "$fixture/english.tsv"
awk -F '\t' 'BEGIN {OFS="\t"} {$3=$1=="unrated" ? 100025 : $3*10; print}' "$fixture/mixed-before.tsv" > "$fixture/scaled.tsv"
diff -u "$fixture/scaled.tsv" "$fixture/mixed.tsv"

configure 4.6 250000 100
generate
printf 'Email\tEmail\t1170000\ncomputer\tcomputer\t1242500\n' > "$fixture/high.tsv"
diff -u "$fixture/high.tsv" "$fixture/english.tsv"
configure 0 250000 100
generate
awk -F '\t' '$1 == "email" || $1 == "unknown" || $1 == "ghost" { exit 1 }' "$fixture/english.tsv"
# Duplicate dictionary rows and aliases get the same observed weight.
printf 'computer\tcomputer\t999000\ncomputer\tComputer\t1\n' >> "$fixture/build/deps/rime-easy-en-fixture/easy_en.dict.yaml"
configure 4.0 250000 100
generate
printf 'computer\tcomputer\t1242500\ncomputer\tComputer\t1242500\n' >> "$fixture/expected-overrides.tsv"
diff -u "$fixture/expected-overrides.tsv" "$fixture/english.tsv"
configure 9 250000 100
generate
test ! -s "$fixture/english.tsv"
test ! -s "$fixture/mixed.tsv"
for dictionary in easy_en inkflow_mixed; do
  grep -q "^name: $dictionary$" "$fixture/output/$dictionary.dict.yaml"
  grep -q '^\.\.\.$' "$fixture/output/$dictionary.dict.yaml"
done

configure 4 250000 0
expect_failure 'zero divisor' 'MIXED_ENGLISH_WEIGHT_DIVISOR'
configure invalid 250000 100
expect_failure 'invalid threshold' 'ENGLISH_MIN_ZIPF'
configure 4 0 100
expect_failure 'zero scale' 'ENGLISH_WEIGHT_SCALE'
configure 4 250000 100
for invalid in invalid NaN inf -1 9.01; do
  printf 'widget\t%s\treason\n' "$invalid" > "$fixture/macOS/config/english-overrides.tsv"
  expect_failure 'invalid override' 'english-overrides.tsv'
done
printf 'widget\t4\tfirst\nwidget\t5\tduplicate\n' > "$fixture/macOS/config/english-overrides.tsv"
expect_failure 'duplicate override' 'english-overrides.tsv'
: > "$fixture/macOS/config/english-overrides.tsv"
printf 'email\t5\n' >> "$fixture/macOS/Data/english-wordfreq.tsv"
expect_failure 'duplicate snapshot word' 'english-wordfreq.tsv'
printf 'email\tinvalid\n' > "$fixture/macOS/Data/english-wordfreq.tsv"
expect_failure 'malformed snapshot' 'english-wordfreq.tsv'
# Empty data is valid and cannot fall back to old source weights.
: > "$fixture/macOS/Data/english-wordfreq.tsv"
generate
test ! -s "$fixture/english.tsv"
test ! -s "$fixture/mixed.tsv"
rm "$fixture/macOS/Data/english-wordfreq.tsv"
expect_failure 'missing snapshot' 'english-wordfreq.tsv'

echo 'PASS Rime policy: observed/missing Zipf, shared inclusive admission, exact-case aliases, overrides/exclusion, scaling isolation, empty data/rules, malformed/duplicate data, Chinese preservation, failure without fallback'
