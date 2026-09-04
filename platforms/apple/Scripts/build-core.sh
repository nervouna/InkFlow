#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
apple_dir=${script_dir:h}
repo_root=${apple_dir:h:h}
generated_dir="$apple_dir/Generated"
native_build_dir="$generated_dir/NativeBuild"
products_dir="$generated_dir/NativeProducts"
headers_dir="$generated_dir/Headers"
xcframework="$generated_dir/InkFlowEngine.xcframework"

typeset -a slices
slices=(macos-arm64 ios-arm64 ios-simulator-arm64)

configure_slice() {
  local slice=$1
  local sysroot=$2
  local system_name=$3
  local deployment_target=$4
  local build_dir="$native_build_dir/$slice"

  typeset -a arguments
  arguments=(
    -S "$repo_root"
    -B "$build_dir"
    -G "Unix Makefiles"
    -DBUILD_TESTING=OFF
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$deployment_target"
    -DCMAKE_OSX_SYSROOT="$sysroot"
  )
  if [[ -n "$system_name" ]]; then
    arguments+=("-DCMAKE_SYSTEM_NAME=$system_name")
  fi
  cmake "${arguments[@]}"
  cmake --build "$build_dir" --target inkflow_engine --parallel
}

merge_slice() {
  local slice=$1
  local build_dir="$native_build_dir/$slice"
  local output_dir="$products_dir/$slice"
  local output="$output_dir/libInkFlowEngine.a"
  local unbounded="$output_dir/libInkFlowEngine.unbounded.a"
  local closure_object="$output_dir/InkFlowEngineClosure.o"
  typeset -a archives
  archives=(
    "$build_dir/engine/libinkflow_engine.a"
    "$build_dir/engine/third-party/librime/lib/librime.a"
    "$build_dir/engine/third-party/yaml-cpp/libyaml-cpp.a"
    "$build_dir/engine/third-party/leveldb/libleveldb.a"
    "$build_dir/engine/third-party/opencc/src/libopencc.a"
    "$build_dir/engine/third-party/marisa/libmarisa.a"
  )
  for archive in "${archives[@]}"; do
    if [[ ! -s "$archive" ]]; then
      print -u2 "Missing native archive for $slice: $archive"
      return 1
    fi
  done
  mkdir -p "$output_dir"
  /usr/bin/libtool -static -D -no_warning_for_no_symbols \
    -o "$unbounded" "${archives[@]}"

  local sdk platform deployment_target
  case "$slice" in
    macos-arm64)
      sdk=macosx
      platform=macos
      deployment_target=13.0
      ;;
    ios-arm64)
      sdk=iphoneos
      platform=ios
      deployment_target=16.0
      ;;
    ios-simulator-arm64)
      sdk=iphonesimulator
      platform=ios-simulator
      deployment_target=16.0
      ;;
  esac
  local sdk_version exports_file
  sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
  exports_file="$output_dir/exports.txt"
  sed 's/^/_/' "$repo_root/engine/exports/inkflow_engine.symbols" \
    > "$exports_file"
  xcrun --sdk "$sdk" ld -r -arch arm64 \
    -platform_version "$platform" "$deployment_target" "$sdk_version" \
    -keep_private_externs \
    -all_load "$unbounded" \
    -exported_symbols_list "$exports_file" \
    -o "$closure_object"
  /usr/bin/libtool -static -D -no_warning_for_no_symbols \
    -o "$output" "$closure_object"
  /usr/bin/lipo -info "$output" | grep -q 'arm64'

  local global_symbols_file="$output_dir/global-symbols.txt"
  local symbol_details_file="$output_dir/symbol-details.txt"
  /usr/bin/nm -gU "$output" | awk '{print $NF}' > "$global_symbols_file"
  /usr/bin/nm -m -gU "$output" > "$symbol_details_file"

  local symbol
  while IFS= read -r symbol; do
    [[ -z "$symbol" ]] && continue
    grep -qx "_$symbol" "$global_symbols_file"
  done < "$repo_root/engine/exports/inkflow_engine.symbols"
  grep -q ' private external _rime_get_api$' "$symbol_details_file"

  local public_symbols_file="$output_dir/public-symbols.txt"
  awk '/ external / && !/ private external / {print $NF}' "$symbol_details_file" \
    | sed 's/^_//' \
    | sort -u > "$public_symbols_file"
  if ! diff -u \
      <(grep -v '^[[:space:]]*$' "$repo_root/engine/exports/inkflow_engine.symbols" | sort) \
      "$public_symbols_file"; then
    print -u2 "Public symbol boundary mismatch for $slice"
    return 1
  fi
}

configure_slice macos-arm64 macosx "" 13.0
configure_slice ios-arm64 iphoneos iOS 16.0
configure_slice ios-simulator-arm64 iphonesimulator iOS 16.0

for slice in "${slices[@]}"; do
  merge_slice "$slice"
done

rm -rf "$headers_dir"
mkdir -p "$headers_dir"
cp "$repo_root/engine/include/inkflow/engine.h" "$headers_dir/engine.h"
cp "$apple_dir/Native/Headers/module.modulemap" "$headers_dir/module.modulemap"

rm -rf "$xcframework"
xcodebuild -create-xcframework \
  -library "$products_dir/macos-arm64/libInkFlowEngine.a" \
  -headers "$headers_dir" \
  -library "$products_dir/ios-arm64/libInkFlowEngine.a" \
  -headers "$headers_dir" \
  -library "$products_dir/ios-simulator-arm64/libInkFlowEngine.a" \
  -headers "$headers_dir" \
  -output "$xcframework"

probe_xcframework_slice() {
  local identifier=$1
  local sdk=$2
  local target=$3
  local slice_dir="$xcframework/$identifier"
  local library="$slice_dir/libInkFlowEngine.a"
  local headers="$slice_dir/Headers"
  local probe_dir="$products_dir/probes/$identifier"
  local sdk_path
  sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
  mkdir -p "$probe_dir"

  xcrun --sdk "$sdk" clang -std=c11 -Werror \
    -target "$target" -isysroot "$sdk_path" \
    -I "$headers" \
    -c "$apple_dir/Native/closure_consumer.c" \
    -o "$probe_dir/closure_consumer.o"
  xcrun --sdk "$sdk" clang++ \
    -target "$target" -isysroot "$sdk_path" \
    "$probe_dir/closure_consumer.o" "$library" \
    -o "$probe_dir/c-consumer"
  xcrun --sdk "$sdk" swiftc \
    -target "$target" -sdk "$sdk_path" \
    -I "$headers" \
    -module-cache-path "$probe_dir/ModuleCache" \
    "$apple_dir/Native/closure_consumer.swift" "$library" \
    -Xlinker -lc++ \
    -o "$probe_dir/swift-consumer"
}

probe_xcframework_slice macos-arm64 macosx arm64-apple-macos13.0
probe_xcframework_slice ios-arm64 iphoneos arm64-apple-ios16.0
probe_xcframework_slice ios-arm64-simulator iphonesimulator \
  arm64-apple-ios16.0-simulator

"$products_dir/probes/macos-arm64/c-consumer"
"$products_dir/probes/macos-arm64/swift-consumer"

print "Created $xcframework"
