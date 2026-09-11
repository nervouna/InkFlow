#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() {
  echo 'Usage: release-verification.sh [--from STABLE_TAG] [--plan-only --changed-paths FILE]'
}
from=""
plan_only=false
changed_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; from=$2; shift 2 ;;
    --plan-only) plan_only=true; shift ;;
    --changed-paths) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; changed_file=$2; shift 2 ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

declare -a gates=(core bundle-deep)
add_gate() {
  local candidate=$1 existing
  for existing in "${gates[@]}"; do [[ "$existing" == "$candidate" ]] && return; done
  gates+=("$candidate")
}
classify() {
  local file=$1
  case "$file" in
    macOS/Info.plist) add_gate settings-gui; add_gate candidate-controller-gui; add_gate installer; add_gate release-tools ;;
    macOS/Sources/Settings.swift) add_gate settings-gui; add_gate candidate-controller-gui ;;
    macOS/Sources/SmartSettingsView.swift|macOS/Sources/DictionarySettings.swift|macOS/Sources/DictionaryModels.swift|macOS/Sources/DictionaryStore.swift|macOS/Tests/Settings*|macOS/Tests/DictionarySettingsUI*|macOS/scripts/test-settings-ui.sh)
      add_gate settings-gui ;;
    macOS/Sources/*Candidate*|macOS/Sources/InputController.swift|macOS/Sources/AIInputPresentation.swift|macOS/Sources/AISettings.swift|macOS/Sources/AISuggestionPanel.swift|macOS/Sources/ApplicationBootstrap.swift|macOS/Sources/ApplicationLifecycle.swift|macOS/Sources/Engine.swift|macOS/Sources/NativeCandidates.*|macOS/Tests/AIControllerNativeTests.swift|macOS/Tests/ControllerInitializationTests.swift|macOS/scripts/test-ai-native.sh|macOS/scripts/test-controller-initialization.sh)
      add_gate candidate-controller-gui ;;
    macOS/Installer/*|macOS/Shared/InputSourceManager.swift|macOS/Shared/RegisterInputSourceBootstrap.swift|macOS/Tests/Installer*|macOS/scripts/build-installer.sh|macOS/scripts/check-installer-core.sh|macOS/scripts/test-installer-*)
      add_gate installer ;;
    .agents/skills/inkflow-release/*|macOS/DeveloperID.entitlements|macOS/scripts/check-bundle.sh|macOS/scripts/quality-metadata.sh|macOS/Tools/QualityBuildMetadata.swift)
      add_gate release-tools ;;
  esac
}

if [[ -n "$changed_file" ]]; then
  [[ -f "$changed_file" ]] || { echo 'Changed-path file does not exist.' >&2; exit 2; }
  while IFS= read -r file || [[ -n "$file" ]]; do [[ -z "$file" ]] || classify "$file"; done < "$changed_file"
else
  if [[ -z "$from" ]]; then
    while IFS= read -r tag; do
      if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then from=$tag; break; fi
    done < <(git tag --merged HEAD --sort=-version:refname)
  fi
  [[ -n "$from" ]] || { echo 'No stable release tag is an ancestor of HEAD.' >&2; exit 1; }
  git merge-base --is-ancestor "$from" HEAD || { echo "$from is not an ancestor of HEAD." >&2; exit 1; }
  while IFS= read -r file; do classify "$file"; done < <(git diff --name-only "$from..HEAD")
fi

if [[ "$plan_only" == true ]]; then printf '%s\n' "${gates[@]}"; exit 0; fi
[[ -z "$changed_file" ]] || { echo '--changed-paths is only valid with --plan-only.' >&2; exit 2; }
[[ -z $(git status --porcelain --untracked-files=normal) ]] || { echo 'Release verification requires a clean commit.' >&2; exit 1; }
git_dir=$(cd "$(git rev-parse --git-dir)" && pwd -P)
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
[[ "$git_dir" != "$common_dir" ]] || { echo 'Release verification must run in an isolated linked worktree.' >&2; exit 1; }
release_commit=$(git rev-parse HEAD)

echo "Release verification range: $from..HEAD"
bash macOS/scripts/build.sh
bash macOS/scripts/test.sh
bash macOS/scripts/test-workflow.sh
bash macOS/scripts/check-bundle.sh --deep
for gate in "${gates[@]:2}"; do
  case "$gate" in
    settings-gui) bash macOS/scripts/test-settings-ui.sh ;;
    candidate-controller-gui)
      bash macOS/scripts/test-controller-initialization.sh
      bash macOS/scripts/test-ai-native.sh
      ;;
    installer)
      bash macOS/scripts/test-installer-core.sh
      bash macOS/scripts/test-installer-window.sh
      ;;
    release-tools) bash .agents/skills/inkflow-release/scripts/test.sh ;;
  esac
done
[[ "$(git rev-parse HEAD)" == "$release_commit" && -z $(git status --porcelain --untracked-files=normal) ]] || {
  echo 'Release source changed during verification.' >&2; exit 1;
}
source macOS/scripts/swift-package.sh
receipt_dir=build/release-verification
mkdir -p "$receipt_dir"
build_swift_product InkFlowInstaller "$receipt_dir/InkFlowInstaller" release
[[ -f build/AppIcon.icns && ! -L build/AppIcon.icns ]] || { echo 'Verified app build did not produce AppIcon.icns.' >&2; exit 1; }
cp build/AppIcon.icns "$receipt_dir/AppIcon.icns"
[[ "$(git rev-parse HEAD)" == "$release_commit" && -z $(git status --porcelain --untracked-files=normal) ]] || {
  echo 'Release source changed while building the verified installer.' >&2; exit 1;
}
bash macOS/scripts/release-receipt.sh create "$receipt_dir/InkFlowInstaller" "$receipt_dir/AppIcon.icns" "$receipt_dir/installer.plist"
printf 'PASS release verification: %s\n' "${gates[*]}"
