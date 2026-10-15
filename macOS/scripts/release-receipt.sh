#!/bin/bash
# The receipt freezes the commit and the allocated app build that release verification approved.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# -eq 2 && ( "$1" == create || "$1" == verify ) ]] || { echo 'Usage: release-receipt.sh create|verify RECEIPT' >&2; exit 2; }
mode=$1; receipt=$2
fail() { echo "$*" >&2; exit 1; }
[[ -z $(git status --porcelain --untracked-files=normal) ]] || fail 'Release receipt requires a clean commit.'
commit=$(git rev-parse HEAD)
if [[ "$mode" == create ]]; then
  app_build=$(plutil -extract CFBundleVersion raw build/InkFlow.app/Contents/Info.plist)
  [[ "$app_build" =~ ^[1-9][0-9]*$ && ${#app_build} -le 9 ]] || fail 'Invalid verified candidate build.'
  mkdir -p "$(dirname "$receipt")"
  temporary=$(mktemp "$(dirname "$receipt")/.release-receipt.XXXXXX")
  plutil -create xml1 "$temporary"
  plutil -insert sourceCommit -string "$commit" "$temporary"
  plutil -insert appBuild -string "$app_build" "$temporary"
  mv "$temporary" "$receipt"
  exit 0
fi
[[ -f "$receipt" && ! -L "$receipt" ]] || fail 'Missing release verification receipt.'
[[ $(plutil -extract sourceCommit raw "$receipt") == "$commit" ]] || fail 'Release receipt commit does not match current source.'
echo 'PASS verified release receipt: commit'
