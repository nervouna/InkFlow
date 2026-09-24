#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Process and TIS observations must come from the real login session.
/bin/ps -p "$$" -o pid= >/dev/null || { echo 'Desktop process access unavailable; input-source state is unknown. Run installation outside the restricted sandbox.' >&2; exit 1; }
source macOS/scripts/sparkle-signing.sh
app="$PWD/build/InkFlow.app"
mode="${1:-}"
case "$mode" in
  --debug) signing=(--sign -); entitlements=macOS/Debug.entitlements ;;
  --developer-id)
    identity="${INKFLOW_SIGN_IDENTITY:?Set INKFLOW_SIGN_IDENTITY to the verified Developer ID certificate SHA1 (OU T7976FL2LP)}"
    signing=(--options runtime --timestamp --sign "$identity"); entitlements=macOS/DeveloperID.entitlements ;;
  *) echo 'Usage: install.sh --developer-id | --debug (development debugging only)' >&2; exit 2 ;;
esac
if [[ "$mode" == --developer-id ]]; then
  bash macOS/scripts/verify-developer-id.sh "$identity" T7976FL2LP
fi
[[ -x "$app/Contents/MacOS/InkFlow" ]] || { echo 'Run macOS/scripts/build.sh first.' >&2; exit 1; }
[[ -s "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib" ]] || { echo 'Missing Lua plugin; rebuild InkFlow first.' >&2; exit 1; }
codesign --force "${signing[@]}" "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
codesign --force "${signing[@]}" "$app/Contents/Frameworks/librime.1.dylib"
[[ -x "$app/Contents/MacOS/InkFlowDictionaryWorker" ]] || { echo "Missing dictionary helper; rebuild InkFlow first." >&2; exit 1; }
codesign --force "${signing[@]}" "$app/Contents/MacOS/InkFlowDictionaryWorker"
sign_sparkle "$app" "${signing[@]}"
codesign --force "${signing[@]}" --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
metadata=$(codesign -dvvv "$app" 2>&1)
if [[ "$mode" == --developer-id ]]; then
  verify_sparkle_developer_id "$app" T7976FL2LP
  [[ "$metadata" == *'TeamIdentifier=T7976FL2LP'* ]] || { echo 'Unexpected signing team.' >&2; exit 1; }
  [[ "$metadata" == *'Authority=Developer ID Application:'* ]] || { echo 'Expected Developer ID Application signature.' >&2; exit 1; }
fi
[[ "$metadata" == *'Identifier=io.damao.inputmethod.inkflow'* ]] || { echo 'Unexpected bundle identifier.' >&2; exit 1; }
target="$HOME/Library/Input Methods/InkFlow.app"
updating=false
if [[ -e "$target" ]]; then updating=true; fi
mkdir -p "$(dirname "$target")"
[[ ! -L "$target" ]] || { echo 'Refusing to replace a symlinked installation.' >&2; exit 1; }
stage=$(mktemp -d "$(dirname "$target")/.inkflow-install.XXXXXX")
replaced=false
verified=false
cleanup() {
  if [[ "$replaced" == true && "$verified" != true ]]; then
    echo "Installation verification failed; staged previous app and state retained at $stage" >&2
    return
  fi
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
fi
# The lifecycle helper waits for graceful shutdown before any installed file moves.
bash macOS/scripts/register.sh "$target" --prepare-update "$stage/state.json" "$stage/InkFlow.app"
if [[ -e "$target" ]]; then mv "$target" "$stage/previous"; fi
mv "$stage/InkFlow.app" "$target"
replaced=true
codesign --verify --deep --strict "$target"
bash macOS/scripts/register.sh "$target" --finish-update "$stage/state.json"
verified=true
echo "Installed and verified fresh process: $target ($mode)"
if [[ "$updating" == true ]]; then
  if ! bash macOS/scripts/refresh-menu.sh; then
    echo '应用已更新，但输入菜单刷新未完成。可重试 bash macOS/scripts/refresh-menu.sh。' >&2
    exit 1
  fi
  echo '更新完成：新进程路径和构建号已核验，原输入源状态已恢复。实际输入及语音仍需手动试用。'
else
  echo '首次安装：在系统设置 → 键盘 → 文本输入 → 编辑中添加墨流拼音（英文系统显示 InkFlow Pinyin），然后从输入菜单选择。'
fi
