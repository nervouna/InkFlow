#!/bin/bash
# Child-shell programs and the injection fixture intentionally contain literal dollars.
# shellcheck disable=SC2016
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-tests.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
plist="$fixture/Info.plist"
bump="$root/.agents/skills/inkflow-release/scripts/bump-version.sh"
for spec in 'major 2.0.0' 'minor 1.10.0' 'patch 1.9.10'; do
  read -r kind expected <<< "$spec"
  cp "$root/macOS/Info.plist" "$plist"
  plutil -replace CFBundleShortVersionString -string 1.9.9 "$plist"
  plutil -replace CFBundleVersion -string 99 "$plist"
  bash "$bump" "$kind" "$plist"
  [[ "$(plutil -extract CFBundleShortVersionString raw "$plist")" == "$expected" ]]
  [[ "$(plutil -extract CFBundleVersion raw "$plist")" == 100 ]]
  [[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == io.damao.inputmethod.inkflow ]]
done
for invalid in 01.2.3 1.2 1.2.3-beta 10000000000.0.0; do
  plutil -replace CFBundleShortVersionString -string "$invalid" "$plist"
  cp "$plist" "$fixture/before.plist"
  if bash "$bump" patch "$plist" > "$fixture/error.log" 2>&1; then
    echo "Accepted invalid version: $invalid" >&2; exit 1
  fi
  cmp "$plist" "$fixture/before.plist"
done
plutil -replace CFBundleShortVersionString -string 0.1.0 "$plist"
plutil -replace CFBundleVersion -string 01 "$plist"
cp "$plist" "$fixture/before.plist"
if bash "$bump" patch "$plist" > "$fixture/error.log" 2>&1; then exit 1; fi
cmp "$plist" "$fixture/before.plist"
if bash "$bump" feature "$plist" > "$fixture/error.log" 2>&1; then exit 1; fi
cmp "$plist" "$fixture/before.plist"

# Configuration loading never evaluates file contents or consults real credentials.
config="$fixture/release.plist"
plutil -create xml1 "$config"
plutil -insert INKFLOW_SIGN_IDENTITY -string 1111111111111111111111111111111111111111 "$config"
plutil -insert INKFLOW_NOTARY_PROFILE -string '$(touch forbidden)' "$config"
loader="$root/.agents/skills/inkflow-release/scripts/release-config.sh"
env -u INKFLOW_SIGN_IDENTITY -u INKFLOW_NOTARY_PROFILE INKFLOW_RELEASE_CONFIG="$config" bash -c '
  set -eu; source "$1"; load_release_config
  [[ "$INKFLOW_SIGN_IDENTITY" == 1111111111111111111111111111111111111111 ]]
  [[ "$INKFLOW_NOTARY_PROFILE" == '\''$(touch forbidden)'\'' ]]
' _ "$loader"
INKFLOW_SIGN_IDENTITY=2222222222222222222222222222222222222222 INKFLOW_NOTARY_PROFILE=override INKFLOW_RELEASE_CONFIG="$config" bash -c '
  set -eu; source "$1"; load_release_config
  [[ "$INKFLOW_SIGN_IDENTITY" == 2222222222222222222222222222222222222222 && "$INKFLOW_NOTARY_PROFILE" == override ]]
' _ "$loader"
if INKFLOW_SIGN_IDENTITY='' INKFLOW_RELEASE_CONFIG="$config" bash -c 'source "$1"; load_release_config' _ "$loader" > "$fixture/error.log" 2>&1; then exit 1; fi
printf 'invalid plist' > "$fixture/invalid.plist"
if INKFLOW_RELEASE_CONFIG="$fixture/invalid.plist" bash -c 'source "$1"; load_release_config' _ "$loader" > "$fixture/error.log" 2>&1; then exit 1; fi

# Use an isolated repository-shaped fixture; never access signing credentials.
scripts="$fixture/repo/.agents/skills/inkflow-release/scripts"
mkdir -p "$scripts" "$fixture/repo/macOS" "$fixture/repo/build/InkFlow.app/Contents/MacOS"
cp "$root/.agents/skills/inkflow-release/scripts/"{package,release-config,check-credentials}.sh "$scripts/"
export INKFLOW_RELEASE_CONFIG="$fixture/missing.plist" INKFLOW_NOTARY_PROFILE=fixture-profile
cp "$root/macOS/Info.plist" "$fixture/repo/macOS/Info.plist"
cp "$root/macOS/Info.plist" "$fixture/repo/build/InkFlow.app/Contents/Info.plist"
touch "$fixture/repo/build/InkFlow.app/Contents/MacOS/InkFlow"
chmod +x "$fixture/repo/build/InkFlow.app/Contents/MacOS/InkFlow"
if INKFLOW_SIGN_IDENTITY=invalid bash "$scripts/package.sh" > "$fixture/error.log" 2>&1; then exit 1; fi
[[ ! -e "$fixture/repo/build/releases" ]]
version=$(plutil -extract CFBundleShortVersionString raw "$fixture/repo/macOS/Info.plist")
build=$(plutil -extract CFBundleVersion raw "$fixture/repo/macOS/Info.plist")
output="$fixture/repo/build/releases/InkFlow-$version-$build"
mkdir -p "$output"
echo preserved > "$output/sentinel"
if INKFLOW_SIGN_IDENTITY=0000000000000000000000000000000000000000 bash "$scripts/package.sh" > "$fixture/error.log" 2>&1; then exit 1; fi
[[ "$(cat "$output/sentinel")" == preserved && ! -e "$output/stage" ]]
plutil -replace CFBundleVersion -string 999 "$fixture/repo/build/InkFlow.app/Contents/Info.plist"
if INKFLOW_SIGN_IDENTITY=0000000000000000000000000000000000000000 bash "$scripts/package.sh" > "$fixture/error.log" 2>&1; then exit 1; fi
[[ ! -e "$output/stage" ]]
echo 'PASS: version updates, configuration loading/overrides, invalid-input rejection and package overwrite protection'
