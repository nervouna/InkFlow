#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-build-workflow.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"
mkdir -p "$repo/macOS/scripts" "$repo/macOS/Resources" "$repo/macOS/Licenses" "$repo/macOS/Sources" "$repo/macOS/DictionaryTool" \
  "$repo/build/deps/dist/lib/rime-plugins" "$repo/build/InkFlow.app/Contents"
cp macOS/scripts/build.sh "$repo/macOS/scripts/"
cp macOS/Info.plist "$repo/macOS/Info.plist"
printf resource > "$repo/macOS/Resources/resource"
printf license > "$repo/macOS/Licenses/license"
printf input > "$repo/macOS/Sources/input"
printf entry > "$repo/macOS/DictionaryTool/main.swift"
printf old > "$repo/build/InkFlow.app/Contents/sentinel"
touch "$repo/build/deps/dist/lib/librime.1.17.0.dylib" "$repo/build/deps/dist/lib/rime-plugins/librime-lua.dylib"
for name in dependencies prepare-rime prepare-packaged-cache; do printf '#!/bin/bash\nexit 0\n' > "$repo/macOS/scripts/$name.sh"; done
printf 'generator script\n' > "$repo/macOS/scripts/build-dictionary-generator.sh"
cat > "$repo/macOS/scripts/quality-metadata.sh" <<'STUB'
#!/bin/bash
[[ "${SKIP_METADATA:-0}" != 1 ]] || exit 0
output="$1/Contents/Resources/QualityBuild.json"
if [[ "${2:-}" == --verify ]]; then [[ -s "$output" ]]; else mkdir -p "$(dirname "$output")"; printf metadata > "$output"; fi
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
build_swift_product() {
  if [[ "$1" == quality-build-metadata ]]; then
    cat > "$2" <<'TOOL'
#!/bin/bash
[[ "$2" == --build-snapshot ]] || exit 0
printf 'fixture clean '; shasum -a 256 macOS/Sources/input macOS/DictionaryTool/main.swift \
  macOS/scripts/quality-metadata.sh macOS/scripts/build-dictionary-generator.sh | shasum -a 256 | awk '{print $1}'
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
  bash macOS/scripts/build.sh >/dev/null
  [[ -x build/InkFlow.app/Contents/MacOS/InkFlow && ! -e build/InkFlow.app/Contents/sentinel ]]
  [[ -z $(find build -maxdepth 1 -name 'app-stage.*' -print) ]]
)
echo 'PASS build workflow: staging assembly, drift rejection, old-bundle preservation and fresh replacement'
