#!/bin/bash
set -euo pipefail
case "${1:-}" in
  major|minor|patch) kind=$1 ;;
  *) echo 'Usage: bump-version.sh major|minor|patch [Info.plist]' >&2; exit 2 ;;
esac
[[ $# -le 2 ]] || exit 2
root=$(cd "$(dirname "$0")/../../../.." && pwd)
plist=${2:-$root/macOS/Info.plist}
version=$(plutil -extract CFBundleShortVersionString raw "$plist")
build=$(plutil -extract CFBundleVersion raw "$plist")
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'Expected a stable X.Y.Z version.' >&2; exit 1; }
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
[[ "$build" =~ ^[1-9][0-9]*$ ]] || { echo 'Expected a positive integer build.' >&2; exit 1; }
# Keep arithmetic within a practical, precisely representable range.
for number in "$major" "$minor" "$patch" "$build"; do
  [[ ${#number} -le 9 ]] || { echo 'Version component exceeds supported range.' >&2; exit 1; }
done
case "$kind" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
next="$major.$minor.$patch"
stage=$(mktemp "${plist}.XXXXXX")
trap 'rm -f "$stage"' EXIT
cp -p "$plist" "$stage"
plutil -replace CFBundleShortVersionString -string "$next" "$stage"
plutil -replace CFBundleVersion -string "$((build + 1))" "$stage"
plutil -lint "$stage" >/dev/null
mv "$stage" "$plist"
printf '%s (%s) -> %s (%s)\n' "$version" "$build" "$next" "$((build + 1))"
