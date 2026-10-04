#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# macOS awk collates distinct CJK strings as equal under UTF-8 locales; compare bytes.
awk() { LC_ALL=C command awk "$@"; }

check_repository_policy_word() {
  local word=$1 code=$2
  if ! awk -F '\t' -v word="$word" -v code="$code" '
      $1 == word { count++; valid = NF == 3 && $2 == code && $3 == "inkflow-maintained" }
      END { exit !(count == 1 && valid) }
    ' Core/Data/english-technology.tsv; then
    echo "FAIL: missing canonical technology source $code -> $word" >&2
    exit 1
  fi
  if ! awk -F '\t' -v word="$word" '
      $1 == word { count++; valid = NF == 6 && $2 == "inkflow-maintained" && $3 == "" && $4 == "" && $5 == "" && $6 == "product-policy-4.0" }
      END { exit !(count == 1 && valid) }
    ' Core/Data/english-technology-provenance.tsv; then
    echo "FAIL: missing InkFlow-maintained provenance for $word" >&2
    exit 1
  fi
  if ! awk -F '\t' -v word="$word" '
      $1 == word { count++; valid = NF == 3 && $2 == "4.0" && $3 ~ /[^[:space:]]/ }
      END { exit !(count == 1 && valid) }
    ' Core/config/english-overrides.tsv; then
    echo "FAIL: missing shared-gate policy override for $word" >&2
    exit 1
  fi
  test "$(awk -F '\t' -v word="$word" '$1 == word { count++ } END { print count + 0 }' Core/Data/english-wordfreq.tsv)" -eq 0
}

check_repository_policy_word eBPF ebpf
check_repository_policy_word Type-C typec
awk -F '\t' '
  NF && $0 !~ /^[[:space:]]*#/ {
    if (NF != 3 || $1 == "" || $2 !~ /^[a-z0-9]+$/ || ($3 != "inkflow-maintained" && $3 != "rime-ice-en-ext") || display[$1]++ || code[$2]++) exit 1
    rows++
  }
  END { if (!rows) exit 1 }
' Core/Data/english-technology.tsv
awk -F '\t' '
  FNR == NR {
    if (NF && $0 !~ /^[[:space:]]*#/) { expected[$1] = $3; sourceRows++ }
    next
  }
  NF && $0 !~ /^[[:space:]]*#/ {
    if (NF != 6 || !($1 in expected) || $2 != expected[$1] || seen[$1]++) exit 1
    provenanceRows++
  }
  END { if (!sourceRows || provenanceRows != sourceRows) exit 1 }
' Core/Data/english-technology.tsv Core/Data/english-technology-provenance.tsv
awk -F '\t' '
  NF && $0 !~ /^[[:space:]]*#/ {
    if (NF != 3 || $1 == "" || $2 !~ /^([0-8](\.[0-9]+)?|9(\.0+)?)$/ || $3 == "" || word[$1]++) exit 1
    rows++
  }
  END { if (!rows) exit 1 }
' Core/config/english-overrides.tsv

fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-rime-policy.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/Core/Tools/DictionaryGeneratorTool" "$fixture/Core/Sources/InkFlowDomain" "$fixture/Core/scripts" "$fixture/Core/config" "$fixture/Core/Data" "$fixture/schemas" \
  "$fixture/build/deps/rime-pinyin-simp-fixture" "$fixture/build/deps/rime-easy-en-fixture"
cp Core/scripts/prepare-rime.sh Core/scripts/prepare-spelling.sh "$fixture/Core/scripts/"
printf 'fixture package\n' > "$fixture/Core/Package.swift"
printf 'fixture entry\n' > "$fixture/Core/Tools/DictionaryGeneratorTool/main.swift"
printf 'fixture generator implementation\n' > "$fixture/Core/Sources/InkFlowDomain/DictionaryGenerator.swift"
printf 'fixture build generator\n' > "$fixture/Core/scripts/build-dictionary-generator.sh"
printf 'fixture SwiftPM wrapper\n' > "$fixture/Core/scripts/swift-package.sh"
: > "$fixture/Core/Data/english-technology.tsv"
# Isolate English policy fixtures from the independently tested Chinese/spelling generators.
# This stub exists only inside this test's temporary repository.
cat > "$fixture/Core/scripts/prepare-chinese.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "$1"
cp build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml "$1/"
shasum -a 256 Core/Package.swift Core/Tools/DictionaryGeneratorTool/main.swift Core/Sources/InkFlowDomain/DictionaryGenerator.swift \
  Core/scripts/build-dictionary-generator.sh Core/scripts/swift-package.sh | shasum -a 256 | awk '{print $1}' \
  > "$1/dictionary-manifest.json"
STUB
# Spelling must run after the generated Chinese dictionary has been copied. The
# shared generator's output and CLI parity are tested by test-dictionary-generator.sh.
cat > "$fixture/Core/scripts/prepare-spelling.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
test -s "$1/pinyin_simp.dict.yaml"
STUB
cp -R schemas/. "$fixture/schemas/"
printf '%s\n' '---' 'name: pinyin_simp' '...' > "$fixture/build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml"
printf '中文\tzhong wen\t1000\n' >> "$fixture/build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml"
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
API	api	999999
API	Api	999999
D	D	999999
Alias	alias	999999
foo-bar	foo-bar	999999
unknown	unknown	999999
unrated	unrated
DATA
cat > "$fixture/Core/Data/english-wordfreq.tsv" <<'DATA'
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
API	4.50
D	4.50
Alias	4.50
foo-bar	4.50
DATA
configure() {
  printf 'ENGLISH_MIN_ZIPF=%s\nENGLISH_WEIGHT_SCALE=%s\nMIXED_ENGLISH_WEIGHT_DIVISOR=%s\n' "$1" "$2" "$3" \
    > "$fixture/Core/config/english.conf"
}
records() {
  awk -F '\t' '$0 == "..." { entries=1; next } entries && NF == 3' "$1"
}
generate() {
  bash "$fixture/Core/scripts/prepare-rime.sh" "$fixture/output"
  records "$fixture/output/easy_en.dict.yaml" > "$fixture/english.tsv"
  records "$fixture/output/inkflow_mixed.dict.yaml" > "$fixture/mixed.tsv"
  cmp "$fixture/build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml" "$fixture/output/pinyin_simp.dict.yaml"
  cmp "$fixture/build/deps/emoji.txt" "$fixture/output/opencc/emoji.txt"
  cmp "$fixture/schemas/opencc/inkflow_emoji.json" "$fixture/output/opencc/inkflow_emoji.json"
}
expect_failure() {
  cp "$fixture/output/easy_en.dict.yaml" "$fixture/before-english.yaml"
  cp "$fixture/output/inkflow_mixed.dict.yaml" "$fixture/before-mixed.yaml"
  if bash "$fixture/Core/scripts/prepare-rime.sh" "$fixture/output" > "$fixture/error.log" 2>&1; then
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
: > "$fixture/Core/config/english-overrides.tsv"
generate
[[ -z $(find "$fixture/output" -name '.english.*' -print) ]]
cache_count=$(find "$fixture/build/rime-cache" -name complete -type f | wc -l | tr -d ' ')
cached_english=$(find "$fixture/build/rime-cache" -path '*/content/easy_en.dict.yaml' -type f)
touch -t 200001010000 "$cached_english"
generate
[[ ! "$fixture/output/easy_en.dict.yaml" -nt "$cached_english" && ! "$cached_english" -nt "$fixture/output/easy_en.dict.yaml" ]]
[[ $(find "$fixture/build/rime-cache" -name complete -type f | wc -l | tr -d ' ') == "$cache_count" ]]
[[ ! -e "$fixture/macOS" ]]
mkdir -p "$fixture/macOS/scripts"
cp macOS/scripts/prepare-rime.sh "$fixture/macOS/scripts/"
bash "$fixture/macOS/scripts/prepare-rime.sh" "$fixture/wrapper-output"
diff -r "$fixture/output" "$fixture/wrapper-output"
[[ $(find "$fixture/build/rime-cache" -name complete -type f | wc -l | tr -d ' ') == "$cache_count" ]]
receipt=$(cat "$fixture/output/dictionary-manifest.json")
for changed in Core/Sources/InkFlowDomain/DictionaryGenerator.swift Core/Tools/DictionaryGeneratorTool/main.swift Core/scripts/build-dictionary-generator.sh; do
  cp "$fixture/$changed" "$fixture/source-before"
  printf '\nchanged closure\n' >> "$fixture/$changed"
  generate
  [[ $(find "$fixture/build/rime-cache" -name complete -type f | wc -l | tr -d ' ') -eq $((cache_count + 1)) ]]
  [[ $(cat "$fixture/output/dictionary-manifest.json") != "$receipt" ]]
  mv "$fixture/source-before" "$fixture/$changed"
  cache_count=$((cache_count + 1))
done
cat > "$fixture/expected.tsv" <<'DATA'
email	email	1170000
Email	Email	1170000
emails	emails	1060000
computer	computer	1242500
boundary	boundary	1000000
above	above	1002500
api	api	1125000
API	api	1125000
API	Api	1125000
D	D	1125000
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
API	API	11250
API	Api	11250
D	D	11250
Alias	Alias	11250
DATA
diff -u "$fixture/expected-mixed.tsv" "$fixture/mixed.tsv"

# The engine mapping is configurable independently of observed frequencies.
configure 4.0 100000 100
generate
awk -F '\t' 'BEGIN {OFS="\t"} {$3=$3/2.5; print}' "$fixture/expected.tsv" > "$fixture/rescaled.tsv"
diff -u "$fixture/rescaled.tsv" "$fixture/english.tsv"
configure 4.0 250000 100

# Overrides cover absent and nonzero evidence, exact text aliases, and exclusion.
cat > "$fixture/Core/config/english-overrides.tsv" <<'DATA'
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
API	api	1125000
API	Api	1125000
D	D	1125000
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
# Duplicate dictionary rows collapse; distinct aliases get the same observed weight.
printf 'computer\tcomputer\t999000\ncomputer\tComputer\t1\n' >> "$fixture/build/deps/rime-easy-en-fixture/easy_en.dict.yaml"
configure 4.0 250000 100
generate
printf 'computer\tComputer\t1242500\n' >> "$fixture/expected-overrides.tsv"
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
  printf 'widget\t%s\treason\n' "$invalid" > "$fixture/Core/config/english-overrides.tsv"
  expect_failure 'invalid override' 'english-overrides.tsv'
done
printf 'widget\t4\tfirst\nwidget\t5\tduplicate\n' > "$fixture/Core/config/english-overrides.tsv"
expect_failure 'duplicate override' 'english-overrides.tsv'
: > "$fixture/Core/config/english-overrides.tsv"
printf 'email\t5\n' >> "$fixture/Core/Data/english-wordfreq.tsv"
expect_failure 'duplicate snapshot word' 'english-wordfreq.tsv'
printf 'email\tinvalid\n' > "$fixture/Core/Data/english-wordfreq.tsv"
expect_failure 'malformed snapshot' 'english-wordfreq.tsv'

# Curated technical spellings are explicit source data, still subject to the same gate.
printf 'computer\t4.97\n' > "$fixture/Core/Data/english-wordfreq.tsv"
printf 'TechUI\t4\tExplicit technology policy, not an observation\nC++\t4\tExplicit technology policy\n' > "$fixture/Core/config/english-overrides.tsv"
cat > "$fixture/Core/Data/english-technology.tsv" <<'DATA'
TechUI	techui	inkflow-maintained
TechUI	techuialias	inkflow-maintained
C++	cpp	rime-ice-en-ext
computer	computer	inkflow-maintained
computer	laptop	inkflow-maintained
Unknown	unknown	inkflow-maintained
DATA
generate
cat > "$fixture/expected-technology.tsv" <<'DATA'
computer	computer	1242500
computer	Computer	1242500
TechUI	techui	1000000
TechUI	techuialias	1000000
C++	cpp	1000000
computer	laptop	1242500
DATA
diff -u "$fixture/expected-technology.tsv" "$fixture/english.tsv"
cat > "$fixture/expected-technology-mixed.tsv" <<'DATA'
computer	computer	12425
computer	Computer	12425
TechUI	TechUI	10000
DATA
diff -u "$fixture/expected-technology-mixed.tsv" "$fixture/mixed.tsv"
configure 4.1 250000 100
generate
awk -F '\t' '$1 != "computer" {exit 1} END {if(NR != 3) exit 1}' "$fixture/english.tsv"
configure 0 250000 100
printf 'TechUI\t0\tExclude every alias of this exact display form\n' > "$fixture/Core/config/english-overrides.tsv"
generate
awk -F '\t' '$1 == "TechUI" || $1 == "C++" || $1 == "Unknown" {exit 1}' "$fixture/english.tsv"
cp "$fixture/Core/Data/english-technology.tsv" "$fixture/good-technology.tsv"
for invalid in $'Bad\tBad\tinkflow-maintained' $'Bad\tbad\tunknown-source' $'Bad\tbad' $' Bad\tbad\tinkflow-maintained'; do
  printf '%s\n' "$invalid" > "$fixture/Core/Data/english-technology.tsv"
  expect_failure 'malformed technology source' 'english-technology.tsv'
done
cat "$fixture/good-technology.tsv" "$fixture/good-technology.tsv" > "$fixture/Core/Data/english-technology.tsv"
expect_failure 'duplicate technology pair' 'english-technology.tsv'
rm "$fixture/Core/Data/english-technology.tsv"
expect_failure 'missing technology source' 'english-technology.tsv'
: > "$fixture/Core/Data/english-technology.tsv"
: > "$fixture/Core/config/english-overrides.tsv"
configure 4 250000 100
# Empty data is valid and cannot fall back to old source weights.
: > "$fixture/Core/Data/english-wordfreq.tsv"
generate
test ! -s "$fixture/english.tsv"
test ! -s "$fixture/mixed.tsv"
rm "$fixture/Core/Data/english-wordfreq.tsv"
expect_failure 'missing snapshot' 'english-wordfreq.tsv'

echo 'PASS Rime policy: observed/missing Zipf, shared inclusive admission, curated technology/aliases/deduplication, exact-case overrides/exclusion, scaling isolation, empty data/rules, malformed/duplicate data, Chinese preservation, failure without fallback'
