#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/sparkle-signing.sh
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-sparkle-signing.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
app="$fixture/InkFlow.app"
mkdir -p "$fixture/bin"
while IFS= read -r component; do mkdir -p "$component"; done < <(sparkle_components "$app")
export EVENTS="$fixture/events" PATH="$fixture/bin:$PATH"
cat > "$fixture/bin/codesign" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$EVENTS"
if [[ "$1" == -dvvv ]]; then
  team=T7976FL2LP
  authority='Developer ID Application'
  if [[ "${!#}" == *"${BAD_COMPONENT:-not-a-component}" ]]; then
    team=${BAD_TEAM:-T7976FL2LP}
    authority=${BAD_AUTHORITY:-Developer ID Application}
  fi
  printf 'TeamIdentifier=%s\nAuthority=%s: Fixture\n' "$team" "$authority"
fi
STUB
chmod +x "$fixture/bin/codesign"
sign_sparkle "$app" --options runtime --timestamp --sign fixture
while IFS= read -r component; do
  extra=''
  [[ "$component" != */Downloader.xpc ]] || extra=' --preserve-metadata=entitlements'
  printf '%s\n' "--force --options runtime --timestamp --sign fixture$extra $component"
done < <(sparkle_components "$app") > "$fixture/expected"
cmp "$EVENTS" "$fixture/expected"
verify_sparkle_developer_id "$app" T7976FL2LP
# Every nested target must fail independently, even when the outer app is valid.
while IFS= read -r component; do
  if BAD_COMPONENT="$component" BAD_TEAM=WRONGTEAM verify_sparkle_developer_id "$app" T7976FL2LP > "$fixture/error" 2>&1; then exit 1; fi
  grep -Fq 'Unexpected Sparkle signing team:' "$fixture/error"
  if BAD_COMPONENT="$component" BAD_AUTHORITY='Apple Development' verify_sparkle_developer_id "$app" T7976FL2LP > "$fixture/error" 2>&1; then exit 1; fi
  grep -Fq 'Expected Developer ID Application signature.' "$fixture/error"
done < <(sparkle_components "$app")
missing="$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
rmdir "$missing"
: > "$EVENTS"
if sign_sparkle "$app" --sign fixture > "$fixture/error" 2>&1; then exit 1; fi
grep -Fq 'Missing Sparkle signing component:' "$fixture/error"
[[ ! -s "$EVENTS" ]]
if verify_sparkle_developer_id "$app" T7976FL2LP > "$fixture/error" 2>&1; then exit 1; fi
echo 'PASS Sparkle signing: inside-out order, Downloader entitlements, all nested teams/authorities, missing component fails before signing'
