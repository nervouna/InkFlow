#!/bin/bash
# After release-verification.sh and package.sh prepare: notarize, package, verify,
# generate the appcast and the dictionary source bundle, tag, upload and publish. Existing outputs are reused after
# receipt and artifact validation, so rerunning after a failure resumes the release.
#
#   release.sh              full release (tag + push + publish as latest)
#   release.sh --prerelease full release published as a GitHub pre-release; the Sparkle feed
#                           (releases/latest) keeps serving the previous stable release
#   release.sh --draft      everything except tag/push/publish; leaves a GitHub draft
set -euo pipefail
draft=false prerelease=false
case "${1:-}" in
  '') ;;
  --draft) draft=true ;;
  --prerelease) prerelease=true ;;
  *) echo 'Usage: release.sh [--draft|--prerelease]' >&2; exit 2 ;;
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
build=$(bash macOS/scripts/release-build.sh build/release-verification/receipt.plist)
tag="v$version"
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
release_dir="$PWD/build/releases/InkFlow-$version-$build"
app="$release_dir/payload/InkFlow.app"
pkg="$release_dir/InkFlow-$version-$build-arm64.pkg"
update_zip="$release_dir/InkFlow-$version-$build-arm64.zip"
appcast="$release_dir/appcast.xml"
checksum="$release_dir/SHA256SUMS"
notes="$PWD/build/public-release-notes.md"
[[ -d "$app" && -f "$release_dir/inputmethod-submission.zip" ]] || fail 'Run package.sh prepare first.'
bash macOS/scripts/release-receipt.sh verify "$release_dir/verified/receipt.plist"
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

# 2. Assemble the signed installer package and the Sparkle ZIP from the stapled app.
[[ -f "$pkg" ]] || bash "$scripts/package.sh" finish

# 3. Check what users will run before spending a notarization on it: the package signer,
# the lifecycle tool its scripts run and the app it installs.
extract=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-pkg.XXXXXX")
trap 'rm -rf "$extract"' EXIT
pkgutil --check-signature "$pkg" > "$extract/signature"
grep -Fq 'Developer ID Installer:' "$extract/signature" && grep -Fq '(T7976FL2LP)' "$extract/signature" || fail 'Unexpected package signature.'
pkgutil --expand-full "$pkg" "$extract/pkg"
component="$extract/pkg/InkFlow-component.pkg"
bundle="$component/Payload/InkFlow.app"
codesign --verify --deep --strict --verbose=2 "$bundle"
spctl --assess --type execute --verbose=2 "$bundle"
grep -Fxq 'TeamIdentifier=T7976FL2LP' <<< "$(codesign -dvvv "$bundle" 2>&1)" || fail "Wrong team: $bundle"
[[ $(plutil -extract CFBundleShortVersionString raw "$bundle/Contents/Info.plist") == "$version" &&
   $(plutil -extract CFBundleVersion raw "$bundle/Contents/Info.plist") == "$build" ]] || fail "Wrong version/build: $bundle"
xcrun stapler validate "$bundle"
tool="$component/Scripts/register-input-source"
codesign --verify --strict --verbose=2 "$tool"
metadata=$(codesign -dvvv "$tool" 2>&1)
grep -Fxq 'TeamIdentifier=T7976FL2LP' <<< "$metadata" && grep -Fq 'Authority=Developer ID Application:' <<< "$metadata" &&
  grep -Fq 'flags=0x10000(runtime)' <<< "$metadata" && grep -Fq 'Timestamp=' <<< "$metadata" || fail 'Unexpected register-input-source signature.'
[[ $(<"$component/Scripts/build-number") == "$build" ]] || fail 'Package scripts expect another build.'

# 4. Notarize and staple the package, then confirm Gatekeeper accepts it.
if ! xcrun stapler validate "$pkg" >/dev/null 2>&1; then
  notarize "$pkg" "$release_dir/pkg-notary.plist"
  xcrun stapler staple "$pkg"
fi
xcrun stapler validate "$pkg"
spctl --assess --type install --verbose=2 "$pkg"

# 5. Appcast, dictionary corresponding-source bundle and checksums.
bash "$scripts/release-appcast.sh" generate "$previous_tag"
# Always rebuilt: a rerun after another commit must package the HEAD being tagged.
source_bundle="$release_dir/InkFlow-$version-$build-dictionary-source.tar.gz"
rm -f "$source_bundle"
bash macOS/scripts/dictionary-source-bundle.sh "$source_bundle" "$build"
printf '%s  %s\n' "$(sha256 "$pkg")" "$(basename "$pkg")" "$(sha256 "$source_bundle")" "$(basename "$source_bundle")" > "$checksum"
assets=("$pkg" "$checksum" "$update_zip" "$appcast" "$source_bundle")

# 6. Tag and push (full release only). Drafts are created without a tag.
if ! $draft; then
  remote_main=$(git ls-remote origin refs/heads/main | awk '{print $1}')
  commit=$(git rev-parse HEAD)
  [[ $remote_main == "$commit" ]] || git merge-base --is-ancestor "$remote_main" "$commit" || fail 'origin/main has diverged.'
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "InkFlow $version (build $build)"
  [[ $(git rev-parse "$tag^{commit}") == "$commit" ]] || fail "Local $tag points elsewhere."
  git push --atomic origin "$commit:refs/heads/main" "refs/tags/$tag"
fi

# 7. Draft release with assets; reuse an existing draft only if its assets match.
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

# 8. Publish. A pre-release is never "latest", so Sparkle clients are not offered it.
if $prerelease; then
  gh release edit "$tag" --repo "$repo" --draft=false --prerelease --latest=false
else
  gh release edit "$tag" --repo "$repo" --draft=false --prerelease=false --latest
fi
echo "PASS release $tag build $build: $(gh release view "$tag" --repo "$repo" --json url --jq .url)"
