#!/bin/bash
# The verified receipt freezes the allocated candidate build; source plist is its floor.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 1 || $# == 2 ]] || { echo 'Usage: release-build.sh RECEIPT [APP_PLIST]' >&2; exit 2; }
receipt=$1
[[ -f "$receipt" && ! -L "$receipt" ]] || { echo 'Missing release build receipt.' >&2; exit 1; }
build=$(plutil -extract appBuild raw "$receipt")
floor=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
[[ "$build" =~ ^[1-9][0-9]*$ && ${#build} -le 9 && "$floor" =~ ^[1-9][0-9]*$ && ${#floor} -le 9 && "$build" -ge "$floor" ]] || {
  echo 'Invalid allocated release build or source floor.' >&2; exit 1;
}
if [[ $# == 2 ]]; then
  [[ $(plutil -extract CFBundleVersion raw "$2") == "$build" ]] || { echo 'Candidate build differs from verified receipt.' >&2; exit 1; }
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-build-plist.XXXXXX")
  trap 'rm -rf "$scratch"' EXIT
  cp macOS/Info.plist "$scratch/source.plist"
  cp "$2" "$scratch/app.plist"
  for file in "$scratch/source.plist" "$scratch/app.plist"; do
    plutil -remove CFBundleVersion "$file"
    plutil -convert xml1 "$file"
  done
  cmp "$scratch/source.plist" "$scratch/app.plist" || { echo 'Candidate plist differs beyond allocated build.' >&2; exit 1; }
fi
printf '%s\n' "$build"
