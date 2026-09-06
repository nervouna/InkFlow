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
offer	offer	999319
email	email	0
Email	Email	0
emails	emails	0
Emails	Emails	0
computer	computer	998830
compute	compute	981698
widget	widget	0
novel	novel	980000
boundary	boundary	990000
below	below	989999
api	api	999999
Alias	alias	999999
foo-bar	foo-bar	999999
unknown	unknown	0
unrated	unrated
EOF

configure() {
  printf 'MIXED_ENGLISH_MIN_SOURCE_WEIGHT=%s\nMIXED_ENGLISH_WEIGHT_DIVISOR=%s\n' "$1" "$2" \
    > "$fixture/macOS/config/mixed-english.conf"
}

generate() {
  bash "$fixture/macOS/scripts/prepare-rime.sh" "$fixture/output"
  awk -F '\t' 'NF == 3' "$fixture/output/inkflow_mixed.dict.yaml" > "$fixture/actual.tsv"
  cmp "$fixture/build/deps/rime-easy-en-fixture/easy_en.dict.yaml" "$fixture/output/easy_en.dict.yaml"
  cmp "$fixture/build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml" "$fixture/output/pinyin_simp.dict.yaml"
}

expect_failure() {
  if bash "$fixture/macOS/scripts/prepare-rime.sh" "$fixture/output" > "$fixture/error.log" 2>&1; then
    echo "FAIL: invalid policy accepted ($1)" >&2
    exit 1
  fi
  if ! grep -q "$2" "$fixture/error.log"; then
    cat "$fixture/error.log" >&2
    echo "FAIL: missing policy error ($1)" >&2
    exit 1
  fi
}

configure 990000 100
cat > "$fixture/macOS/config/mixed-english-boosts.tsv" <<'EOF'
# Exact spelling, replacement source weight, rationale.
email	990000	Common mail term
Email	990000	Common mail term
emails	990000	Plural mail term
Emails	990000	Plural mail term
widget	995000	Fixture verifies a new zero-weight correction without code changes
novel	999999	Must not change an existing nonzero source weight
api	999999	Must not bypass the minimum word length
ghost	999999	Must not synthesize absent dictionary entries
unrated	990100	A missing source weight is treated as zero
EOF
generate
cat > "$fixture/expected.tsv" <<'EOF'
offer	offer	9993
email	email	9900
Email	Email	9900
emails	emails	9900
Emails	Emails	9900
computer	computer	9988
widget	widget	9950
boundary	boundary	9900
unrated	unrated	9901
EOF
diff -u "$fixture/expected.tsv" "$fixture/actual.tsv"

# Both policy variables apply to corrected and original source weights.
configure 998000 10
generate
printf 'offer\toffer\t99931\ncomputer\tcomputer\t99883\n' > "$fixture/expected.tsv"
diff -u "$fixture/expected.tsv" "$fixture/actual.tsv"

# Corrections use the configured divisor just like original source weights.
configure 990000 10
generate
cat > "$fixture/expected.tsv" <<'EOF'
offer	offer	99931
email	email	99000
Email	Email	99000
emails	emails	99000
Emails	Emails	99000
computer	computer	99883
widget	widget	99500
boundary	boundary	99000
unrated	unrated	99010
EOF
diff -u "$fixture/expected.tsv" "$fixture/actual.tsv"

# An empty correction list must not be confused with the dictionary input.
configure 990000 100
: > "$fixture/macOS/config/mixed-english-boosts.tsv"
generate
printf 'offer\toffer\t9993\ncomputer\tcomputer\t9988\nboundary\tboundary\t9900\n' > "$fixture/expected.tsv"
diff -u "$fixture/expected.tsv" "$fixture/actual.tsv"

configure 990000 0
expect_failure 'zero divisor' 'MIXED_ENGLISH_WEIGHT_DIVISOR'
configure invalid 100
expect_failure 'invalid threshold' 'MIXED_ENGLISH_MIN_SOURCE_WEIGHT'
configure 990000 100
printf 'widget\tinvalid\treason\n' > "$fixture/macOS/config/mixed-english-boosts.tsv"
expect_failure 'invalid correction weight' 'mixed-english-boosts.tsv'
printf 'widget\t995000\tfirst\nwidget\t996000\tduplicate\n' > "$fixture/macOS/config/mixed-english-boosts.tsv"
expect_failure 'duplicate correction' 'mixed-english-boosts.tsv'

echo 'PASS Rime policy: configurable threshold/divisor, zero-weight corrections, empty rules, admission boundaries, original dictionaries, invalid configuration'
