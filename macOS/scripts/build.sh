#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
macOS/scripts/dependencies.sh
app="$PWD/build/InkFlow.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources/Rime" "$app/Contents/Resources/Licenses"
cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns "$app/Contents/Resources/InputMethod.icns"
bash macOS/scripts/build-icon.sh
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
ditto macOS/Resources "$app/Contents/Resources"
cp macOS/Info.plist "$app/Contents/Info.plist"
cp build/deps/dist/lib/librime.1.17.0.dylib "$app/Contents/Frameworks/librime.1.dylib"
cp schemas/*.yaml "$app/Contents/Resources/Rime/"
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml "$app/Contents/Resources/Rime/"
cp macOS/Licenses/* "$app/Contents/Resources/Licenses/"
source macOS/scripts/swift-common.sh
rime_rpath='@executable_path/../Frameworks' build_swift "$app/Contents/MacOS/InkFlow" "${swift_sources[@]}" macOS/Sources/main.swift
plutil -lint "$app/Contents/Info.plist"
echo "Built $app"
