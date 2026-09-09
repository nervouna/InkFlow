#!/bin/bash
# Repository-shaped fixtures only: no signing credentials, Apple requests, or installation.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-package-tests.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
scripts="$repo/.agents/skills/inkflow-release/scripts"
mkdir -p "$scripts" "$repo/macOS/scripts" "$repo/build/InkFlow.app/Contents/MacOS" "$fixture/bin"
cp "$root/.agents/skills/inkflow-release/scripts/"{package,release-config}.sh "$scripts/"
cp "$root/macOS/Info.plist" "$repo/macOS/Info.plist"
cp "$root/macOS/Info.plist" "$repo/build/InkFlow.app/Contents/Info.plist"
touch "$repo/build/InkFlow.app/Contents/MacOS/InkFlow"
chmod +x "$repo/build/InkFlow.app/Contents/MacOS/InkFlow"
mkdir -p "$repo/.agents/skills/inkflow-release/assets"
cp "$root/.agents/skills/inkflow-release/assets/安装说明.txt" "$repo/.agents/skills/inkflow-release/assets/"
export EVENTS="$fixture/events" INKFLOW_RELEASE_CONFIG="$fixture/missing.plist"
export INKFLOW_SIGN_IDENTITY=0000000000000000000000000000000000000000 INKFLOW_NOTARY_PROFILE=fixture
export PATH="$fixture/bin:$PATH"
cat > "$scripts/check-credentials.sh" <<'STUB'
echo credentials >> "$EVENTS"
exit "${CREDENTIAL_FAILURE:-0}"
STUB
cat > "$repo/macOS/scripts/check-bundle.sh" <<'STUB'
echo bundle >> "$EVENTS"
exit "${BUNDLE_FAILURE:-0}"
STUB
cat > "$repo/macOS/scripts/build-installer.sh" <<'STUB'
echo build-installer >> "$EVENTS"
mkdir -p "$2/Contents/MacOS" "$2/Contents/Resources/Payload"
cp "$1" "$2/Contents/Resources/Payload/InkFlow.zip"
cp macOS/Info.plist "$2/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.damao.inkflow.installer "$2/Contents/Info.plist"
cat > "$2/Contents/MacOS/InkFlowInstaller" <<'PROBE'
#!/bin/bash
[[ $# == 1 && "$1" == --check-payload ]] || exit 99
echo check-payload >> "$EVENTS"
unzip -t "$(dirname "$0")/../Resources/Payload/InkFlow.zip" >/dev/null
[[ $? == 0 ]] || exit 44
exit "${PAYLOAD_FAILURE:-0}"
PROBE
chmod +x "$2/Contents/MacOS/InkFlowInstaller"
STUB
cat > "$fixture/bin/codesign" <<'STUB'
#!/bin/bash
last="${!#}"
case "$1" in
  --verify)
    echo "verify:$last" >> "$EVENTS"
    [[ "${SIGNATURE_FAILURE:-}" != inner || "$last" != */payload/InkFlow.app ]] || exit 41
    [[ "${SIGNATURE_FAILURE:-}" != outer || "$last" != *'InkFlow Installer.app' ]] || exit 42
    ;;
  -dvvv)
    id=io.damao.inputmethod.inkflow
    [[ "$last" != *'InkFlow Installer.app' ]] || id=io.damao.inkflow.installer
    printf 'TeamIdentifier=%s\nAuthority=Developer ID Application: Fixture\nIdentifier=%s\n' "${TEAM:-T7976FL2LP}" "$id"
    ;;
  --display) printf '<?xml version="1.0"?><plist version="1.0"><dict/></plist>\n' ;;
  *) echo "sign:$last" >> "$EVENTS" ;;
esac
STUB
cat > "$fixture/bin/xcrun" <<'STUB'
#!/bin/bash
[[ "$1" != notarytool ]] || exit 99
if [[ "$1" == stapler && "$2" == validate ]]; then
  echo staple-validate >> "$EVENTS"
  [[ -f "$3/ticket-fixture" ]] || exit 43
elif [[ "$1" == lipo ]]; then
  echo arm64 >> "$EVENTS"
  exit "${ARCH_FAILURE:-0}"
else exit 99
fi
STUB
cat > "$fixture/bin/otool" <<'STUB'
#!/bin/bash
printf 'binary:\n\t%s (compatibility version 1.0.0)\n' "${DEPENDENCY:-/usr/lib/libSystem.B.dylib}"
STUB
cat > "$fixture/bin/hdiutil" <<'STUB'
#!/bin/bash
set -euo pipefail
echo dmg >> "$EVENTS"
[[ "${DMG_FAILURE:-0}" == 0 ]] || exit 45
[[ "$1" == create ]] || exit 99
# Only the installer and instructions may be exposed on the volume.
[[ $(find "$5" -mindepth 1 -maxdepth 1 | wc -l) -eq 2 ]] || exit 46
[[ -d "$5/InkFlow Installer.app" && -f "$5/安装说明.txt" ]] || exit 47
echo fixture-dmg > "${!#}"
STUB
cat > "$fixture/bin/ditto" <<'STUB'
#!/bin/bash
if [[ "${MALFORMED_PAYLOAD:-0}" == 1 && "${!#}" == */assembly.*/InkFlow.zip ]]; then
  printf 'invalid zip' > "${!#}"
else
  /usr/bin/ditto "$@"
fi
STUB
chmod +x "$fixture/bin/"*
# Prove the volume-content assertions reject an extra root entry.
mkdir -p "$fixture/invalid-volume/InkFlow Installer.app"
touch "$fixture/invalid-volume/安装说明.txt" "$fixture/invalid-volume/unexpected.txt"
if hdiutil create -volname Fixture -srcfolder "$fixture/invalid-volume" -format UDZO "$fixture/invalid.dmg"; then
  echo 'Accepted unexpected volume content.' >&2; exit 1
fi
[[ ! -e "$fixture/invalid.dmg" ]]
: > "$EVENTS"


version=$(plutil -extract CFBundleShortVersionString raw "$repo/macOS/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$repo/macOS/Info.plist")
output="$repo/build/releases/InkFlow-$version-$build"
dmg="$output/InkFlow-$version-$build-arm64.dmg"
package() { bash "$scripts/package.sh" "$@" > "$fixture/result.log" 2>&1; }
reject() {
  if package "$@"; then echo "Unexpected success: $*" >&2; exit 1; fi
}
reject finish
CREDENTIAL_FAILURE=1 reject prepare
[[ ! -e "$output" ]]
plutil -replace CFBundleVersion -string 999 "$repo/build/InkFlow.app/Contents/Info.plist"
reject prepare
[[ ! -e "$output" ]]
cp "$repo/macOS/Info.plist" "$repo/build/InkFlow.app/Contents/Info.plist"
package prepare
[[ -f "$output/inputmethod-submission.zip" && ! -e "$dmg" ]]
if grep -q 'build-installer\|dmg\|staple-validate' "$EVENTS"; then exit 1; fi
# Nested signing order is preserved.
sed -n 's/^sign:.*\///p' "$EVENTS" > "$fixture/sign-order"
printf '%s\n' librime-lua.dylib librime.1.dylib InkFlowDictionaryWorker InkFlow.app > "$fixture/expected"
cmp "$fixture/sign-order" "$fixture/expected"
shasum "$output/inputmethod-submission.zip" > "$fixture/submission.sha"
reject prepare
reject finish # Not notarized/stapled, so no assembly.
[[ -z $(find "$output" -name 'assembly.*' -print) ]]
touch "$output/payload/InkFlow.app/ticket-fixture"
SIGNATURE_FAILURE=inner reject finish
TEAM=WRONGTEAM reject finish
plutil -replace CFBundleVersion -string 999 "$output/payload/InkFlow.app/Contents/Info.plist"
reject finish
cp "$repo/macOS/Info.plist" "$output/payload/InkFlow.app/Contents/Info.plist"
for gate in BUNDLE_FAILURE ARCH_FAILURE PAYLOAD_FAILURE; do
  export "$gate=1"
  reject finish
  unset "$gate"
  [[ ! -e "$dmg" ]]
done
DEPENDENCY=/opt/homebrew/lib/unshipped.dylib reject finish
SIGNATURE_FAILURE=outer reject finish
MALFORMED_PAYLOAD=1 reject finish
DMG_FAILURE=1 reject finish
mkdir "$output/finishing"
reject finish
rmdir "$output/finishing"
[[ ! -e "$dmg" ]]
# Fixture probe failure represents malformed payload; production runs the actual loader.
: > "$EVENTS"
package finish
[[ -f "$dmg" ]]
shasum -c "$fixture/submission.sha"
# The fresh embedded archive contains the post-submission ticket.
[[ $(grep -c '^Retained assembly: ' "$fixture/result.log") == 1 ]]
assembly=$(sed -n 's/^Retained assembly: //p' "$fixture/result.log")
[[ -d "$assembly" ]]
zip="$assembly/stage/InkFlow Installer.app/Contents/Resources/Payload/InkFlow.zip"
unzip -l "$zip" > "$fixture/archive-list"
grep -q 'InkFlow.app/ticket-fixture' "$fixture/archive-list"
awk '/staple-validate/{s=NR} /build-installer/{b=NR} /check-payload/{p=NR} /^dmg$/{d=NR} END{exit !(s<b && b<p && p<d)}' "$EVENTS"
printf unknown > "$dmg"
reject finish
[[ $(cat "$dmg") == unknown ]]
echo 'PASS: package phases, nested signing order, stapled fresh ZIP, identity/version/signature/closure/probe gates and no-clobber'
