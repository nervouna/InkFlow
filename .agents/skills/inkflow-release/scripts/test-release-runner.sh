#!/bin/bash
# shellcheck disable=SC2016
# Repository-shaped fixtures only. PATH stubs reject every unmodelled external effect.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
runner_source="$root/.agents/skills/inkflow-release/scripts/release-runner.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-runner.XXXXXX")
trap '[[ ${INKFLOW_KEEP_RUNNER_FIXTURE:-0} == 1 ]] || rm -rf "$fixture"' EXIT

make_plist() {
  local file=$1; shift
  plutil -create xml1 "$file"
  while [[ $# -gt 0 ]]; do plutil -insert "$1" -string "$2" "$file"; shift 2; done
}

setup_fixture() {
  local name=$1 manual=${2:-false}
  base="$fixture/$name"; seed="$base/seed"; bare="$base/origin.git"; repo="$base/repo"; bin="$base/bin"; external="$base/external"
  mkdir -p "$seed/.agents/skills/inkflow-release/scripts" "$seed/macOS/scripts" "$seed/build" "$bin" "$external"
  cp "$runner_source" "$seed/.agents/skills/inkflow-release/scripts/release-runner.sh"
  chmod +x "$seed/.agents/skills/inkflow-release/scripts/release-runner.sh"
  printf 'build/\n' > "$seed/.gitignore"
  make_plist "$seed/macOS/Info.plist" CFBundleShortVersionString 1.2.3 CFBundleVersion 7
  printf 'notes\n' > "$seed/README.md"
  cat > "$seed/macOS/scripts/release-receipt.sh" <<'STUB'
#!/bin/bash
[[ "$1" == verify && -f "$2" && -f "$3" && -f "$4" ]]
STUB
  cat > "$seed/macOS/scripts/release-verification.sh" <<STUB
#!/bin/bash
printf '%s\n' core bundle-deep
[[ '$manual' != true ]] || echo manual-install
STUB
  cat > "$seed/.agents/skills/inkflow-release/scripts/package.sh" <<'STUB'
#!/bin/bash
set -eu
[[ "$1" == finish ]] || exit 92
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist); build=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
dir="build/releases/InkFlow-$version-$build"; scratch=$(mktemp -d "$dir/assembly.XXXXXX")
echo fixture-dmg > "$scratch/InkFlow-$version-$build-arm64.dmg"
echo package-finish-attempt >> "$EVENTS"
if [[ ${PACKAGE_FAIL_ONCE:-0} == 1 && ! -e "$PACKAGE_STATE/failed-once" ]]; then mkdir -p "$PACKAGE_STATE"; touch "$PACKAGE_STATE/failed-once"; exit 73; fi
ln "$scratch/InkFlow-$version-$build-arm64.dmg" "$dir/InkFlow-$version-$build-arm64.dmg"
echo package-finish >> "$EVENTS"
STUB
  cat > "$seed/.agents/skills/inkflow-release/scripts/notary.sh" <<'STUB'
#!/bin/bash
set -eu
action=$1; shift; history="$NOTARY_STATE/history.tsv"; mkdir -p "$NOTARY_STATE"; touch "$history"
case "$action" in
history)
  out=$(mktemp); plutil -create xml1 "$out"; plutil -insert history -array "$out"; i=0
  while IFS="	" read -r id name created; do [[ -n "$id" ]] || continue; plutil -insert "history.$i" -dictionary "$out"; plutil -insert "history.$i.id" -string "$id" "$out"; plutil -insert "history.$i.name" -string "$name" "$out"; plutil -insert "history.$i.createdDate" -string "$created" "$out"; i=$((i+1)); done < "$history"
  cat "$out"; rm "$out" ;;
submit)
  artifact=$1; name=$(basename "$artifact"); count=0; [[ ! -f "$NOTARY_STATE/count" ]] || count=$(cat "$NOTARY_STATE/count"); count=$((count+1)); echo "$count" > "$NOTARY_STATE/count"; printf -v id '00000000-0000-4000-8000-%012d' "$count"
  created=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); mode=${NOTARY_MODE:-ok}; [[ "$mode" != late-* || "$name" != *"${mode#late-}"* ]] || created=2199-01-01T00:00:00Z; [[ "$mode" != bad-id ]] || id=damaged-id
  printf '%s\t%s\t%s\n' "$id" "$name" "$created" >> "$history"; echo "submit:$name" >> "$EVENTS"
  if [[ "$mode" == ambiguous-* && "$name" == *"${mode#ambiguous-}"* ]]; then printf -v extra '00000000-0000-4000-8000-%012d' "$((count + 100))"; printf '%s\t%s\t%s\n' "$extra" "$name" "$created" >> "$history"; exit 70; fi
  [[ "$mode" != late-* || "$name" != *"${mode#late-}"* ]] || exit 70
  [[ "$mode" != loss-* || "$name" != *"${mode#loss-}"* ]] || exit 70
  out=$(mktemp); plutil -create xml1 "$out"; plutil -insert id -string "$id" "$out"; cat "$out"; rm "$out" ;;
info)
  id=$1; out=$(mktemp); plutil -create xml1 "$out"; plutil -insert id -string "$id" "$out"; status=Accepted; [[ ${NOTARY_MODE:-ok} != invalid ]] || status=Invalid; [[ ${NOTARY_MODE:-ok} != unknown ]] || status=Mystery; plutil -insert status -string "$status" "$out"; cat "$out"; rm "$out" ;;
log) echo fixture-invalid-log ;;
*) exit 99 ;;
esac
STUB
  chmod +x "$seed/macOS/scripts/"*.sh "$seed/.agents/skills/inkflow-release/scripts/"*.sh
  (cd "$seed" && git init -q && git config user.name Fixture && git config user.email fixture@example.invalid && git add . && git commit -qm base && git tag -a v1.2.2 -m old)
  git init -q --bare "$bare"; (cd "$seed" && git remote add origin "$bare" && git push -q origin HEAD:main --tags && printf 'release\n' >> README.md && git add README.md && git commit -qm release)
  git -C "$seed" worktree add -q --detach "$repo" HEAD
  release="$repo/build/releases/InkFlow-1.2.3-7"
  mkdir -p "$release/payload/InkFlow.app/Contents/MacOS" "$release/verified" "$repo/build/mount/InkFlow Installer.app/Contents/MacOS" "$repo/build/mount/InkFlow Installer.app/Contents/Resources/Payload" "$repo/build/mount-payload/InkFlow.app/Contents/MacOS"
  cp "$repo/macOS/Info.plist" "$release/payload/InkFlow.app/Contents/Info.plist"; cp "$repo/macOS/Info.plist" "$repo/build/mount/InkFlow Installer.app/Contents/Info.plist"; plutil -replace CFBundleIdentifier -string io.damao.inkflow.installer "$repo/build/mount/InkFlow Installer.app/Contents/Info.plist"; cp "$repo/macOS/Info.plist" "$repo/build/mount-payload/InkFlow.app/Contents/Info.plist"
  printf '#!/bin/bash\nexit 0\n' > "$repo/build/mount/InkFlow Installer.app/Contents/MacOS/InkFlowInstaller"; chmod +x "$repo/build/mount/InkFlow Installer.app/Contents/MacOS/InkFlowInstaller"
  touch "$repo/build/mount/安装说明.txt" "$repo/build/mount/InkFlow Installer.app/Contents/Resources/Payload/InkFlow.zip"; echo zip > "$release/inputmethod-submission.zip"; echo installer > "$release/verified/InkFlowInstaller"; echo icon > "$release/verified/AppIcon.icns"
  touch "$repo/build/mount-payload/InkFlow.app.ticket"
  make_plist "$release/verified/installer.plist" sourceCommit "$(git -C "$repo" rev-parse HEAD)"
  printf 'INTERNAL SECRET PLACEHOLDER must never publish\n' > "$repo/build/release-notes.md"
  printf '公开发布说明\n' > "$repo/build/public-release-notes.md"
  cat > "$bin/xcrun" <<'STUB'
#!/bin/bash
[[ "$1" == stapler ]] || { echo "UNSTUBBED xcrun $*" >&2; exit 99; }; target=${!#}
case "$2" in staple) touch "$target.ticket"; echo "staple:$(basename "$target")" >> "$EVENTS";; validate) [[ -e "$target.ticket" ]];; *) exit 99;; esac
STUB
  cat > "$bin/codesign" <<'STUB'
#!/bin/bash
last=${!#}; if [[ "$1" == -dvvv ]]; then id=io.damao.inputmethod.inkflow; [[ "$last" != *'InkFlow Installer.app' ]] || id=io.damao.inkflow.installer; printf 'TeamIdentifier=T7976FL2LP\nIdentifier=%s\n' "$id" >&2; fi
STUB
  printf '#!/bin/bash\nexit 0\n' > "$bin/spctl"
  cat > "$bin/hdiutil" <<'STUB'
#!/bin/bash
case "$1" in verify|detach) exit 0;; attach) printf '/dev/disk9\tApple_HFS\t%s\n' "$MOUNT_POINT";; *) echo "UNSTUBBED hdiutil $*" >&2; exit 99;; esac
STUB
  cat > "$bin/ditto" <<'STUB'
#!/bin/bash
[[ "$1" == -x && "$2" == -k ]] || exit 99; cp -R "$MOUNT_PAYLOAD/." "${!#}/"
STUB
  printf '#!/bin/bash\nexit 0\n' > "$bin/sleep"
  cat > "$bin/gh" <<'STUB'
#!/bin/bash
set -eu; echo "gh:$*" >> "$EVENTS"
[[ "$1 $2" != 'repo view' ]] || { echo fixture/inkflow; exit; }
if [[ "$1" == api ]]; then printf 'HTTP/2.0 404 Not Found\n'; exit 1; fi
[[ "$1" == release ]] || exit 99
action=$2; tag=${3:-}; state="$GH_STATE"; mkdir -p "$state/assets"
case "$action" in
view) [[ -f "$state/exists" ]] || exit 1; case "$*" in *'--json tagName'*) cat "$state/tag";; *'--json name'*) cat "$state/name";; *'--json body'*) cat "$state/body";; *'--json isDraft'*) cat "$state/draft";; *'--json url'*) echo https://example.invalid/release;; *'--json assets'*) find "$state/assets" -type f -maxdepth 1 -exec basename {} \; | sort;; *) exit 99;; esac;;
create) touch "$state/exists"; echo "$tag" > "$state/tag"; echo 'InkFlow 1.2.3' > "$state/name"; echo true > "$state/draft"; cp "${!#}" "$state/body"; echo create >> "$SIDE_EFFECTS";;
upload) cp "$4" "$state/assets/$(basename "$4")"; echo "upload:$(basename "$4")" >> "$SIDE_EFFECTS";;
download) dir=''; patterns=(); shift 3; while [[ $# -gt 0 ]]; do case "$1" in --dir) dir=$2; shift 2;; --pattern) patterns+=("$2"); shift 2;; --repo) shift 2;; *) shift;; esac; done; mkdir -p "$dir"; for pattern in "${patterns[@]}"; do cp "$state/assets/$pattern" "$dir/$pattern"; done;;
edit) echo false > "$state/draft"; echo publish >> "$SIDE_EFFECTS";; *) exit 99;; esac
STUB
  chmod +x "$bin/"*
  export PATH="$bin:/usr/bin:/bin:/usr/sbin:/sbin" EVENTS="$base/events" SIDE_EFFECTS="$base/side-effects" NOTARY_STATE="$external/notary" GH_STATE="$external/gh" PACKAGE_STATE="$external/package" MOUNT_POINT="$repo/build/mount" MOUNT_PAYLOAD="$repo/build/mount-payload"
  export INKFLOW_RELEASE_TESTING=1 INKFLOW_RELEASE_POLL_INTERVAL=0
  unset INKFLOW_RELEASE_REPO INKFLOW_RELEASE_PREVIOUS_TAG INKFLOW_RELEASE_NOTES
  : > "$EVENTS"; : > "$SIDE_EFFECTS"
}

run_ok() { (cd "$repo" && bash .agents/skills/inkflow-release/scripts/release-runner.sh continue) > "$base/out" 2> "$base/err"; }
run_fail() { if run_ok; then echo "Unexpected success: $base" >&2; exit 1; fi; }
accept_install() { printf 'Release-Installation-Acceptance: version=1.2.3 build=7 releaseCommit=%s dmgSHA256=%s scope=installation-upgrade result=pass\n' "$(git -C "$repo" rev-parse HEAD)" "$(shasum -a 256 "$release/InkFlow-1.2.3-7-arm64.dmg" | awk '{print $1}')" >> "$repo/build/release-notes.md"; }

setup_fixture happy false; run_ok
[[ $(grep -c '^submit:' "$EVENTS") == 2 && $(grep -c '^upload:' "$SIDE_EFFECTS") == 2 && $(grep -c '^publish$' "$SIDE_EFFECTS") == 1 ]]
cmp "$GH_STATE/body" "$repo/build/public-release-notes.md"; if grep -Fq 'INTERNAL SECRET PLACEHOLDER' "$GH_STATE/body"; then exit 1; fi
effects=$(shasum -a 256 "$SIDE_EFFECTS" | awk '{print $1}'); run_ok; [[ $(shasum -a 256 "$SIDE_EFFECTS" | awk '{print $1}') == "$effects" ]]
echo 'PASS: happy path and completed continue are exactly-once'

for loss in zip dmg; do setup_fixture "loss-$loss" false; export NOTARY_MODE="loss-$loss"; run_ok; [[ $(grep -c '^submit:' "$EVENTS") == 2 ]]; unset NOTARY_MODE; done
echo 'PASS: unique payload and DMG response-loss recovery does not resubmit'

setup_fixture ambiguous false; export NOTARY_MODE=ambiguous-zip; run_fail; [[ $(grep -c '^submit:' "$EVENTS") == 1 ]]; run_fail; [[ $(grep -c '^submit:' "$EVENTS") == 1 ]]; unset NOTARY_MODE; grep -Fq 'refusing to resubmit' "$base/err"
echo 'PASS: ambiguous notarization history fails closed'

setup_fixture late false; export NOTARY_MODE=late-zip; run_fail; [[ $(grep -c '^submit:' "$EVENTS") == 1 ]]; run_fail; [[ $(grep -c '^submit:' "$EVENTS") == 1 ]]; unset NOTARY_MODE; grep -Fq '0 matching history entries' "$base/err"
echo 'PASS: response-loss history outside the recovery window is rejected without resubmit'

setup_fixture invalid-id false; export NOTARY_MODE=bad-id; run_fail; unset NOTARY_MODE; [[ ! -e "$release/payload-submission.plist" ]]
echo 'PASS: malformed notarization UUID is rejected before querying'

setup_fixture invalid false; export NOTARY_MODE=invalid; run_fail; unset NOTARY_MODE; [[ -s "$release/payload-notary.log" ]]
echo 'PASS: Invalid notarization retains the log and stops'

setup_fixture unknown false; export NOTARY_MODE=unknown; run_fail; unset NOTARY_MODE; [[ -s "$release/payload-notary.log" ]]
echo 'PASS: unknown notarization status retains the response and stops'

setup_fixture drift false; run_ok; printf tamper >> "$release/inputmethod-submission.zip"; run_fail
echo 'PASS: state and artifact drift stop continuation'

setup_fixture finish-crash false; export INKFLOW_RELEASE_TEST_INTERRUPT_AFTER_FINISH=1; run_fail; unset INKFLOW_RELEASE_TEST_INTERRUPT_AFTER_FINISH
[[ -f "$release/InkFlow-1.2.3-7-arm64.dmg" && -f "$release/dmg-build.intent.plist" && ! -e "$release/dmg-build.plist" && ! -e "$release/dmg-receipt.plist" ]]
run_ok
[[ $(grep -c '^package-finish$' "$EVENTS") == 1 && $(grep -c '^submit:inputmethod-submission.zip$' "$EVENTS") == 1 && $(grep -c '^submit:InkFlow-1.2.3-7-arm64.dmg$' "$EVENTS") == 1 && $(grep -c '^upload:' "$SIDE_EFFECTS") == 2 ]]
[[ -f "$release/dmg-receipt.plist" ]]
echo 'PASS: post-finish pre-receipt crash adopts only the fully verified intended DMG'

setup_fixture replaced-after-finish false; export INKFLOW_RELEASE_TEST_INTERRUPT_AFTER_FINISH=1; run_fail; unset INKFLOW_RELEASE_TEST_INTERRUPT_AFTER_FINISH
echo replacement > "$base/replacement.dmg"; mv -f "$base/replacement.dmg" "$release/InkFlow-1.2.3-7-arm64.dmg"; run_fail
[[ $(grep -c '^package-finish$' "$EVENTS") == 1 && $(grep -c '^submit:inputmethod-submission.zip$' "$EVENTS") == 1 ]]; if grep -q '^submit:InkFlow-1.2.3-7-arm64.dmg$' "$EVENTS"; then exit 1; fi; [[ ! -s "$SIDE_EFFECTS" && ! -e "$release/dmg-build.plist" ]]
echo 'PASS: replaced post-crash DMG is rejected before DMG submission or upload'

setup_fixture failed-finish-retry false; export PACKAGE_FAIL_ONCE=1; run_fail; [[ ! -e "$release/InkFlow-1.2.3-7-arm64.dmg" && $(find "$release" -maxdepth 1 -type d -name 'assembly.*' | wc -l) -eq 1 ]]; run_ok; unset PACKAGE_FAIL_ONCE
[[ $(grep -c '^package-finish-attempt$' "$EVENTS") == 2 && $(grep -c '^package-finish$' "$EVENTS") == 1 && $(grep -c '^submit:inputmethod-submission.zip$' "$EVENTS") == 1 && $(grep -c '^submit:InkFlow-1.2.3-7-arm64.dmg$' "$EVENTS") == 1 && $(grep -c '^upload:' "$SIDE_EFFECTS") == 2 ]]
[[ $(find "$release" -maxdepth 1 -type d -name 'assembly.*' | wc -l) -eq 2 && -f "$release/dmg-build.plist" ]]
echo 'PASS: failed finish assembly is retained while the unique successful retry is bound'

setup_fixture multiple-matching false; export INKFLOW_RELEASE_TEST_INTERRUPT_AFTER_FINISH=1; run_fail; unset INKFLOW_RELEASE_TEST_INTERRUPT_AFTER_FINISH
mkdir "$release/assembly.suspicious"; ln "$release/InkFlow-1.2.3-7-arm64.dmg" "$release/assembly.suspicious/InkFlow-1.2.3-7-arm64.dmg"; run_fail
if grep -q '^submit:InkFlow-1.2.3-7-arm64.dmg$' "$EVENTS"; then exit 1; fi; [[ ! -s "$SIDE_EFFECTS" && ! -e "$release/dmg-build.plist" ]]
echo 'PASS: multiple new assemblies owning the final DMG fail closed before submission'

setup_fixture arbitrary-dmg false; echo arbitrary > "$release/InkFlow-1.2.3-7-arm64.dmg"; run_fail
[[ ! -e "$release/dmg-build.intent.plist" && ! -s "$SIDE_EFFECTS" ]]; if grep -Eq '^submit:|^package-finish$' "$EVENTS"; then exit 1; fi
echo 'PASS: arbitrary preexisting DMG without pre-finish intent is rejected before effects'

setup_fixture manual true; run_fail; [[ $(cat "$GH_STATE/draft") == true ]]; [[ $(find "$GH_STATE/assets" -type f | wc -l) -eq 2 ]]; accept_install; run_ok; [[ $(cat "$GH_STATE/draft") == false ]]
echo 'PASS: installation gate preserves draft and publishes after bound acceptance'

setup_fixture asset-conflict false; mkdir -p "$GH_STATE/assets"; touch "$GH_STATE/exists"; echo v1.2.3 > "$GH_STATE/tag"; echo 'InkFlow 1.2.3' > "$GH_STATE/name"; echo true > "$GH_STATE/draft"; cp "$repo/build/public-release-notes.md" "$GH_STATE/body"; echo wrong > "$GH_STATE/assets/InkFlow-1.2.3-7-arm64.dmg"; run_fail; [[ $(cat "$GH_STATE/assets/InkFlow-1.2.3-7-arm64.dmg") == wrong ]]
echo 'PASS: mismatched existing assets are never clobbered'

setup_fixture release-conflict false; mkdir -p "$GH_STATE/assets"; touch "$GH_STATE/exists"; echo v9.9.9 > "$GH_STATE/tag"; echo 'InkFlow 1.2.3' > "$GH_STATE/name"; echo true > "$GH_STATE/draft"; cp "$repo/build/public-release-notes.md" "$GH_STATE/body"; run_fail
echo 'PASS: conflicting Release metadata stops'

setup_fixture tag-conflict false; git -C "$repo" tag -a v1.2.3 -m conflict 'v1.2.2^{}'; run_fail; [[ $(git -C "$repo" rev-parse 'v1.2.3^{}') != $(git -C "$repo" rev-parse HEAD) ]]
echo 'PASS: conflicting local tag is never moved'

setup_fixture main-conflict false
git clone -q -b main "$bare" "$base/diverge"; git -C "$base/diverge" config user.name Fixture; git -C "$base/diverge" config user.email fixture@example.invalid; echo diverged >> "$base/diverge/README.md"; git -C "$base/diverge" add README.md; git -C "$base/diverge" commit -qm diverged; git -C "$base/diverge" push -q origin main
diverged=$(git -C "$base/diverge" rev-parse HEAD); run_fail; [[ $(git --git-dir="$bare" rev-parse refs/heads/main) == "$diverged" ]]
echo 'PASS: divergent remote main stops without force update'

setup_fixture remote-tag-conflict false
git clone -q -b main "$bare" "$base/tagger"; git -C "$base/tagger" config user.name Fixture; git -C "$base/tagger" config user.email fixture@example.invalid; git -C "$base/tagger" tag -a v1.2.3 -m conflict 'v1.2.2^{}'; git -C "$base/tagger" push -q origin v1.2.3; run_fail
[[ $(git --git-dir="$bare" rev-parse 'refs/tags/v1.2.3^{}') != $(git -C "$repo" rev-parse HEAD) ]]
echo 'PASS: conflicting remote annotated tag is never moved'

setup_fixture retained-lock false; echo 424242 > "$release/runner.lock"; run_fail; [[ $(cat "$release/runner.lock") == 424242 && ! -s "$EVENTS" ]]
echo 'PASS: pre-existing runner lock is retained and blocks all effects'

setup_fixture partial-assets true; run_fail; rm "$GH_STATE/assets/SHA256SUMS"; run_fail
[[ $(grep -c '^upload:InkFlow-1.2.3-7-arm64.dmg$' "$SIDE_EFFECTS") == 1 && $(grep -c '^upload:SHA256SUMS$' "$SIDE_EFFECTS") == 2 ]]
echo 'PASS: partial matching assets upload only the missing byte set'

setup_fixture published false; run_ok; effects=$(shasum -a 256 "$SIDE_EFFECTS" | awk '{print $1}'); run_ok; [[ $(cat "$GH_STATE/draft") == false && $(shasum -a 256 "$SIDE_EFFECTS" | awk '{print $1}') == "$effects" ]]
echo 'PASS: already-published identical release succeeds'
echo 'PASS: release runner fixture'
