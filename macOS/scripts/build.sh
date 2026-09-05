#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
macOS/scripts/dependencies.sh
app="$PWD/build/InkFlow.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Rime" "$app/Contents/Resources/Licenses"
cp macOS/Info.plist "$app/Contents/Info.plist"
cp build/deps/dist/lib/librime.1.17.0.dylib "$app/Contents/Frameworks/librime.1.dylib"
cp schemas/*.yaml "$app/Contents/Resources/Rime/"
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml "$app/Contents/Resources/Rime/"
cp macOS/Licenses/* "$app/Contents/Resources/Licenses/"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 -I build/deps/dist/include macOS/Sources/*.m -framework AppKit -framework InputMethodKit -L build/deps/dist/lib -lrime -Wl,-rpath,@executable_path/../Frameworks -o "$app/Contents/MacOS/InkFlow"
plutil -lint "$app/Contents/Info.plist"
echo "Built $app"
