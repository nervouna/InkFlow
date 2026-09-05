#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="$PWD/build/InkFlow.app"
mode="${1:-}"
case "$mode" in
  --debug) signing=(--sign -); entitlements=macOS/Debug.entitlements ;;
  --developer-id)
    identity="${INKFLOW_SIGN_IDENTITY:?Set INKFLOW_SIGN_IDENTITY to the verified Developer ID certificate SHA1 (OU T7976FL2LP)}"
    signing=(--options runtime --timestamp --sign "$identity"); entitlements=macOS/DeveloperID.entitlements ;;
  *) echo 'Usage: install.sh --debug | --developer-id' >&2; exit 2 ;;
esac
[[ -x "$app/Contents/MacOS/InkFlow" ]] || { echo 'Run macOS/scripts/build.sh first.' >&2; exit 1; }
# For Developer ID, the caller must verify the certificate OU before selecting it.
codesign --force "${signing[@]}" "$app/Contents/Frameworks/librime.1.dylib"
codesign --force "${signing[@]}" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
metadata=$(codesign -dv "$app" 2>&1)
if [[ "$mode" == --developer-id ]]; then
  [[ "$metadata" == *'TeamIdentifier=T7976FL2LP'* ]] || { echo 'Unexpected signing team.' >&2; exit 1; }
fi
[[ "$metadata" == *'Identifier=io.damao.inputmethod.inkflow'* ]] || { echo 'Unexpected bundle identifier.' >&2; exit 1; }
target="$HOME/Library/Input Methods/InkFlow.app"
mkdir -p "$(dirname "$target")"
[[ ! -L "$target" ]] || { echo 'Refusing to replace a symlinked installation.' >&2; exit 1; }
stage=$(mktemp -d "$(dirname "$target")/.inkflow-install.XXXXXX")
cleanup() {
  if [[ -e "$stage/previous" && ! -e "$target" ]]; then mv "$stage/previous" "$target"; fi
  rm -rf "$stage"
}
trap cleanup EXIT
ditto "$app" "$stage/InkFlow.app"
codesign --verify --deep --strict "$stage/InkFlow.app"
if [[ -e "$target" ]]; then
  mkdir -p build/backups
  backup_dir=$(mktemp -d "$PWD/build/backups/installation.XXXXXX")
  ditto -c -k --keepParent "$target" "$backup_dir/InkFlow.zip"
  unzip -tq "$backup_dir/InkFlow.zip"
  echo "Previous app archived at $backup_dir/InkFlow.zip"
  mv "$target" "$stage/previous"
fi
mv "$stage/InkFlow.app" "$target"
codesign --verify --deep --strict "$target"
echo "Installed $target ($mode)"
macOS/scripts/register.sh "$target"
echo '在系统设置 → 键盘 → 文本输入 → 编辑中添加 InkFlow 简体拼音，然后从输入菜单选择。'
