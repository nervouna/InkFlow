#!/bin/bash
set -euo pipefail
fail() {
  echo "FAIL $*" >&2
  exit 1
}
cd "$(dirname "$0")/../.."
root=$PWD
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-resume.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
export TMPDIR="$fixture/"
git clone --quiet --shared --no-hardlinks "$PWD" "$fixture/repo"
scripts=.agents/skills/inkflow-release/scripts
cp "$scripts/release.sh" "$scripts/release-appcast.sh" "$fixture/repo/$scripts/"
cp macOS/scripts/release-receipt.sh macOS/scripts/release-build.sh "$fixture/repo/macOS/scripts/"
cd "$fixture/repo"
printf '#!/bin/bash\nprintf bundle > "$1"\n' > macOS/scripts/dictionary-source-bundle.sh
git add "$scripts" macOS/scripts/dictionary-source-bundle.sh macOS/scripts/release-receipt.sh macOS/scripts/release-build.sh
git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm 'fixture release scripts'
git init -q --bare "$fixture/origin.git"
git remote set-url origin "$fixture/origin.git"
git push -q origin HEAD:refs/heads/main
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
previous=$(git tag --merged HEAD --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx "v$version" | head -1)
release="build/releases/InkFlow-$version-$build"
app="$release/payload/InkFlow.app"
mkdir -p "$app/Contents" build/InkFlow.app/Contents build/release-verification "$release/verified" "$fixture/bin"
cp macOS/Info.plist "$app/Contents/Info.plist"
cp macOS/Info.plist build/InkFlow.app/Contents/Info.plist
bash macOS/scripts/release-receipt.sh create "$release/verified/receipt.plist"
cp "$release/verified/receipt.plist" build/release-verification/receipt.plist
printf notes > build/public-release-notes.md
printf submission > "$release/inputmethod-submission.zip"
pkg="$release/InkFlow-$version-$build-arm64.pkg"
printf pkg > "$pkg"
zip="$release/InkFlow-$version-$build-arm64.zip"
ditto -c -k --keepParent "$app" "$zip"
export FIXTURE_PKG_TREE="$fixture/pkg-tree"
component="$FIXTURE_PKG_TREE/InkFlow-component.pkg"
mkdir -p "$component/Payload" "$component/Scripts"
ditto "$app" "$component/Payload/InkFlow.app"
printf '#!/bin/bash\nexit 0\n' > "$component/Scripts/register-input-source"
printf '%s\n' "$build" > "$component/Scripts/build-number"
cat > "$fixture/bin/gh" <<'MOCK'
#!/bin/bash
if [[ "$1 $2" == 'repo view' ]]; then echo fixture/InkFlow; exit 0; fi
if [[ "$1 $2" == 'api repos/fixture/InkFlow/releases/latest' ]]; then cat "$FIXTURE_LATEST"; exit 0; fi
if [[ "$1 $2" == 'api --paginate' ]]; then cat "$FIXTURE_STABLE"; exit 0; fi
if [[ -n ${FIXTURE_LIVE:-} && $1 == release ]]; then
  case "$2" in
    view)
      if [[ "$*" == *'--json url'* ]]; then echo https://example.invalid/release; exit 0; fi
      exit 1 ;;
    create) exit 0 ;;
    upload)
      for file in "$@"; do
        if [[ -f $file ]]; then cp "$file" "$FIXTURE_LIVE/assets/"; fi
      done
      exit 0 ;;
    download) cp "$FIXTURE_LIVE"/assets/* "${@: -1}"; exit 0 ;;
    edit)
      if [[ "$*" == *' --latest'* && "$*" != *'--latest=false'* ]]; then
        cat "$FIXTURE_LATEST_AFTER" > "$FIXTURE_LATEST"
      fi
      exit 0 ;;
  esac
fi
echo 'FIXTURE_PUBLICATION_BOUNDARY'
exit 73
MOCK
cat > "$fixture/bin/codesign" <<'MOCK'
#!/bin/bash
if [[ "$1" == -dvvv ]]; then
  flags=0x10000
  [[ "$2" != *register-input-source ]] || flags=${FIXTURE_TOOL_FLAGS:-0x10000}
  cat <<METADATA
Identifier=io.damao.inputmethod.inkflow
CodeDirectory v=20500 size=1 flags=$flags(runtime) hashes=1+3 location=embedded
Authority=Developer ID Application: Fixture (T7976FL2LP)
Timestamp=Oct 15, 2026 at 10:00:00
TeamIdentifier=T7976FL2LP
METADATA
fi
MOCK
cat > "$fixture/bin/pkgutil" <<'MOCK'
#!/bin/bash
case "$1" in
  --check-signature)
    printf '%s\n' 'Package "fixture.pkg":' '   Status: signed by a developer certificate issued by Apple for distribution' \
      '   Certificate Chain:' "    1. ${FIXTURE_PKG_SIGNER:-Developer ID Installer: Fixture (T7976FL2LP)}" ;;
  --expand-full) ditto "$FIXTURE_PKG_TREE" "$3" ;;
  *) exit 64 ;;
esac
MOCK
for tool in xcrun spctl; do printf '#!/bin/bash\nexit 0\n' > "$fixture/bin/$tool"; done
for tool in curl; do printf '#!/bin/bash\nexit 91\n' > "$fixture/bin/$tool"; done
chmod +x "$fixture/bin/"*
export FIXTURE_LATEST="$fixture/latest" FIXTURE_STABLE="$fixture/stable"
printf 'v0.7.7\n' > "$FIXTURE_LATEST"
printf 'v0.7.7\n' > "$FIXTURE_STABLE"
export PATH="$fixture/bin:$PATH"
sparkle=build/swiftpm/artifacts/sparkle/Sparkle/bin
mkdir -p "$sparkle"
printf '#!/bin/bash\nexit 0\n' > "$sparkle/generate_appcast"
export FIXTURE_SPARKLE_ARGS="$fixture/sparkle-args"
cat > "$sparkle/sign_update" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "$FIXTURE_SPARKLE_ARGS"
MOCK
chmod +x "$sparkle/generate_appcast" "$sparkle/sign_update"
signature=$(printf '%086d==' 0)
minimum=$(plutil -extract LSMinimumSystemVersion raw macOS/Info.plist)
cat > "$release/appcast.xml" <<XML
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>$build</sparkle:version><sparkle:shortVersionString>$version</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
<enclosure url="https://github.com/nervouna/InkFlow/releases/download/v$version/$(basename "$zip")" length="$(stat -f '%z' "$zip")" sparkle:edSignature="$signature"/>
</item></channel></rss>
XML
cp "$release/appcast.xml" "$fixture/appcast.original"
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
receipt="$release/sparkle-receipt.plist"
plutil -create xml1 "$receipt"
plutil -insert schema -integer 1 "$receipt"
plutil -insert version -string "$version" "$receipt"
plutil -insert build -string "$build" "$receipt"
plutil -insert previousTag -string "$previous" "$receipt"
plutil -insert previousBuild -string '' "$receipt"
plutil -insert updateZIPSHA256 -string "$(sha256 "$zip")" "$receipt"
plutil -insert appcastSHA256 -string "$(sha256 "$release/appcast.xml")" "$receipt"

check_release() {
  local name=$1 expected=$2 status=0
  bash "$scripts/release.sh" --draft > "$fixture/output" 2>&1 || status=$?
  if [[ "$expected" == FIXTURE_PUBLICATION_BOUNDARY ]]; then
    [[ "$status" == 73 ]] || { cat "$fixture/output"; exit 1; }
  else
    [[ "$status" == 1 ]] && ! grep -q FIXTURE_PUBLICATION_BOUNDARY "$fixture/output" || {
      echo "FAIL $name: reached publication or failed for another reason ($status)"; cat "$fixture/output"; exit 1;
    }
  fi
  grep -Fq "$expected" "$fixture/output" || { cat "$fixture/output"; exit 1; }
  echo "PASS release resume: $name"
}
check_release 'unchanged candidate reaches publication boundary' FIXTURE_PUBLICATION_BOUNDARY
grep -Fxq -- --account "$FIXTURE_SPARKLE_ARGS" || { echo 'FAIL Sparkle key: Keychain account not used'; exit 1; }
key_file="$fixture/sparkle.key"
printf key > "$key_file"
chmod 600 "$key_file"
INKFLOW_SPARKLE_KEY_FILE="$key_file" check_release 'Sparkle key file' FIXTURE_PUBLICATION_BOUNDARY
sparkle_args=$(cat "$FIXTURE_SPARKLE_ARGS")
[[ $sparkle_args == *$'--ed-key-file\n'"$key_file"* ]] || { echo 'FAIL Sparkle key file not used'; exit 1; }
! grep -Fxq -- --account "$FIXTURE_SPARKLE_ARGS" || { echo 'FAIL Sparkle key file also used the account'; exit 1; }
chmod 644 "$key_file"
INKFLOW_SPARKLE_KEY_FILE="$key_file" check_release 'readable Sparkle key file' 'Restrict the Sparkle key file'
INKFLOW_SPARKLE_KEY_FILE=sparkle.key check_release 'relative Sparkle key file' 'must be an existing absolute path'
plutil -replace sourceCommit -string stale "$release/verified/receipt.plist"
check_release 'stale prepared candidate' 'Release receipt commit does not match current source.'
cp build/release-verification/receipt.plist "$release/verified/receipt.plist"
FIXTURE_PKG_SIGNER='Developer ID Application: Fixture (T7976FL2LP)' check_release 'package not signed by the installer certificate' 'Unexpected package signature.'
FIXTURE_TOOL_FLAGS=0x0 check_release 'embedded tool without hardened runtime' 'Unexpected register-input-source signature.'
printf 99 > "$component/Scripts/build-number"
check_release 'package scripts from another build' 'Package scripts expect another build.'
printf '%s\n' "$build" > "$component/Scripts/build-number"
cp "$zip" "$fixture/original.zip"
printf changed > "$app/Contents/changed"
ditto -c -k --keepParent "$app" "$zip"
check_release 'repacked update ZIP' 'Sparkle update ZIP changed after appcast generation.'
cp "$fixture/original.zip" "$zip"
printf '\n<!-- changed -->\n' >> "$release/appcast.xml"
check_release 'modified appcast' 'Sparkle appcast changed after generation.'
cp "$fixture/appcast.original" "$release/appcast.xml"
rm -rf "$fixture/live"
mkdir -p "$fixture/live/assets"
live_release() {
  local name=$1 after=$2 expected_status=$3 expected=$4 status=0
  FIXTURE_LIVE="$fixture/live" FIXTURE_LATEST_AFTER="$fixture/$after" \
    bash "$scripts/release.sh" > "$fixture/output" 2>&1 || status=$?
  if [[ $status != "$expected_status" ]]; then
    cat "$fixture/output"
    fail "$name: exit $status, expected $expected_status"
  fi
  if ! grep -Fq -- "$expected" "$fixture/output"; then
    cat "$fixture/output"
    fail "$name: output lacks $expected"
  fi
  echo "PASS release resume: $name"
}
git tag -d "v$version" > /dev/null 2>&1 || true
printf 'linux-v0.7.8\n' > "$FIXTURE_LATEST"
printf 'v0.7.7\n' > "$FIXTURE_STABLE"
printf 'v0.7.7\n' > "$fixture/latest-after"
live_release 'Linux Latest blocks tagging' latest-after 1 \
  'GitHub Latest is linux-v0.7.8 before tagging. Restore the macOS release with: gh release edit v0.7.7 --latest'
[[ -z $(git tag -l "v$version") ]] || fail 'Blocked release created a local tag'
[[ -z $(git -C "$fixture/origin.git" tag -l) ]] || fail 'Blocked release pushed a tag'
printf 'v0.7.7\n' > "$FIXTURE_LATEST"
printf 'v0.7.8\n' > "$FIXTURE_STABLE"
printf 'linux-v0.7.8\n' > "$fixture/latest-after"
live_release 'Linux Latest after publishing' latest-after 1 \
  'GitHub Latest is linux-v0.7.8 after publishing. Restore the macOS release with: gh release edit v0.7.8 --latest'
printf 'v0.7.7\n' > "$FIXTURE_LATEST"
printf 'v0.7.8\n' > "$fixture/latest-after"
live_release 'macOS Latest after publishing' latest-after 0 "PASS release v$version build $build:"
linux_version=9.9.9
linux_revision=0123456789abcdef0123456789abcdef01234567
linux="$fixture/linux-assets"
linux_bin="$fixture/linux-bin"
mkdir -p "$linux" "$linux_bin"
printf binary > "$linux/InkFlow-$linux_version-linux-aarch64.tar.xz"
printf source > "$linux/InkFlow-$linux_version-linux-source.tar.xz"
linux_binary="InkFlow-$linux_version-linux-aarch64.tar.xz"
linux_source="InkFlow-$linux_version-linux-source.tar.xz"
(cd "$linux" && sha256sum "$linux_binary" "$linux_source" > SHA256SUMS-linux)
cat > "$linux_bin/assets.json" <<JSON
{"assets":[{"name":"$linux_binary","state":"uploaded"},{"name":"$linux_source","state":"uploaded"},
{"name":"SHA256SUMS-linux","state":"uploaded"}]}
JSON
cat > "$linux_bin/draft.json" <<JSON
{"url":"https://example.invalid/linux-v$linux_version","isDraft":true,"targetCommitish":"$linux_revision"}
JSON
cat > "$linux_bin/gh" <<'MOCK'
#!/bin/bash
case "$1 $2" in
  'api repos/'*) echo '[]' ;;
  'api --paginate') ;;
  'release create') ;;
  'release view')
    if [[ "$*" == *'--json assets'* ]]; then cat "$LINUX_STUB/assets.json"; else cat "$LINUX_STUB/draft.json"; fi ;;
  'release download') cp "$LINUX_ASSETS"/* "${@: -1}" ;;
  *) echo "Unexpected gh call: $*" >&2; exit 99 ;;
esac
MOCK
chmod +x "$linux_bin/gh"
summary="$fixture/summary"
: > "$summary"
if ! PATH="$linux_bin:$PATH" GH_REPO=fixture/InkFlow GITHUB_STEP_SUMMARY="$summary" LINUX_ASSETS="$linux" \
  LINUX_STUB="$linux_bin" bash "$root/Linux/scripts/draft-release.sh" "$linux_version" "$linux_revision" "$linux" \
  > "$fixture/linux-output" 2>&1; then
  cat "$fixture/linux-output"
  fail 'draft-release.sh failed in the fixture'
fi
grep -Fxq 'Publish without taking Latest: `gh release edit linux-v9.9.9 --draft=false --latest=false`' "$summary" ||
  fail 'draft summary lacks the exact publish command'
echo 'PASS draft-release summary: publish command'
