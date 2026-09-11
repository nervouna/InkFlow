#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
apply=false
keep=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=true; shift ;;
    --keep-install-backups) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || exit 2; keep=$2; shift 2 ;;
    --help) echo 'Usage: cleanup.sh [--apply] [--keep-install-backups COUNT]'; exit 0 ;;
    *) echo 'Unknown cleanup option.' >&2; exit 2 ;;
  esac
done
remove() { printf '%s\n' "$1"; [[ "$apply" != true ]] || rm -rf "$1"; }
echo '[SwiftPM cache]'
[[ ! -e build/swiftpm ]] || remove build/swiftpm
echo '[test harnesses]'
shopt -s nullglob
harnesses=(ai-adoption-learning-tests ai-credential-tests ai-headless-tests ai-live-tests ai-native-tests
  ai-pronunciation-tests ai-runtime-tests ai-statistics-tests ai-suggestion-tests bundle-engine-tests
  controller-initialization-tests controller-tests deployment-tests dictionary-activation-tests
  dictionary-generator-tests dictionary-update-tests engine-tests installer-core-tests installer-window-tests
  metadata-tests quality-capture-tests quality-store-tests quality-timing-tests serving-startup-tests settings-tests
  settings-ui-tests startup-diagnostics-tests termination-tests)
for name in "${harnesses[@]}"; do
  [[ ! -e "build/$name" ]] || remove "build/$name"
  [[ ! -e "build/$name.dSYM" ]] || remove "build/$name.dSYM"
done
for item in build/SettingsHarness.app build/installer-task/compiler; do [[ ! -e "$item" ]] || remove "$item"; done
echo '[diagnostic logs, preserved]'
for item in build/*.log build/*/*.log build/gui-verification build/ai-native-run.* build/serving-startup-run.* build/quality-evidence build/ai-statistics-evidence; do printf '%s\n' "$item"; done
echo "[installation backups, keep $keep]"
backups=(build/backups/installation.*)
if (( ${#backups[@]} > keep )); then
  while IFS= read -r item; do remove "$item"; done < <(
    for item in "${backups[@]}"; do printf '%s\t%s\n' "$(stat -f %m "$item")" "$item"; done | sort -n | head -n $(( ${#backups[@]} - keep )) | cut -f2-
  )
fi
echo '[always preserved]'
echo 'build/releases and unknown failure artifacts'
[[ "$apply" == true ]] && echo 'Cleanup applied.' || echo 'Dry run only; pass --apply to remove listed cache/harness/old-backup paths.'
