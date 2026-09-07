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

# Exercise notary argument routing with dummy keys and a stub, never Apple services.
mkdir "$fixture/bin"
cat > "$fixture/bin/xcrun" <<'STUB'
#!/bin/bash
if read -r input; then echo 'Unexpected interactive stdin' >&2; exit 98; fi
printf '%s\n' "$@"
exit "${NOTARY_TEST_EXIT:-0}"
STUB
chmod +x "$fixture/bin/xcrun"
touch "$fixture/key with spaces.p8"
chmod 600 "$fixture/key with spaces.p8"
(
  export PATH="$fixture/bin:$PATH" INKFLOW_NOTARY_AUTH=api-key
  export INKFLOW_NOTARY_KEY_FILE="$fixture/key with spaces.p8" INKFLOW_NOTARY_KEY_ID=FIXTUREKEY
  export INKFLOW_NOTARY_KEY_TYPE=team INKFLOW_NOTARY_ISSUER=fixture-issuer
  unset INKFLOW_SIGN_IDENTITY
  notary="$root/.agents/skills/inkflow-release/scripts/notary.sh"
  bash "$notary" history --output-format plist > "$fixture/args"
  printf '%s\n' notarytool history --output-format plist --key "$INKFLOW_NOTARY_KEY_FILE" --key-id FIXTUREKEY --issuer fixture-issuer > "$fixture/expected"
  cmp "$fixture/args" "$fixture/expected"
  reject_notary() {
    if bash "$notary" "$@" > "$fixture/args" 2> "$fixture/notary-error"; then exit 1; fi
    [[ ! -s "$fixture/args" ]]
  }
  reject_notary history --keychain-profile alternate
  unset INKFLOW_NOTARY_ISSUER
  reject_notary history
  export INKFLOW_NOTARY_KEY_TYPE=individual
  bash "$notary" info fixture-id > "$fixture/args"
  printf '%s\n' notarytool info fixture-id --key "$INKFLOW_NOTARY_KEY_FILE" --key-id FIXTUREKEY > "$fixture/expected"
  cmp "$fixture/args" "$fixture/expected"
  export INKFLOW_NOTARY_ISSUER=forbidden
  reject_notary history
  unset INKFLOW_NOTARY_ISSUER
  chmod 644 "$INKFLOW_NOTARY_KEY_FILE"
  reject_notary history
  chmod 600 "$INKFLOW_NOTARY_KEY_FILE"
  NOTARY_TEST_EXIT=7 bash "$notary" history > "$fixture/args" && exit 1
  [[ $? == 7 ]]
  export INKFLOW_NOTARY_AUTH=keychain INKFLOW_NOTARY_PROFILE=fixture-profile
  bash "$notary" history > "$fixture/args"
  printf '%s\n' notarytool history --keychain-profile fixture-profile > "$fixture/expected"
  cmp "$fixture/args" "$fixture/expected"
)
echo 'PASS: team/individual API key routing, closed stdin, permissions, failure propagation and legacy profile mode'

# Synthetic GUI receipts in a disposable clone test reuse, not real GUI behavior.
git clone --quiet --shared --no-hardlinks "$root" "$fixture/gui-repo"
gui="$root/.agents/skills/inkflow-release/scripts/gui-verification.sh"
(
  cd "$fixture/gui-repo"
  evidence=build/gui-verification
  expect_rejected() {
    if bash "$gui" check > "$fixture/gui-error.log" 2>&1; then
      echo 'Unexpected GUI evidence acceptance.' >&2; exit 1
    fi
  }
  expect_rejected
  mkdir -p "$evidence"
  git rev-parse 'HEAD^{tree}' > "$evidence/passed.tree"
  for script in build test-controller-initialization test-settings-ui; do
    echo 'Synthetic successful fixture' > "$evidence/$script.log"
  done
  bash "$gui" check
  cp macOS/Info.plist "$fixture/gui-original.plist"
  plutil -replace CFBundleShortVersionString -string 2.3.4 macOS/Info.plist
  plutil -replace CFBundleVersion -string 999 macOS/Info.plist
  bash "$gui" check
  git add macOS/Info.plist
  bash "$gui" check
  plutil -replace LSMinimumSystemVersion -string 99.0 macOS/Info.plist
  expect_rejected
  cp "$fixture/gui-original.plist" macOS/Info.plist
  git add macOS/Info.plist
  # A changed commit identity with identical files is still reusable.
  other=$(printf 'Synthetic commit identity\n' | git -c user.name=Fixture -c user.email=fixture@example.invalid commit-tree 'HEAD^{tree}' -p HEAD)
  git rev-parse "$other^{tree}" > "$evidence/passed.tree"
  bash "$gui" check
  printf '\n// Changed test input\n' >> macOS/Sources/Engine.swift
  expect_rejected
  git show HEAD:macOS/Sources/Engine.swift > macOS/Sources/Engine.swift
  echo input > unexpected-input
  expect_rejected
  rm unexpected-input
  plutil -replace CFBundleVersion -string invalid macOS/Info.plist
  expect_rejected
  cp "$fixture/gui-original.plist" macOS/Info.plist
  mkdir "$evidence/running"
  expect_rejected
  rmdir "$evidence/running"
  rm "$evidence/test-settings-ui.log"
  expect_rejected
  # Stub commands exercise receipt lifecycle without a desktop or app build.
  for script in build test-controller-initialization test-settings-ui; do
    printf '#!/bin/bash\nexit "${GUI_FIXTURE_EXIT:-0}"\n' > "macOS/scripts/$script.sh"
    git add "macOS/scripts/$script.sh"
  done
  echo 'uncommitted test input' > gui-fixture-input
  index_before=$(git write-tree)
  GUI_FIXTURE_EXIT=0 bash "$gui" record
  [[ "$(git write-tree)" == "$index_before" ]]
  bash "$gui" check
  if GUI_FIXTURE_EXIT=1 bash "$gui" record > "$fixture/gui-error.log" 2>&1; then exit 1; fi
  [[ ! -e "$evidence/passed.tree" && ! -e "$evidence/running" ]]
  expect_rejected
)
echo 'PASS: GUI evidence permits only version/build changes and requires complete local passing records'
