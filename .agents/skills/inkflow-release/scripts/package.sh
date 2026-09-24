#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
  echo 'Usage: bash package.sh prepare|finish'
  echo 'Prepare signs the input method and retains its notarization ZIP. Finish requires its stapled app.'
  echo 'Finish preserves the installer DMG and adds a Sparkle ZIP containing only InkFlow.app.'
  echo 'No installation, notarization submission or publication. Existing outputs are preserved.'
  exit 0
fi
[[ $# -eq 1 && ( "$1" == prepare || "$1" == finish ) ]] || { echo 'Use package.sh prepare|finish.' >&2; exit 2; }
phase=$1
cd "$(dirname "$0")/../../../.."
source .agents/skills/inkflow-release/scripts/release-config.sh
source macOS/scripts/sparkle-signing.sh
load_release_config
identity=$INKFLOW_SIGN_IDENTITY
fail() { echo "$*" >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(bash macOS/scripts/release-build.sh build/release-verification/installer.plist)
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$build" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid release version/build.'
release_dir="$PWD/build/releases/InkFlow-$version-$build"
app="$release_dir/payload/InkFlow.app"
dmg="$release_dir/InkFlow-$version-$build-arm64.dmg"
update_zip="$release_dir/InkFlow-$version-$build-arm64.zip"
update_zip_name=$(basename "$update_zip")
signing=(--force --options runtime --timestamp --sign "$identity")
verify_app() {
  local target=$1 expected_id=$2 metadata entitlements expected_entitlements
  codesign --verify --deep --strict --verbose=2 "$target"
  if [[ "$expected_id" == io.damao.inputmethod.inkflow ]]; then
    verify_sparkle_developer_id "$target" T7976FL2LP
  fi
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
  bash macOS/scripts/release-build.sh build/release-verification/installer.plist "$source_app/Contents/Info.plist" >/dev/null
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
  sign_sparkle "$app" "${signing[@]}"
  codesign "${signing[@]}" --entitlements macOS/DeveloperID.entitlements "$app"
  verify_app "$app" io.damao.inputmethod.inkflow
  INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/check-bundle.sh --fast --signed "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$release_dir/inputmethod-submission.zip"
  printf 'Prepare complete. Finalize build/public-release-notes.md, then run:\nbash .agents/skills/inkflow-release/scripts/release-runner.sh continue\n'
  exit 0
fi
[[ -d "$release_dir" && ! -L "$release_dir" && -f "$release_dir/inputmethod-submission.zip" && -d "$app" && ! -L "$app" ]] || fail 'Missing prepared payload; run prepare first or inspect the interrupted attempt.'
[[ ! -e "$dmg" && ! -L "$dmg" ]] || fail 'Final DMG already exists; preserve it and inspect/resume notarization.'
[[ ! -e "$update_zip" && ! -L "$update_zip" ]] || fail 'Sparkle update ZIP already exists; preserve it and inspect the interrupted attempt.'
verified_installer="$release_dir/verified/InkFlowInstaller"
verified_icon="$release_dir/verified/AppIcon.icns"
installer_receipt="$release_dir/verified/installer.plist"
bash macOS/scripts/release-receipt.sh verify "$verified_installer" "$verified_icon" "$installer_receipt"
# Prevent concurrent finish attempts. An interrupted lock requires explicit inspection/removal.
mkdir "$release_dir/finishing" 2>/dev/null || fail 'Finish already running or interrupted; inspect finishing lock.'
trap 'rmdir "$release_dir/finishing"' EXIT
verify_app "$app" io.damao.inputmethod.inkflow
bash macOS/scripts/release-build.sh "$installer_receipt" "$app/Contents/Info.plist" >/dev/null
xcrun stapler validate "$app"
INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/check-bundle.sh --fast --signed "$app"
bash .agents/skills/inkflow-release/scripts/check-credentials.sh
scratch=$(mktemp -d "$release_dir/assembly.XXXXXX")
printf 'Retained assembly: %s\n' "$scratch"
# This single post-notarization archive is both the Sparkle update payload and
# the app payload embedded by the legacy Installer DMG.
ditto -c -k --sequesterRsrc --keepParent "$app" "$scratch/$update_zip_name"
python3 - "$scratch/$update_zip_name" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = [name for name in archive.namelist() if name.rstrip("/")]
roots = {name.split("/", 1)[0] for name in names}
payload = {name.rstrip("/") for name in names if name.startswith("InkFlow.app/")}
sidecars = [name for name in names if name.startswith("__MACOSX/")]
if not payload or "InkFlow.app" not in roots or roots - {"InkFlow.app", "__MACOSX"}:
    raise SystemExit("Sparkle update ZIP must contain only InkFlow.app.")
for name in sidecars:
    relative = name.removeprefix("__MACOSX/")
    if relative == "" or relative == "InkFlow.app":
        continue
    if not relative.startswith("InkFlow.app/"):
        raise SystemExit("Sparkle update ZIP contains metadata outside InkFlow.app.")
    relative = relative.rstrip("/")
    parent, separator, leaf = relative.rpartition("/")
    counterpart = f"{parent}/{leaf[2:]}" if leaf.startswith("._") else relative
    if not counterpart or counterpart not in payload:
        raise SystemExit("Sparkle update ZIP contains an orphaned AppleDouble resource entry.")
if "InkFlow.app/Contents/Info.plist" not in names:
    raise SystemExit("Sparkle update ZIP is missing its app bundle Info.plist.")
PY
mkdir "$scratch/stage"
installer="$scratch/stage/InkFlow Installer.app"
bash macOS/scripts/build-installer.sh "$scratch/$update_zip_name" "$installer" "$verified_installer" "$verified_icon"
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
ln "$scratch/$update_zip_name" "$update_zip"
printf 'Signed installer DMG (not yet notarized): %s\n' "$dmg"
printf 'Sparkle update ZIP (signed app only): %s\n' "$update_zip"
