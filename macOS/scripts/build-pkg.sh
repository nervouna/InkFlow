#!/bin/bash
# Assemble the user-domain installer package for a built InkFlow.app. Signing and notarization belong to release packaging.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# -eq 2 ]] || { echo 'Usage: build-pkg.sh /path/to/InkFlow.app /path/to/InkFlow.pkg' >&2; exit 2; }
app=$1 out=$2
plist="$app/Contents/Info.plist"
[[ -d "$app" && ! -L "$app" && -f "$plist" ]] || { echo 'Application must be an existing InkFlow.app bundle.' >&2; exit 2; }
[[ $(plutil -extract CFBundleIdentifier raw "$plist") == io.damao.inputmethod.inkflow ]] || { echo 'Unexpected application bundle identity.' >&2; exit 1; }
build=$(plutil -extract CFBundleVersion raw "$plist")
version=$(plutil -extract CFBundleShortVersionString raw "$plist")
source macOS/scripts/swift-package.sh
mkdir -p build "$(dirname "$out")"
work=$(mktemp -d "$PWD/build/pkg-stage.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root" "$work/scripts" "$work/products"
ditto "$app" "$work/root/InkFlow.app"
# The scripts quit and relaunch InkFlow through the lifecycle tool and check the build they were packaged with.
cp macOS/Package/preinstall macOS/Package/postinstall "$work/scripts/"
printf '%s\n' "$build" > "$work/scripts/build-number"
build_swift_product register-input-source "$work/scripts/register-input-source" release
pkgbuild --root "$work/root" --component-plist macOS/Package/component.plist --scripts "$work/scripts" \
  --identifier io.damao.inputmethod.inkflow.pkg --version "$version" --install-location 'Library/Input Methods' --compression legacy \
  "$work/component.pkg"
# Every locally created file carries a com.apple.provenance attribute, which pkgbuild archives as ._ entries
# beside each path. Rewrite the payload, its bill of materials and the scripts without them.
pkgutil --expand "$work/component.pkg" "$work/component"
find "$work/component/Scripts" -name '._*' -delete
gzcat "$work/component/Payload" | bsdtar --format odc --exclude '._*' -czf "$work/Payload" @-
lsbom "$work/component/Bom" | grep -v '/\._' > "$work/bom.txt"
mkbom -i "$work/bom.txt" "$work/Bom"
mv "$work/Payload" "$work/Bom" "$work/component/"
pkgutil --flatten "$work/component" "$work/products/InkFlow-component.pkg"
productbuild --distribution macOS/Package/Distribution.xml --resources macOS/Package/Resources \
  --package-path "$work/products" "$work/InkFlow.pkg"
mv -f "$work/InkFlow.pkg" "$out"
printf 'Built %s (build %s, unsigned; nothing installed)\n' "$out" "$build"
