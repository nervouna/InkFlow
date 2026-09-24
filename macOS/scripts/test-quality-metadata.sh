#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-quality-metadata.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repository"
app="$fixture/Fixture.app"
mkdir -p "$repo/macOS/Quality" "$repo/macOS/Sources" "$app/Contents/Resources/Rime" \
  "$app/Contents/MacOS" "$app/Contents/Frameworks/rime-plugins"
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
cp /usr/bin/true "$app/Contents/MacOS/InkFlow"
printf 'int inkflow_fixture(void) { return 1; }\n' > "$fixture/nested.c"
xcrun clang -arch arm64 -dynamiclib -install_name @rpath/librime.1.dylib \
  "$fixture/nested.c" -o "$app/Contents/Frameworks/librime.1.dylib"
xcrun clang -arch arm64 -dynamiclib -install_name @rpath/librime-lua.dylib \
  "$fixture/nested.c" -o "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
chmod +x "$app/Contents/MacOS/InkFlow"
git -C "$repo" init -q
git -C "$repo" config user.name 'InkFlow Tests'
git -C "$repo" config user.email 'tests@invalid'
git -C "$repo" add macOS
git -C "$repo" commit -qm fixture

source macOS/scripts/swift-package.sh
build_swift_product quality-build-metadata build/quality-build-metadata release
build/quality-build-metadata "$repo" "$app"
cp "$app/Contents/Resources/QualityBuild.json" "$fixture/first.json"
build/quality-build-metadata "$repo" "$app" --verify
# Re-signing may or may not change canonical payload bytes on this toolchain.
for binary in "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib" \
  "$app/Contents/Frameworks/librime.1.dylib" "$app/Contents/MacOS/InkFlow"; do
  codesign --force --options runtime --timestamp=none --sign - "$binary"
done
codesign --force --options runtime --timestamp=none --sign - "$app"
codesign --verify --deep --strict "$app"
build/quality-build-metadata "$repo" "$app"
resigned_hash=$(plutil -extract bundleSHA256 raw "$app/Contents/Resources/QualityBuild.json")
cp "$fixture/first.json" "$app/Contents/Resources/QualityBuild.json"
if [[ "$resigned_hash" == "$(plutil -extract bundleSHA256 raw "$fixture/first.json")" ]]; then
  build/quality-build-metadata "$repo" "$app" --verify
elif build/quality-build-metadata "$repo" "$app" --verify > "$fixture/re-signed-ordinary.log" 2>&1; then
  echo 'FAIL: ordinary verification accepted changed canonical bundle bytes' >&2
  exit 1
fi
build/quality-build-metadata "$repo" "$app" --verify-signed

# Exercise the signing-sensitive digest boundary deterministically, regardless
# of whether real re-signing changed the canonical layout on this platform.
plutil -replace bundleSHA256 -string mismatched "$app/Contents/Resources/QualityBuild.json"
if build/quality-build-metadata "$repo" "$app" --verify > "$fixture/mismatched-bundle.log" 2>&1; then
  echo 'FAIL: ordinary verification accepted a mismatched bundle digest' >&2
  exit 1
fi
build/quality-build-metadata "$repo" "$app" --verify-signed
cp "$fixture/first.json" "$app/Contents/Resources/QualityBuild.json"

# Signed verification ignores only the signing-sensitive bundle digest. Every
# other recorded provenance field remains mandatory and exact.
cp "$app/Contents/Resources/QualityBuild.json" "$fixture/signed.json"
reject_signed_metadata() {
  local label=$1
  if build/quality-build-metadata "$repo" "$app" --verify-signed > "$fixture/signed-$label.log" 2>&1; then
    echo "FAIL: signed verification accepted $label metadata" >&2
    exit 1
  fi
  cp "$fixture/signed.json" "$app/Contents/Resources/QualityBuild.json"
}
for field in sourceRevision sourceTreeSHA256 sourceDirty bundledResourcesSHA256 \
  rankingSourceSHA256 rankingResourcesSHA256 appVersion appBuild; do
  case "$field" in
    sourceDirty) plutil -replace "$field" -bool true "$app/Contents/Resources/QualityBuild.json" ;;
    *) plutil -replace "$field" -string mismatched "$app/Contents/Resources/QualityBuild.json" ;;
  esac
  reject_signed_metadata "mismatched-$field"
done
for kind in integer string null missing; do
  case "$kind" in
    integer) plutil -replace sourceDirty -integer 0 "$app/Contents/Resources/QualityBuild.json" ;;
    string) plutil -replace sourceDirty -string false "$app/Contents/Resources/QualityBuild.json" ;;
    null) plutil -replace sourceDirty -json null "$app/Contents/Resources/QualityBuild.json" ;;
    missing) plutil -remove sourceDirty "$app/Contents/Resources/QualityBuild.json" ;;
  esac
  reject_signed_metadata "sourceDirty-$kind"
done
for kind in integer null missing; do
  case "$kind" in
    integer) plutil -replace bundleSHA256 -integer 0 "$app/Contents/Resources/QualityBuild.json" ;;
    null) plutil -replace bundleSHA256 -json null "$app/Contents/Resources/QualityBuild.json" ;;
    missing) plutil -remove bundleSHA256 "$app/Contents/Resources/QualityBuild.json" ;;
  esac
  reject_signed_metadata "bundleSHA256-$kind"
done
plutil -insert unexpected -string value "$app/Contents/Resources/QualityBuild.json"
reject_signed_metadata extra-key
printf '{' > "$app/Contents/Resources/QualityBuild.json"
reject_signed_metadata malformed-json
printf 'simulated stapled notarization ticket\n' > "$app/Contents/CodeResources"
build/quality-build-metadata "$repo" "$app" --verify-signed
build/quality-build-metadata "$repo" "$app"
for field in sourceRevision sourceTreeSHA256 sourceDirty bundledResourcesSHA256 \
  rankingSourceSHA256 rankingResourcesSHA256 appVersion appBuild; do
  [[ "$(plutil -extract "$field" raw "$fixture/first.json")" == \
     "$(plutil -extract "$field" raw "$app/Contents/Resources/QualityBuild.json")" ]]
done
cp "$app/Contents/Resources/QualityBuild.json" "$fixture/current-layout.json"
build/quality-build-metadata "$repo" "$app"
cmp "$fixture/current-layout.json" "$app/Contents/Resources/QualityBuild.json"
build/quality-build-metadata "$repo" "$app" --verify
# Change only executable bytes, then restore them, so rejection cannot be caused
# by an unrelated source/provenance change elsewhere in this fixture.
cp "$app/Contents/MacOS/InkFlow" "$fixture/unchanged-executable"
printf 'modified executable bytes\n' > "$app/Contents/MacOS/InkFlow"
if build/quality-build-metadata "$repo" "$app" --verify > "$fixture/changed-payload.log" 2>&1; then
  echo 'FAIL: ordinary verification accepted changed executable bytes' >&2
  exit 1
fi
cp "$fixture/unchanged-executable" "$app/Contents/MacOS/InkFlow"
build/quality-build-metadata "$repo" "$app" --verify
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

printf 'modified executable bytes\n' > "$app/Contents/MacOS/InkFlow"
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
printf '\317\372\355\376broken Mach-O\n' > "$app/Contents/Resources/broken-macho.bin"
if build/quality-build-metadata "$repo" "$app" > "$fixture/broken-macho.log" 2>&1; then
  echo 'FAIL: invalid Mach-O signature canonicalization was accepted' >&2
  exit 1
fi
rm "$app/Contents/Resources/broken-macho.bin"

# Sparkle uses a versioned framework with internal symlinks. Hash each link's
# relative target, and reject a link whose lexical or resolved destination exits
# the framework boundary.
sparkle_fixture="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$sparkle_fixture/Versions/B"
printf 'fixture Sparkle framework payload\n' > "$sparkle_fixture/Versions/B/Sparkle"
ln -s B "$sparkle_fixture/Versions/Current"
ln -s Versions/Current/Sparkle "$sparkle_fixture/Sparkle"
build/quality-build-metadata "$repo" "$app"
cp "$app/Contents/Resources/QualityBuild.json" "$fixture/sparkle-symlinks.json"
build/quality-build-metadata "$repo" "$app" --verify
sparkle_hash=$(plutil -extract bundleSHA256 raw "$fixture/sparkle-symlinks.json")
rm "$sparkle_fixture/Sparkle"
ln -s Versions/B/Sparkle "$sparkle_fixture/Sparkle"
build/quality-build-metadata "$repo" "$app"
[[ "$sparkle_hash" != "$(plutil -extract bundleSHA256 raw "$app/Contents/Resources/QualityBuild.json")" ]]
rm "$sparkle_fixture/Sparkle"
ln -s ../../../../../../outside "$sparkle_fixture/Sparkle"
if build/quality-build-metadata "$repo" "$app" > "$fixture/escaping-sparkle-link.log" 2>&1; then
  echo 'FAIL: escaping Sparkle.framework symlink was accepted' >&2
  exit 1
fi
grep -Fq 'Unsafe or broken Sparkle.framework symlink' "$fixture/escaping-sparkle-link.log"
rm "$sparkle_fixture/Sparkle"
ln -s Versions/Current/Sparkle "$sparkle_fixture/Sparkle"
cp "$fixture/sparkle-symlinks.json" "$app/Contents/Resources/QualityBuild.json"
build/quality-build-metadata "$repo" "$app" --verify
echo 'PASS quality build metadata: deterministic layered hashes, AI boundary, and fail-closed manifests'

identity_repo="$fixture/identity-repo"
git clone --quiet --shared --no-hardlinks "$PWD" "$identity_repo"
cp Package.resolved "$identity_repo/Package.resolved"
git -C "$identity_repo" config user.name 'InkFlow Tests'
git -C "$identity_repo" config user.email 'tests@invalid'
git -C "$identity_repo" add Package.resolved
if ! git -C "$identity_repo" diff --cached --quiet; then
  git -C "$identity_repo" commit -qm 'fixture resolved dependency lock'
fi
tool="$PWD/build/quality-build-metadata"
before=$($tool "$identity_repo" --build-snapshot)
[[ "$before" == "$(git -C "$identity_repo" rev-parse HEAD) clean "* ]]
printf 'documentation only\n' >> "$identity_repo/README.md"
[[ "$($tool "$identity_repo" --build-snapshot)" == "$before" ]]
cp "$identity_repo/Package.resolved" "$fixture/Package.resolved"
python3 - "$identity_repo/Package.resolved" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
lock = json.loads(path.read_text())
lock["pins"][0]["state"]["revision"] = "0" * 40
path.write_text(json.dumps(lock, indent=2) + "\n")
PY
[[ "$($tool "$identity_repo" --build-snapshot)" != "$before" ]]
cp "$fixture/Package.resolved" "$identity_repo/Package.resolved"
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
# Newly introduced helpers are untracked before the delivery commit, but still
# must participate in the build closure and dirty-state calculation.
for helper in build-number build-summary; do
  snapshot=$($tool "$identity_repo" --build-snapshot)
  printf 'fixture build helper\n' > "$identity_repo/macOS/scripts/$helper.sh"
  [[ "$($tool "$identity_repo" --build-snapshot)" != "$snapshot" ]]
done
echo 'PASS quality build metadata: deterministic build-input/resources hashes, clean/dirty revision, docs excluded'
