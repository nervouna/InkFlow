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

source macOS/scripts/test-groups.sh
source macOS/scripts/test-impact.sh
impact_reset
classify() {
  if [[ -z "$changed_file" && -n "$from" ]]; then impact_classify_git "$1" "$from"
  else impact_classify "$1"
  fi
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
  from=$(git rev-parse --verify --end-of-options "$from^{commit}" 2>/dev/null) || { echo 'Unknown release baseline.' >&2; exit 2; }
  git merge-base --is-ancestor "$from" HEAD || { echo "$from is not an ancestor of HEAD." >&2; exit 1; }
  while IFS= read -r -d '' file; do classify "$file"; done < <(git diff --no-renames --name-only -z "$from..HEAD")
fi

gates=(core bundle-deep)
if $impact_release_tools; then gates+=(release-tools); fi
automated_gates=("${gates[@]}")
release_manual=()
if [[ ${#impact_manual[@]} -gt 0 ]]; then
  for item in "${impact_manual[@]}"; do
    [[ "$item" != manual-install ]] || release_manual+=("$item")
  done
fi
if [[ ${#release_manual[@]} -gt 0 ]]; then gates+=("${release_manual[@]}"); fi
if [[ "$plan_only" == true ]]; then printf '%s\n' "${gates[@]}"; exit 0; fi
[[ -z "$changed_file" ]] || { echo '--changed-paths is only valid with --plan-only.' >&2; exit 2; }
[[ -z $(git status --porcelain --untracked-files=normal) ]] || { echo 'Release verification requires a clean commit.' >&2; exit 1; }
git_dir=$(cd "$(git rev-parse --git-dir)" && pwd -P)
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
[[ "$git_dir" != "$common_dir" ]] || { echo 'Release verification must run in an isolated linked worktree.' >&2; exit 1; }
release_commit=$(git rev-parse HEAD)
if [[ -z "${INKFLOW_RELEASE_EVIDENCE_DIR:-}" ]]; then
  attempt_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  export INKFLOW_RELEASE_EVIDENCE_DIR="$PWD/build/release-verification-attempts/$attempt_id"
  mkdir -p "$INKFLOW_RELEASE_EVIDENCE_DIR/test-units"
  set +e
  bash "$0" --from "$from" 2>&1 | tee "$INKFLOW_RELEASE_EVIDENCE_DIR/release.log"
  status=${PIPESTATUS[0]}
  exit "$status"
fi
release_evidence_dir="$INKFLOW_RELEASE_EVIDENCE_DIR"
mkdir -p "$release_evidence_dir/test-units"
export INKFLOW_TEST_EVIDENCE_DIR="$release_evidence_dir/test-units"
test_priority=""
if [[ ${#impact_groups[@]} -gt 0 ]]; then
  expand_test_groups "${impact_groups[@]}"
  test_priority="${test_units[*]}"
fi

echo "Release verification range: $from..HEAD"
echo "Release evidence: $release_evidence_dir"
echo "Test priority: ${test_priority:-canonical}"
bash macOS/scripts/build.sh
INKFLOW_TEST_PRIORITY="$test_priority" bash macOS/scripts/test.sh all
bash macOS/scripts/check-bundle.sh --deep
if $impact_release_tools; then bash .agents/skills/inkflow-release/scripts/test.sh; fi

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
printf 'PASS automated release verification: %s\n' "${automated_gates[*]}"
if [[ ${#release_manual[@]} -gt 0 ]]; then
  for item in "${release_manual[@]}"; do
    printf 'Manual acceptance pending: %s: %s\n' "$item" "$(impact_manual_description "$item")"
  done
fi
echo 'GUI interaction is preaccepted on entry; installation acceptance remains separate and is required before publication when selected.'
