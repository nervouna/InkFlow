#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-build-workflow.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
mkdir -p "$repo/macOS/scripts" "$repo/macOS/Resources" "$repo/macOS/Licenses" "$repo/macOS/Sources" "$repo/macOS/DictionaryTool" \
  "$repo/build/deps/dist/lib/rime-plugins" "$repo/build/InkFlow.app/Contents"
cp macOS/scripts/{build,build-number,build-summary}.sh "$repo/macOS/scripts/"
mkdir -p "$repo/.git" "$fixture/bin"
cat > "$fixture/bin/git" <<'STUB'
#!/bin/bash
[[ "$*" == 'rev-parse --git-common-dir' ]] || exit 98
printf '%s/.git\n' "$BUILD_FIXTURE_REPO"
STUB
chmod +x "$fixture/bin/git"
export PATH="$fixture/bin:$PATH" BUILD_FIXTURE_REPO="$repo"
cp macOS/Info.plist "$repo/macOS/Info.plist"
printf resource > "$repo/macOS/Resources/resource"
printf license > "$repo/macOS/Licenses/license"
printf input > "$repo/macOS/Sources/input"
printf entry > "$repo/macOS/DictionaryTool/main.swift"
printf old > "$repo/build/InkFlow.app/Contents/sentinel"
touch "$repo/build/deps/dist/lib/librime.1.17.0.dylib" "$repo/build/deps/dist/lib/rime-plugins/librime-lua.dylib"
sparkle_framework="$repo/build/swiftpm/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$sparkle_framework/Versions/B/Resources" \
  "$sparkle_framework/Versions/B/XPCServices/Installer.xpc" \
  "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc" "$sparkle_framework/Versions/B/Updater.app"
printf helper > "$sparkle_framework/Versions/B/Autoupdate"
printf framework > "$sparkle_framework/Versions/B/Sparkle"
ln -s B "$sparkle_framework/Versions/Current"
ln -s Versions/Current/Sparkle "$sparkle_framework/Sparkle"
ln -s Versions/Current/Resources "$sparkle_framework/Resources"
for name in dependencies prepare-packaged-cache; do printf '#!/bin/bash\nexit 0\n' > "$repo/macOS/scripts/$name.sh"; done
cat > "$repo/macOS/scripts/prepare-chinese.sh" <<'STUB'
#!/bin/bash
[[ "${1:-}" == --sources-only ]] || exit 2
mkdir -p build/dictionary-sources
printf 'pinned dictionary source\n' > build/dictionary-sources/fresh.yaml
STUB
cat > "$repo/macOS/scripts/prepare-rime.sh" <<'STUB'
#!/bin/bash
bash macOS/scripts/prepare-chinese.sh --sources-only
STUB
printf 'generator script\n' > "$repo/macOS/scripts/build-dictionary-generator.sh"
cat > "$repo/macOS/scripts/quality-metadata.sh" <<'STUB'
#!/bin/bash
[[ "${SKIP_METADATA:-0}" != 1 ]] || exit 0
output="$1/Contents/Resources/QualityBuild.json"
if [[ "${2:-}" == --verify ]]; then [[ -s "$output" ]]; else
  mkdir -p "$(dirname "$output")"
  printf '{"sourceRevision":"fixture","sourceDirty":false,"sourceTreeSHA256":"source-sha","bundleSHA256":"bundle-sha"}\n' > "$output"
fi
STUB
cat > "$repo/macOS/scripts/build-icon.sh" <<'STUB'
#!/bin/bash
mkdir -p build; printf icon > build/AppIcon.icns
STUB
cat > "$repo/macOS/scripts/build-dictionary-worker.sh" <<'STUB'
#!/bin/bash
mkdir -p "$(dirname "$1")"; printf worker > "$1"; chmod +x "$1"
STUB
cat > "$repo/macOS/scripts/swift-package.sh" <<'STUB'
swiftpm_scratch="$PWD/build/swiftpm"
build_swift_product() {
  if [[ "$1" == quality-build-metadata ]]; then
    cat > "$2" <<'TOOL'
#!/bin/bash
[[ "$2" == --build-snapshot ]] || exit 0
printf 'fixture clean '
{
  shasum -a 256 macOS/Sources/input macOS/DictionaryTool/main.swift \
    macOS/scripts/quality-metadata.sh macOS/scripts/build-dictionary-generator.sh
  find build/dictionary-sources -type f -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done
} | shasum -a 256 | awk '{print $1}'
TOOL
    chmod +x "$2"; return
  fi
  [[ "${FAIL_APP_BUILD:-0}" != 1 ]] || return 19
  mkdir -p "$(dirname "$2")"; printf app > "$2"; chmod +x "$2"
  [[ "${MUTATE_BUILD_INPUT:-0}" != 1 ]] || printf changed > macOS/Sources/input
  [[ "${MUTATE_METADATA_WRAPPER:-0}" != 1 ]] || printf '\nchanged\n' >> macOS/scripts/quality-metadata.sh
}
STUB
chmod +x "$repo/macOS/scripts/"*.sh
(
  cd "$repo"
  if FAIL_APP_BUILD=1 bash macOS/scripts/build.sh >/dev/null 2>&1; then exit 1; fi
  [[ $(cat build/InkFlow.app/Contents/sentinel) == old ]]
  if MUTATE_BUILD_INPUT=1 bash macOS/scripts/build.sh >/dev/null 2>&1; then exit 1; fi
  [[ $(cat build/InkFlow.app/Contents/sentinel) == old ]]
  printf input > macOS/Sources/input
  cp macOS/scripts/quality-metadata.sh "$fixture/quality-wrapper"
  if MUTATE_METADATA_WRAPPER=1 bash macOS/scripts/build.sh >/dev/null 2>&1; then exit 1; fi
  [[ $(cat build/InkFlow.app/Contents/sentinel) == old ]]
  cp "$fixture/quality-wrapper" macOS/scripts/quality-metadata.sh
  if SKIP_METADATA=1 bash macOS/scripts/build.sh >/dev/null 2>&1; then exit 1; fi
  [[ $(cat build/InkFlow.app/Contents/sentinel) == old ]]
  rm -rf build/dictionary-sources
  source_before=$(shasum -a 256 macOS/Info.plist)
  bash macOS/scripts/build.sh > "$fixture/first-summary"
  first=$(plutil -extract CFBundleVersion raw build/InkFlow.app/Contents/Info.plist)
  grep -Fxq "| Build | $first |" "$fixture/first-summary"
  grep -Fxq '| Source commit | fixture |' "$fixture/first-summary"
  grep -Fxq '| Source dirty | false |' "$fixture/first-summary"
  bash macOS/scripts/build.sh > "$fixture/second-summary"
  second=$(plutil -extract CFBundleVersion raw build/InkFlow.app/Contents/Info.plist)
  [[ "$second" == "$((first + 1))" && $(shasum -a 256 macOS/Info.plist) == "$source_before" ]]
  grep -Fxq "| Build | $second |" "$fixture/second-summary"
  # Allocation is shared and serialized even when independent callers overlap.
  pids=()
  for ((i=0; i<8; i++)); do bash macOS/scripts/build-number.sh > "$fixture/number.$i" & pids+=("$!"); done
  for pid in "${pids[@]}"; do wait "$pid"; done
  [[ $(cat "$fixture"/number.* | sort -u | wc -l | tr -d ' ') == 8 ]]
  [[ $(cat build/build-number/last) == "$((second + 8))" ]]
  mkdir -p "$fixture/linked/macOS/scripts"
  cp macOS/scripts/build-number.sh "$fixture/linked/macOS/scripts/"
  cp macOS/Info.plist "$fixture/linked/macOS/Info.plist"
  linked=$(bash "$fixture/linked/macOS/scripts/build-number.sh")
  [[ "$linked" == "$((second + 9))" && $(cat build/build-number/last) == "$linked" ]]
  plutil -replace CFBundleVersion -string "$((linked + 20))" "$fixture/linked/macOS/Info.plist"
  [[ $(bash "$fixture/linked/macOS/scripts/build-number.sh") == "$((linked + 21))" ]]
  # A second app build must fail before touching the previous output.
  mkdir build/app-build.lock
  if bash macOS/scripts/build.sh >/dev/null 2>&1; then exit 1; fi
  [[ -d build/app-build.lock ]]
  rmdir build/app-build.lock
  # Corrupt state cannot reset the counter or damage the last completed bundle.
  printf invalid > build/build-number/last
  if bash macOS/scripts/build.sh > "$fixture/failed-summary" 2>&1; then exit 1; fi
  ! grep -Fq '| Artifact metadata |' "$fixture/failed-summary"
  [[ $(plutil -extract CFBundleVersion raw build/InkFlow.app/Contents/Info.plist) == "$second" ]]
  [[ -s build/dictionary-sources/fresh.yaml ]]
  [[ -x build/InkFlow.app/Contents/MacOS/InkFlow && ! -e build/InkFlow.app/Contents/sentinel ]]
  [[ -s build/InkFlow.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate ]]
  [[ -d build/InkFlow.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc ]]
  [[ -d build/InkFlow.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc ]]
  [[ -d build/InkFlow.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app ]]
  [[ -z $(find build -maxdepth 1 -name 'app-stage.*' -print) ]]
)
echo 'PASS build workflow: cold source bootstrap, staging assembly, drift rejection, old-bundle preservation and fresh replacement'
