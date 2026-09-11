#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-cleanup.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"; mkdir -p "$repo/macOS/scripts" "$repo/build/releases/history" "$repo/build/swiftpm/cache" \
  "$repo/build/SettingsHarness.app" "$repo/build/unknown-failure" "$repo/build/gui-verification" "$repo/build/backups"
cp macOS/scripts/cleanup.sh "$repo/macOS/scripts/"
touch "$repo/build/releases/history/sentinel" "$repo/build/unknown-failure/sentinel" "$repo/build/gui-verification/failed.log"
for index in 1 2 3 4; do mkdir "$repo/build/backups/installation.$index"; touch -t "2026090${index}0101" "$repo/build/backups/installation.$index"; done
(
  cd "$repo"
  bash macOS/scripts/cleanup.sh > "$fixture/dry.log"
  [[ -d build/swiftpm && -d build/SettingsHarness.app && -d build/backups/installation.1 ]]
  grep -Fq '[SwiftPM cache]' "$fixture/dry.log"
  grep -Fq '[test harnesses]' "$fixture/dry.log"
  grep -Fq '[diagnostic logs, preserved]' "$fixture/dry.log"
  grep -Fq '[installation backups, keep 2]' "$fixture/dry.log"
  bash macOS/scripts/cleanup.sh --apply > "$fixture/apply.log"
  [[ ! -e build/swiftpm && ! -e build/SettingsHarness.app ]]
  [[ ! -e build/backups/installation.1 && ! -e build/backups/installation.2 ]]
  [[ -d build/backups/installation.3 && -d build/backups/installation.4 ]]
  [[ -f build/releases/history/sentinel && -f build/unknown-failure/sentinel && -f build/gui-verification/failed.log ]]
)
echo 'PASS cleanup: dry-run default, scoped apply, two backups retained, releases/failure evidence preserved'
