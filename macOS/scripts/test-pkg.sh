#!/bin/bash
set -euo pipefail
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
out="$fixture/out/InkFlow.pkg"
build_pkg() { (cd "$repo" && bash macOS/scripts/build-pkg.sh "$@"); }

if build_pkg > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'Usage: build-pkg.sh' "$fixture/output"
if build_pkg "$fixture/missing.app" "$out" > "$fixture/output" 2>&1; then exit 1; fi
[[ ! -e "$out" ]]
build_pkg "$app" "$out" > "$fixture/output" 2>&1
[[ -s "$out" ]]
# A second build over the same path must work: the acceptance command is rerun.
build_pkg "$app" "$out" > "$fixture/output" 2>&1
[[ -z "$(ls -A "$repo/build")" ]]

pkgutil --expand "$out" "$fixture/expanded"
distribution="$fixture/expanded/Distribution"
# Installs into the current user's home folder only, on the macOS the app supports.
grep -Fq 'enable_currentUserHome="true"' "$distribution"
grep -Fq 'enable_anywhere="false"' "$distribution"
grep -Fq 'enable_localSystem="false"' "$distribution"
minimum=$(plutil -extract LSMinimumSystemVersion raw macOS/Info.plist)
grep -Fq "<os-version min=\"$minimum\"/>" "$distribution"

# The app is installed in place, never relocated to another copy found on disk.
[[ $(plutil -extract 0.BundleIsRelocatable raw macOS/Package/component.plist) == false ]]
component=("$fixture/expanded"/*.pkg)
[[ ${#component[@]} -eq 1 ]]
grep -Fq 'install-location="Library/Input Methods"' "${component[0]}/PackageInfo"
grep -Fq 'relocatable="false"' "${component[0]}/PackageInfo"
grep -Fq '<relocate/>' "${component[0]}/PackageInfo"

# The payload holds only the app.
pkgutil --payload-files "$out" > "$fixture/payload"
[[ -z "$(grep -Ev '^\.$|^\./InkFlow\.app(/|$)' "$fixture/payload")" ]]
grep -Fxq './InkFlow.app/Contents/Info.plist' "$fixture/payload"
grep -Fxq './InkFlow.app/Contents/MacOS/InkFlow' "$fixture/payload"

# The first-install sentence in install.sh reaches the conclusion page.
sentence=$(sed -n "s/.*echo '\(首次安装：[^']*\)'.*/\1/p" macOS/scripts/install.sh)
[[ -n "$sentence" ]]
grep -Fq "$sentence" "$fixture/expanded/Resources/conclusion.html"
[[ -s "$fixture/expanded/Resources/welcome.html" ]]

# The scripts are executable and carry the lifecycle tool and the build they expect.
scripts="${component[0]}/Scripts"
for file in preinstall postinstall register-input-source; do [[ -x "$scripts/$file" ]]; done
[[ $(ls -A "$scripts" | sort | tr '\n' ' ') == 'build-number postinstall preinstall register-input-source ' ]]
grep -Fq 'fixture register-input-source' "$scripts/register-input-source"
[[ $(<"$scripts/build-number") == 42 ]]
! grep -Eq 'killall|pkill|kill ' "$scripts/preinstall" "$scripts/postinstall"

# Script behavior: Installer runs both as the user with HOME set.
export HOME="$fixture/home" EVENTS="$fixture/events"
target="$HOME/Library/Input Methods/InkFlow.app"
state="$HOME/Library/Caches/io.damao.inkflow.installer/state.json"
mkdir -p "$HOME/Library/Application Support/InkFlow"
printf 'personal data\n' > "$HOME/Library/Application Support/InkFlow/dictionary.db"

: > "$EVENTS"
"$scripts/preinstall" > "$fixture/output" 2>&1
grep -Fxq "tool:$target --prepare-update $state 42" "$EVENTS"
[[ -s "$state" ]]

: > "$EVENTS"
"$scripts/postinstall" > "$fixture/output" 2>&1
grep -Fxq "tool:$target --finish-update $state" "$EVENTS"
[[ ! -e "$state" ]]

# A preinstall failure aborts the install and leaves no state to restore from.
printf 'stale\n' > "$state"
if TOOL_FAILURE=--prepare-update "$scripts/preinstall" > "$fixture/output" 2>&1; then
  echo 'FAIL: preinstall must fail when InkFlow cannot be stopped' >&2
  exit 1
fi
[[ ! -e "$state" ]]

# A postinstall failure prints one recovery line, fails the install and still clears the state.
"$scripts/preinstall" > "$fixture/output" 2>&1
if TOOL_FAILURE=--finish-update "$scripts/postinstall" > "$fixture/output" 2>&1; then
  echo 'FAIL: postinstall must fail when InkFlow cannot be restored' >&2
  exit 1
fi
[[ $(wc -l < "$fixture/output") -eq 1 ]]
grep -Fq '再次运行' "$fixture/output"
[[ ! -e "$state" ]]

# Neither script touches personal data.
[[ $(<"$HOME/Library/Application Support/InkFlow/dictionary.db") == 'personal data' ]]
[[ -z "$(ls -A "$HOME/Library/Application Support/InkFlow" | grep -v '^dictionary.db$')" ]]
echo 'PASS installer package: home-only domain, non-relocatable app, app-only payload, executable scripts with the lifecycle tool, preinstall aborts and postinstall recovers without touching personal data'
