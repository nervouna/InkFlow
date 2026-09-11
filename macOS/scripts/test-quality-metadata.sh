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
identity_repo="$fixture/identity-repo"
git clone --quiet --shared --no-hardlinks "$PWD" "$identity_repo"
tool="$PWD/build/quality-build-metadata"
before=$($tool "$identity_repo" --build-snapshot)
[[ "$before" == "$(git -C "$identity_repo" rev-parse HEAD) clean "* ]]
printf 'documentation only\n' >> "$identity_repo/README.md"
[[ "$($tool "$identity_repo" --build-snapshot)" == "$before" ]]
mkdir "$fixture/originals"
cp "$identity_repo/macOS/Sources/Engine.swift" "$fixture/originals/Engine.swift"
cp "$identity_repo/macOS/scripts/quality-metadata.sh" "$fixture/originals/quality-metadata.sh"
cp "$identity_repo/macOS/scripts/build-dictionary-generator.sh" "$fixture/originals/build-dictionary-generator.sh"
cp "$identity_repo/macOS/DictionaryTool/main.swift" "$fixture/originals/main.swift"
printf 'build input\n' >> "$identity_repo/macOS/Sources/Engine.swift"
[[ "$($tool "$identity_repo" --build-snapshot)" != "$before" ]]
for changed in macOS/scripts/quality-metadata.sh macOS/scripts/build-dictionary-generator.sh macOS/DictionaryTool/main.swift; do
  cp "$fixture/originals/Engine.swift" "$identity_repo/macOS/Sources/Engine.swift"
  cp "$fixture/originals/quality-metadata.sh" "$identity_repo/macOS/scripts/quality-metadata.sh"
  cp "$fixture/originals/build-dictionary-generator.sh" "$identity_repo/macOS/scripts/build-dictionary-generator.sh"
  cp "$fixture/originals/main.swift" "$identity_repo/macOS/DictionaryTool/main.swift"
  printf '\nchanged build closure\n' >> "$identity_repo/$changed"
  [[ "$($tool "$identity_repo" --build-snapshot)" != "$before" ]]
done
echo 'PASS quality build metadata: deterministic build-input/resources hashes, clean/dirty revision, docs excluded'
