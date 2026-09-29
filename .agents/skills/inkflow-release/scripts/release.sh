#!/bin/bash
# After release-verification.sh and package.sh prepare: notarize, package, verify,
# generate the appcast, tag, upload and publish. Each step is skipped when its output
# already exists, so rerunning after a failure resumes where it stopped.
#
#   release.sh           full release (tag + push + publish)
#   release.sh --draft   everything except tag/push/publish; leaves a GitHub draft
set -euo pipefail
draft=false
case "${1:-}" in
  '') ;;
  --draft) draft=true ;;
  *) echo 'Usage: release.sh [--draft]' >&2; exit 2 ;;
esac
cd "$(dirname "$0")/../../../.."
scripts=.agents/skills/inkflow-release/scripts
fail() { echo "Release stopped: $*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
notarize() {
  local artifact=$1 log=$2
  bash "$scripts/notary.sh" submit "$artifact" --wait --timeout 30m --no-s3-acceleration --output-format plist > "$log" || fail "notarytool failed; see $log"
  [[ $(plutil -extract status raw "$log") == Accepted ]] || {
    bash "$scripts/notary.sh" log "$(plutil -extract id raw "$log")" >> "$log.details" 2>&1 || true
    fail "Notarization not accepted; see $log and $log.details"
  }
}

[[ -z $(git status --porcelain --untracked-files=normal) ]] || fail 'Worktree must be clean.'
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(bash macOS/scripts/release-build.sh build/release-verification/installer.plist)
tag="v$version"
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
release_dir="$PWD/build/releases/InkFlow-$version-$build"
app="$release_dir/payload/InkFlow.app"
dmg="$release_dir/InkFlow-$version-$build-arm64.dmg"
update_zip="$release_dir/InkFlow-$version-$build-arm64.zip"
appcast="$release_dir/appcast.xml"
checksum="$release_dir/SHA256SUMS"
notes="$PWD/build/public-release-notes.md"
[[ -d "$app" && -f "$release_dir/inputmethod-submission.zip" ]] || fail 'Run package.sh prepare first.'
[[ -f "$notes" ]] || fail 'Write build/public-release-notes.md first.'
previous_tag=$(git tag --merged HEAD --sort=-version:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx "$tag" | head -1)
[[ -n "$previous_tag" ]] || fail 'No previous release tag is an ancestor of HEAD.'
echo "Releasing $tag build $build (previous $previous_tag) to $repo$($draft && echo ' as a draft')"

# 1. Notarize and staple the input method.
if ! xcrun stapler validate "$app" >/dev/null 2>&1; then
  notarize "$release_dir/inputmethod-submission.zip" "$release_dir/payload-notary.plist"
  xcrun stapler staple "$app"
fi
xcrun stapler validate "$app"

# 2. Assemble the Installer DMG and Sparkle ZIP, then notarize and staple the DMG.
[[ -f "$dmg" ]] || bash "$scripts/package.sh" finish
if ! xcrun stapler validate "$dmg" >/dev/null 2>&1; then
  notarize "$dmg" "$release_dir/dmg-notary.plist"
  xcrun stapler staple "$dmg"
fi
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
hdiutil verify "$dmg"

# 3. Check what users will actually run: the mounted installer and its embedded app.
mount_point=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-dmg.XXXXXX")
extract=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-inner.XXXXXX")
trap 'hdiutil detach "$mount_point" >/dev/null 2>&1 || true; rm -rf "$extract"' EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$dmg" >/dev/null
installer="$mount_point/InkFlow Installer.app"
[[ -d "$installer" && -f "$mount_point/安装说明.txt" ]] || fail 'Unexpected DMG contents.'
ditto -x -k "$installer/Contents/Resources/Payload/InkFlow.zip" "$extract"
for bundle in "$installer" "$extract/InkFlow.app"; do
  codesign --verify --deep --strict --verbose=2 "$bundle"
  spctl --assess --type execute --verbose=2 "$bundle"
  codesign -dvvv "$bundle" 2>&1 | grep -Fxq 'TeamIdentifier=T7976FL2LP' || fail "Wrong team: $bundle"
  [[ $(plutil -extract CFBundleShortVersionString raw "$bundle/Contents/Info.plist") == "$version" &&
     $(plutil -extract CFBundleVersion raw "$bundle/Contents/Info.plist") == "$build" ]] || fail "Wrong version/build: $bundle"
done
xcrun stapler validate "$extract/InkFlow.app"
"$installer/Contents/MacOS/InkFlowInstaller" --check-payload
hdiutil detach "$mount_point" >/dev/null
trap 'rm -rf "$extract"' EXIT

# 4. Appcast and checksum.
[[ -f "$appcast" ]] || bash "$scripts/release-appcast.sh" generate "$previous_tag"
printf '%s  %s\n' "$(sha256 "$dmg")" "$(basename "$dmg")" > "$checksum"
assets=("$dmg" "$checksum" "$update_zip" "$appcast")

# 5. Tag and push (full release only). Drafts are created without a tag.
if ! $draft; then
  remote_main=$(git ls-remote origin refs/heads/main | awk '{print $1}')
  commit=$(git rev-parse HEAD)
  [[ $remote_main == "$commit" ]] || git merge-base --is-ancestor "$remote_main" "$commit" || fail 'origin/main has diverged.'
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "InkFlow $version (build $build)"
  [[ $(git rev-parse "$tag^{commit}") == "$commit" ]] || fail "Local $tag points elsewhere."
  git push --atomic origin "$commit:refs/heads/main" "refs/tags/$tag"
fi

# 6. Draft release with assets; reuse an existing draft only if its assets match.
if is_draft=$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>/dev/null); then
  [[ $is_draft == true ]] || fail "$tag is already published."
  gh release edit "$tag" --repo "$repo" --notes-file "$notes"
else
  gh release create "$tag" --repo "$repo" --draft --title "InkFlow $version" --notes-file "$notes"
fi
gh release upload "$tag" --repo "$repo" --clobber "${assets[@]}"
download=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-download.XXXXXX")
gh release download "$tag" --repo "$repo" --dir "$download"
for asset in "${assets[@]}"; do cmp "$asset" "$download/$(basename "$asset")" || fail "Uploaded $(basename "$asset") differs."; done
[[ $(ls "$download" | wc -l | tr -d ' ') == ${#assets[@]} ]] || fail 'Draft has unexpected extra assets.'
rm -rf "$download"

if $draft; then
  echo "PASS draft $tag build $build: $(gh release view "$tag" --repo "$repo" --json url --jq .url)"
  exit 0
fi

# 7. Publish.
gh release edit "$tag" --repo "$repo" --draft=false --latest
echo "PASS release $tag build $build: $(gh release view "$tag" --repo "$repo" --json url --jq .url)"
