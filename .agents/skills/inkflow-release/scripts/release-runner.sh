#!/bin/bash
set -euo pipefail

[[ $# -eq 1 && "$1" == continue ]] || { echo 'Usage: bash release-runner.sh continue' >&2; exit 2; }
root=$(cd "$(dirname "$0")/../../../.." && pwd -P)
cd "$root"

fail() { echo "Release runner stopped: $*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
plist_get() { plutil -extract "$2" raw "$1" 2>/dev/null; }
atomic_plist_command() {
  local target=$1; shift
  local temporary response_id
  temporary=$(mktemp "$(dirname "$target")/.response.XXXXXX")
  if "$@" > "$temporary"; then
    plutil -lint "$temporary" >/dev/null 2>&1 || { rm -f "$temporary"; return 1; }
    response_id=$(plist_get "$temporary" id || true)
    valid_uuid "$response_id" || { rm -f "$temporary"; return 1; }
    [[ ! -e "$target" && ! -L "$target" ]] || { rm -f "$temporary"; fail "Refusing to replace $(basename "$target")."; }
    mv "$temporary" "$target"
    return 0
  fi
  rm -f "$temporary"
  return 1
}
write_plist() {
  local target=$1; shift
  local temporary key value
  temporary=$(mktemp "$(dirname "$target")/.plist.XXXXXX")
  plutil -create xml1 "$temporary"
  while [[ $# -gt 0 ]]; do
    key=$1; value=$2; shift 2
    plutil -insert "$key" -string "$value" "$temporary"
  done
  [[ ! -e "$target" && ! -L "$target" ]] || { rm -f "$temporary"; fail "Refusing to replace $(basename "$target")."; }
  mv "$temporary" "$target"
}
require_equal() { [[ "$1" == "$2" ]] || fail "$3"; }
valid_uuid() { [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; }

version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$build" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid source version/build.'
tag="v$version"
release_dir="$root/build/releases/InkFlow-$version-$build"
payload_zip="$release_dir/inputmethod-submission.zip"
payload_app="$release_dir/payload/InkFlow.app"
dmg="$release_dir/InkFlow-$version-$build-arm64.dmg"
checksum="$release_dir/SHA256SUMS"
state="$release_dir/release-state.plist"
notes="$root/build/public-release-notes.md"
internal_notes="$root/build/release-notes.md"
[[ -d "$release_dir" && ! -L "$release_dir" && -f "$payload_zip" && ! -L "$payload_zip" && -d "$payload_app" && ! -L "$payload_app" ]] || fail 'Missing trustworthy package.sh prepare output.'
[[ -f "$notes" && ! -L "$notes" ]] || fail 'Missing build/public-release-notes.md.'
[[ -f "$internal_notes" && ! -L "$internal_notes" ]] || fail 'Missing internal build/release-notes.md.'

lock="$release_dir/runner.lock"
if ! ( set -C; printf '%s\n' "$$" > "$lock" ) 2>/dev/null; then
  fail 'runner.lock already exists; inspect the retained lock and process before removing it.'
fi
own_lock=true
cleanup_lock() { if [[ ${own_lock:-false} == true ]]; then rm -f "$lock"; fi; }
trap cleanup_lock EXIT

release_commit=$(git rev-parse HEAD)
[[ -z $(git status --porcelain --untracked-files=normal) ]] || fail 'Release runner requires a clean worktree.'
git_dir=$(cd "$(git rev-parse --git-dir)" && pwd -P)
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
[[ "$git_dir" != "$common_dir" ]] || fail 'Release runner requires an isolated linked worktree.'
[[ -z $(git symbolic-ref -q HEAD || true) ]] || fail 'Release runner requires detached HEAD.'

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
[[ "$repo" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || fail 'Could not observe a valid GitHub repository identity.'
remote_url=$(git remote get-url origin)
[[ -n "$remote_url" ]] || fail 'Missing origin URL.'
if [[ ${INKFLOW_RELEASE_TESTING:-0} != 1 ]]; then
  case "$remote_url" in
    "https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo"|"git@github.com:$repo.git") ;;
    *) fail 'origin URL does not match the observed GitHub repository.' ;;
  esac
fi

receipt="$release_dir/verified/installer.plist"
bash macOS/scripts/release-receipt.sh verify "$release_dir/verified/InkFlowInstaller" "$release_dir/verified/AppIcon.icns" "$receipt" >/dev/null
require_equal "$(plist_get "$receipt" sourceCommit)" "$release_commit" 'Installer receipt is not bound to the release commit.'
source_sha=$(sha256 macOS/Info.plist)
payload_sha=$(sha256 "$payload_zip")
notes_sha=$(sha256 "$notes")
if [[ -f "$state" && ! -L "$state" ]]; then
  previous_tag=$(plist_get "$state" previousTag)
  require_equal "$(plist_get "$state" schema)" 1 'Unknown release state schema.'
  require_equal "$(plist_get "$state" releaseCommit)" "$release_commit" 'Release commit drifted from state.'
  require_equal "$(plist_get "$state" version)" "$version" 'Version drifted from state.'
  require_equal "$(plist_get "$state" build)" "$build" 'Build drifted from state.'
  require_equal "$(plist_get "$state" tag)" "$tag" 'Tag drifted from state.'
  require_equal "$(plist_get "$state" sourcePlistSHA256)" "$source_sha" 'Source plist drifted from state.'
  require_equal "$(plist_get "$state" payloadZIPSHA256)" "$payload_sha" 'Payload ZIP drifted from state.'
  require_equal "$(plist_get "$state" notesPath)" "$notes" 'Release notes path drifted from state.'
  require_equal "$(plist_get "$state" notesSHA256)" "$notes_sha" 'Release notes drifted from state.'
  require_equal "$(plist_get "$state" repo)" "$repo" 'Observed repository conflicts with state.'
else
  [[ ! -e "$state" && ! -L "$state" ]] || fail 'Untrusted release state path.'
  previous_tag=''
  while IFS= read -r candidate; do
    if [[ "$candidate" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$candidate" != "$tag" ]]; then previous_tag=$candidate; break; fi
  done < <(git tag --merged HEAD --sort=-version:refname)
  [[ -n "$previous_tag" ]] || fail 'No previous stable release tag is an ancestor of HEAD.'
  git merge-base --is-ancestor "$previous_tag" "$release_commit" || fail 'Previous tag is not an ancestor of the release commit.'
  plan=$(bash macOS/scripts/release-verification.sh --plan-only --from "$previous_tag")
  manual_install=false
  printf '%s\n' "$plan" | grep -Fxq manual-install && manual_install=true
  write_plist "$state" schema 1 releaseCommit "$release_commit" version "$version" build "$build" tag "$tag" previousTag "$previous_tag" repo "$repo" sourcePlistSHA256 "$source_sha" payloadZIPSHA256 "$payload_sha" notesPath "$notes" notesSHA256 "$notes_sha" manualInstallNeeded "$manual_install"
fi
state_sha=$(sha256 "$state")
manual_install=$(plist_get "$state" manualInstallNeeded)

verified_repo=$(gh repo view --repo "$repo" --json nameWithOwner --jq .nameWithOwner)
require_equal "$verified_repo" "$repo" 'GitHub repository identity mismatch.'

poll_interval=${INKFLOW_RELEASE_POLL_INTERVAL:-30}
[[ "$poll_interval" =~ ^[0-9]+$ ]] || fail 'Invalid polling interval.'
if [[ "$poll_interval" == 0 && ${INKFLOW_RELEASE_TESTING:-0} != 1 ]]; then fail 'Zero polling interval is test-only.'; fi

history_snapshot() {
  local output=$1 temporary
  temporary=$(mktemp "$release_dir/.history.XXXXXX")
  bash .agents/skills/inkflow-release/scripts/notary.sh history --output-format plist > "$temporary"
  plutil -lint "$temporary" >/dev/null 2>&1 || { rm -f "$temporary"; fail 'Invalid notarization history response.'; }
  : > "$output"
  local i=0 id
  while id=$(plutil -extract "history.$i.id" raw "$temporary" 2>/dev/null); do
    valid_uuid "$id" || { rm -f "$temporary"; fail 'Notarization history contains an invalid submission ID.'; }
    printf '%s\n' "$id" >> "$output"; i=$((i + 1))
  done
  rm -f "$temporary"
}
recover_submission() {
  local artifact=$1 intent=$2 response=$3 temporary i id name created created_base submitted_base recover_base candidates=0 candidate=''
  temporary=$(mktemp "$release_dir/.history.XXXXXX")
  bash .agents/skills/inkflow-release/scripts/notary.sh history --output-format plist > "$temporary"
  plutil -lint "$temporary" >/dev/null 2>&1 || { rm -f "$temporary"; fail 'Invalid notarization recovery history.'; }
  i=0
  submitted_base=$(plist_get "$intent" submittedAt); submitted_base=${submitted_base:0:19}
  recover_base=$(plist_get "$intent" recoverUntil); recover_base=${recover_base:0:19}
  while id=$(plutil -extract "history.$i.id" raw "$temporary" 2>/dev/null); do
    valid_uuid "$id" || { rm -f "$temporary"; fail 'Notarization recovery history contains an invalid submission ID.'; }
    name=$(plutil -extract "history.$i.name" raw "$temporary" 2>/dev/null || true)
    created=$(plutil -extract "history.$i.createdDate" raw "$temporary" 2>/dev/null || true); created_base=${created:0:19}
    if [[ "$name" == "$(basename "$artifact")" && "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} && ( "$created_base" == "$submitted_base" || "$created_base" > "$submitted_base" ) && ( "$created_base" == "$recover_base" || "$created_base" < "$recover_base" ) ]] && ! printf '%s\n' "$(plist_get "$intent" preHistoryIDs)" | grep -Fxq "$id"; then
      candidates=$((candidates + 1)); candidate=$id
    fi
    i=$((i + 1))
  done
  rm -f "$temporary"
  [[ $candidates -eq 1 ]] || fail "Lost submission response has $candidates matching history entries; refusing to resubmit."
  write_plist "$response" id "$candidate" recoveredFromHistory true
}
ensure_submission() {
  local kind=$1 artifact=$2 response=$3 intent=$4 pre_history id status info log
  if [[ -e "$intent" && ( ! -f "$intent" || -L "$intent" ) ]]; then fail "Untrusted $kind submission intent path."; fi
  if [[ -e "$response" && ( ! -f "$response" || -L "$response" ) ]]; then fail "Untrusted $kind submission response path."; fi
  if [[ -e "$response" && ! -f "$intent" ]]; then fail "$kind submission response lacks its immutable intent."; fi
  require_equal "$(sha256 "$artifact")" "$(plist_get "$intent" artifactSHA256 2>/dev/null || sha256 "$artifact")" "$kind artifact drifted after submission intent."
  if [[ ! -f "$response" ]]; then
    if [[ -f "$intent" && ! -L "$intent" ]]; then
      recover_submission "$artifact" "$intent" "$response"
    else
      [[ ! -e "$intent" && ! -L "$intent" ]] || fail "Untrusted $kind submission intent."
      pre_history="$release_dir/$kind-pre-history.ids"
      [[ ! -e "$pre_history" ]] || fail "Existing $kind pre-history without intent."
      history_snapshot "$pre_history"
      submitted_epoch=$(date -u '+%s')
      submitted_at=$(date -u -r "$submitted_epoch" '+%Y-%m-%dT%H:%M:%SZ')
      recover_until=$(date -u -r "$((submitted_epoch + 600))" '+%Y-%m-%dT%H:%M:%SZ')
      write_plist "$intent" artifactSHA256 "$(sha256 "$artifact")" submittedAt "$submitted_at" recoverUntil "$recover_until" preHistoryIDs "$(cat "$pre_history")" stateSHA256 "$state_sha"
      if ! atomic_plist_command "$response" bash .agents/skills/inkflow-release/scripts/notary.sh submit "$artifact" --no-wait --output-format plist; then
        recover_submission "$artifact" "$intent" "$response"
      fi
    fi
  fi
  require_equal "$(plist_get "$intent" artifactSHA256)" "$(sha256 "$artifact")" "$kind artifact changed after submission."
  require_equal "$(plist_get "$intent" stateSHA256)" "$state_sha" "$kind intent is not bound to release state."
  id=$(plist_get "$response" id)
  valid_uuid "$id" || fail "$kind submission response contains an invalid submission ID."
  info="$release_dir/$kind-info.plist"; log="$release_dir/$kind-notary.log"
  while :; do
    local temporary
    temporary=$(mktemp "$release_dir/.info.XXXXXX")
    bash .agents/skills/inkflow-release/scripts/notary.sh info "$id" --output-format plist > "$temporary" || { rm -f "$temporary"; fail "$kind notarization info failed for $id."; }
    plutil -lint "$temporary" >/dev/null 2>&1 || { mv "$temporary" "$log"; fail "Invalid $kind notarization info retained in $log."; }
    status=$(plist_get "$temporary" status || true)
    mv "$temporary" "$info"
    case "$status" in
      Accepted) break ;;
      'In Progress') sleep "$poll_interval" ;;
      Invalid) bash .agents/skills/inkflow-release/scripts/notary.sh log "$id" > "$log" 2>&1 || true; fail "$kind notarization is Invalid; log retained at $log." ;;
      *) cp "$info" "$log"; fail "Unknown $kind notarization status '$status'; response retained at $log." ;;
    esac
  done
}

dmg_receipt="$release_dir/dmg-receipt.plist"
dmg_build_intent="$release_dir/dmg-build.intent.plist"
dmg_build_response="$release_dir/dmg-build.plist"
assembly_snapshot() {
  local candidate
  while IFS= read -r candidate; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || fail 'Untrusted preexisting assembly path.'
    printf '%s\n' "$candidate"
  done < <(find "$release_dir" -mindepth 1 -maxdepth 1 -name 'assembly.*' -print | LC_ALL=C sort)
}
if [[ -e "$dmg_build_intent" && ( ! -f "$dmg_build_intent" || -L "$dmg_build_intent" ) ]]; then fail 'Untrusted DMG build intent path.'; fi
if [[ ! -f "$dmg_build_intent" ]]; then
  [[ ! -e "$dmg" && ! -L "$dmg" ]] || fail 'Existing DMG has no immutable pre-finish intent.'
  write_plist "$dmg_build_intent" stateSHA256 "$state_sha" releaseCommit "$release_commit" expectedDMGPath "$dmg" expectedDMGName "$(basename "$dmg")" sourcePlistSHA256 "$source_sha" payloadZIPSHA256 "$payload_sha" installerReceiptSHA256 "$(sha256 "$receipt")" preexistingAssemblies "$(assembly_snapshot)"
fi
require_equal "$(plist_get "$dmg_build_intent" stateSHA256)" "$state_sha" 'DMG build intent does not match release state.'
require_equal "$(plist_get "$dmg_build_intent" releaseCommit)" "$release_commit" 'DMG build intent commit mismatch.'
require_equal "$(plist_get "$dmg_build_intent" expectedDMGPath)" "$dmg" 'DMG build intent path mismatch.'
require_equal "$(plist_get "$dmg_build_intent" expectedDMGName)" "$(basename "$dmg")" 'DMG build intent name mismatch.'
require_equal "$(plist_get "$dmg_build_intent" sourcePlistSHA256)" "$source_sha" 'DMG build intent source plist mismatch.'
require_equal "$(plist_get "$dmg_build_intent" payloadZIPSHA256)" "$payload_sha" 'DMG build intent payload ZIP mismatch.'
require_equal "$(plist_get "$dmg_build_intent" installerReceiptSHA256)" "$(sha256 "$receipt")" 'DMG build intent installer receipt mismatch.'

payload_response="$release_dir/payload-submission.plist"
payload_intent="$release_dir/payload-submission.intent.plist"
ensure_submission payload "$payload_zip" "$payload_response" "$payload_intent"
if ! xcrun stapler validate "$payload_app" >/dev/null 2>&1; then xcrun stapler staple "$payload_app"; fi
xcrun stapler validate "$payload_app"

if [[ ! -e "$dmg" && ! -L "$dmg" ]]; then
  bash .agents/skills/inkflow-release/scripts/package.sh finish
  [[ -f "$dmg" && ! -L "$dmg" ]] || fail 'package.sh finish did not create the expected DMG.'
  if [[ ${INKFLOW_RELEASE_TESTING:-0} == 1 && ${INKFLOW_RELEASE_TEST_INTERRUPT_AFTER_FINISH:-0} == 1 ]]; then fail 'Fixture interruption after package.sh finish.'; fi
else
  [[ -f "$dmg" && ! -L "$dmg" ]] || fail 'Untrusted existing DMG path.'
fi
bind_dmg_build() {
  local candidates candidate count assembled intent_sha
  intent_sha=$(sha256 "$dmg_build_intent")
  if [[ -e "$dmg_build_response" || -L "$dmg_build_response" ]]; then
    [[ -f "$dmg_build_response" && ! -L "$dmg_build_response" ]] || fail 'Untrusted DMG build binding path.'
    candidate=$(plist_get "$dmg_build_response" assemblyPath)
    require_equal "$(plist_get "$dmg_build_response" intentSHA256)" "$intent_sha" 'DMG build binding does not match its intent.'
  else
    candidates=$(mktemp "$release_dir/.new-assemblies.XXXXXX")
    : > "$candidates"
    while IFS= read -r candidate; do
      if ! printf '%s\n' "$(plist_get "$dmg_build_intent" preexistingAssemblies)" | grep -Fxq "$candidate"; then
        assembled="$candidate/$(basename "$dmg")"
        if [[ -f "$assembled" && ! -L "$assembled" && "$assembled" -ef "$dmg" ]]; then printf '%s\n' "$candidate" >> "$candidates"; fi
      fi
    done < <(assembly_snapshot)
    count=$(wc -l < "$candidates" | tr -d ' ')
    [[ "$count" == 1 ]] || { rm -f "$candidates"; fail "Expected exactly one new package assembly owning the final DMG hard link, found $count."; }
    candidate=$(cat "$candidates"); rm -f "$candidates"
    assembled="$candidate/$(basename "$dmg")"
    [[ -f "$assembled" && ! -L "$assembled" && "$assembled" -ef "$dmg" ]] || fail 'Final DMG is not the hard-linked output of the unique new package assembly.'
    write_plist "$dmg_build_response" intentSHA256 "$intent_sha" assemblyPath "$candidate" assembledDMGSHA256 "$(sha256 "$assembled")" finalDMGSHA256 "$(sha256 "$dmg")"
  fi
  assembled="$candidate/$(basename "$dmg")"
  [[ -d "$candidate" && ! -L "$candidate" && -f "$assembled" && ! -L "$assembled" && "$assembled" -ef "$dmg" ]] || fail 'Bound package assembly no longer owns the final DMG hard link.'
  require_equal "$(plist_get "$dmg_build_response" assembledDMGSHA256)" "$(sha256 "$assembled")" 'Assembled DMG drifted from build binding.'
  require_equal "$(plist_get "$dmg_build_response" finalDMGSHA256)" "$(sha256 "$dmg")" 'Final DMG drifted from build binding.'
}
bind_dmg_build
if [[ -e "$dmg_receipt" || -L "$dmg_receipt" ]]; then
  [[ -f "$dmg_receipt" && ! -L "$dmg_receipt" ]] || fail 'Untrusted DMG receipt path.'
  require_equal "$(plist_get "$dmg_receipt" stateSHA256)" "$state_sha" 'DMG receipt does not match release state.'
  require_equal "$(plist_get "$dmg_receipt" releaseCommit)" "$release_commit" 'DMG receipt commit mismatch.'
  require_equal "$(plist_get "$dmg_receipt" dmgSHA256)" "$(sha256 "$dmg")" 'DMG bytes drifted from receipt.'
fi

dmg_response="$release_dir/submission.plist"
dmg_intent="$release_dir/submission.intent.plist"
ensure_submission dmg "$dmg" "$dmg_response" "$dmg_intent"
if ! xcrun stapler validate "$dmg" >/dev/null 2>&1; then xcrun stapler staple "$dmg"; fi
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
hdiutil verify "$dmg"
mount_log=$(mktemp "$release_dir/.mount.XXXXXX")
mount_point=''
detach_mount() { [[ -z "$mount_point" ]] || hdiutil detach "$mount_point" >/dev/null; }
trap 'detach_mount; cleanup_lock' EXIT
hdiutil attach -readonly -nobrowse "$dmg" > "$mount_log"
mount_point=$(awk -F '\t' '$3 ~ /^\// {print $3; exit}' "$mount_log")
[[ -n "$mount_point" && -d "$mount_point" ]] || fail 'Could not determine mounted DMG path.'
installer="$mount_point/InkFlow Installer.app"
[[ -d "$installer" && -f "$mount_point/安装说明.txt" && $(find "$mount_point" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') == 2 ]] || fail 'Unexpected DMG root contents.'
codesign --verify --deep --strict --verbose=2 "$installer"
metadata=$(codesign -dvvv "$installer" 2>&1)
printf '%s\n' "$metadata" | grep -Fxq 'TeamIdentifier=T7976FL2LP' || fail 'Mounted installer Team ID mismatch.'
printf '%s\n' "$metadata" | grep -Fxq 'Identifier=io.damao.inkflow.installer' || fail 'Mounted installer identifier mismatch.'
require_equal "$(plutil -extract CFBundleShortVersionString raw "$installer/Contents/Info.plist")" "$version" 'Mounted installer version mismatch.'
require_equal "$(plutil -extract CFBundleVersion raw "$installer/Contents/Info.plist")" "$build" 'Mounted installer build mismatch.'
spctl --assess --type execute --verbose=2 "$installer"
"$installer/Contents/MacOS/InkFlowInstaller" --check-payload
extract=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-inner.XXXXXX")
ditto -x -k "$installer/Contents/Resources/Payload/InkFlow.zip" "$extract"
inner="$extract/InkFlow.app"
codesign --verify --deep --strict --verbose=2 "$inner"
xcrun stapler validate "$inner"
spctl --assess --type execute --verbose=2 "$inner"
inner_metadata=$(codesign -dvvv "$inner" 2>&1)
printf '%s\n' "$inner_metadata" | grep -Fxq 'TeamIdentifier=T7976FL2LP' || fail 'Extracted payload Team ID mismatch.'
printf '%s\n' "$inner_metadata" | grep -Fxq 'Identifier=io.damao.inputmethod.inkflow' || fail 'Extracted payload identifier mismatch.'
require_equal "$(plutil -extract CFBundleShortVersionString raw "$inner/Contents/Info.plist")" "$version" 'Extracted payload version mismatch.'
require_equal "$(plutil -extract CFBundleVersion raw "$inner/Contents/Info.plist")" "$build" 'Extracted payload build mismatch.'
rm -rf "$extract"
detach_mount; mount_point=''; rm -f "$mount_log"

if [[ ! -e "$dmg_receipt" && ! -L "$dmg_receipt" ]]; then
  write_plist "$dmg_receipt" stateSHA256 "$state_sha" releaseCommit "$release_commit" version "$version" build "$build" dmgSHA256 "$(sha256 "$dmg")"
fi
require_equal "$(plist_get "$dmg_receipt" stateSHA256)" "$state_sha" 'Verified DMG receipt does not match release state.'
require_equal "$(plist_get "$dmg_receipt" releaseCommit)" "$release_commit" 'Verified DMG receipt commit mismatch.'
require_equal "$(plist_get "$dmg_receipt" dmgSHA256)" "$(sha256 "$dmg")" 'Verified DMG bytes drifted from receipt.'

dmg_name=$(basename "$dmg")
expected_checksum="$(sha256 "$dmg")  $dmg_name"
if [[ -f "$checksum" && ! -L "$checksum" ]]; then require_equal "$(cat "$checksum")" "$expected_checksum" 'SHA256SUMS conflicts with final DMG.'
else [[ ! -e "$checksum" ]] || fail 'Untrusted SHA256SUMS path.'; printf '%s\n' "$expected_checksum" > "$checksum"; fi

remote_main=$(git ls-remote origin refs/heads/main | awk 'NR==1{print $1}')
[[ -n "$remote_main" ]] || fail 'Remote main is missing.'
if [[ "$remote_main" != "$release_commit" ]]; then git merge-base --is-ancestor "$remote_main" "$release_commit" || fail 'Remote main diverged from release commit.'; fi
remote_tag_direct=$(git ls-remote origin "refs/tags/$tag" | awk 'NR==1{print $1}')
remote_tag=$(git ls-remote origin "refs/tags/$tag^{}" | awk 'NR==1{print $1}')
if [[ -n "$remote_tag_direct" && -z "$remote_tag" ]]; then fail 'Remote release tag exists but is not a verifiable annotated tag.'; fi
if [[ -n "$remote_tag" ]]; then require_equal "$remote_tag" "$release_commit" 'Remote tag conflicts with release commit.'; fi
[[ -z $(git status --porcelain --untracked-files=normal) && $(git rev-parse HEAD) == "$release_commit" ]] || fail 'Source changed before tagging.'
local_tag=$(git rev-parse -q --verify "$tag^{}" 2>/dev/null || true)
if [[ -n "$local_tag" ]]; then
  require_equal "$local_tag" "$release_commit" 'Local tag points to another commit.'
  require_equal "$(git cat-file -t "$tag")" tag 'Local release tag is not annotated.'
else git tag -a "$tag" -m "InkFlow $version (build $build)" "$release_commit"; fi
if [[ "$remote_main" != "$release_commit" || -z "$remote_tag" ]]; then git push --atomic origin "$release_commit:refs/heads/main" "refs/tags/$tag"; fi

if release_tag=$(gh release view "$tag" --repo "$repo" --json tagName --jq .tagName 2>/dev/null); then
  require_equal "$release_tag" "$tag" 'GitHub Release tag mismatch.'
  require_equal "$(gh release view "$tag" --repo "$repo" --json name --jq .name)" "InkFlow $version" 'GitHub Release title mismatch.'
  release_body=$(mktemp "$release_dir/.github-body.XXXXXX")
  gh release view "$tag" --repo "$repo" --json body --jq .body > "$release_body"
  cmp "$notes" "$release_body" || { rm -f "$release_body"; fail 'GitHub Release notes differ from the immutable notes file.'; }
  rm -f "$release_body"
else
  absence=$(mktemp "$release_dir/.github-absence.XXXXXX")
  if gh api "repos/$repo/releases/tags/$tag" --include > "$absence" 2>&1; then
    rm -f "$absence"; fail 'GitHub API found a Release that gh release view could not verify.'
  fi
  grep -Eq '^HTTP/[0-9.]+ 404|^HTTP [0-9.]+ 404' "$absence" || { mv "$absence" "$release_dir/github-release-observation.log"; fail 'GitHub Release absence is unknown; observation retained.'; }
  rm -f "$absence"
  gh release create "$tag" --repo "$repo" --verify-tag --draft --title "InkFlow $version" --notes-file "$notes"
fi
asset_names=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' | LC_ALL=C sort)
for existing in $asset_names; do
  [[ "$existing" == "$dmg_name" || "$existing" == SHA256SUMS ]] || fail "Unexpected existing Release asset: $existing"
done
for asset in "$dmg" "$checksum"; do
  name=$(basename "$asset")
  if printf '%s\n' "$asset_names" | grep -Fxq "$name"; then
    check_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-asset-check.XXXXXX")
    gh release download "$tag" --repo "$repo" --pattern "$name" --dir "$check_dir"
    cmp "$asset" "$check_dir/$name" || fail "Existing Release asset differs: $name"
    rm -rf "$check_dir"
  else
    gh release upload "$tag" "$asset" --repo "$repo"
  fi
done
download=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-download.XXXXXX")
gh release download "$tag" --repo "$repo" --pattern "$dmg_name" --pattern SHA256SUMS --dir "$download"
cmp "$dmg" "$download/$dmg_name" || fail 'Downloaded DMG differs from local bytes.'
cmp "$checksum" "$download/SHA256SUMS" || fail 'Downloaded checksum differs from local bytes.'
(cd "$download" && shasum -a 256 -c SHA256SUMS)
rm -rf "$download"

is_draft=$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)
if [[ "$is_draft" == true ]]; then
  if [[ "$manual_install" == true ]]; then
    acceptance="Release-Installation-Acceptance: version=$version build=$build releaseCommit=$release_commit dmgSHA256=$(sha256 "$dmg") scope=installation-upgrade result=pass"
    grep -Fxq "$acceptance" "$internal_notes" || fail "Draft and assets are ready; internal build/release-notes.md still needs: $acceptance"
  fi
  gh release edit "$tag" --repo "$repo" --draft=false --latest
elif [[ "$is_draft" != false ]]; then fail "Unknown GitHub draft state: $is_draft"; fi

require_equal "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)" false 'GitHub Release is still a draft.'
require_equal "$(gh release view "$tag" --repo "$repo" --json tagName --jq .tagName)" "$tag" 'Final GitHub Release tag mismatch.'
final_assets=$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name' | LC_ALL=C sort)
require_equal "$final_assets" "$(printf '%s\n' SHA256SUMS "$dmg_name" | LC_ALL=C sort)" 'Final GitHub asset set mismatch.'
require_equal "$(git ls-remote origin "refs/tags/$tag^{}" | awk 'NR==1{print $1}')" "$release_commit" 'Remote annotated tag does not peel to release commit.'
require_equal "$(git ls-remote origin refs/heads/main | awk 'NR==1{print $1}')" "$release_commit" 'Remote main does not equal the release commit.'
url=$(gh release view "$tag" --repo "$repo" --json url --jq .url)
echo "PASS release $tag build $build: $dmg_name"
echo "$url"
