#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-verification.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
changed_file="$fixture/changed"
plan() { printf '%s\n' "$@" > "$changed_file"; bash macOS/scripts/release-verification.sh --plan-only --changed-paths "$changed_file"; }
expect() {
  local output=$1; shift
  for gate in "$@"; do grep -Fxq "$gate" <<< "$output" || { echo "Missing gate: $gate" >&2; exit 1; }; done
  ! grep -Eq 'gui|candidate-controller|^installer$' <<< "$output"
  [[ $(sort <<< "$output" | uniq -d | wc -l | tr -d ' ') == 0 ]]
}
reject() {
  local output=$1; shift
  for gate in "$@"; do ! grep -Fxq "$gate" <<< "$output" || { echo "Unexpected gate: $gate" >&2; exit 1; }; done
}
output=$(plan README.md AGENTS.md macOS/DEVELOPMENT.md)
expect "$output" core bundle-deep
reject "$output" manual-input manual-settings manual-install release-tools
output=$(plan macOS/Sources/SmartSettingsView.swift macOS/Sources/InputPreferences.swift)
expect "$output" core bundle-deep
reject "$output" manual-input manual-settings manual-install
for path in InputControllerCore InputControllerAI EngineAI AISuggestionPanel; do
  output=$(plan "macOS/Sources/$path.swift")
  expect "$output" core bundle-deep
  reject "$output" manual-input manual-settings manual-install
done
output=$(plan macOS/Installer/InstallerCoordinator.swift macOS/Shared/InputSourceManager.swift)
expect "$output" core bundle-deep manual-install
output=$(plan .agents/skills/inkflow-release/scripts/package.sh macOS/DeveloperID.entitlements)
expect "$output" core bundle-deep release-tools
for path in macOS/Info.plist Package.swift macOS/Sources/Unknown.swift; do
  output=$(plan "$path")
  expect "$output" core bundle-deep manual-install
  reject "$output" manual-input manual-settings
done
for path in AIStatistics AIStatisticsStore StartupDiagnostics; do
  output=$(plan "macOS/Sources/$path.swift")
  expect "$output" core bundle-deep
  reject "$output" manual-input manual-settings manual-install
done
for path in macOS/Sources/AIContext.swift macOS/Sources/AISuggestionCoordinator.swift \
  macOS/Sources/DictionaryGenerator.swift macOS/Sources/DictionaryToolBootstrap.swift macOS/DictionaryTool/main.swift; do
  output=$(plan "$path")
  expect "$output" core bundle-deep
  reject "$output" manual-input manual-settings manual-install
done
for path in macOS/Tests/AIRuntimeTests.swift macOS/scripts/test-ai-runtime.sh \
  macOS/Tests/DictionaryGeneratorTests.swift macOS/scripts/build-dictionary-generator.sh macOS/scripts/test-dictionary-generator.sh; do
  output=$(plan "$path")
  expect "$output" core bundle-deep
  reject "$output" manual-input manual-settings manual-install
done
output=$(plan macOS/Tests/NativeTestSupport.m macOS/Tests/UnknownTests.swift)
expect "$output" core bundle-deep
reject "$output" manual-input manual-settings manual-install
# Run the actual dispatcher in a clean linked fixture, stubbing expensive commands.
git clone --quiet --shared "$PWD" "$fixture/repo"
cp macOS/scripts/release-verification.sh macOS/scripts/test-impact.sh macOS/scripts/test-groups.sh "$fixture/repo/macOS/scripts/"
# Exercise the non-plan output with a change that remains a daily input/Settings handoff.
printf '\n' >> "$fixture/repo/macOS/Sources/InputPreferences.swift"
export INKFLOW_RELEASE_LOG="$fixture/commands"
for name in build test check-bundle release-receipt; do
  cat > "$fixture/repo/macOS/scripts/$name.sh" <<'STUB'
#!/bin/bash
name=$(basename "$0" .sh)
echo "$name $*" >> "$INKFLOW_RELEASE_LOG"
if [[ "$name" == build ]]; then mkdir -p build; printf icon > build/AppIcon.icns; fi
STUB
done
cat > "$fixture/repo/macOS/scripts/swift-package.sh" <<'STUB'
build_swift_product() { printf installer > "$2"; echo "product $1" >> "$INKFLOW_RELEASE_LOG"; }
STUB
cp "$fixture/repo/macOS/scripts/test.sh" "$fixture/repo/.agents/skills/inkflow-release/scripts/test.sh"
git -C "$fixture/repo" add macOS/scripts macOS/Sources/InputPreferences.swift .agents/skills/inkflow-release/scripts/test.sh
git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test: release dispatcher fixture'
git -C "$fixture/repo" worktree add --quiet --detach "$fixture/release" HEAD
bash "$fixture/release/macOS/scripts/release-verification.sh" --from HEAD~1 > "$fixture/output"
[[ $(grep -Fxc 'build ' "$INKFLOW_RELEASE_LOG") == 1 ]]
[[ $(grep -Fxc 'test all' "$INKFLOW_RELEASE_LOG") == 1 ]]
[[ $(grep -Fxc 'check-bundle --deep' "$INKFLOW_RELEASE_LOG") == 1 ]]
! grep -Eq 'gui|native|keychain|--live|installer-core|test-workflow' "$INKFLOW_RELEASE_LOG"
grep -q 'PASS automated release verification' "$fixture/output"
! grep -q '^PASS release verification:' "$fixture/output"
! grep -q '^Manual acceptance pending: manual-\(input\|settings\):' "$fixture/output"
grep -q '^GUI interaction is preaccepted on entry;' "$fixture/output"
# Real version-only release changes retain build checks without a typing requirement.
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 900002' "$fixture/repo/macOS/Info.plist"
git -C "$fixture/repo" add macOS/Info.plist
git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test: version-only release'
output=$(bash "$fixture/repo/macOS/scripts/release-verification.sh" --plan-only --from HEAD~1)
expect "$output" core bundle-deep release-tools
reject "$output" manual-input manual-settings manual-install
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 99.0' "$fixture/repo/macOS/Info.plist"
git -C "$fixture/repo" add macOS/Info.plist
git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test: compatibility change'
output=$(bash "$fixture/repo/macOS/scripts/release-verification.sh" --plan-only --from HEAD~1)
expect "$output" core bundle-deep manual-install
reject "$output" manual-input manual-settings
echo 'PASS release verification: one core/deep run, preaccepted GUI policy, change-based installation handoff'
