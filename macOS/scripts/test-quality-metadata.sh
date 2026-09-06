#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-quality-metadata.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
app="$fixture/Fixture.app"
mkdir -p "$app/Contents/Resources"
cp macOS/Info.plist "$app/Contents/Info.plist"
printf 'actual bundled content\n' > "$app/Contents/Resources/payload.txt"
bash macOS/scripts/quality-metadata.sh "$app"
cp "$app/Contents/Resources/QualityBuild.json" "$fixture/first.json"
build/quality-build-metadata "$PWD" "$app" --verify
build/quality-build-metadata "$PWD" "$app"
cmp "$fixture/first.json" "$app/Contents/Resources/QualityBuild.json"
source_hash=$(plutil -extract sourceTreeSHA256 raw "$fixture/first.json")
[[ ${#source_hash} -eq 64 ]]
[[ "$(plutil -extract sourceRevision raw "$fixture/first.json")" == "$(git rev-parse HEAD)" ]]
printf 'modified actual bundled content\n' > "$app/Contents/Resources/payload.txt"
if build/quality-build-metadata "$PWD" "$app" --verify > "$fixture/stale.log" 2>&1; then
  echo 'FAIL: stale resource metadata was accepted' >&2
  exit 1
fi
build/quality-build-metadata "$PWD" "$app"
[[ "$(plutil -extract bundledResourcesSHA256 raw "$fixture/first.json")" != "$(plutil -extract bundledResourcesSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
[[ "$source_hash" == "$(plutil -extract sourceTreeSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
echo 'PASS quality build metadata: deterministic hashes, source identity, changed resource detection'
