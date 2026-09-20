#!/bin/bash
# Allocate once per app build. The main checkout owns state shared by linked worktrees.
set -euo pipefail
cd "$(dirname "$0")/../.."
common=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
[[ $(basename "$common") == .git ]] || { echo 'Build numbering requires a non-bare checkout.' >&2; exit 1; }
main=$(dirname "$common")
state="$main/build/build-number"
mkdir -p "$state"
lock="$state/allocation.lock"
acquired=false
for ((attempt=0; attempt<100; attempt++)); do
  if mkdir "$lock" 2>/dev/null; then acquired=true; break; fi
  sleep 0.1
done
[[ "$acquired" == true ]] || { echo "Build-number allocation locked; inspect active allocators before removing $lock" >&2; exit 1; }
temporary=''
cleanup() { [[ -z "$temporary" ]] || rm -f "$temporary"; rmdir "$lock"; }
trap cleanup EXIT
maximum=0
observe() {
  local value=$1
  [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le 9 ]] || { echo 'Invalid build-number state or baseline.' >&2; exit 1; }
  (( value <= maximum )) || maximum=$value
}
observe "$(plutil -extract CFBundleVersion raw macOS/Info.plist)"
if [[ -e "$state/last" ]]; then observe "$(cat "$state/last")"; fi
for plist in "$main/build/InkFlow.app/Contents/Info.plist" "$PWD/build/InkFlow.app/Contents/Info.plist" \
  "$HOME/Library/Input Methods/InkFlow.app/Contents/Info.plist" '/Library/Input Methods/InkFlow.app/Contents/Info.plist'; do
  [[ ! -f "$plist" ]] || observe "$(plutil -extract CFBundleVersion raw "$plist")"
done
(( maximum < 999999999 )) || { echo 'Build number exhausted.' >&2; exit 1; }
next=$((maximum + 1))
temporary=$(mktemp "$state/.last.XXXXXX")
printf '%s\n' "$next" > "$temporary"
mv "$temporary" "$state/last"
temporary=''
printf '%s\n' "$next"
