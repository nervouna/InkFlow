#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source_root=$PWD
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-affected.XXXXXX")
trap 'rm -rf "$fixture"' EXIT

# Real clones cover Git path discovery; stubbed commands keep this test about policy.
git clone --quiet --shared "$source_root" "$fixture/seed"
cp macOS/scripts/test-{affected,impact,groups}.sh "$fixture/seed/macOS/scripts/"
for script in build test check-bundle; do
  cat > "$fixture/seed/macOS/scripts/$script.sh" <<'STUB'
#!/bin/bash
name=$(basename "$0" .sh)
echo "$name $*" >> "$INKFLOW_AFFECTED_LOG"
[[ "$name" != "${INKFLOW_AFFECTED_FAIL:-}" ]] || exit 19
STUB
done
mkdir -p "$fixture/seed/.agents/skills/inkflow-release/scripts"
cp "$fixture/seed/macOS/scripts/test.sh" "$fixture/seed/.agents/skills/inkflow-release/scripts/test.sh"
git -C "$fixture/seed" add macOS/scripts .agents/skills/inkflow-release/scripts/test.sh
git -C "$fixture/seed" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'test: create affected runner fixture'

index=0
new_case() {
  index=$((index + 1))
  case_root="$fixture/case-$index"
  git clone --quiet --shared "$fixture/seed" "$case_root"
  export INKFLOW_AFFECTED_LOG="$fixture/commands-$index"
  : > "$INKFLOW_AFFECTED_LOG"
}
change() { mkdir -p "$(dirname "$case_root/$1")"; printf '\n# fixture\n' >> "$case_root/$1"; }
plan() { bash "$case_root/macOS/scripts/test-affected.sh" "$@" > "$fixture/output" 2>&1; }
has() { grep -Fq -- "$1" "$fixture/output" || { cat "$fixture/output"; echo "Missing: $1" >&2; exit 1; }; }
not_has() { ! grep -Fq -- "$1" "$fixture/output" || { cat "$fixture/output"; echo "Unexpected: $1" >&2; exit 1; }; }

new_case
mkdir -p "$case_root/build"; printf ignored > "$case_root/build/untracked.swift"
plan --run; has 'Units: none'; [[ ! -s "$INKFLOW_AFFECTED_LOG" ]]

new_case
change 'docs/a note.md'; plan --run
has 'Units: none'; [[ ! -s "$INKFLOW_AFFECTED_LOG" ]]

for input in '--unknown' '--from'; do
  if plan "$input"; then exit 1; else [[ $? == 2 ]]; fi
done
if plan --from absent-ref --run; then exit 1; else [[ $? == 2 ]]; fi

new_case
change macOS/Sources/InputPreferences.swift; plan
has 'engine-options'; has 'controller'; has 'manual-input'; has 'manual-settings'; not_has 'manual-install'

new_case
change macOS/Sources/AIStatisticsStore.swift; plan
has 'ai-transport'; has 'ai-runtime'; has 'ai-statistics'; not_has 'manual-input'

new_case
change macOS/Sources/VoiceLexicon.swift; plan
has 'voice-session'; has 'apple-voice'; has 'voice-lexicon'; has 'voice-controller'; has 'ai-learning'; has 'manual-input'

new_case
change schemas/lua/inkflow_ai_learning.lua; plan
has 'voice-lexicon'; has 'ai-learning'; has 'ai-headless'; has 'preparation'; has 'dictionary-worker'; has 'bundle-fast'

new_case
change schemas/lua/inkflow_mixed.lua; plan
has 'preparation'; has 'dictionary-generator'; has 'dictionary-worker'; has 'engine-english'; has 'manual-input'

new_case
change macOS/Sources/Future.swift; plan
has 'quality-store'; has 'dictionary-worker'; has 'workflow'; has 'manual-install'

new_case
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 900001' "$case_root/macOS/Info.plist"
plan
has 'Units: quality-metadata workflow'; has 'bundle-fast'
not_has 'manual-input'; not_has 'manual-settings'; not_has 'manual-install'
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 99.0' "$case_root/macOS/Info.plist"
plan
has 'quality-store'; has 'manual-input'; has 'manual-settings'; has 'manual-install'

new_case
change macOS/Sources/DictionaryStore.swift; plan --run
[[ $(head -n 1 "$INKFLOW_AFFECTED_LOG") == 'build ' ]]
grep -Fq 'test ' "$INKFLOW_AFFECTED_LOG"
grep -Fxq 'check-bundle --fast' "$INKFLOW_AFFECTED_LOG"

for path in macOS/Resources/MenuIconTemplate.tiff macOS/Sources/PackagedCache.swift macOS/Tools/PackagedCacheTool.swift; do
  new_case
  change "$path"; plan
  has 'preparation'; has 'dictionary-worker'; has 'bundle-fast'
done

new_case
change macOS/scripts/build.sh
export INKFLOW_AFFECTED_FAIL=build
if plan --run; then exit 1; else [[ $? == 19 ]]; fi
has 'Not executed:'; [[ $(wc -l < "$INKFLOW_AFFECTED_LOG" | tr -d ' ') == 1 ]]
unset INKFLOW_AFFECTED_FAIL

for log in "$fixture"/commands-*; do ! grep -Eq 'gui|native|keychain|--live|install.sh' "$log"; done
echo 'PASS affected selection: coarse domains, version metadata, preparation and failure propagation'
