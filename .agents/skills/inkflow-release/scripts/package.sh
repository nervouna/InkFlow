#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
  echo 'Usage: bash package.sh prepare|finish'
  echo 'Prepare signs the input method and retains its submission ZIP. Finish requires its stapled app.'
  echo 'No installation, notarization submission or publication. Existing outputs are preserved.'
  exit 0
fi
[[ $# -eq 1 && ( "$1" == prepare || "$1" == finish ) ]] || { echo 'Use package.sh prepare|finish.' >&2; exit 2; }
phase=$1
cd "$(dirname "$0")/../../../.."
source .agents/skills/inkflow-release/scripts/release-config.sh
load_release_config
identity=$INKFLOW_SIGN_IDENTITY
fail() { echo "$*" >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$build" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid release version/build.'
release_dir="$PWD/build/releases/InkFlow-$version-$build"
app="$release_dir/payload/InkFlow.app"
dmg="$release_dir/InkFlow-$version-$build-arm64.dmg"
signing=(--force --options runtime --timestamp --sign "$identity")
verify_app() {
  local target=$1 expected_id=$2 metadata entitlements expected_entitlements
  codesign --verify --deep --strict --verbose=2 "$target"
  metadata=$(codesign -dvvv "$target" 2>&1)
  printf '%s\n' "$metadata" | grep -Fxq 'TeamIdentifier=T7976FL2LP' || fail 'Unexpected signing team.'
  printf '%s\n' "$metadata" | grep -Fq 'Authority=Developer ID Application:' || fail 'Expected Developer ID Application signature.'
  printf '%s\n' "$metadata" | grep -Fxq "Identifier=$expected_id" || fail 'Unexpected signed bundle ID.'
  [[ $(plutil -extract CFBundleIdentifier raw "$target/Contents/Info.plist") == "$expected_id" ]] || fail 'Unexpected bundle ID.'
  [[ $(plutil -extract CFBundleShortVersionString raw "$target/Contents/Info.plist") == "$version" && $(plutil -extract CFBundleVersion raw "$target/Contents/Info.plist") == "$build" ]] || fail 'Payload/installer version mismatch.'
  entitlements=$(mktemp "$release_dir/entitlements.XXXXXX")
  codesign --display --entitlements - --xml "$target" > "$entitlements"
  plutil -lint "$entitlements" >/dev/null
  [[ $(plutil -extract com.apple.security.get-task-allow raw "$entitlements" 2>/dev/null || true) != true ]] || fail 'Debug entitlement in release app.'
  expected_entitlements=$(mktemp "$release_dir/expected-entitlements.XXXXXX")
  cp macOS/DeveloperID.entitlements "$expected_entitlements"
  plutil -convert xml1 "$entitlements" "$expected_entitlements"
  cmp -s "$expected_entitlements" "$entitlements" || fail 'Unexpected release entitlements.'
  rm -f "$entitlements" "$expected_entitlements"
}
if [[ "$phase" == prepare ]]; then
  [[ ! -e "$release_dir" && ! -L "$release_dir" ]] || fail 'Release output already exists; inspect it before retrying.'
  source_app="$PWD/build/InkFlow.app"
  cmp macOS/Info.plist "$source_app/Contents/Info.plist"
  [[ -x "$source_app/Contents/MacOS/InkFlow" ]] || fail 'Missing built executable.'
  verified_installer="$PWD/build/release-verification/InkFlowInstaller"
  verified_icon="$PWD/build/release-verification/AppIcon.icns"
  installer_receipt="$PWD/build/release-verification/installer.plist"
  bash macOS/scripts/release-receipt.sh verify "$verified_installer" "$verified_icon" "$installer_receipt"
  bash .agents/skills/inkflow-release/scripts/check-credentials.sh
  INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/check-bundle.sh --fast
  mkdir -p "$(dirname "$release_dir")"
  mkdir "$release_dir"
  mkdir "$release_dir/payload"
  mkdir "$release_dir/verified"
  cp "$verified_installer" "$release_dir/verified/InkFlowInstaller"
  cp "$verified_icon" "$release_dir/verified/AppIcon.icns"
  cp "$installer_receipt" "$release_dir/verified/installer.plist"
  ditto "$source_app" "$app"
  find "$app" -name '*.dSYM' -type d -prune -exec rm -rf {} +
  for binary in "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib" "$app/Contents/Frameworks/librime.1.dylib" "$app/Contents/MacOS/InkFlowDictionaryWorker"; do
    codesign "${signing[@]}" "$binary"
  done
  codesign "${signing[@]}" --entitlements macOS/DeveloperID.entitlements "$app"
  verify_app "$app" io.damao.inputmethod.inkflow
  ditto -c -k --sequesterRsrc --keepParent "$app" "$release_dir/inputmethod-submission.zip"
  printf 'Submit externally: %s\nThen staple/validate: %s\nThen run package.sh finish.\n' "$release_dir/inputmethod-submission.zip" "$app"
  exit 0
fi
[[ -d "$release_dir" && ! -L "$release_dir" && -f "$release_dir/inputmethod-submission.zip" && -d "$app" && ! -L "$app" ]] || fail 'Missing prepared payload; run prepare first or inspect the interrupted attempt.'
[[ ! -e "$dmg" && ! -L "$dmg" ]] || fail 'Final DMG already exists; preserve it and inspect/resume notarization.'
verified_installer="$release_dir/verified/InkFlowInstaller"
verified_icon="$release_dir/verified/AppIcon.icns"
installer_receipt="$release_dir/verified/installer.plist"
bash macOS/scripts/release-receipt.sh verify "$verified_installer" "$verified_icon" "$installer_receipt"
# Prevent concurrent finish attempts. An interrupted lock requires explicit inspection/removal.
mkdir "$release_dir/finishing" 2>/dev/null || fail 'Finish already running or interrupted; inspect finishing lock.'
trap 'rmdir "$release_dir/finishing"' EXIT
verify_app "$app" io.damao.inputmethod.inkflow
cmp macOS/Info.plist "$app/Contents/Info.plist"
xcrun stapler validate "$app"
INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/check-bundle.sh --fast "$app"
bash .agents/skills/inkflow-release/scripts/check-credentials.sh
scratch=$(mktemp -d "$release_dir/assembly.XXXXXX")
printf 'Retained assembly: %s\n' "$scratch"
# Fresh archive includes the app ticket; never embed the pre-stapling submission ZIP.
ditto -c -k --sequesterRsrc --keepParent "$app" "$scratch/InkFlow.zip"
mkdir "$scratch/stage"
installer="$scratch/stage/InkFlow Installer.app"
bash macOS/scripts/build-installer.sh "$scratch/InkFlow.zip" "$installer" "$verified_installer" "$verified_icon"
binary="$installer/Contents/MacOS/InkFlowInstaller"
bash macOS/scripts/release-receipt.sh verify "$binary" "$installer/Contents/Resources/AppIcon.icns" "$installer_receipt"
xcrun lipo "$binary" -verify_arch arm64
otool -L "$binary" | awk 'NR>1 && /^\t/ {print $1}' | while read -r dependency; do
  case "$dependency" in
    /usr/lib/*|/System/Library/*) ;;
    *) fail "Unbundled installer dependency: $dependency" ;;
  esac
done
codesign "${signing[@]}" --entitlements macOS/DeveloperID.entitlements "$installer"
verify_app "$installer" io.damao.inkflow.installer
# Assembly-only extraction/metadata probe. Signature checks above remain separate. No TIS.
"$binary" --check-payload
cp .agents/skills/inkflow-release/assets/安装说明.txt "$scratch/stage/安装说明.txt"
assembled="$scratch/InkFlow-$version-$build-arm64.dmg"
hdiutil create -volname "InkFlow $version" -srcfolder "$scratch/stage" -format UDZO "$assembled"
codesign --force --timestamp --sign "$identity" "$assembled"
codesign --verify --strict --verbose=2 "$assembled"
# Exclusive publication on the same volume; never overwrite even an unknown existing output.
ln "$assembled" "$dmg"
printf 'Signed installer DMG (not yet notarized): %s\n' "$dmg"
