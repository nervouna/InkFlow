#!/bin/bash
# Repository-shaped fixtures. Network and app signing/stapling are stubbed; the pinned Sparkle signer uses a temporary EdDSA key file.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-appcast.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
test_home="$fixture/home"
mkdir -p "$test_home/Library/Caches"
export HOME="$test_home" CFFIXED_USER_HOME="$test_home"

openssl genpkey -algorithm ED25519 -out "$fixture/fixture-key.pem"
openssl pkey -in "$fixture/fixture-key.pem" -outform DER | tail -c 32 | base64 > "$fixture/fixture-private.seed"
openssl pkey -in "$fixture/fixture-key.pem" -pubout -outform DER | tail -c 32 | base64 > "$fixture/fixture-public.key"
test_public_key=$(tr -d '\n' < "$fixture/fixture-public.key")
sign_tool="$root/build/swiftpm/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$sign_tool" ]] || { echo 'Pinned Sparkle sign_update tool is unavailable.' >&2; exit 1; }

make_plist() {
  local path=$1; shift
  plutil -create xml1 "$path"
  while [[ $# -gt 0 ]]; do plutil -insert "$1" -string "$2" "$path"; shift 2; done
}

setup_case() {
  local name=$1 mode=$2
  repo="$fixture/$name"
  bin="$repo/test-bin"
  release="$repo/build/releases/InkFlow-1.2.3-7"
  mkdir -p "$repo/.agents/skills/inkflow-release/scripts" "$repo/macOS/scripts" \
    "$repo/build/release-verification" "$repo/build/swiftpm/artifacts/sparkle/Sparkle/bin" \
    "$release/payload/InkFlow.app/Contents/MacOS" "$bin"
  cp "$root/.agents/skills/inkflow-release/scripts/release-appcast.sh" "$repo/.agents/skills/inkflow-release/scripts/"
  cp "$root/macOS/scripts/release-build.sh" "$repo/macOS/scripts/"
  cp "$root/macOS/Info.plist" "$repo/macOS/Info.plist"
  cp "$root/Package.resolved" "$repo/Package.resolved"
  plutil -replace CFBundleShortVersionString -string 1.2.3 "$repo/macOS/Info.plist"
  plutil -replace CFBundleVersion -string 6 "$repo/macOS/Info.plist"
  plutil -replace SUPublicEDKey -string "$test_public_key" "$repo/macOS/Info.plist"
  cp "$repo/macOS/Info.plist" "$release/payload/InkFlow.app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string 7 "$release/payload/InkFlow.app/Contents/Info.plist"
  printf '#!/bin/sh\nexit 0\n' > "$release/payload/InkFlow.app/Contents/MacOS/InkFlow"
  chmod +x "$release/payload/InkFlow.app/Contents/MacOS/InkFlow"
  plutil -create xml1 "$repo/build/release-verification/installer.plist"
  plutil -insert appBuild -string 7 "$repo/build/release-verification/installer.plist"
  ditto -c -k --sequesterRsrc --keepParent "$release/payload/InkFlow.app" "$release/InkFlow-1.2.3-7-arm64.zip"
  printf '%s\n' "$mode" > "$repo/feed-mode"

  cat > "$bin/codesign" <<'STUB'
#!/bin/bash
last=${!#}
if [[ "$1" == -dvvv ]]; then printf 'TeamIdentifier=T7976FL2LP\nIdentifier=io.damao.inputmethod.inkflow\n' >&2; fi
exit 0
STUB
  cat > "$bin/xcrun" <<'STUB'
#!/bin/bash
[[ "$1" == stapler && "$2" == validate ]] || exit 99
exit 0
STUB
  cat > "$repo/build/swiftpm/artifacts/sparkle/Sparkle/bin/sign_update" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ "$1" == --verify && "$2" == --account && "$3" == "$INKFLOW_SPARKLE_TEST_ACCOUNT" ]]
"$SPARKLE_TEST_SIGN_TOOL" --ed-key-file "$SPARKLE_TEST_PRIVATE_KEY" --verify "$4" "$5" >/dev/null
STUB
  cat > "$bin/curl" <<'STUB'
#!/bin/bash
set -euo pipefail
output=''; url=''; mode=$(cat "$FEED_MODE_FILE")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --write-out) shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
[[ "$url" == https://github.com/nervouna/InkFlow/releases/latest/download/appcast.xml ]]
if [[ "$mode" == 200 ]]; then cp "$PREVIOUS_FEED" "$output"; printf '200\nhttps://github.com/nervouna/InkFlow/releases/download/v1.2.2/appcast.xml\n'
else : > "$output"; printf '404\nhttps://github.com/nervouna/InkFlow/releases/download/v1.2.2/appcast.xml\n'; fi
STUB
  cat > "$repo/build/swiftpm/artifacts/sparkle/Sparkle/bin/generate_appcast" <<'STUB'
#!/bin/bash
set -euo pipefail
account=''; max_versions=''; max_deltas=''; prefix=''; work=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --account) account=$2; shift 2 ;;
    --maximum-versions) max_versions=$2; shift 2 ;;
    --maximum-deltas) max_deltas=$2; shift 2 ;;
    --download-url-prefix) prefix=$2; shift 2 ;;
    *) work=$1; shift ;;
  esac
done
[[ "$account" == "$INKFLOW_SPARKLE_TEST_ACCOUNT" && "$max_versions" == 3 && "$max_deltas" == 0 ]]
[[ "$prefix" == https://github.com/nervouna/InkFlow/releases/download/v1.2.3/ ]]
echo 'generate_appcast --account InkFlow --maximum-versions 3 --maximum-deltas 0' >> "$EVENTS"
app="$work/InkFlow-1.2.3-7-arm64.zip"
length=$(stat -f '%z' "$app")
signature=$("$SPARKLE_TEST_SIGN_TOOL" --ed-key-file "$SPARKLE_TEST_PRIVATE_KEY" -p "$app")
cat > "$work/appcast.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>InkFlow</title>
<item><title>InkFlow 1.2.3</title><sparkle:version>7</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString><sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion><enclosure url="${prefix}InkFlow-1.2.3-7-arm64.zip" length="$length" sparkle:edSignature="$signature" type="application/octet-stream" /></item>
XML
if [[ $(cat "$FEED_MODE_FILE") == 200 ]]; then
  printf '<item><title>InkFlow 1.2.2</title><sparkle:version>6</sparkle:version><sparkle:shortVersionString>1.2.2</sparkle:shortVersionString><sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion><enclosure url="https://github.com/nervouna/InkFlow/releases/download/v1.2.2/InkFlow-1.2.2-6-arm64.zip" length="1" sparkle:edSignature="%s" type="application/octet-stream" /></item>\n' "$signature" >> "$work/appcast.xml"
fi
printf '</channel></rss>\n' >> "$work/appcast.xml"
STUB
  chmod +x "$bin/"* "$repo/build/swiftpm/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    "$repo/build/swiftpm/artifacts/sparkle/Sparkle/bin/sign_update"
  export PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" FEED_MODE_FILE="$repo/feed-mode" PREVIOUS_FEED="$repo/previous.xml" EVENTS="$repo/events"
  export SPARKLE_TEST_SIGN_TOOL="$sign_tool" SPARKLE_TEST_PRIVATE_KEY="$fixture/fixture-private.seed"
  export INKFLOW_SPARKLE_TEST_MODE=1 INKFLOW_SPARKLE_TEST_ACCOUNT="inkflow-fixture-$name"
}

make_previous_feed() {
  local path=$1
  cat > "$path" <<'XML'
<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item><sparkle:version>6</sparkle:version><sparkle:shortVersionString>1.2.2</sparkle:shortVersionString><sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion><enclosure url="https://github.com/nervouna/InkFlow/releases/download/v1.2.2/InkFlow-1.2.2-6-arm64.zip" length="1" sparkle:edSignature="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==" type="application/octet-stream" /></item></channel></rss>
XML
}

setup_case bootstrap 404
: > "$EVENTS"
(cd "$repo" && bash .agents/skills/inkflow-release/scripts/release-appcast.sh generate v1.2.2)
[[ -f "$release/appcast.xml" && -f "$release/sparkle-receipt.plist" ]]
[[ $(grep -c '^generate_appcast ' "$EVENTS") == 1 ]]
(cd "$repo" && bash .agents/skills/inkflow-release/scripts/release-appcast.sh generate v1.2.2)
[[ $(grep -c '^generate_appcast ' "$EVENTS") == 1 ]]
printf tamper >> "$release/InkFlow-1.2.3-7-arm64.zip"
if (cd "$repo" && bash .agents/skills/inkflow-release/scripts/release-appcast.sh generate v1.2.2) > "$fixture/tamper.out" 2>&1; then exit 1; fi
grep -Fq 'Sparkle update ZIP changed after appcast generation' "$fixture/tamper.out"
echo 'PASS: appcast bootstrap, receipt reuse, ZIP-only payload, and drift rejection'

setup_case history 200
make_previous_feed "$PREVIOUS_FEED"
: > "$EVENTS"
(cd "$repo" && bash .agents/skills/inkflow-release/scripts/release-appcast.sh generate v1.2.2)
[[ $(xmllint --xpath "string(/rss/channel/item[2]/*[local-name()='version'])" "$release/appcast.xml") == 6 ]]
[[ $(plutil -extract previousBuild raw "$release/sparkle-receipt.plist") == 6 ]]
[[ $(grep -c '^generate_appcast ' "$EVENTS") == 1 ]]
echo 'PASS: existing feed history preserved with monotonically newer CFBundleVersion'
