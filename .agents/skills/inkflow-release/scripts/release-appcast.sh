#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../../.."

[[ $# -eq 2 && "$1" == generate ]] || {
  echo 'Usage: release-appcast.sh generate PREVIOUS_TAG' >&2
  exit 2
}
previous_tag=$2
fail() { echo "Sparkle appcast stopped: $*" >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(bash macOS/scripts/release-build.sh build/release-verification/installer.plist)
tag="v$version"
release_dir="$PWD/build/releases/InkFlow-$version-$build"
app="$release_dir/payload/InkFlow.app"
update_zip="$release_dir/InkFlow-$version-$build-arm64.zip"
appcast="$release_dir/appcast.xml"
receipt="$release_dir/sparkle-receipt.plist"
feed_url=$(plutil -extract SUFeedURL raw macOS/Info.plist)
public_key=$(plutil -extract SUPublicEDKey raw macOS/Info.plist)
expected_feed='https://github.com/nervouna/InkFlow/releases/latest/download/appcast.xml'
expected_bundle='io.damao.inputmethod.inkflow'
account='io.damao.inputmethod.inkflow'
if [[ ${INKFLOW_SPARKLE_TEST_MODE:-0} == 1 ]]; then
  account=${INKFLOW_SPARKLE_TEST_ACCOUNT:-}
  [[ -n "$account" && "$account" != io.damao.inputmethod.inkflow ]] || fail 'Sparkle fixture mode requires an isolated test account.'
elif [[ -n ${INKFLOW_SPARKLE_TEST_ACCOUNT:-} ]]; then
  fail 'Sparkle test account override requires fixture mode.'
fi
sparkle_version='2.10.0'
sparkle_revision='eef1a539a373c1f1a320624b1130fc5de7b2e100'
download_prefix="https://github.com/nervouna/InkFlow/releases/download/$tag/"
tool="$PWD/build/swiftpm/artifacts/sparkle/Sparkle/bin/generate_appcast"
sign_tool="$PWD/build/swiftpm/artifacts/sparkle/Sparkle/bin/sign_update"

[[ "$previous_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid previous stable release tag.'
[[ "$feed_url" == "$expected_feed" ]] || fail 'Unexpected stable appcast URL.'
[[ ${#public_key} -eq 44 && "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail 'Missing or malformed SUPublicEDKey.'
[[ -d "$release_dir" && ! -L "$release_dir" && -d "$app" && ! -L "$app" ]] || fail 'Missing verified release app.'
[[ -f "$update_zip" && ! -L "$update_zip" ]] || fail 'Missing Sparkle update ZIP.'
[[ "$account" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'Invalid Sparkle signing account.'
[[ -x "$tool" && -x "$sign_tool" && -f Package.resolved && ! -L Package.resolved ]] || fail 'Missing pinned Sparkle appcast/signing tool.'

python3 - "$PWD/Package.resolved" "$sparkle_version" "$sparkle_revision" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    pins = json.load(source).get("pins", [])
matches = [pin for pin in pins if pin.get("identity", "").lower() == "sparkle"]
if len(matches) != 1:
    raise SystemExit("Package.resolved must contain exactly one Sparkle pin.")
state = matches[0].get("state", {})
if state.get("version") != sys.argv[2] or state.get("revision") != sys.argv[3]:
    raise SystemExit("The Sparkle appcast tool does not match the locked 2.10.0 revision.")
PY

validate_zip_contents() {
  python3 - "$update_zip" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = [name for name in archive.namelist() if name.rstrip("/")]
roots = {name.split("/", 1)[0] for name in names}
payload = {name.rstrip("/") for name in names if name.startswith("InkFlow.app/")}
sidecars = [name for name in names if name.startswith("__MACOSX/")]
if not payload or "InkFlow.app" not in roots or roots - {"InkFlow.app", "__MACOSX"}:
    raise SystemExit("Sparkle ZIP must contain only the InkFlow.app bundle.")
for name in sidecars:
    relative = name.removeprefix("__MACOSX/")
    if relative == "" or relative == "InkFlow.app":
        continue
    if not relative.startswith("InkFlow.app/"):
        raise SystemExit("Sparkle ZIP contains metadata outside InkFlow.app.")
    relative = relative.rstrip("/")
    parent, separator, leaf = relative.rpartition("/")
    counterpart = f"{parent}/{leaf[2:]}" if leaf.startswith("._") else relative
    if not counterpart or counterpart not in payload:
        raise SystemExit("Sparkle ZIP contains an orphaned AppleDouble resource entry.")
if "InkFlow.app/Contents/Info.plist" not in names:
    raise SystemExit("Sparkle ZIP is missing InkFlow.app/Contents/Info.plist.")
PY
}

validate_appcast() {
  local feed=$1 zip=$2 expected_previous=${3:-} items first_build first_short first_min first_url first_length first_signature zip_length previous_count
  xmllint --noout "$feed" || fail 'Sparkle generated invalid XML.'
  items=$(xmllint --xpath 'count(/rss/channel/item)' "$feed" 2>/dev/null)
  [[ "$items" =~ ^[0-9]+(\.0+)?$ && "$items" != 0 && "$items" != 0.0 ]] || fail 'Sparkle appcast has no update items.'
  first_build=$(xmllint --xpath "string(/rss/channel/item[1]/*[local-name()='version'])" "$feed" 2>/dev/null)
  first_short=$(xmllint --xpath "string(/rss/channel/item[1]/*[local-name()='shortVersionString'])" "$feed" 2>/dev/null)
  first_min=$(xmllint --xpath "string(/rss/channel/item[1]/*[local-name()='minimumSystemVersion'])" "$feed" 2>/dev/null)
  first_url=$(xmllint --xpath 'string(/rss/channel/item[1]/enclosure/@url)' "$feed" 2>/dev/null)
  first_length=$(xmllint --xpath 'string(/rss/channel/item[1]/enclosure/@length)' "$feed" 2>/dev/null)
  first_signature=$(xmllint --xpath "string(/rss/channel/item[1]/enclosure/@*[local-name()='edSignature'])" "$feed" 2>/dev/null)
  zip_length=$(stat -f '%z' "$zip")
  [[ "$first_build" == "$build" ]] || fail 'The newest appcast item is not the allocated CFBundleVersion.'
  [[ "$first_short" == "$version" ]] || fail 'Appcast short version does not match the release tag.'
  [[ "$first_min" == "$(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")" ]] || fail 'Appcast minimum macOS version differs from the payload.'
  [[ "$first_url" == "$download_prefix$(basename "$zip")" ]] || fail 'Appcast enclosure URL does not point to this versioned GitHub Release asset.'
  [[ "$first_length" == "$zip_length" ]] || fail 'Appcast enclosure length differs from the update ZIP.'
  [[ "$first_signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] || fail 'Appcast update is missing a valid EdDSA signature.'
  "$sign_tool" --verify --account "$account" "$zip" "$first_signature" >/dev/null || fail 'Sparkle EdDSA signature does not verify for the versioned update ZIP.'
  if [[ -n "$expected_previous" ]]; then
    previous_count=$(xmllint --xpath "count(/rss/channel/item[*[local-name()='version']='$expected_previous'])" "$feed" 2>/dev/null)
    [[ "$previous_count" =~ ^[1-9][0-9]*(\.0+)?$ ]] || fail 'The latest previously published Sparkle update was dropped from the feed.'
  fi
}

validate_zip_contents
extract=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-sparkle-payload.XXXXXX")
work=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-sparkle-appcast.XXXXXX")
cleanup() { rm -rf "$extract" "$work"; }
trap cleanup EXIT
ditto -x -k "$update_zip" "$extract"
extracted_app="$extract/InkFlow.app"
[[ -d "$extracted_app" && ! -L "$extracted_app" ]] || fail 'Sparkle ZIP did not extract one InkFlow.app.'
[[ $(plutil -extract CFBundleIdentifier raw "$extracted_app/Contents/Info.plist") == "$expected_bundle" ]] || fail 'Sparkle ZIP bundle ID mismatch.'
[[ $(plutil -extract CFBundleShortVersionString raw "$extracted_app/Contents/Info.plist") == "$version" ]] || fail 'Sparkle ZIP short version mismatch.'
[[ $(plutil -extract CFBundleVersion raw "$extracted_app/Contents/Info.plist") == "$build" ]] || fail 'Sparkle ZIP build mismatch.'
[[ $(plutil -extract SUPublicEDKey raw "$extracted_app/Contents/Info.plist") == "$public_key" ]] || fail 'Sparkle ZIP public key differs from the source app.'
[[ $(plutil -extract SUFeedURL raw "$extracted_app/Contents/Info.plist") == "$expected_feed" ]] || fail 'Sparkle ZIP feed URL mismatch.'
codesign --verify --deep --strict --verbose=2 "$extracted_app"
metadata=$(codesign -dvvv "$extracted_app" 2>&1)
printf '%s\n' "$metadata" | grep -Fxq 'TeamIdentifier=T7976FL2LP' || fail 'Sparkle ZIP Developer ID team mismatch.'
printf '%s\n' "$metadata" | grep -Fxq "Identifier=$expected_bundle" || fail 'Sparkle ZIP signing identifier mismatch.'
xcrun stapler validate "$extracted_app"

if [[ -e "$receipt" || -L "$receipt" || -e "$appcast" || -L "$appcast" ]]; then
  [[ -f "$receipt" && ! -L "$receipt" && -f "$appcast" && ! -L "$appcast" ]] || fail 'Partial or untrusted Sparkle appcast output; inspect retained files.'
  [[ $(plutil -extract schema raw "$receipt") == 1 ]] || fail 'Unknown Sparkle receipt schema.'
  [[ $(plutil -extract version raw "$receipt") == "$version" && $(plutil -extract build raw "$receipt") == "$build" ]] || fail 'Sparkle receipt version/build mismatch.'
  [[ $(plutil -extract previousTag raw "$receipt") == "$previous_tag" ]] || fail 'Sparkle receipt previous tag mismatch.'
  [[ $(plutil -extract updateZIPSHA256 raw "$receipt") == "$(shasum -a 256 "$update_zip" | awk '{print $1}')" ]] || fail 'Sparkle update ZIP changed after appcast generation.'
  [[ $(plutil -extract appcastSHA256 raw "$receipt") == "$(shasum -a 256 "$appcast" | awk '{print $1}')" ]] || fail 'Sparkle appcast changed after generation.'
  validate_appcast "$appcast" "$update_zip" "$(plutil -extract previousBuild raw "$receipt")"
  echo 'PASS: existing Sparkle appcast receipt and artifacts are unchanged.'
  exit 0
fi

previous_build=''
feed_status_file="$work/http-response"
feed_url=$expected_feed
curl --silent --show-error --location --max-time 30 --output "$work/previous-appcast.xml" --write-out $'%{http_code}\n%{url_effective}\n' "$feed_url" > "$feed_status_file" || fail 'Anonymous stable appcast request failed.'
read -r http_status < "$feed_status_file"
read -r effective_url < <(sed -n '2p' "$feed_status_file")
case "$http_status" in
  200)
    xmllint --noout "$work/previous-appcast.xml" || fail 'Existing stable appcast is invalid XML.'
    previous_build=$(xmllint --xpath "string(/rss/channel/item[1]/*[local-name()='version'])" "$work/previous-appcast.xml" 2>/dev/null)
    [[ "$previous_build" =~ ^[1-9][0-9]*$ && "$build" -gt "$previous_build" ]] || fail 'CFBundleVersion does not increase beyond the published Sparkle feed.'
    cp "$work/previous-appcast.xml" "$work/appcast.xml"
    ;;
  404)
    [[ "$effective_url" == "https://github.com/nervouna/InkFlow/releases/download/$previous_tag/appcast.xml" ]] || fail 'Appcast 404 did not resolve to the expected previous stable Release.'
    ;;
  *) fail "Anonymous stable appcast returned HTTP $http_status." ;;
esac

cp "$update_zip" "$work/$(basename "$update_zip")"
"$tool" --account "$account" --maximum-versions 3 --maximum-deltas 0 --download-url-prefix "$download_prefix" "$work"
[[ -f "$work/appcast.xml" && ! -L "$work/appcast.xml" ]] || fail 'Sparkle did not create appcast.xml.'
validate_appcast "$work/appcast.xml" "$update_zip" "$previous_build"

staged_appcast=$(mktemp "$release_dir/.appcast.XXXXXX")
staged_receipt=$(mktemp "$release_dir/.sparkle-receipt.XXXXXX")
trap 'cleanup; rm -f "$staged_appcast" "$staged_receipt"' EXIT
cp "$work/appcast.xml" "$staged_appcast"
plutil -create xml1 "$staged_receipt"
plutil -insert schema -integer 1 "$staged_receipt"
plutil -insert version -string "$version" "$staged_receipt"
plutil -insert build -string "$build" "$staged_receipt"
plutil -insert tag -string "$tag" "$staged_receipt"
plutil -insert previousTag -string "$previous_tag" "$staged_receipt"
plutil -insert previousBuild -string "$previous_build" "$staged_receipt"
plutil -insert updateZIPSHA256 -string "$(shasum -a 256 "$update_zip" | awk '{print $1}')" "$staged_receipt"
plutil -insert appcastSHA256 -string "$(shasum -a 256 "$staged_appcast" | awk '{print $1}')" "$staged_receipt"
ln "$staged_appcast" "$appcast" || fail 'Appcast destination already exists; refusing to overwrite.'
ln "$staged_receipt" "$receipt" || fail 'Sparkle receipt destination already exists; refusing to overwrite.'
rm -f "$staged_appcast" "$staged_receipt"
echo 'PASS: generated Sparkle appcast with the pinned tool, preserved available history, and verified ZIP metadata/signature.'
