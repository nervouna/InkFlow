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

new_case
change '.agents/skills/inkflow-quality-analysis/scripts/quality.py'; plan
has 'Units: quality-capture-query'; has 'input quality analysis skill'
not_has 'complete non-GUI coverage'; not_has 'Preparation: build.sh'

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
change Core/Sources/InkFlowDomain/InputPreferences.swift; plan
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

for path in Core/Sources/InkFlowRime/Engine.swift Core/Sources/InkFlowRime/EngineAI.swift macOS/Sources/CustomPhrases.swift macOS/Sources/Settings.swift macOS/Sources/KeyboardShortcuts.swift; do
  new_case
  change "$path"; plan
  has 'controller'; has 'manual-input'
  case "$path" in
    Core/Sources/InkFlowRime/Engine.swift) has 'ai-learning'; has 'deployment'; has 'dictionary-activation' ;;
    Core/Sources/InkFlowRime/EngineAI.swift) has 'ai-learning'; has 'ai-headless' ;;
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

for path in Core/Sources/InkFlowRimeNative/InkFlowRimeNative.cpp Core/Sources/CRime/CRime.c; do
  new_case
  change "$path"; plan
  has 'native mixed decoder and registration'; has 'shared-core'; has 'engine'; has 'ai-learning'
  has 'deployment'; has 'dictionary-activation'; has 'Preparation: build.sh'; has 'manual-input'
done

new_case
change macOS/Tests/SettingsUITests.swift; plan
has 'Units: settings'; not_has 'manual-input'; not_has 'manual-install'

new_case
change Core/Sources/InkFlowRime/VoiceLexicon.swift; plan
has 'voice-session'; has 'apple-voice'; has 'voice-lexicon'; has 'voice-controller'; has 'ai-learning'; has 'manual-input'

new_case
change macOS/Sources/VoiceLearning.swift; plan
has 'voice-session'; has 'voice-lexicon'; has 'voice-controller'; has 'ai-learning'; has 'quality-store'; has 'manual-input'

new_case
change Core/Sources/InkFlowDomain/VoiceLearningCoordinator.swift; plan
has 'shared-core'; has 'voice-controller'; has 'ai-learning'; has 'quality-store'; has 'manual-input'

new_case
change macOS/Sources/InputControllerVoice.swift; plan
has 'voice-controller'; has 'quality-store'; has 'quality-capture-query'; has 'manual-input'

new_case
change macOS/Sources/DictionarySettings.swift; plan
has 'settings'; has 'ai-learning'; has 'engine-english'; has 'voice-controller'; has 'manual-settings'

new_case
change schemas/lua/inkflow_ai_learning.lua; plan
has 'voice-lexicon'; has 'ai-learning'; has 'ai-headless'; has 'preparation'; has 'dictionary-worker'; has 'bundle-fast'

new_case
change schemas/lua/inkflow_english.lua; plan
has 'engine-english'; has 'voice-lexicon'; has 'voice-controller'; has 'ai-learning'; has 'preparation'; has 'dictionary-worker'; has 'bundle-fast'

new_case
change macOS/scripts/fixtures/rime-learning-contract/inkflow_learning_contract.lua; plan
has 'Units: ai-learning'; not_has 'manual-input'; not_has 'manual-settings'; not_has 'bundle-fast'

new_case
change schemas/lua/inkflow_mixed.lua; plan
has 'preparation'; has 'dictionary-generator'; has 'dictionary-worker'; has 'engine-english'; has 'ai-learning'; has 'manual-input'
has 'schemas/lua/inkflow_mixed.lua: personal mixed learning and provenance'

new_case
change schemas/lua/inkflow_input_coverage.lua; plan
has 'engine-context'; has 'controller'; has 'quality-capture-query'; has 'dictionary-worker'; has 'ai-learning'; has 'bundle-fast'; has 'manual-input'
has 'schemas/lua/inkflow_input_coverage.lua: personal mixed learning and provenance'

for path in schemas/lua/inkflow_short_conflict.lua schemas/inkflow_pinyin.schema.yaml schemas/inkflow_pinyin.custom.yaml; do
  new_case
  change "$path"; plan
  has 'ai-learning'; has "$path: personal mixed learning and provenance"
done

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
change Core/Sources/InkFlowDomain/InputPreferences.swift
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
change Core/Sources/InkFlowRime/DictionaryStore.swift; plan --run
[[ $(head -n 1 "$INKFLOW_AFFECTED_LOG") == 'build ' ]]
grep -Fq 'test ' "$INKFLOW_AFFECTED_LOG"
grep -Fxq 'check-bundle --fast' "$INKFLOW_AFFECTED_LOG"

for path in macOS/Resources/MenuIconTemplate.tiff Core/Sources/InkFlowRime/PackagedCache.swift Core/Tools/PackagedCacheTool/PackagedCacheTool.swift; do
  new_case
  change "$path"; plan
  has 'preparation'; has 'dictionary-worker'; has 'bundle-fast'
done

for path in Core/Sources/InkFlowRime/DictionaryCoordinator.swift Core/Sources/InkFlowRime/DictionarySourceClient.swift Core/Sources/InkFlowRime/DictionaryPreparation.swift Core/Tests/DictionaryPreparationFixture/DictionaryPreparationFixture.swift; do
  new_case
  change "$path"; plan
  has 'shared-core'; has 'dictionary-source'; has 'dictionary-store'; has 'dictionary-worker'; has 'dictionary-activation'
  case "$path" in
    Core/Sources/*) has 'bundle-fast' ;;
  esac
  case "$path" in
    */DictionaryCoordinator.swift) has 'local-diagnostics' ;;
  esac
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

for path in Core/Package.swift Core/scripts/test.sh Core/Sources/InkFlowDomain/Future.swift; do
  new_case
  change "$path"; plan
  has 'shared-core'; has 'manual-input'; has 'manual-settings'
done
echo 'PASS affected selection: shared/platform domains, version metadata, preparation and failure propagation'
