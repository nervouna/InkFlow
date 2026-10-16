#!/bin/bash
# Assemble the user-domain installer package for a built InkFlow.app. Unsigned unless --sign is given;
# notarization belongs to release packaging.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# -eq 2 || ( $# -eq 5 && $3 == --sign ) ]] || {
  echo 'Usage: build-pkg.sh /path/to/InkFlow.app /path/to/InkFlow.pkg [--sign APP_SHA1 INSTALLER_SHA1]' >&2; exit 2
}
app=$1 out=$2 app_identity='' installer_name=''
if [[ $# -eq 5 ]]; then
  app_identity=$4
  [[ $4 =~ ^[[:xdigit:]]{40}$ && $5 =~ ^[[:xdigit:]]{40}$ ]] || { echo 'Signing identities are certificate SHA-1 hashes.' >&2; exit 2; }
  # productbuild takes the certificate's common name, not a hash.
  installer_name=$(security find-identity -v -p basic | awk -v id="$5" 'toupper($2) == toupper(id) && /"Developer ID Installer: / {
    sub(/^[^"]*"/, ""); sub(/"[^"]*$/, ""); print; exit }')
  [[ -n "$installer_name" ]] || { echo 'No Developer ID Installer identity with that SHA-1 in the keychain.' >&2; exit 1; }
fi
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
# Notarization requires every Mach-O in the package to carry a Developer ID Application signature with the hardened runtime.
if [[ -n "$app_identity" ]]; then
  codesign --force --options runtime --timestamp --sign "$app_identity" "$work/scripts/register-input-source"
fi
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
sign=()
if [[ -n "$installer_name" ]]; then sign=(--sign "$installer_name" --timestamp); fi
productbuild --distribution macOS/Package/Distribution.xml --resources macOS/Package/Resources \
  --package-path "$work/products" ${sign[@]+"${sign[@]}"} "$work/InkFlow.pkg"
mv -f "$work/InkFlow.pkg" "$out"
printf 'Built %s (build %s, %s; nothing installed)\n' "$out" "$build" "$([[ -n "$installer_name" ]] && echo signed || echo unsigned)"
