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
}
reject() {
  local output=$1; shift
  for gate in "$@"; do ! grep -Fxq "$gate" <<< "$output" || { echo "Unexpected gate: $gate" >&2; exit 1; }; done
}

output=$(plan README.md AGENTS.md macOS/DEVELOPMENT.md)
expect "$output" core bundle-deep
reject "$output" settings-gui candidate-controller-gui installer release-tools
output=$(plan macOS/Sources/SmartSettingsView.swift)
expect "$output" core bundle-deep settings-gui
output=$(plan macOS/Sources/Settings.swift)
expect "$output" core bundle-deep settings-gui candidate-controller-gui
output=$(plan macOS/Sources/AISuggestionPanel.swift macOS/Sources/InputController.swift)
expect "$output" core bundle-deep candidate-controller-gui
output=$(plan macOS/Installer/InstallerCoordinator.swift macOS/Shared/InputSourceManager.swift)
expect "$output" core bundle-deep installer
output=$(plan .agents/skills/inkflow-release/scripts/package.sh macOS/DeveloperID.entitlements)
expect "$output" core bundle-deep release-tools
output=$(plan macOS/scripts/verify-developer-id.sh)
expect "$output" core bundle-deep release-tools
output=$(plan macOS/Info.plist)
expect "$output" core bundle-deep settings-gui candidate-controller-gui installer release-tools
[[ $(sort <<< "$output" | uniq -d | wc -l | tr -d ' ') == 0 ]]
output=$(plan Package.swift)
expect "$output" core bundle-deep settings-gui candidate-controller-gui installer release-tools
[[ $(sort <<< "$output" | uniq -d | wc -l | tr -d ' ') == 0 ]]
output=$(plan macOS/Sources/InputPreferences.swift)
expect "$output" core bundle-deep settings-gui candidate-controller-gui
reject "$output" installer release-tools
for changed_path in macOS/Sources/AISuggestionCoordinator.swift macOS/Sources/AIContext.swift macOS/Sources/AIStatistics.swift; do
  output=$(plan "$changed_path")
  expect "$output" core bundle-deep candidate-controller-gui
  [[ $(sort <<< "$output" | uniq -d | wc -l | tr -d ' ') == 0 ]]
done
output=$(plan macOS/Tests/NativeTestSupport.m macOS/Tests/include/NativeTestSupport.h)
expect "$output" core bundle-deep settings-gui candidate-controller-gui installer
reject "$output" release-tools
[[ $(sort <<< "$output" | uniq -d | wc -l | tr -d ' ') == 0 ]]
grep -Fq 'core_groups=(quality ai preparation dictionary-generator deployment engine controller settings dictionary-updates dictionary-activation termination)' macOS/scripts/release-verification.sh
! grep -Fxq 'bash macOS/scripts/test.sh' macOS/scripts/release-verification.sh
echo 'PASS release verification matrix: core/deep always, scoped GUI/installer/release-tool gates, docs ignored'
