#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-receipt.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
git clone --quiet --shared --no-hardlinks "$PWD" "$fixture/repo"
cp macOS/scripts/{release-receipt,release-build,build-installer}.sh "$fixture/repo/macOS/scripts/"
(
  cd "$fixture/repo"
  git add macOS/scripts/release-receipt.sh macOS/scripts/release-build.sh macOS/scripts/build-installer.sh
  git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm 'fixture receipt scripts'
  mkdir -p build/receipt-fixture
  mkdir -p build/InkFlow.app/Contents
  cp macOS/Info.plist build/InkFlow.app/Contents/Info.plist
  baseline=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
  plutil -replace CFBundleVersion -string "$((baseline + 1))" build/InkFlow.app/Contents/Info.plist
  printf verified > build/receipt-fixture/installer; chmod +x build/receipt-fixture/installer
  printf verified-icon > build/receipt-fixture/AppIcon.icns
  bash macOS/scripts/release-receipt.sh create build/receipt-fixture/installer build/receipt-fixture/AppIcon.icns build/receipt-fixture/receipt.plist
  bash macOS/scripts/release-receipt.sh verify build/receipt-fixture/installer build/receipt-fixture/AppIcon.icns build/receipt-fixture/receipt.plist >/dev/null
  [[ $(bash macOS/scripts/release-build.sh build/receipt-fixture/receipt.plist build/InkFlow.app/Contents/Info.plist) == "$((baseline + 1))" ]]
  ditto -c -k --keepParent build/InkFlow.app build/receipt-fixture/payload.zip
  bash macOS/scripts/build-installer.sh build/receipt-fixture/payload.zip build/receipt-fixture/Installer.app build/receipt-fixture/installer build/receipt-fixture/AppIcon.icns >/dev/null
  [[ $(plutil -extract CFBundleVersion raw build/receipt-fixture/Installer.app/Contents/Info.plist) == "$((baseline + 1))" ]]
  plutil -replace CFBundleVersion -string "$((baseline + 2))" build/InkFlow.app/Contents/Info.plist
  if bash macOS/scripts/release-build.sh build/receipt-fixture/receipt.plist build/InkFlow.app/Contents/Info.plist >/dev/null 2>&1; then exit 1; fi
  plutil -replace CFBundleVersion -string "$((baseline + 1))" build/InkFlow.app/Contents/Info.plist
  plutil -replace LSMinimumSystemVersion -string 99.0 build/InkFlow.app/Contents/Info.plist
  if bash macOS/scripts/release-build.sh build/receipt-fixture/receipt.plist build/InkFlow.app/Contents/Info.plist >/dev/null 2>&1; then exit 1; fi
  for changed in macOS/Installer/AppMain.swift Package.swift macOS/scripts/build-installer.sh; do
    cp "$changed" "$fixture/original"
    printf '\nchanged\n' >> "$changed"
    if bash macOS/scripts/release-receipt.sh verify build/receipt-fixture/installer build/receipt-fixture/AppIcon.icns build/receipt-fixture/receipt.plist >/dev/null 2>&1; then exit 1; fi
    cp "$fixture/original" "$changed"
  done
  printf changed >> build/receipt-fixture/installer
  if bash macOS/scripts/release-receipt.sh verify build/receipt-fixture/installer build/receipt-fixture/AppIcon.icns build/receipt-fixture/receipt.plist >/dev/null 2>&1; then exit 1; fi
  printf verified > build/receipt-fixture/installer; chmod +x build/receipt-fixture/installer
  printf changed >> build/receipt-fixture/AppIcon.icns
  if bash macOS/scripts/release-receipt.sh verify build/receipt-fixture/installer build/receipt-fixture/AppIcon.icns build/receipt-fixture/receipt.plist >/dev/null 2>&1; then exit 1; fi
)
echo 'PASS installer receipt: clean commit/input/executable/icon binding and post-verification drift rejection'
