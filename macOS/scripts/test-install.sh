#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-install-tests.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
mkdir -p "$repo/macOS/scripts" "$repo/build/InkFlow.app/Contents/MacOS" \
  "$repo/build/InkFlow.app/Contents/Frameworks/rime-plugins" "$fixture/bin" "$fixture/home"
cp macOS/scripts/install.sh macOS/scripts/verify-developer-id.sh "$repo/macOS/scripts/"
# Isolate the desktop preflight, including its refusal path, from the test runner's sandbox.
sed -i '' "s|/bin/ps -p|$fixture/bin/ps -p|" "$repo/macOS/scripts/install.sh"
cp macOS/Info.plist macOS/DeveloperID.entitlements macOS/Debug.entitlements "$repo/macOS/"
printf executable > "$repo/build/InkFlow.app/Contents/MacOS/InkFlow"
printf worker > "$repo/build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"
printf rime > "$repo/build/InkFlow.app/Contents/Frameworks/librime.1.dylib"
printf lua > "$repo/build/InkFlow.app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
chmod +x "$repo/build/InkFlow.app/Contents/MacOS/"*
cat > "$repo/macOS/scripts/register.sh" <<'STUB'
echo "register:$1:$2" >> "$EVENTS"
if [[ "$2" == --prepare-update ]]; then
  [[ "${LIFECYCLE_FAILURE:-}" != prepare ]] || exit 1
  [[ ! -f "$1/old-marker" ]] || echo old-intact-before-stop >> "$EVENTS"
  printf 'fixture lifecycle snapshot\n' > "$3"
elif [[ "$2" == --finish-update ]]; then
  [[ ! -f "$1/old-marker" ]] || exit 1
  [[ "${LIFECYCLE_FAILURE:-}" != finish ]] || exit 1
fi
STUB
cat > "$fixture/bin/ps" <<'STUB'
#!/bin/bash
[[ "${DESKTOP_DENIED:-0}" != 1 ]]
STUB
cat > "$repo/macOS/scripts/refresh-menu.sh" <<'STUB'
echo refresh >> "$EVENTS"
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
if [[ "$1" == --verify ]]; then
  case "${!#}" in
    */build/InkFlow.app) phase=source ;;
    */.inkflow-install.*/InkFlow.app) phase=staged ;;
    */Library/Input\ Methods/InkFlow.app) phase=installed ;;
    *) exit 99 ;;
  esac
  if [[ "${VERIFY_FAILURE:-}" == "$phase" ]]; then
    echo "verification-rejected:$phase" >> "$EVENTS"
    exit 1
  fi
fi
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
grep -Fq ':--finish-update' "$EVENTS"
cmp "$repo/build/InkFlow.app/Contents/MacOS/InkFlow" "$HOME/Library/Input Methods/InkFlow.app/Contents/MacOS/InkFlow"

# Verify each integrity gate independently, before any existing failure leaves
# a retained recovery directory. These fixtures never touch the real installation.
target="$HOME/Library/Input Methods/InkFlow.app"
shopt -s nullglob
for phase in source staged installed; do
  printf old > "$target/old-marker"
  : > "$EVENTS"
  if VERIFY_FAILURE="$phase" install --developer-id > "$fixture/output" 2>&1; then
    echo "FAIL: accepted $phase signature verification failure" >&2
    exit 1
  fi
  grep -Fxq "verification-rejected:$phase" "$EVENTS"
  ! grep -Fq 'Installed' "$fixture/output"
  ! grep -Fq ':--finish-update' "$EVENTS"
  ! grep -Fxq refresh "$EVENTS"
  stages=("$HOME/Library/Input Methods"/.inkflow-install.*)
  if [[ "$phase" == installed ]]; then
    [[ ! -e "$target/old-marker" && ${#stages[@]} -eq 1 ]]
    [[ -f "${stages[0]}/previous/old-marker" && -s "${stages[0]}/state.json" ]]
    grep -Fxq old-intact-before-stop "$EVENTS"
    grep -Fq ':--prepare-update' "$EVENTS"
    # Remove only this test-owned recovery fixture before the next scenario.
    rm -rf "${stages[0]}"
  else
    [[ -f "$target/old-marker" && ${#stages[@]} -eq 0 ]]
    ! grep -q '^register:' "$EVENTS"
  fi
done
printf old > "$HOME/Library/Input Methods/InkFlow.app/old-marker"
if LIFECYCLE_FAILURE=prepare install --developer-id > "$fixture/output" 2>&1; then exit 1; fi
[[ -f "$HOME/Library/Input Methods/InkFlow.app/old-marker" ]]
! grep -Fq 'Installed and verified' "$fixture/output"
: > "$EVENTS"
if DESKTOP_DENIED=1 install --developer-id > "$fixture/output" 2>&1; then exit 1; fi
[[ ! -s "$EVENTS" && -f "$HOME/Library/Input Methods/InkFlow.app/old-marker" ]]
grep -Fq 'state is unknown' "$fixture/output"
if LIFECYCLE_FAILURE=finish install --developer-id > "$fixture/output" 2>&1; then exit 1; fi
[[ ! -f "$HOME/Library/Input Methods/InkFlow.app/old-marker" ]]
grep -Fq 'old-intact-before-stop' "$EVENTS"
grep -Fq 'staged previous app and state retained' "$fixture/output"
! grep -Fq 'Installed and verified' "$fixture/output"
: > "$EVENTS"
install --developer-id > "$fixture/output" 2>&1
[[ -x "$target/Contents/MacOS/InkFlow" && ! -e "$target/old-marker" ]]
cmp "$repo/build/InkFlow.app/Contents/MacOS/InkFlow" "$target/Contents/MacOS/InkFlow"
grep -Fq ':--prepare-update' "$EVENTS"
grep -Fq ':--finish-update' "$EVENTS"
grep -Fxq refresh "$EVENTS"

# Exercise the actual read-only wrapper with fake compiler and service diagnostics.
cp macOS/scripts/register.sh "$repo/macOS/scripts/register.sh"
sed -i '' "s|/bin/ps -p|$fixture/bin/ps -p|" "$repo/macOS/scripts/register.sh"
cat > "$repo/macOS/scripts/swift-package.sh" <<'STUB'
build_swift_product() { echo compiler >> "$EVENTS"; }
STUB
cat > "$repo/build/register-input-source" <<'STUB'
#!/bin/bash
[[ "$2" == --verify-enabled ]] || exit 99
echo readonly-query >> "$EVENTS"
echo 'parent_enabled=unconfirmed'
echo 'Connection invalid' >&2
STUB
chmod +x "$repo/build/register-input-source"
: > "$EVENTS"
if DESKTOP_DENIED=1 bash "$repo/macOS/scripts/register.sh" ignored --verify-enabled > "$fixture/output" 2>&1; then exit 1; fi
[[ ! -s "$EVENTS" ]]
if bash "$repo/macOS/scripts/register.sh" ignored --verify-enabled > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'enabled state is unknown' "$fixture/output"
grep -Fq readonly-query "$EVENTS"
echo 'PASS install signing/lifecycle: all three integrity failures stop safely, recovery retained after replacement, lifecycle and installed bytes verified, desktop/query errors unknown'
