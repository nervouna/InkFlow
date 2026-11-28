#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
usage() {
  echo 'Usage: build-pkg.sh APP PKG [--sign APP_SHA1 INSTALLER_SHA1] [--notes NOTES.md]' >&2
  exit 2
}
[[ $# -ge 2 ]] || usage
app=$1 out=$2 app_identity='' installer_identity='' installer_name='' notes=''
shift 2
while [[ $# -gt 0 ]]; do
  case $1 in
    --sign)
      [[ $# -ge 3 ]] || usage
      app_identity=$2
      installer_identity=$3
      shift 3
      ;;
    --notes)
      [[ $# -ge 2 && -f $2 ]] || usage
      notes=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
if [[ -n "$app_identity" ]]; then
  [[ $app_identity =~ ^[[:xdigit:]]{40}$ && $installer_identity =~ ^[[:xdigit:]]{40}$ ]] || {
    echo 'Signing identities are certificate SHA-1 hashes.' >&2
    exit 2
  }
  installer_name=$(security find-identity -v -p basic | awk -v id="$installer_identity" \
    'toupper($2) == toupper(id) && /"Developer ID Installer: / {
    sub(/^[^"]*"/, ""); sub(/"[^"]*$/, ""); print; exit }')
  [[ -n "$installer_name" ]] || { echo 'No Developer ID Installer identity with that SHA-1 in the keychain.' >&2; exit 1; }
fi
plist="$app/Contents/Info.plist"
[[ -d "$app" && ! -L "$app" && -f "$plist" ]] || { echo 'Application must be an existing InkFlow.app bundle.' >&2; exit 2; }
[[ $(plutil -extract CFBundleIdentifier raw "$plist") == io.damao.inputmethod.inkflow ]] || { echo 'Unexpected application bundle identity.' >&2; exit 1; }
codesign --verify --deep --strict "$app" >/dev/null 2>&1 || { echo 'Application signature does not verify; sign it first with install.sh or the release flow.' >&2; exit 1; }
build=$(plutil -extract CFBundleVersion raw "$plist")
version=$(plutil -extract CFBundleShortVersionString raw "$plist")
source macOS/scripts/swift-package.sh
mkdir -p build "$(dirname "$out")"
work=$(mktemp -d "$PWD/build/pkg-stage.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/root" "$work/scripts" "$work/products"
cp -R macOS/Package/Resources "$work/resources"
python3 - "$version" "$work/resources/welcome.html" ${notes:+"$notes"} <<'PY'
import html
import re
import sys
version, output = sys.argv[1], sys.argv[2]
items = []
if len(sys.argv) > 3:
    section = False
    for line in open(sys.argv[3], encoding='utf-8'):
        if line.startswith('#'):
            section = line.strip('# \n') == '更新内容'
        elif section and line.startswith('- '):
            items.append(line[2:].strip())
    if not items:
        raise SystemExit('Release notes have no 更新内容 items.')
def inline(text):
    text = html.escape(re.sub(r'\[([^]]+)\]\([^)]+\)', r'\1', text), quote=False)
    return re.sub(r'`([^`]+)`', r'<code>\1</code>', text)
body = f'<p><b>墨流拼音 {html.escape(version)}</b></p>\n'
if items:
    body = f'<p><b>{html.escape(version)} 更新内容</b></p>\n<ul>\n'
    body += ''.join(f'<li>{inline(item)}</li>\n' for item in items) + '</ul>\n'
open(output, 'w', encoding='utf-8').write(
    '<!DOCTYPE html>\n<html lang="zh-Hans">\n<head><meta charset="utf-8"></head>\n'
    '<body style="font: 13px -apple-system, sans-serif">\n' + body + '</body>\n</html>\n')
PY
ditto "$app" "$work/root/InkFlow.app"
cp macOS/Package/preinstall macOS/Package/postinstall "$work/scripts/"
printf '%s\n' "$build" > "$work/scripts/build-number"
build_swift_product register-input-source "$work/scripts/register-input-source" release
if [[ -n "$app_identity" ]]; then
  codesign --force --options runtime --timestamp --sign "$app_identity" "$work/scripts/register-input-source"
fi
pkgbuild --root "$work/root" --component-plist macOS/Package/component.plist --scripts "$work/scripts" \
  --identifier io.damao.inputmethod.inkflow.pkg --version "$version" --install-location 'Library/Caches/io.damao.inkflow.installer' --compression legacy \
  "$work/component.pkg"
pkgutil --expand "$work/component.pkg" "$work/component"
find "$work/component/Scripts" -name '._*' -delete
gzcat "$work/component/Payload" | bsdtar --format odc --exclude '._*' -czf "$work/Payload" @-
lsbom "$work/component/Bom" | grep -v '/\._' > "$work/bom.txt"
mkbom -i "$work/bom.txt" "$work/Bom"
mv "$work/Payload" "$work/Bom" "$work/component/"
pkgutil --flatten "$work/component" "$work/products/InkFlow-component.pkg"
sign=()
if [[ -n "$installer_name" ]]; then sign=(--sign "$installer_name" --timestamp); fi
productbuild --distribution macOS/Package/Distribution.xml --resources "$work/resources" \
  --package-path "$work/products" ${sign[@]+"${sign[@]}"} "$work/InkFlow.pkg"
mv -f "$work/InkFlow.pkg" "$out"
printf 'Built %s (build %s, %s; nothing installed)\n' "$out" "$build" "$([[ -n "$installer_name" ]] && echo signed || echo unsigned)"
