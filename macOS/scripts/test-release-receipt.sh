#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-receipt.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
git clone --quiet --shared --no-hardlinks "$PWD" "$fixture/repo"
cp macOS/scripts/{release-receipt,release-build}.sh "$fixture/repo/macOS/scripts/"
(
  cd "$fixture/repo"
  git add macOS/scripts/release-receipt.sh macOS/scripts/release-build.sh
  git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm 'fixture receipt scripts'
  mkdir -p build/receipt-fixture build/InkFlow.app/Contents
  cp macOS/Info.plist build/InkFlow.app/Contents/Info.plist
  baseline=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
  plutil -replace CFBundleVersion -string "$((baseline + 1))" build/InkFlow.app/Contents/Info.plist
  receipt=build/receipt-fixture/receipt.plist
  if bash macOS/scripts/release-receipt.sh create >/dev/null 2>&1; then exit 1; fi
  bash macOS/scripts/release-receipt.sh create "$receipt"
  bash macOS/scripts/release-receipt.sh verify "$receipt" >/dev/null
  # The receipt records the verified commit and the allocated build, nothing else.
  [[ $(plutil -p "$receipt" | grep -c '=>') == 2 ]]
  [[ $(plutil -extract sourceCommit raw "$receipt") == $(git rev-parse HEAD) ]]
  [[ $(plutil -extract appBuild raw "$receipt") == "$((baseline + 1))" ]]
  [[ $(bash macOS/scripts/release-build.sh "$receipt" build/InkFlow.app/Contents/Info.plist) == "$((baseline + 1))" ]]
  plutil -replace CFBundleVersion -string "$((baseline + 2))" build/InkFlow.app/Contents/Info.plist
  if bash macOS/scripts/release-build.sh "$receipt" build/InkFlow.app/Contents/Info.plist >/dev/null 2>&1; then exit 1; fi
  plutil -replace CFBundleVersion -string "$((baseline + 1))" build/InkFlow.app/Contents/Info.plist
  plutil -replace LSMinimumSystemVersion -string 99.0 build/InkFlow.app/Contents/Info.plist
  if bash macOS/scripts/release-build.sh "$receipt" build/InkFlow.app/Contents/Info.plist >/dev/null 2>&1; then exit 1; fi
  # Any change to the commit or the tree after verification invalidates the receipt.
  printf '\nchanged\n' >> macOS/Info.plist
  if bash macOS/scripts/release-receipt.sh verify "$receipt" >/dev/null 2>&1; then exit 1; fi
  if bash macOS/scripts/release-receipt.sh create build/receipt-fixture/dirty.plist >/dev/null 2>&1; then exit 1; fi
  git checkout -- macOS/Info.plist
  bash macOS/scripts/release-receipt.sh verify "$receipt" >/dev/null
  git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm 'fixture later commit'
  if bash macOS/scripts/release-receipt.sh verify "$receipt" >/dev/null 2>&1; then exit 1; fi
  git reset --hard -q HEAD~1
  plutil -replace sourceCommit -string stale "$receipt"
  if bash macOS/scripts/release-receipt.sh verify "$receipt" >/dev/null 2>&1; then exit 1; fi
)
echo 'PASS release receipt: commit and build binding, tree and commit drift rejection'
