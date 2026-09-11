#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-receipt.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
git clone --quiet --shared --no-hardlinks "$PWD" "$fixture/repo"
cp macOS/scripts/release-receipt.sh macOS/scripts/build-installer.sh "$fixture/repo/macOS/scripts/"
(
  cd "$fixture/repo"
  git add macOS/scripts/release-receipt.sh macOS/scripts/build-installer.sh
  git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm 'fixture receipt scripts'
  mkdir -p build/receipt-fixture
  printf verified > build/receipt-fixture/installer; chmod +x build/receipt-fixture/installer
  printf verified-icon > build/receipt-fixture/AppIcon.icns
  bash macOS/scripts/release-receipt.sh create build/receipt-fixture/installer build/receipt-fixture/AppIcon.icns build/receipt-fixture/receipt.plist
  bash macOS/scripts/release-receipt.sh verify build/receipt-fixture/installer build/receipt-fixture/AppIcon.icns build/receipt-fixture/receipt.plist >/dev/null
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
