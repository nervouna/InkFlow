#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-install-tests.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
mkdir -p "$repo/macOS/scripts" "$repo/build/InkFlow.app/Contents/MacOS" \
  "$repo/build/InkFlow.app/Contents/Frameworks/rime-plugins" "$fixture/bin" "$fixture/home"
cp macOS/scripts/install.sh macOS/scripts/verify-developer-id.sh "$repo/macOS/scripts/"
cp macOS/Info.plist macOS/DeveloperID.entitlements macOS/Debug.entitlements "$repo/macOS/"
printf executable > "$repo/build/InkFlow.app/Contents/MacOS/InkFlow"
printf worker > "$repo/build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"
printf rime > "$repo/build/InkFlow.app/Contents/Frameworks/librime.1.dylib"
printf lua > "$repo/build/InkFlow.app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
chmod +x "$repo/build/InkFlow.app/Contents/MacOS/"*
cat > "$repo/macOS/scripts/register.sh" <<'STUB'
echo "register:$1" >> "$EVENTS"
STUB
cat > "$fixture/bin/security" <<'STUB'
#!/bin/bash
if [[ "$1 $2" == 'find-identity -v' ]]; then
  name='Developer ID Application: Fixture (T7976FL2LP)'
  [[ "${IDENTITY_KIND:-developer-id}" != development ]] || name='Apple Development: Fixture (T7976FL2LP)'
  printf '  1) %s "%s"\n' "$TEST_IDENTITY" "$name"
elif [[ "$1" == find-certificate ]]; then
  printf '%s\n' '-----BEGIN CERTIFICATE-----' fixture '-----END CERTIFICATE-----'
else exit 99
fi
STUB
cat > "$fixture/bin/openssl" <<'STUB'
#!/bin/bash
if [[ "$*" == *-fingerprint* ]]; then
  printf 'sha1 Fingerprint=%s\n' "$(sed 's/../&:/g;s/:$//' <<< "$TEST_IDENTITY")"
else
  printf 'organizationalUnitName = %s\n' "${CERT_TEAM:-T7976FL2LP}"
fi
STUB
cat > "$fixture/bin/codesign" <<'STUB'
#!/bin/bash
echo "codesign:$*" >> "$EVENTS"
if [[ "$1" == -dvvv ]]; then
  printf 'Authority=%s: Fixture\nTeamIdentifier=%s\nIdentifier=io.damao.inputmethod.inkflow\n' \
    "${SIGNED_AUTHORITY:-Developer ID Application}" "${SIGNED_TEAM:-T7976FL2LP}" >&2
fi
STUB
cat > "$fixture/bin/ditto" <<'STUB'
#!/bin/bash
/usr/bin/ditto "$@"
STUB
chmod +x "$fixture/bin/"* "$repo/macOS/scripts/"*.sh
export TEST_IDENTITY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
export EVENTS="$fixture/events" HOME="$fixture/home" PATH="$fixture/bin:$PATH"
install() { (cd "$repo" && INKFLOW_SIGN_IDENTITY="$TEST_IDENTITY" bash macOS/scripts/install.sh "$@"); }

if install > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'Usage: install.sh --developer-id | --debug (development debugging only)' "$fixture/output"

: > "$EVENTS"
if IDENTITY_KIND=development install --developer-id > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'not an available valid Developer ID Application' "$fixture/output"
[[ ! -s "$EVENTS" && ! -e "$HOME/Library/Input Methods/InkFlow.app" ]]

: > "$EVENTS"
if CERT_TEAM=WRONGTEAM install --developer-id > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'OU does not match the InkFlow team.' "$fixture/output"
[[ ! -s "$EVENTS" && ! -e "$HOME/Library/Input Methods/InkFlow.app" ]]

: > "$EVENTS"
if SIGNED_AUTHORITY='Apple Development' install --developer-id > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'Expected Developer ID Application signature.' "$fixture/output"
[[ ! -e "$HOME/Library/Input Methods/InkFlow.app" ]]
! grep -q '^register:' "$EVENTS"

: > "$EVENTS"
install --developer-id > "$fixture/output" 2>&1
[[ -x "$HOME/Library/Input Methods/InkFlow.app/Contents/MacOS/InkFlow" ]]
grep -Fq "register:$HOME/Library/Input Methods/InkFlow.app" "$EVENTS"
grep -Fq 'Installed ' "$fixture/output"
echo 'PASS install signing contract: Developer ID type/OU preflight, signed authority and isolated target'
