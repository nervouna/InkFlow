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
  *) echo 'Usage: install.sh --developer-id | --debug (development debugging only)' >&2; exit 2 ;;
esac
[[ -x "$app/Contents/MacOS/InkFlow" ]] || { echo 'Run macOS/scripts/build.sh first.' >&2; exit 1; }
# For Developer ID, the caller must verify the certificate OU before selecting it.
[[ -s "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib" ]] || { echo 'Missing Lua plugin; rebuild InkFlow first.' >&2; exit 1; }
codesign --force "${signing[@]}" "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
codesign --force "${signing[@]}" "$app/Contents/Frameworks/librime.1.dylib"
[[ -x "$app/Contents/MacOS/InkFlowDictionaryWorker" ]] || { echo "Missing dictionary helper; rebuild InkFlow first." >&2; exit 1; }
codesign --force "${signing[@]}" "$app/Contents/MacOS/InkFlowDictionaryWorker"
codesign --force "${signing[@]}" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
metadata=$(codesign -dv "$app" 2>&1)
if [[ "$mode" == --developer-id ]]; then
  [[ "$metadata" == *'TeamIdentifier=T7976FL2LP'* ]] || { echo 'Unexpected signing team.' >&2; exit 1; }
fi
[[ "$metadata" == *'Identifier=io.damao.inputmethod.inkflow'* ]] || { echo 'Unexpected bundle identifier.' >&2; exit 1; }
target="$HOME/Library/Input Methods/InkFlow.app"
updating=false
if [[ -e "$target" ]]; then updating=true; fi
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
if [[ "$updating" == true ]]; then
  if ! bash macOS/scripts/refresh-menu.sh; then
    echo '应用已更新，但输入菜单刷新未完成。可重试 bash macOS/scripts/refresh-menu.sh。' >&2
    exit 1
  fi
  echo '更新完成，请重新展开输入菜单查看名称和图标。菜单刷新不代表 InkFlow 引擎已重启或功能验收通过。'
else
  echo '首次安装：在系统设置 → 键盘 → 文本输入 → 编辑中添加墨流拼音（英文系统显示 InkFlow Pinyin），然后从输入菜单选择。'
fi
