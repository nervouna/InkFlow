#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source_root=$PWD
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-affected.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
# A disposable clone gives real index/rename/ref behavior without git init or touching the caller's index.
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
mkdir -p "$case_root/build"
printf ignored > "$case_root/build/untracked.swift"
plan --run
has 'Units: none'
[[ ! -s "$INKFLOW_AFFECTED_LOG" ]]
new_case
change 'docs/a note.md'
plan --run
has 'docs/a note.md'
has 'Units: none'
[[ ! -s "$INKFLOW_AFFECTED_LOG" ]]
for input in '--unknown' '--from'; do
  if plan "$input"; then exit 1; else [[ $? == 2 ]]; fi
done
if plan --from absent-ref --run; then exit 1; else [[ $? == 2 ]]; fi
[[ ! -s "$INKFLOW_AFFECTED_LOG" ]]
new_case
change macOS/Sources/InputPreferences.swift
plan
has 'Units: engine-options controller settings'
has 'manual-input'; has 'manual-settings'; not_has 'manual-install'
[[ ! -s "$INKFLOW_AFFECTED_LOG" ]]
new_case
change macOS/Sources/AIStatisticsStore.swift
change macOS/Sources/StartupDiagnostics.swift
git -C "$case_root" add macOS/Sources/AIStatisticsStore.swift
change macOS/Sources/AIStatisticsStore.swift
plan --run
has 'Changed paths (2):'
has 'Units: ai-transport ai-runtime ai-statistics startup-diagnostics'
not_has 'manual-input'
grep -Fxq 'test ai-transport ai-runtime ai-statistics startup-diagnostics' "$INKFLOW_AFFECTED_LOG"
for path in macOS/Sources/AIStatistics.swift macOS/Sources/AIStatisticsStore.swift; do
  new_case
  change "$path"
  plan
  has 'Units: ai-transport ai-runtime ai-statistics'
  not_has 'manual-input'
done
for path in macOS/Tools/ai-statistics.py macOS/Tests/AIStatisticsTests.swift macOS/Tests/AIStatisticsQueryTests.py; do
  new_case
  change "$path"
  plan
  has 'Units: ai-statistics'
  not_has 'ai-transport'; not_has 'ai-runtime'; not_has 'manual-input'
done
new_case
change macOS/Tests/NativeTestSupport.m
plan
has 'ai-headless'; has 'controller'; has 'quality-capture-query'; has 'dictionary-activation'
new_case
change macOS/Tests/AIStatisticsTestSupport.swift
plan
has 'Units: ai-transport ai-runtime ai-statistics'
for path in macOS/Quality/ranking-sources.txt macOS/Quality/ranking-resources.txt; do
  new_case
  change "$path"
  plan
  has 'quality-metadata'; has 'workflow'; has 'bundle-fast'
done
for path in schemas/lua/inkflow_mixed.lua macOS/config/english-overrides.tsv; do
  new_case
  change "$path"
  plan
  has 'engine-english'; has 'dictionary-worker'; has 'manual-input'
done
new_case
change macOS/Sources/Future.swift
plan
has 'dictionary-worker'; has 'workflow'; has 'manual-input'; has 'manual-settings'; has 'manual-install'
new_case
change macOS/Tests/FutureTests.swift
plan
has 'dictionary-worker'; not_has 'manual-input'
new_case
git -C "$case_root" mv macOS/Sources/AIStatistics.swift macOS/Sources/AIStatisticsStoreMoved.swift
plan
has 'macOS/Sources/AIStatistics.swift'; has 'macOS/Sources/AIStatisticsStoreMoved.swift'
has 'ai-statistics'; has 'dictionary-worker'
new_case
change macOS/Sources/AIStatistics.swift
git -C "$case_root" add macOS/Sources/AIStatistics.swift
git -C "$case_root" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'test: statistics change'
change macOS/Sources/InputPreferences.swift
plan --from HEAD~1
has 'ai-statistics'; has 'engine-options'; has 'macOS/Sources/AIStatistics.swift'
for path in InputControllerCore InputControllerAI EngineAI ThunderPanel ThunderPresentation; do
  new_case
  change "macOS/Sources/$path.swift"
  plan
  has 'ai-headless'; has 'manual-input'
  [[ $path != EngineAI ]] || has 'ai-learning'
done
new_case
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 900001' "$case_root/macOS/Info.plist"
plan
has 'Units: quality-metadata workflow'; has 'bundle-fast'
not_has 'manual-input'; not_has 'manual-settings'; not_has 'manual-install'
git -C "$case_root" add macOS/Info.plist
git -C "$case_root" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'test: version-only change'
plan --from HEAD~1
has 'Units: quality-metadata workflow'; not_has 'manual-input'
original_minimum=$(plutil -extract LSMinimumSystemVersion raw "$case_root/macOS/Info.plist")
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 99.0' "$case_root/macOS/Info.plist"
git -C "$case_root" add macOS/Info.plist
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $original_minimum" "$case_root/macOS/Info.plist"
plan
has 'manual-input'; has 'manual-settings'; has 'manual-install'
new_case
change macOS/Sources/DictionaryStore.swift
plan --run
grep -Fxq 'build ' "$INKFLOW_AFFECTED_LOG"
[[ $(head -n 1 "$INKFLOW_AFFECTED_LOG") == 'build ' ]]
for path in macOS/Tests/TerminationTests.swift macOS/scripts/test-termination.sh; do
  new_case
  change "$path"
  plan --run
  has 'Units: termination'
  [[ $(head -n 1 "$INKFLOW_AFFECTED_LOG") == 'build ' ]]
  grep -Fxq 'test termination' "$INKFLOW_AFFECTED_LOG"
done
new_case
change macOS/scripts/build.sh
plan --run
has 'bundle-fast'
grep -Fxq 'check-bundle --fast' "$INKFLOW_AFFECTED_LOG"
new_case
change macOS/Sources/DictionaryStore.swift
export INKFLOW_AFFECTED_FAIL=build
if plan --run; then exit 1; else [[ $? == 19 ]]; fi
has 'Not executed:'
[[ $(wc -l < "$INKFLOW_AFFECTED_LOG" | tr -d ' ') == 1 ]]
unset INKFLOW_AFFECTED_FAIL
new_case
change macOS/scripts/build.sh
export INKFLOW_AFFECTED_FAIL=test
if plan --run; then exit 1; else [[ $? == 19 ]]; fi
has 'Not executed: bundle-fast'
! grep -q '^check-bundle' "$INKFLOW_AFFECTED_LOG"
unset INKFLOW_AFFECTED_FAIL
for log in "$fixture"/commands-*; do ! grep -Eq 'gui|native|keychain|--live|install.sh' "$log"; done
echo 'PASS affected selection: Git changes, explicit mapping, preparation and failure propagation'
