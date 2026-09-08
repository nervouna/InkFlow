#!/bin/bash
set -euo pipefail

usage() {
  echo 'Usage: release-note-candidates.sh FROM_REF TO_REF' >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
root=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$root"

from_ref=$1
to_ref=$2
git rev-parse --verify --quiet "$to_ref^{commit}" >/dev/null || {
  echo "Unknown ending ref: $to_ref" >&2
  exit 1
}
git rev-parse --verify --quiet "$from_ref^{commit}" >/dev/null || {
  echo "Unknown starting ref: $from_ref" >&2
  exit 1
}
git merge-base --is-ancestor "$from_ref" "$to_ref" || {
  echo "$from_ref is not an ancestor of $to_ref" >&2
  exit 1
}
range="$from_ref..$to_ref"

work=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-note-candidates.XXXXXX")
trap 'rm -rf "$work"' EXIT
included="$work/included"
excluded="$work/excluded"
: > "$included"
: > "$excluded"

candidate_pattern='^(feat|fix|perf|revert)(\([^)]*\))?!?:[[:space:]]+'
breaking_pattern='^[[:alnum:]_-]+(\([^)]*\))?!:[[:space:]]+'

while IFS=$'\t' read -r sha subject; do
  [[ -n "$sha" ]] || continue
  short=${sha:0:7}
  if [[ "$subject" =~ $candidate_pattern || "$subject" =~ $breaking_pattern ]]; then
    printf -- "- \`%s\` %s\n" "$short" "$subject" >> "$included"
  else
    printf -- "- \`%s\` %s\n" "$short" "$subject" >> "$excluded"
  fi
done < <(git log --first-parent --reverse --format='%H%x09%s' "$range")

printf '# Release note candidates: %s\n\n' "$range"
printf '## Suggested user-facing candidates\n\n'
if [[ -s "$included" ]]; then cat "$included"; else echo '- None'; fi
printf '\n## Excluded from the draft; review for mislabeled user impact\n\n'
if [[ -s "$excluded" ]]; then cat "$excluded"; else echo '- None'; fi
