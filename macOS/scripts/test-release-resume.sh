#!/bin/bash
# Exercise the release entry point with real receipts/archives and synthetic platform tools.
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-resume.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
export TMPDIR="$fixture/"
git clone --quiet --shared --no-hardlinks "$PWD" "$fixture/repo"
scripts=.agents/skills/inkflow-release/scripts
cp "$scripts/release.sh" "$scripts/release-appcast.sh" "$fixture/repo/$scripts/"
cp macOS/scripts/release-receipt.sh macOS/scripts/release-build.sh "$fixture/repo/macOS/scripts/"
cd "$fixture/repo"
# The real corresponding-source bundle downloads pinned inputs; the source-bundle unit covers it.
printf '#!/bin/bash\nprintf bundle > "$1"\n' > macOS/scripts/dictionary-source-bundle.sh
git add "$scripts" macOS/scripts/dictionary-source-bundle.sh macOS/scripts/release-receipt.sh macOS/scripts/release-build.sh
git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm 'fixture release scripts'
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
# What pkgutil --expand-full yields for the package, built from the prepared app.
export FIXTURE_PKG_TREE="$fixture/pkg-tree"
component="$FIXTURE_PKG_TREE/InkFlow-component.pkg"
mkdir -p "$component/Payload" "$component/Scripts"
ditto "$app" "$component/Payload/InkFlow.app"
printf '#!/bin/bash\nexit 0\n' > "$component/Scripts/register-input-source"
printf '%s\n' "$build" > "$component/Scripts/build-number"
cat > "$fixture/bin/gh" <<'MOCK'
#!/bin/bash
if [[ "$1 $2" == 'repo view' ]]; then echo fixture/InkFlow; exit 0; fi
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
# No fixture can submit a notarization or make a network request.
for tool in curl; do printf '#!/bin/bash\nexit 91\n' > "$fixture/bin/$tool"; done
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
sparkle=build/swiftpm/artifacts/sparkle/Sparkle/bin
mkdir -p "$sparkle"
for tool in generate_appcast sign_update; do printf '#!/bin/bash\nexit 0\n' > "$sparkle/$tool"; chmod +x "$sparkle/$tool"; done
signature=$(printf '%086d==' 0)
minimum=$(plutil -extract LSMinimumSystemVersion raw macOS/Info.plist)
cat > "$release/appcast.xml" <<XML
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
<sparkle:version>$build</sparkle:version><sparkle:shortVersionString>$version</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
<enclosure url="https://github.com/nervouna/InkFlow/releases/download/v$version/$(basename "$zip")" length="$(stat -f '%z' "$zip")" sparkle:edSignature="$signature"/>
</item></channel></rss>
XML
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
