#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/test-groups.sh
source macOS/scripts/test-impact.sh
usage() { echo 'Usage: test-affected.sh [--from REF] [--run]'; }
from=''
run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) [[ $# -ge 2 && -n $2 ]] || { usage >&2; exit 2; }; from=$2; shift 2 ;;
    --run) run=true; shift ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [[ -n $from ]]; then
  from_commit=$(git rev-parse --verify --end-of-options "$from^{commit}" 2>/dev/null) || {
    echo "Unknown commit reference: $from" >&2; exit 2;
  }
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-affected.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
# --no-renames yields both removed and added names; NUL records preserve whitespace.
git diff --no-renames --name-only -z > "$scratch/paths"
git diff --cached --no-renames --name-only -z >> "$scratch/paths"
git ls-files --others --exclude-standard -z >> "$scratch/paths"
if [[ -n $from ]]; then git diff --no-renames --name-only -z "$from_commit..HEAD" >> "$scratch/paths"; fi
impact_reset
paths=()
while IFS= read -r -d '' path; do
  duplicate=false
  for existing in "${paths[@]}"; do [[ $existing != "$path" ]] || duplicate=true; done
  if ! $duplicate; then paths+=("$path"); impact_classify_git "$path" "${from_commit:-HEAD}"; fi
done < "$scratch/paths"
impact_expand
printf 'Changed paths (%s):\n' "${#paths[@]}"
for path in "${paths[@]}"; do printf '  %q\n' "$path"; done
printf 'Units: %s\n' "${test_units[*]:-none}"
for reason in "${impact_reasons[@]}"; do printf 'Reason: %s\n' "$reason"; done
steps=(diff-check)
if $impact_bundle || test_units_need_app; then
  steps+=(build)
  echo 'Preparation: build.sh for a fresh app/worker, then selected unit prerequisites'
else echo 'Preparation: selected unit prerequisites only'
fi
if [[ ${#test_units[@]} -gt 0 ]]; then steps+=(tests); fi
if $impact_bundle; then steps+=(bundle-fast); fi
if $impact_release_tools; then steps+=(release-tools); fi
printf 'Steps: %s\n' "${steps[*]}"
if [[ ${#impact_manual[@]} == 0 ]]; then echo 'Manual: none'
else
  for item in "${impact_manual[@]}"; do printf 'Manual: %s pending: %s\n' "$item" "$(impact_manual_description "$item")"; done
fi
$run || exit 0
remaining=("${steps[@]}")
report_failure() {
  local status=$?
  echo "FAIL affected step: $step (exit $status)" >&2
  echo "Not executed: ${remaining[*]:-none}" >&2
  exit "$status"
}
trap report_failure ERR
set -E
for step in "${steps[@]}"; do
  remaining=("${remaining[@]:1}")
  case "$step" in
    diff-check)
      git diff --check
      git diff --cached --check
      if [[ -n $from ]]; then git diff --check "$from_commit..HEAD"; fi ;;
    build) bash macOS/scripts/build.sh ;;
    tests) bash macOS/scripts/test.sh "${test_units[@]}" ;;
    bundle-fast) bash macOS/scripts/check-bundle.sh --fast ;;
    release-tools) bash .agents/skills/inkflow-release/scripts/test.sh ;;
  esac
done
echo 'PASS affected automated checks; listed manual acceptance remains pending.'
