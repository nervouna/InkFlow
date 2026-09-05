#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="$PWD/build/InkFlow.app"
identity="${INKFLOW_SIGN_IDENTITY:?Set INKFLOW_SIGN_IDENTITY to the verified Developer ID certificate SHA1 (OU T7976FL2LP)}"
[[ -x "$app/Contents/MacOS/InkFlow" ]] || { echo 'Run macOS/scripts/build.sh first.' >&2; exit 1; }
# The caller must verify the certificate OU before selecting the identity.
codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Frameworks/librime.1.dylib"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
metadata=$(codesign -dv "$app" 2>&1)
[[ "$metadata" == *'TeamIdentifier=T7976FL2LP'* ]] || { echo 'Unexpected signing team.' >&2; exit 1; }
[[ "$metadata" == *'Identifier=io.damao.inkflow'* ]] || { echo 'Unexpected bundle identifier.' >&2; exit 1; }
target="$HOME/Library/Input Methods/InkFlow.app"
mkdir -p "$(dirname "$target")"
if [[ -e "$target" ]]; then
  backup="$target.backup.$(date +%Y%m%d%H%M%S)"
  [[ ! -e "$backup" ]] || { echo 'Backup path already exists.' >&2; exit 1; }
  mv "$target" "$backup"
  echo "Previous app preserved at $backup"
fi
ditto "$app" "$target"
codesign --verify --deep --strict "$target"
echo "Installed $target"
echo '在系统设置 → 键盘 → 文本输入 → 编辑中添加 InkFlow；必要时注销后重新登录。'
