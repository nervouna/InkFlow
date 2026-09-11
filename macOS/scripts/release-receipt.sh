#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# -eq 4 && ( "$1" == create || "$1" == verify ) ]] || { echo 'Usage: release-receipt.sh create|verify BINARY ICON RECEIPT' >&2; exit 2; }
mode=$1; binary=$2; icon=$3; receipt=$4
fail() { echo "$*" >&2; exit 1; }
[[ -f "$binary" && ! -L "$binary" ]] || fail 'Missing verified installer executable.'
[[ -f "$icon" && ! -L "$icon" ]] || fail 'Missing verified installer icon.'
input_digest() {
  local manifest digest
  manifest=$(mktemp "${TMPDIR:-/tmp}/inkflow-installer-inputs.XXXXXX")
  git ls-files -z -- Package.swift macOS/Info.plist macOS/Installer macOS/Shared \
    macOS/scripts/build-installer.sh macOS/scripts/swift-package.sh | while IFS= read -r -d '' file; do
      [[ -e "$file" && ! -L "$file" ]] || fail "Missing installer input: $file"
      shasum -a 256 "$file"
    done > "$manifest"
  digest=$(shasum -a 256 "$manifest" | awk '{print $1}')
  rm -f "$manifest"
  printf '%s\n' "$digest"
}
commit=$(git rev-parse HEAD)
[[ -z $(git status --porcelain --untracked-files=normal) ]] || fail 'Installer receipt requires a clean commit.'
inputs=$(input_digest)
binary_sha=$(shasum -a 256 "$binary" | awk '{print $1}')
icon_sha=$(shasum -a 256 "$icon" | awk '{print $1}')
if [[ "$mode" == create ]]; then
  mkdir -p "$(dirname "$receipt")"
  temporary=$(mktemp "$(dirname "$receipt")/.installer-receipt.XXXXXX")
  plutil -create xml1 "$temporary"
  plutil -insert sourceCommit -string "$commit" "$temporary"
  plutil -insert installerInputsSHA256 -string "$inputs" "$temporary"
  plutil -insert installerExecutableSHA256 -string "$binary_sha" "$temporary"
  plutil -insert installerIconSHA256 -string "$icon_sha" "$temporary"
  mv "$temporary" "$receipt"
  exit 0
fi
[[ -f "$receipt" && ! -L "$receipt" ]] || fail 'Missing installer verification receipt.'
[[ $(plutil -extract sourceCommit raw "$receipt") == "$commit" ]] || fail 'Installer receipt commit does not match current source.'
[[ $(plutil -extract installerInputsSHA256 raw "$receipt") == "$inputs" ]] || fail 'Installer inputs changed after release verification.'
[[ $(plutil -extract installerExecutableSHA256 raw "$receipt") == "$binary_sha" ]] || fail 'Verified installer executable changed.'
[[ $(plutil -extract installerIconSHA256 raw "$receipt") == "$icon_sha" ]] || fail 'Verified installer icon changed.'
echo 'PASS verified installer receipt: commit, inputs, executable and icon'
