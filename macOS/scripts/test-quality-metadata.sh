#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-quality-metadata.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repository"
app="$fixture/Fixture.app"
mkdir -p "$repo/macOS/Quality" "$repo/macOS/Sources" "$app/Contents/Resources/Rime" "$app/Contents/MacOS"
cp macOS/Info.plist "$app/Contents/Info.plist"
printf 'offline candidate behavior\n' > "$repo/macOS/Sources/Engine.swift"
printf 'offline context glue\n' > "$repo/macOS/Sources/InputRankingContext.swift"
core_source='controller calls offline context glue; selection keys 1-9; presents candidate strings with engine highlight'
printf '%s\n' "$core_source" > "$repo/macOS/Sources/InputControllerCore.swift"
printf 'font size 14, horizontal presentation\n' > "$repo/macOS/Sources/InputController.swift"
printf 'AI-only controller behavior\n' > "$repo/macOS/Sources/InputControllerAI.swift"
cp macOS/Sources/CandidatePresentation.swift "$repo/macOS/Sources/CandidatePresentation.swift"
cp macOS/Sources/AIInputPresentation.swift "$repo/macOS/Sources/AIInputPresentation.swift"
printf 'macOS/Sources/Engine.swift\nmacOS/Sources/InputRankingContext.swift\nmacOS/Sources/InputControllerCore.swift\nmacOS/Sources/CandidatePresentation.swift\n' > "$repo/macOS/Quality/ranking-sources.txt"
printf 'Rime/ranking.yaml\n' > "$repo/macOS/Quality/ranking-resources.txt"
printf 'actual bundled ranking content\n' > "$app/Contents/Resources/Rime/ranking.yaml"
printf 'executable bytes\n' > "$app/Contents/MacOS/Fixture"
git -C "$repo" init -q
git -C "$repo" config user.name 'InkFlow Tests'
git -C "$repo" config user.email 'tests@invalid'
git -C "$repo" add macOS
git -C "$repo" commit -qm fixture

mkdir -p build/swift-module-cache
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/QualityRecords.swift macOS/Tools/QualityBuildMetadata.swift \
  -o build/quality-build-metadata
build/quality-build-metadata "$repo" "$app"
cp "$app/Contents/Resources/QualityBuild.json" "$fixture/first.json"
build/quality-build-metadata "$repo" "$app" --verify
build/quality-build-metadata "$repo" "$app"
cmp "$fixture/first.json" "$app/Contents/Resources/QualityBuild.json"
source_hash=$(plutil -extract sourceTreeSHA256 raw "$fixture/first.json")
ranking_source=$(plutil -extract rankingSourceSHA256 raw "$fixture/first.json")
ranking_resources=$(plutil -extract rankingResourcesSHA256 raw "$fixture/first.json")
bundle_hash=$(plutil -extract bundleSHA256 raw "$fixture/first.json")
[[ ${#source_hash} -eq 64 && ${#ranking_source} -eq 64 && ${#ranking_resources} -eq 64 && ${#bundle_hash} -eq 64 ]]
[[ "$(plutil -extract sourceRevision raw "$fixture/first.json")" == "$(git -C "$repo" rev-parse HEAD)" ]]

printf 'modified AI-only controller behavior\n' > "$repo/macOS/Sources/InputControllerAI.swift"
build/quality-build-metadata "$repo" "$app"
[[ "$source_hash" != "$(plutil -extract sourceTreeSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
[[ "$ranking_source" == "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
[[ "$ranking_resources" == "$(plutil -extract rankingResourcesSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]

printf '\n// modified AI suggestion-only presentation\n' >> "$repo/macOS/Sources/AIInputPresentation.swift"
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_source" == "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]

printf 'font size 20, horizontal presentation\n' > "$repo/macOS/Sources/InputController.swift"
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_source" == "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]

printf 'font size 20, vertical presentation\n' > "$repo/macOS/Sources/InputController.swift"
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_source" == "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]

printf 'controller calls offline context glue; selection keys 9-1; presents candidate strings with engine highlight\n' > "$repo/macOS/Sources/InputControllerCore.swift"
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_source" != "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
printf '%s\n' "$core_source" > "$repo/macOS/Sources/InputControllerCore.swift"

printf 'controller calls offline context glue; selection keys 1-9; presents highlight as candidate index zero\n' > "$repo/macOS/Sources/InputControllerCore.swift"
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_source" != "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
printf '%s\n' "$core_source" > "$repo/macOS/Sources/InputControllerCore.swift"

cp "$repo/macOS/Sources/CandidatePresentation.swift" "$fixture/CandidatePresentation.swift"
sed 's/candidates\[index\]/candidates[0]/' "$fixture/CandidatePresentation.swift" > "$repo/macOS/Sources/CandidatePresentation.swift"
if cmp -s "$fixture/CandidatePresentation.swift" "$repo/macOS/Sources/CandidatePresentation.swift"; then
  echo 'FAIL: production candidate/highlight mapping mutation did not apply' >&2
  exit 1
fi
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_source" != "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
cp "$fixture/CandidatePresentation.swift" "$repo/macOS/Sources/CandidatePresentation.swift"

printf 'modified offline context glue\n' > "$repo/macOS/Sources/InputRankingContext.swift"
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_source" != "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
printf 'offline context glue\n' > "$repo/macOS/Sources/InputRankingContext.swift"

printf 'modified executable bytes\n' > "$app/Contents/MacOS/Fixture"
build/quality-build-metadata "$repo" "$app"
[[ "$bundle_hash" != "$(plutil -extract bundleSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
[[ "$ranking_source" == "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
[[ "$ranking_resources" == "$(plutil -extract rankingResourcesSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]

printf 'modified offline candidate behavior\n' > "$repo/macOS/Sources/Engine.swift"
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_source" != "$(plutil -extract rankingSourceSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]

printf 'modified actual bundled ranking content\n' > "$app/Contents/Resources/Rime/ranking.yaml"
build/quality-build-metadata "$repo" "$app"
[[ "$ranking_resources" != "$(plutil -extract rankingResourcesSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
[[ "$bundle_hash" != "$(plutil -extract bundleSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]

cp "$repo/macOS/Quality/ranking-sources.txt" "$fixture/sources.manifest"
for invalid in missing duplicate nonexistent; do
  case "$invalid" in
    missing) rm "$repo/macOS/Quality/ranking-sources.txt" ;;
    duplicate) printf 'macOS/Sources/Engine.swift\nmacOS/Sources/Engine.swift\n' > "$repo/macOS/Quality/ranking-sources.txt" ;;
    nonexistent) printf 'macOS/Sources/DoesNotExist.swift\n' > "$repo/macOS/Quality/ranking-sources.txt" ;;
  esac
  if build/quality-build-metadata "$repo" "$app" > "$fixture/$invalid.log" 2>&1; then
    echo "FAIL: $invalid ranking manifest was accepted" >&2
    exit 1
  fi
  cp "$fixture/sources.manifest" "$repo/macOS/Quality/ranking-sources.txt"
done
cp "$repo/macOS/Quality/ranking-resources.txt" "$fixture/resources.manifest"
for invalid in missing duplicate nonexistent; do
  case "$invalid" in
    missing) rm "$repo/macOS/Quality/ranking-resources.txt" ;;
    duplicate) printf 'Rime/ranking.yaml\nRime/ranking.yaml\n' > "$repo/macOS/Quality/ranking-resources.txt" ;;
    nonexistent) printf 'Rime/missing.yaml\n' > "$repo/macOS/Quality/ranking-resources.txt" ;;
  esac
  if build/quality-build-metadata "$repo" "$app" > "$fixture/resource-$invalid.log" 2>&1; then
    echo "FAIL: $invalid ranking resource manifest was accepted" >&2
    exit 1
  fi
  cp "$fixture/resources.manifest" "$repo/macOS/Quality/ranking-resources.txt"
done
echo 'PASS quality build metadata: deterministic layered hashes, AI boundary, and fail-closed manifests'
