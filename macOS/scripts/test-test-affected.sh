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

# macOS Bash 3.2 with nounset must accept the first manual item in an empty array.
bash -c 'set -euo pipefail; source macOS/scripts/test-impact.sh; impact_reset; impact_manual_add manual-settings; [[ ${#impact_manual[@]} == 1 && ${impact_manual[0]} == manual-settings ]]'

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

for path in macOS/scripts/probe-imk-candidate-lifetime.sh macOS/scripts/diagnostics/IMKCandidateLifetimeProbe.m; do
  new_case
  change "$path"; plan --run
  has 'Units: none'; has 'standalone native diagnostic'; has 'Manual: none'
  [[ ! -s "$INKFLOW_AFFECTED_LOG" ]]
done

new_case
change macOS/scripts/diagnostics/UnclassifiedProbe.m; plan
has 'quality-store'; has 'workflow'

new_case
change macOS/Sources/InputPreferences.swift; plan
has 'engine-options'; has 'controller'; has 'manual-input'; has 'manual-settings'; not_has 'manual-install'

new_case
change macOS/Tests/SettingsUITests.swift; plan
has 'Units: settings'; not_has 'quality-store'; not_has 'manual-input'; not_has 'manual-settings'; not_has 'manual-install'

new_case
change macOS/Sources/AIStatisticsStore.swift
change macOS/Sources/StartupDiagnostics.swift
git -C "$case_root" add macOS/Sources/AIStatisticsStore.swift
change macOS/Sources/AIStatisticsStore.swift
plan --run
has 'Changed paths (2):'; has 'ai-transport'; has 'ai-runtime'; has 'ai-statistics'; has 'startup-diagnostics'; has 'local-diagnostics'; not_has 'manual-input'

new_case
change macOS/Sources/DiagnosticFeedbackModel.swift; plan
has 'settings'; has 'local-diagnostics'; has 'diagnostic-archive'; has 'manual-settings'

for path in macOS/Sources/Engine.swift macOS/Sources/EngineAI.swift macOS/Sources/CustomPhrases.swift macOS/Sources/Settings.swift macOS/Sources/KeyboardShortcuts.swift; do
  new_case
  change "$path"; plan
  has 'controller'; has 'manual-input'
  case "$path" in
    macOS/Sources/Engine.swift) has 'ai-learning'; has 'deployment'; has 'dictionary-activation' ;;
    macOS/Sources/EngineAI.swift) has 'ai-learning'; has 'ai-headless' ;;
    macOS/Sources/CustomPhrases.swift) has 'settings'; has 'dictionary-activation' ;;
    macOS/Sources/Settings.swift|macOS/Sources/KeyboardShortcuts.swift) has 'settings'; has 'ai-transport'; has 'ai-runtime'; has 'ai-headless' ;;
  esac
done

for path in macOS/Sources/FeedbackReport.swift macOS/Sources/FeedbackSettingsView.swift macOS/Sources/AboutSettingsView.swift; do
  new_case
  change "$path"; plan
  has 'Units: settings'; has 'manual-settings'
  not_has 'manual-input'; not_has 'manual-install'; not_has 'ai-transport'
done

new_case
change macOS/Tests/SettingsUITests.swift; plan
has 'Units: settings'; not_has 'manual-input'; not_has 'manual-install'

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
change schemas/lua/inkflow_input_coverage.lua; plan
has 'engine-context'; has 'controller'; has 'quality-capture-query'; has 'dictionary-worker'; has 'bundle-fast'; has 'manual-input'

new_case
change macOS/Sources/Future.swift; plan
has 'quality-store'; has 'dictionary-worker'; has 'workflow'; has 'manual-install'

new_case
git -C "$case_root" mv macOS/Sources/AIStatistics.swift macOS/Sources/AIStatisticsStoreMoved.swift
plan
has 'macOS/Sources/AIStatistics.swift'; has 'macOS/Sources/AIStatisticsStoreMoved.swift'; has 'ai-statistics'

new_case
change macOS/Sources/AIStatistics.swift
git -C "$case_root" add macOS/Sources/AIStatistics.swift
git -C "$case_root" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'test: statistics change'
change macOS/Sources/InputPreferences.swift
plan --from HEAD~1
has 'macOS/Sources/AIStatistics.swift'; has 'ai-statistics'; has 'engine-options'

new_case
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 900001' "$case_root/macOS/Info.plist"
plan
has 'Units: quality-metadata workflow'; has 'bundle-fast'
not_has 'manual-input'; not_has 'manual-settings'; not_has 'manual-install'
git -C "$case_root" add macOS/Info.plist
git -C "$case_root" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m 'test: version-only change'
plan --from HEAD~1
has 'Units: quality-metadata workflow'; has 'bundle-fast'; not_has 'manual-input'
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

new_case
change macOS/scripts/build.sh
export INKFLOW_AFFECTED_FAIL=test
if plan --run; then exit 1; else [[ $? == 19 ]]; fi
has 'Not executed: bundle-fast'; ! grep -q '^check-bundle' "$INKFLOW_AFFECTED_LOG"
unset INKFLOW_AFFECTED_FAIL

for log in "$fixture"/commands-*; do ! grep -Eq 'gui|native|keychain|--live|install.sh' "$log"; done
echo 'PASS affected selection: coarse domains, version metadata, preparation and failure propagation'
