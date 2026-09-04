#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h:h}
apple_dir="$repo_root/platforms/apple"
project="$apple_dir/InkFlow.xcodeproj"
derived_data="$apple_dir/build/DerivedData"

for tool in cmake ruby xcodebuild xcodegen; do
  command -v "$tool" >/dev/null || {
    print -u2 "Missing required Apple build tool: $tool"
    exit 1
  }
done

ruby "$script_dir/check_dependency_lock.rb"
"$apple_dir/Scripts/build-core.sh"
"$apple_dir/Scripts/stage-schema.sh"

rm -rf "$project"
(
  cd "$apple_dir"
  xcodegen generate
)
project_digest() {
  find "$project" -type f -print \
    | LC_ALL=C sort \
    | while IFS= read -r file; do shasum -a 256 "$file"; done \
    | shasum -a 256 \
    | awk '{print $1}'
}
first_digest=$(project_digest)
rm -rf "$project"
(
  cd "$apple_dir"
  xcodegen generate
)
second_digest=$(project_digest)
if [[ "$first_digest" != "$second_digest" ]]; then
  print -u2 "XcodeGen output is not reproducible"
  exit 1
fi

rm -rf "$derived_data"
common_build_settings=(
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  "CODE_SIGN_IDENTITY="
  "DEVELOPMENT_TEAM="
  "PROVISIONING_PROFILE_SPECIFIER="
  ENABLE_DEBUG_DYLIB=NO
)
xcodebuild \
  -project "$project" \
  -scheme InkFlowAppleEngineTests \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  "${common_build_settings[@]}" \
  test
xcodebuild \
  -project "$project" \
  -scheme InkFlowInputMethod \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  "${common_build_settings[@]}" \
  build
xcodebuild \
  -project "$project" \
  -scheme InkFlowApp \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  "${common_build_settings[@]}" \
  build

xcframework="$apple_dir/Generated/InkFlowEngine.xcframework"
audit_dir="$derived_data/Audit"
mkdir -p "$audit_dir"
typeset -a libraries
while IFS= read -r library; do
  libraries+=("$library")
done < <(find "$xcframework" -name libInkFlowEngine.a -type f | LC_ALL=C sort)
if [[ ${#libraries[@]} -ne 3 ]]; then
  print -u2 "Expected three XCFramework static libraries, found ${#libraries[@]}"
  exit 1
fi

typeset -a observed_platforms
for library in "${libraries[@]}"; do
  [[ $(/usr/bin/lipo -archs "$library") == arm64 ]]
  identifier=${library:h:t}
  slice_audit_dir="$audit_dir/$identifier"
  mkdir -p "$slice_audit_dir"
  header_inventory="$audit_dir/$identifier.headers"
  (
    cd "${library:h}/Headers"
    find . -type f -print | LC_ALL=C sort
  ) > "$header_inventory"
  diff -u \
    <(printf '%s\n' ./engine.h ./module.modulemap) \
    "$header_inventory"
  (
    cd "$slice_audit_dir"
    /usr/bin/xcrun ar -x "$library"
  )
  closure_object="$slice_audit_dir/InkFlowEngineClosure.o"
  [[ -s "$closure_object" ]]
  build_info=$(/usr/bin/xcrun vtool -show-build "$closure_object")
  if [[ "$build_info" == *"platform IOSSIMULATOR"* ]]; then
    observed_platforms+=(iOS-simulator)
  elif [[ "$build_info" == *"platform MACOS"* ]]; then
    observed_platforms+=(macOS)
  elif [[ "$build_info" == *"platform IOS"* ]]; then
    observed_platforms+=(iOS)
  else
    print -u2 "Unexpected LC_BUILD_VERSION in $library"
    print -u2 "$build_info"
    exit 1
  fi

  details="$audit_dir/$identifier.symbols"
  /usr/bin/nm -m -gU "$library" > "$details"
  actual="$audit_dir/$identifier.public"
  awk '/ external / && !/ private external / {print $NF}' "$details" \
    | sed 's/^_//' \
    | sort -u > "$actual"
  expected="$audit_dir/$identifier.expected"
  grep -v '^[[:space:]]*$' "$repo_root/engine/exports/inkflow_engine.symbols" \
    | sort > "$expected"
  diff -u "$expected" "$actual"
  grep -q ' private external _rime_get_api$' "$details"
done
printf '%s\n' "${observed_platforms[@]}" | sort -u > "$derived_data/platforms.txt"
diff -u \
  <(printf '%s\n' iOS iOS-simulator macOS | sort) \
  "$derived_data/platforms.txt"

mac_app="$derived_data/Build/Products/Debug/InkFlow.app"
mac_executable="$mac_app/Contents/MacOS/InkFlow"
ios_app="$derived_data/Build/Products/Debug-iphonesimulator/InkFlow.app"
keyboard="$ios_app/PlugIns/InkFlowKeyboard.appex"
keyboard_executable="$keyboard/InkFlowKeyboard"
host_executable="$ios_app/InkFlow"

for artifact_path in "$mac_executable" "$keyboard_executable" "$host_executable"; do
  [[ -s "$artifact_path" ]] || {
    print -u2 "Missing built Apple artifact: $artifact_path"
    exit 1
  }
done

for schema_file in \
    default.yaml \
    inkflow.schema.yaml \
    inkflow.table.bin \
    inkflow.prism.bin \
    inkflow.reverse.bin; do
  for schema_root in \
      "$mac_app/Contents/Resources/Schema" \
      "$keyboard/Schema"; do
    [[ -s "$schema_root/$schema_file" ]] || {
      print -u2 "Missing bundled schema artifact: $schema_root/$schema_file"
      exit 1
    }
  done
done

[[ ! -e "$ios_app/Schema" ]]

for probe in \
    "$apple_dir/Generated/NativeProducts/probes/macos-arm64/c-consumer" \
    "$apple_dir/Generated/NativeProducts/probes/macos-arm64/swift-consumer" \
    "$apple_dir/Generated/NativeProducts/probes/ios-arm64/c-consumer" \
    "$apple_dir/Generated/NativeProducts/probes/ios-arm64/swift-consumer" \
    "$apple_dir/Generated/NativeProducts/probes/ios-arm64-simulator/c-consumer" \
    "$apple_dir/Generated/NativeProducts/probes/ios-arm64-simulator/swift-consumer"; do
  [[ -s "$probe" ]] || {
    print -u2 "Missing final-XCFramework closure probe: $probe"
    exit 1
  }
done

[[ $(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$mac_app/Contents/Info.plist") == true ]]
[[ $(/usr/libexec/PlistBuddy -c \
  'Print :InputMethodServerControllerClass' \
  "$mac_app/Contents/Info.plist") == InkFlowInputController ]]
mac_bundle_id=$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleIdentifier' "$mac_app/Contents/Info.plist")
[[ $(/usr/libexec/PlistBuddy -c 'Print :TISInputSourceID' \
  "$mac_app/Contents/Info.plist") == "$mac_bundle_id" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :InputMethodConnectionName' \
  "$mac_app/Contents/Info.plist") == "$mac_bundle_id.Connection" ]]
[[ $(/usr/libexec/PlistBuddy -c \
  'Print :TISIntendedLanguage' \
  "$mac_app/Contents/Info.plist") == zh-Hans ]]
[[ $(/usr/libexec/PlistBuddy -c \
  'Print :tsInputMethodCharacterRepertoireKey:0' \
  "$mac_app/Contents/Info.plist") == Hans ]]

[[ $(/usr/libexec/PlistBuddy -c \
  'Print :NSExtension:NSExtensionAttributes:RequestsOpenAccess' \
  "$keyboard/Info.plist") == false ]]
[[ $(/usr/libexec/PlistBuddy -c \
  'Print :NSExtension:NSExtensionPointIdentifier' \
  "$keyboard/Info.plist") == com.apple.keyboard-service ]]
[[ $(/usr/libexec/PlistBuddy -c \
  'Print :NSExtension:NSExtensionAttributes:PrimaryLanguage' \
  "$keyboard/Info.plist") == zh-Hans ]]
host_bundle_id=$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleIdentifier' "$ios_app/Info.plist")
keyboard_bundle_id=$(/usr/libexec/PlistBuddy -c \
  'Print :CFBundleIdentifier' "$keyboard/Info.plist")
[[ "$keyboard_bundle_id" == "$host_bundle_id.keyboard" ]]

verify_system_linkage() {
  local label=$1
  local executable=$2
  local linkage="$audit_dir/$label.linkage"
  local dependencies="$audit_dir/$label.dependencies"
  /usr/bin/xcrun otool -L "$executable" > "$linkage"
  awk 'NR > 1 {print $1}' "$linkage" > "$dependencies"
  if grep -Ev '^(/System/Library/|/usr/lib/)' "$dependencies"; then
    print -u2 "Non-system dynamic dependency found in $executable"
    exit 1
  fi
}

verify_system_linkage mac-input-method "$mac_executable"
verify_system_linkage ios-keyboard "$keyboard_executable"
verify_system_linkage ios-host "$host_executable"

for executable in "$mac_executable" "$keyboard_executable"; do
  symbols="$audit_dir/${executable:t}.symbols"
  /usr/bin/nm -gU "$executable" > "$symbols"
  grep -q '_inkflow_runtime_create$' "$symbols"
done

/usr/bin/nm -gU "$host_executable" > "$audit_dir/ios-host.symbols"
if grep -q '_inkflow_runtime_create$' "$audit_dir/ios-host.symbols"; then
  print -u2 "The iOS container unexpectedly links the engine"
  exit 1
fi

if find \
    "$mac_app" \
    "$ios_app" \
    "$derived_data/Build/Products/Debug/InkFlowAppleEngineTests.xctest" \
    \( -name '*.framework' -o -name '*.a' \) \
    -print -quit | grep -q .; then
  print -u2 "A static library or framework was unexpectedly embedded"
  exit 1
fi

if find "$mac_app" "$ios_app" \
    \( -name '_CodeSignature' -o -name 'embedded.mobileprovision' \
       -o -name '*.provisionprofile' \) \
    -print -quit | grep -q .; then
  print -u2 "A signature or provisioning profile exists in a signing-disabled product"
  exit 1
fi

if rg -n \
    'RequestsOpenAccess[^<]*(true|YES)|com\.apple\.security\.application-groups|URLSession|NWConnection|Network\.framework|NSAllowsArbitraryLoads|INKFLOW_ENGINE_BACKEND.*fake' \
    "$apple_dir" \
    --glob '!Generated/**' \
    --glob '!build/**'; then
  print -u2 "Unexpected Apple privacy, network, or fake-backend setting"
  exit 1
fi

if rg -n \
    '/U[s]ers/|/opt/homebrew|com\.apple\.security\.network\.client|CFNetwork' \
    "$apple_dir" \
    "$repo_root/README.md" \
    "$repo_root/docs/apple-acceptance.md" \
    --glob '!Generated/**' \
    --glob '!build/**' \
    --glob '!InkFlow.xcodeproj/**'; then
  print -u2 "Machine-local path or network capability found in Apple sources"
  exit 1
fi

git -C "$repo_root" diff --check
git -C "$repo_root" submodule foreach --recursive 'git diff --quiet && git diff --cached --quiet'

print "Apple verification passed"
print "XcodeGen digest: $second_digest"
print "Builds: macOS Debug and iOS Simulator Debug (signing disabled)"
