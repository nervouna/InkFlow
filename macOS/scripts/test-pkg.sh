#!/bin/bash
set -euo pipefail
fail() { echo "FAIL ${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}" >&2; exit 1; }
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-pkg-tests.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
mkdir -p "$repo/macOS/scripts" "$repo/build" "$fixture/home"
cp macOS/scripts/build-pkg.sh "$repo/macOS/scripts/"
cp -R macOS/Package "$repo/macOS/Package"
# The real register-input-source is a SwiftPM product; the fixture swaps in a recorder so packaging stays fast.
cat > "$repo/macOS/scripts/swift-package.sh" <<'STUB'
build_swift_product() {
  [[ "$1 $3" == 'register-input-source release' ]] || return 99
  cat > "$2" <<'TOOL'
#!/bin/bash
# fixture register-input-source
echo "tool:$*" >> "$EVENTS"
[[ "${TOOL_FAILURE:-}" != "$2" ]] || exit 1
if [[ "$2" == --prepare-update ]]; then printf 'fixture state\n' > "$3"; fi
if [[ "$2" == --finish-update ]]; then [[ -s "$3" ]]; fi
TOOL
  chmod +x "$2"
}
STUB

# A minimal InkFlow.app: the real Info.plist (identity, versions, minimum macOS) and a placeholder executable.
app="$fixture/InkFlow.app"
mkdir -p "$app/Contents/MacOS"
cp macOS/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string 42 "$app/Contents/Info.plist"
printf '#!/bin/sh\n' > "$app/Contents/MacOS/InkFlow"
chmod +x "$app/Contents/MacOS/InkFlow"
# build.sh leaves the app unsealed, so a copy taken before the fixture is signed is the refusal case.
unsealed="$fixture/unsealed/InkFlow.app"
mkdir -p "$fixture/unsealed"
cp -R "$app" "$unsealed"
# build-pkg.sh needs a sealed app, so the fixture carries an ad-hoc signature (no keychain).
codesign --sign - "$app"
out="$fixture/out/InkFlow.pkg"
build_pkg() { (cd "$repo" && bash macOS/scripts/build-pkg.sh "$@"); }

if build_pkg > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'Usage: build-pkg.sh' "$fixture/output"
# An unsealed app is refused with one line, before any package or build state is written.
if build_pkg "$unsealed" "$fixture/unsealed.pkg" > "$fixture/output" 2>&1; then exit 1; fi
[[ $(<"$fixture/output") == 'Application signature does not verify; sign it first with install.sh or the release flow.' ]] || fail
[[ ! -e "$fixture/unsealed.pkg" && -z "$(ls -A "$repo/build")" ]] || fail
if build_pkg "$fixture/missing.app" "$out" > "$fixture/output" 2>&1; then exit 1; fi
[[ ! -e "$out" ]] || fail
build_pkg "$app" "$out" > "$fixture/output" 2>&1
[[ -s "$out" ]] || fail
# A second build over the same path must work: the acceptance command is rerun.
build_pkg "$app" "$out" > "$fixture/output" 2>&1
[[ -z "$(ls -A "$repo/build")" ]] || fail

pkgutil --expand "$out" "$fixture/expanded"
distribution="$fixture/expanded/Distribution"
# Installs into the current user's home folder only, on the macOS the app supports.
grep -Fq 'enable_currentUserHome="true"' "$distribution"
grep -Fq 'enable_anywhere="false"' "$distribution"
grep -Fq 'enable_localSystem="false"' "$distribution"
minimum=$(plutil -extract LSMinimumSystemVersion raw macOS/Info.plist)
grep -Fq "<os-version min=\"$minimum\"/>" "$distribution"

# The app is installed in place, never relocated to another copy found on disk.
[[ $(plutil -extract 0.BundleIsRelocatable raw macOS/Package/component.plist) == false ]] || fail
component=("$fixture/expanded"/*.pkg)
[[ ${#component[@]} -eq 1 ]] || fail
grep -Fq 'install-location="Library/Caches/io.damao.inkflow.installer"' "${component[0]}/PackageInfo"
grep -Fq 'relocatable="false"' "${component[0]}/PackageInfo"
grep -Fq '<relocate/>' "${component[0]}/PackageInfo"

# The payload holds only the app.
pkgutil --payload-files "$out" > "$fixture/payload"
[[ -z "$(grep -Ev '^\.$|^\./InkFlow\.app(/|$)' "$fixture/payload")" ]] || fail
grep -Fxq './InkFlow.app/Contents/Info.plist' "$fixture/payload"
grep -Fxq './InkFlow.app/Contents/MacOS/InkFlow' "$fixture/payload"

# The input-source instruction install.sh prints for an unconfirmed update reaches the conclusion page.
sentence=$(sed -n "s/.*echo '\(请在系统设置[^']*\)'.*/\1/p" macOS/scripts/install.sh)
[[ -n "$sentence" ]] || fail
grep -Fq "$sentence" "$fixture/expanded/Resources/conclusion.html"
[[ -s "$fixture/expanded/Resources/welcome.html" ]] || fail

# The scripts are executable and carry the lifecycle tool and the build they expect.
scripts="${component[0]}/Scripts"
for file in preinstall postinstall register-input-source; do [[ -x "$scripts/$file" ]] || fail; done
[[ $(ls -A "$scripts" | sort | tr '\n' ' ') == 'build-number postinstall preinstall register-input-source ' ]] || fail
grep -Fq 'fixture register-input-source' "$scripts/register-input-source"
[[ $(<"$scripts/build-number") == 42 ]] || fail
! grep -Eq 'killall|pkill|kill ' "$scripts/preinstall" "$scripts/postinstall" || fail

# Script behavior: Installer runs both as the user with HOME set.
export HOME="$fixture/home" EVENTS="$fixture/events"
target="$HOME/Library/Input Methods/InkFlow.app"
state_dir="$HOME/Library/Caches/io.damao.inkflow.installer"
state="$state_dir/state.json"
staged="$state_dir/InkFlow.app"
mkdir -p "$HOME/Library/Application Support/InkFlow"
printf 'personal data\n' > "$HOME/Library/Application Support/InkFlow/dictionary.db"

: > "$EVENTS"
"$scripts/preinstall" > "$fixture/output" 2>&1
grep -Fxq "tool:$target --prepare-update $state 42" "$EVENTS"
[[ -s "$state" ]] || fail

# Installer stages the app in the state directory; postinstall swaps it in before the restore. The parent
# folder may be missing on a fresh account, so postinstall creates it.
mkdir -p "$staged/Contents"
[[ ! -e "$HOME/Library/Input Methods" ]] || fail
: > "$EVENTS"
"$scripts/postinstall" > "$fixture/output" 2>&1
[[ "$(<"$EVENTS")" == "tool:$target --commit-update $state"$'\n'"tool:$target --finish-update $state" ]] || fail
[[ -d "$HOME/Library/Input Methods" ]] || fail
[[ ! -e "$state" ]] || fail
[[ ! -e "$staged" ]] || fail

# A preinstall failure aborts the install and leaves no state to restore from.
printf 'stale\n' > "$state"
if TOOL_FAILURE=--prepare-update "$scripts/preinstall" > "$fixture/output" 2>&1; then
  echo 'FAIL: preinstall must fail when InkFlow cannot be stopped' >&2
  exit 1
fi
[[ ! -e "$state" ]] || fail

# A failed swap prints one recovery line, fails the install, never restores, and clears the staged app.
"$scripts/preinstall" > "$fixture/output" 2>&1
mkdir -p "$staged/Contents"
: > "$EVENTS"
if TOOL_FAILURE=--commit-update "$scripts/postinstall" > "$fixture/output" 2>&1; then
  echo 'FAIL: postinstall must fail when the staged app cannot be swapped in' >&2
  exit 1
fi
grep -Fxq "tool:$target --commit-update $state" "$EVENTS"
[[ "$(grep -Fc -e '--finish-update' "$EVENTS")" -eq 0 ]] || fail
[[ "$(wc -l < "$fixture/output")" -eq 1 ]] || fail
grep -Fq '再次运行' "$fixture/output"
[[ ! -e "$state" ]] || fail
[[ ! -e "$staged" ]] || fail

# A failed restore after the swap prints one recovery line, fails the install and still clears the state and the old app.
"$scripts/preinstall" > "$fixture/output" 2>&1
mkdir -p "$staged/Contents"
if TOOL_FAILURE=--finish-update "$scripts/postinstall" > "$fixture/output" 2>&1; then
  echo 'FAIL: postinstall must fail when InkFlow cannot be restored' >&2
  exit 1
fi
[[ "$(wc -l < "$fixture/output")" -eq 1 ]] || fail
grep -Fq '再次运行' "$fixture/output"
[[ ! -e "$state" ]] || fail
[[ ! -e "$staged" ]] || fail

# Neither script touches personal data.
[[ "$(<"$HOME/Library/Application Support/InkFlow/dictionary.db")" == 'personal data' ]] || fail
[[ -z "$(ls -A "$HOME/Library/Application Support/InkFlow" | grep -v '^dictionary.db$')" ]] || fail
# Signing (--sign APP_SHA1 INSTALLER_SHA1) is wired with stand-in tools; no keychain is used. The embedded tool
# is signed with the hardened runtime and a timestamp before it is packaged, and the package with the
# installer identity's common name, which productbuild takes instead of a hash.
shims="$fixture/shims"
mkdir -p "$shims"
cat > "$shims/security" <<'STUB'
#!/bin/bash
[[ "$*" == 'find-identity -v -p basic' ]] || exit 64
printf '  1) %s "Developer ID Application: Fixture (T7976FL2LP)"\n' "$APP_IDENTITY"
[[ "${NO_INSTALLER:-}" == 1 ]] || printf '  2) %s "Developer ID Installer: Fixture (T7976FL2LP)"\n' "$INSTALLER_IDENTITY"
STUB
cat > "$shims/codesign" <<'STUB'
#!/bin/bash
# Verification is read-only: it reaches the real codesign and is not a signing event.
[[ "$1" != --verify ]] || exec /usr/bin/codesign "$@"
echo "codesign:$*" >> "$EVENTS"
printf '# signed\n' >> "${!#}"
STUB
cat > "$shims/productbuild" <<'STUB'
#!/bin/bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign) echo "productbuild-sign:$2" >> "$EVENTS"; shift 2 ;;
    --timestamp) echo 'productbuild-timestamp' >> "$EVENTS"; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/productbuild "${args[@]}"
STUB
chmod +x "$shims"/*
export APP_IDENTITY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA INSTALLER_IDENTITY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
signed="$fixture/signed/InkFlow.pkg"
signed_pkg() { PATH="$shims:$PATH" build_pkg "$@"; }
for arguments in "--sign" "--sign $APP_IDENTITY" "--sign $APP_IDENTITY $INSTALLER_IDENTITY extra" "--unknown"; do
  # shellcheck disable=SC2086
  if signed_pkg "$app" "$signed" $arguments > "$fixture/output" 2>&1; then exit 1; fi
  grep -Fq 'Usage: build-pkg.sh' "$fixture/output"
done
if signed_pkg "$app" "$signed" --sign not-a-hash "$INSTALLER_IDENTITY" > "$fixture/output" 2>&1; then exit 1; fi
if NO_INSTALLER=1 signed_pkg "$app" "$signed" --sign "$APP_IDENTITY" "$INSTALLER_IDENTITY" > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'Developer ID Installer' "$fixture/output"
[[ ! -e "$signed" ]] || fail
: > "$EVENTS"
signed_pkg "$app" "$signed" --sign "$APP_IDENTITY" "$INSTALLER_IDENTITY" > "$fixture/output" 2>&1
grep -Fq ', signed;' "$fixture/output"
grep -Eq "^codesign:--force --options runtime --timestamp --sign $APP_IDENTITY .*/register-input-source$" "$EVENTS"
[[ $(grep -c '^codesign:' "$EVENTS") -eq 1 ]] || fail
grep -Fxq 'productbuild-sign:Developer ID Installer: Fixture (T7976FL2LP)' "$EVENTS"
grep -Fxq 'productbuild-timestamp' "$EVENTS"
pkgutil --expand-full "$signed" "$fixture/signed-expanded"
grep -Fxq '# signed' "$fixture/signed-expanded/InkFlow-component.pkg/Scripts/register-input-source"
[[ -z "$(ls -A "$repo/build")" ]] || fail
# The unsigned default never reaches codesign or the keychain.
: > "$EVENTS"
PATH="$shims:$PATH" build_pkg "$app" "$fixture/plain.pkg" > "$fixture/output" 2>&1
grep -Fq ', unsigned;' "$fixture/output"
[[ ! -s "$EVENTS" ]] || fail
echo 'PASS installer package: home-only domain, non-relocatable app, app-only payload, executable scripts with the lifecycle tool, preinstall aborts, postinstall swaps the staged app in and recovers without touching personal data, optional signing of the tool and the package'
