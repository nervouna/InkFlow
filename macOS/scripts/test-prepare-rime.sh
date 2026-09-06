#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-rime-policy.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/macOS/scripts" "$fixture/macOS/config" "$fixture/schemas" \
  "$fixture/build/deps/rime-pinyin-simp-fixture" "$fixture/build/deps/rime-easy-en-fixture"
cp macOS/scripts/prepare-rime.sh "$fixture/macOS/scripts/"
cp -R schemas/. "$fixture/schemas/"
printf '中文\tzhong wen\t1000\n' > "$fixture/build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml"
cat > "$fixture/build/deps/rime-easy-en-fixture/easy_en.dict.yaml" <<'EOF'
# Fixture with the upstream dictionary header and record shape.
---
name: easy_en
version: '0.2'
sort: by_weight
use_preset_vocabulary: false
...
offer	offer	999319
email	email	0
Email	Email	0
emails	emails	0
Emails	Emails	0
computer	computer	998830
compute	compute	981698
widget	widget	0
widget	Widget	0
Widget	Widget	0
novel	novel	980000
boundary	boundary	990000
above	above	990001
below	below	989999
api	api	999999
Alias	alias	999999
foo-bar	foo-bar	999999
unknown	unknown	0
unrated	unrated
EOF

configure() {
  printf 'ENGLISH_MIN_SOURCE_WEIGHT=%s\nMIXED_ENGLISH_WEIGHT_DIVISOR=%s\n' "$1" "$2" \
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
}

expect_failure() {
  cp "$fixture/output/easy_en.dict.yaml" "$fixture/before-english.yaml"
  cp "$fixture/output/inkflow_mixed.dict.yaml" "$fixture/before-mixed.yaml"
  if bash "$fixture/macOS/scripts/prepare-rime.sh" "$fixture/output" > "$fixture/error.log" 2>&1; then
    echo "FAIL: invalid policy accepted ($1)" >&2
    exit 1
  fi
  if ! grep -q "$2" "$fixture/error.log"; then
    cat "$fixture/error.log" >&2
    echo "FAIL: missing policy error ($1)" >&2
    exit 1
  fi
  # Failure must not overwrite either dictionary with complete or partial input.
  cmp "$fixture/before-english.yaml" "$fixture/output/easy_en.dict.yaml"
  cmp "$fixture/before-mixed.yaml" "$fixture/output/inkflow_mixed.dict.yaml"
}

configure 990000 100
cat > "$fixture/macOS/config/english-boosts.tsv" <<'EOF'
# Exact spelling, replacement source weight, rationale.
email	990000	Common mail term
Email	990000	Common mail term
emails	990000	Plural mail term
Emails	990000	Plural mail term
widget	995000	Correct zero weights for this displayed spelling and its code aliases
novel	999999	Must not change an existing nonzero source weight
api	999999	Must not bypass the mixed minimum word length
ghost	999999	Must not synthesize absent dictionary entries
unrated	990100	A missing source weight is treated as zero
EOF
generate
cat > "$fixture/expected-english.tsv" <<'EOF'
offer	offer	999319
email	email	990000
Email	Email	990000
emails	emails	990000
Emails	Emails	990000
computer	computer	998830
widget	widget	995000
widget	Widget	995000
boundary	boundary	990000
above	above	990001
api	api	999999
Alias	alias	999999
foo-bar	foo-bar	999999
unrated	unrated	990100
EOF
diff -u "$fixture/expected-english.tsv" "$fixture/english.tsv"
cat > "$fixture/expected-mixed.tsv" <<'EOF'
offer	offer	9993
email	email	9900
Email	Email	9900
emails	emails	9900
Emails	Emails	9900
computer	computer	9988
widget	widget	9950
boundary	boundary	9900
above	above	9900
unrated	unrated	9901
EOF
diff -u "$fixture/expected-mixed.tsv" "$fixture/mixed.tsv"

# The one threshold admits both original and corrected records to both paths.
configure 998000 10
generate
cat > "$fixture/expected-high-english.tsv" <<'EOF'
offer	offer	999319
computer	computer	998830
api	api	999999
Alias	alias	999999
foo-bar	foo-bar	999999
EOF
diff -u "$fixture/expected-high-english.tsv" "$fixture/english.tsv"
printf 'offer\toffer\t99931\ncomputer\tcomputer\t99883\n' > "$fixture/expected-high-mixed.tsv"
diff -u "$fixture/expected-high-mixed.tsv" "$fixture/mixed.tsv"

# The divisor changes mixed weights only, including corrected entries.
configure 990000 10
generate
diff -u "$fixture/expected-english.tsv" "$fixture/english.tsv"
cat > "$fixture/expected-scaled.tsv" <<'EOF'
offer	offer	99931
email	email	99000
Email	Email	99000
emails	emails	99000
Emails	Emails	99000
computer	computer	99883
widget	widget	99500
boundary	boundary	99000
above	above	99000
unrated	unrated	99010
EOF
diff -u "$fixture/expected-scaled.tsv" "$fixture/mixed.tsv"

# An empty correction list must not be confused with the dictionary input.
configure 990000 100
: > "$fixture/macOS/config/english-boosts.tsv"
generate
cat > "$fixture/expected-unboosted.tsv" <<'EOF'
offer	offer	999319
computer	computer	998830
boundary	boundary	990000
above	above	990001
api	api	999999
Alias	alias	999999
foo-bar	foo-bar	999999
EOF
diff -u "$fixture/expected-unboosted.tsv" "$fixture/english.tsv"
printf 'offer\toffer\t9993\ncomputer\tcomputer\t9988\nboundary\tboundary\t9900\nabove\tabove\t9900\n' > "$fixture/expected-unboosted-mixed.tsv"
diff -u "$fixture/expected-unboosted-mixed.tsv" "$fixture/mixed.tsv"

# Duplicate source spellings remain separate admitted records; runtime deduplicates.
printf 'computer\tcomputer\t999000\ncomputer\tComputer\t1\n' >> "$fixture/build/deps/rime-easy-en-fixture/easy_en.dict.yaml"
generate
printf 'computer\tcomputer\t999000\n' >> "$fixture/expected-unboosted.tsv"
diff -u "$fixture/expected-unboosted.tsv" "$fixture/english.tsv"

# A policy may admit nothing; both outputs still have complete dictionary headers.
configure 1000000 100
generate
test ! -s "$fixture/english.tsv" && test ! -s "$fixture/mixed.tsv"
for dictionary in easy_en inkflow_mixed; do
  grep -q "^name: $dictionary$" "$fixture/output/$dictionary.dict.yaml"
  grep -q '^\.\.\.$' "$fixture/output/$dictionary.dict.yaml"
done

configure 990000 0
expect_failure 'zero divisor' 'MIXED_ENGLISH_WEIGHT_DIVISOR'
configure invalid 100
expect_failure 'invalid threshold' 'ENGLISH_MIN_SOURCE_WEIGHT'
configure 990000 100
printf 'widget\tinvalid\treason\n' > "$fixture/macOS/config/english-boosts.tsv"
expect_failure 'invalid correction weight' 'english-boosts.tsv'
printf 'widget\t995000\tfirst\nwidget\t996000\tduplicate\n' > "$fixture/macOS/config/english-boosts.tsv"
expect_failure 'duplicate correction' 'english-boosts.tsv'

echo 'PASS Rime policy: shared admission, boundary weights, aliases/case, zero/missing corrections, divisor isolation, empty rules/dictionaries, duplicate records, original Chinese, failure without fallback'
