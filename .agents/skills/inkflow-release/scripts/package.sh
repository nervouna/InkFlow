#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
  echo 'Usage: bash package.sh prepare|finish'
  echo 'Prepare signs the input method and retains its notarization ZIP. Finish requires its stapled app.'
  echo 'Finish builds the signed installer package from the stapled app and adds a Sparkle ZIP containing only InkFlow.app.'
  echo 'No installation, notarization submission or publication.'
  exit 0
fi
[[ $# -eq 1 && ( "$1" == prepare || "$1" == finish ) ]] || { echo 'Use package.sh prepare|finish.' >&2; exit 2; }
phase=$1
cd "$(dirname "$0")/../../../.."
source .agents/skills/inkflow-release/scripts/release-config.sh
source macOS/scripts/sparkle-signing.sh
load_release_config
identity=$INKFLOW_SIGN_IDENTITY
installer_identity=$INKFLOW_INSTALLER_IDENTITY
fail() { echo "$*" >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(bash macOS/scripts/release-build.sh build/release-verification/receipt.plist)
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$build" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid release version/build.'
release_dir="$PWD/build/releases/InkFlow-$version-$build"
app="$release_dir/payload/InkFlow.app"
pkg="$release_dir/InkFlow-$version-$build-arm64.pkg"
update_zip="$release_dir/InkFlow-$version-$build-arm64.zip"
update_zip_name=$(basename "$update_zip")
pkg_name=$(basename "$pkg")
signing=(--force --options runtime --timestamp --sign "$identity")
verify_app() {
  local target=$1 expected_id=io.damao.inputmethod.inkflow metadata entitlements expected_entitlements
  codesign --verify --deep --strict --verbose=2 "$target"
  verify_sparkle_developer_id "$target" T7976FL2LP
  metadata=$(codesign -dvvv "$target" 2>&1)
  grep -Fxq 'TeamIdentifier=T7976FL2LP' <<< "$metadata" || fail 'Unexpected signing team.'
  grep -Fq 'Authority=Developer ID Application:' <<< "$metadata" || fail 'Expected Developer ID Application signature.'
  grep -Fxq "Identifier=$expected_id" <<< "$metadata" || fail 'Unexpected signed bundle ID.'
  [[ $(plutil -extract CFBundleIdentifier raw "$target/Contents/Info.plist") == "$expected_id" ]] || fail 'Unexpected bundle ID.'
  [[ $(plutil -extract CFBundleShortVersionString raw "$target/Contents/Info.plist") == "$version" && $(plutil -extract CFBundleVersion raw "$target/Contents/Info.plist") == "$build" ]] || fail 'Payload version mismatch.'
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
  receipt="$PWD/build/release-verification/receipt.plist"
  bash macOS/scripts/release-build.sh "$receipt" "$source_app/Contents/Info.plist" >/dev/null
  [[ -x "$source_app/Contents/MacOS/InkFlow" ]] || fail 'Missing built executable.'
  bash macOS/scripts/release-receipt.sh verify "$receipt"
  bash .agents/skills/inkflow-release/scripts/check-credentials.sh
  INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/check-bundle.sh --fast
  mkdir -p "$(dirname "$release_dir")"
  mkdir "$release_dir"
  mkdir "$release_dir/payload"
  mkdir "$release_dir/verified"
  cp "$receipt" "$release_dir/verified/receipt.plist"
  ditto "$source_app" "$app"
  find "$app" -name '*.dSYM' -type d -prune -exec rm -rf {} +
  for binary in "$app/Contents/Frameworks/librime.1.dylib" "$app/Contents/MacOS/InkFlowDictionaryWorker"; do
    codesign "${signing[@]}" "$binary"
  done
  sign_sparkle "$app" "${signing[@]}"
  codesign "${signing[@]}" --entitlements macOS/DeveloperID.entitlements "$app"
  verify_app "$app"
  INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/check-bundle.sh --fast --signed "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$release_dir/inputmethod-submission.zip"
  printf 'Prepare complete. Finalize build/public-release-notes.md, then run:\nbash .agents/skills/inkflow-release/scripts/release.sh [--draft]\n'
  exit 0
fi
[[ -d "$release_dir" && ! -L "$release_dir" && -f "$release_dir/inputmethod-submission.zip" && -d "$app" && ! -L "$app" ]] || fail 'Missing prepared payload; run prepare first or inspect the interrupted attempt.'
receipt="$release_dir/verified/receipt.plist"
bash macOS/scripts/release-receipt.sh verify "$receipt"
verify_app "$app"
bash macOS/scripts/release-build.sh "$receipt" "$app/Contents/Info.plist" >/dev/null
xcrun stapler validate "$app"
INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/check-bundle.sh --fast --signed "$app"
bash .agents/skills/inkflow-release/scripts/check-credentials.sh
scratch=$(mktemp -d "$release_dir/assembly.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
# The Sparkle update payload: the stapled app alone, archived after notarization.
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
# The package wraps the same stapled app; it is notarized and stapled by release.sh.
bash macOS/scripts/build-pkg.sh "$app" "$scratch/$pkg_name" --sign "$identity" "$installer_identity"
# release.sh treats the package as the mark of a finished assembly, so it is moved last.
mv -f "$scratch/$update_zip_name" "$update_zip"
mv -f "$scratch/$pkg_name" "$pkg"
printf 'Signed installer package (not yet notarized): %s\n' "$pkg"
printf 'Sparkle update ZIP (signed app only): %s\n' "$update_zip"
