#!/bin/bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo 'Usage: placeholder-notes.sh PREVIOUS_TAG' >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
printf '%s\n' '<!-- inkflow-ci-placeholder-notes -->'
printf '### 更新内容\n\n'
printf '%s\n\n' '- Placeholder from a CI dry run. Replace it with the public notes before publishing.'
bash "$here/release-note-candidates.sh" "$1" HEAD
