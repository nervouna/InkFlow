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
cd "$fixture/repo"
git add "$scripts"
git -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm 'fixture release scripts'
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
previous=$(git tag --merged HEAD --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx "v$version" | head -1)
release="build/releases/InkFlow-$version-$build"
app="$release/payload/InkFlow.app"
mkdir -p "$app/Contents" build/InkFlow.app/Contents build/release-verification "$release/verified" "$fixture/bin"
cp macOS/Info.plist "$app/Contents/Info.plist"
cp macOS/Info.plist build/InkFlow.app/Contents/Info.plist
printf installer > "$release/verified/InkFlowInstaller"
printf icon > "$release/verified/AppIcon.icns"
bash macOS/scripts/release-receipt.sh create "$release/verified/InkFlowInstaller" "$release/verified/AppIcon.icns" "$release/verified/installer.plist"
cp "$release/verified/installer.plist" build/release-verification/installer.plist
printf notes > build/public-release-notes.md
printf submission > "$release/inputmethod-submission.zip"
printf dmg > "$release/InkFlow-$version-$build-arm64.dmg"
zip="$release/InkFlow-$version-$build-arm64.zip"
ditto -c -k --keepParent "$app" "$zip"
export FIXTURE_INSTALLER="$fixture/installer/InkFlow Installer.app"
mkdir -p "$FIXTURE_INSTALLER/Contents/Resources/Payload" "$FIXTURE_INSTALLER/Contents/MacOS"
cp macOS/Info.plist "$FIXTURE_INSTALLER/Contents/Info.plist"
cp "$zip" "$FIXTURE_INSTALLER/Contents/Resources/Payload/InkFlow.zip"
printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_INSTALLER/Contents/MacOS/InkFlowInstaller"
chmod +x "$FIXTURE_INSTALLER/Contents/MacOS/InkFlowInstaller"
cat > "$fixture/bin/gh" <<'MOCK'
#!/bin/bash
if [[ "$1 $2" == 'repo view' ]]; then echo fixture/InkFlow; exit 0; fi
echo 'FIXTURE_PUBLICATION_BOUNDARY'
exit 73
MOCK
cat > "$fixture/bin/codesign" <<'MOCK'
#!/bin/bash
if [[ "$1" == -dvvv ]]; then
  cat <<'METADATA'
TeamIdentifier=T7976FL2LP
Identifier=io.damao.inputmethod.inkflow
METADATA
fi
MOCK
cat > "$fixture/bin/hdiutil" <<'MOCK'
#!/bin/bash
if [[ "$1" == attach ]]; then
  ditto "$FIXTURE_INSTALLER" "$5/InkFlow Installer.app"
  touch "$5/安装说明.txt"
fi
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
plutil -replace sourceCommit -string stale "$release/verified/installer.plist"
check_release 'stale prepared candidate' 'Installer receipt commit does not match current source.'
cp build/release-verification/installer.plist "$release/verified/installer.plist"
cp "$zip" "$fixture/original.zip"
printf changed > "$app/Contents/changed"
ditto -c -k --keepParent "$app" "$zip"
check_release 'repacked update ZIP' 'Sparkle update ZIP changed after appcast generation.'
cp "$fixture/original.zip" "$zip"
printf '\n<!-- changed -->\n' >> "$release/appcast.xml"
check_release 'modified appcast' 'Sparkle appcast changed after generation.'
