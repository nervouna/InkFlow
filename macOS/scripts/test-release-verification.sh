#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-verification.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
parent_evidence="$fixture/parent-evidence"
mkdir -p "$parent_evidence/gates"
printf 'immutable parent marker\n' > "$parent_evidence/marker"
printf '91\t12345\n' > "$parent_evidence/gates/core.status"
printf '92\t23456\n' > "$parent_evidence/gates/release-tools.status"
snapshot_parent_evidence() {
  find "$parent_evidence" -exec stat -f '%N|%HT|%z|%m' {} \; | LC_ALL=C sort
  find "$parent_evidence" -type f -exec shasum -a 256 {} \; | LC_ALL=C sort
}
parent_evidence_before=$(snapshot_parent_evidence)
export INKFLOW_RELEASE_EVIDENCE_DIR="$parent_evidence"
changed_file="$fixture/changed"
plan() { printf '%s\n' "$@" > "$changed_file"; bash macOS/scripts/release-verification.sh --plan-only --changed-paths "$changed_file"; }
expect() {
  local output=$1; shift
  for gate in "$@"; do grep -Fxq "$gate" <<< "$output" || { echo "Missing gate: $gate" >&2; exit 1; }; done
  ! grep -Eq 'gui|candidate-controller|^installer$' <<< "$output"
  [[ $(sort <<< "$output" | uniq -d | wc -l | tr -d ' ') == 0 ]]
}
reject() {
  local output=$1; shift
  for gate in "$@"; do ! grep -Fxq "$gate" <<< "$output" || { echo "Unexpected gate: $gate" >&2; exit 1; }; done
}
output=$(plan README.md AGENTS.md macOS/DEVELOPMENT.md)
expect "$output" core bundle-deep
reject "$output" manual-input manual-settings manual-install release-tools
output=$(plan macOS/Sources/SmartSettingsView.swift Core/Sources/InkFlowDomain/InputPreferences.swift)
expect "$output" core bundle-deep
reject "$output" manual-input manual-settings manual-install
for path in InputControllerCore InputControllerAI EngineAI AISuggestionPanel; do
  output=$(plan "macOS/Sources/$path.swift")
  expect "$output" core bundle-deep
  reject "$output" manual-input manual-settings manual-install
done
output=$(plan macOS/Installer/InstallerCoordinator.swift macOS/Shared/InputSourceManager.swift)
expect "$output" core bundle-deep manual-install
output=$(plan .agents/skills/inkflow-release/scripts/package.sh macOS/DeveloperID.entitlements)
expect "$output" core bundle-deep release-tools
for path in macOS/Info.plist Package.swift macOS/Sources/Unknown.swift; do
  output=$(plan "$path")
  expect "$output" core bundle-deep manual-install
  reject "$output" manual-input manual-settings
done
for path in StartupDiagnostics; do
  output=$(plan "macOS/Sources/$path.swift")
  expect "$output" core bundle-deep
  reject "$output" manual-input manual-settings manual-install
done
for path in macOS/Sources/AIContext.swift macOS/Sources/AISuggestionCoordinator.swift \
  Core/Sources/InkFlowDomain/DictionaryGenerator.swift Core/Sources/InkFlowDomain/DictionaryToolBootstrap.swift Core/Tools/DictionaryGeneratorTool/main.swift; do
  output=$(plan "$path")
  expect "$output" core bundle-deep
  reject "$output" manual-input manual-settings manual-install
done
for path in macOS/Tests/AIRuntimeTests.swift macOS/scripts/test-ai-runtime.sh \
  Core/Tests/DictionaryGeneratorTests/DictionaryGeneratorTests.swift macOS/scripts/build-dictionary-generator.sh macOS/scripts/test-dictionary-generator.sh; do
  output=$(plan "$path")
  expect "$output" core bundle-deep
  reject "$output" manual-input manual-settings manual-install
done
output=$(plan macOS/Tests/NativeTestSupport.m macOS/Tests/UnknownTests.swift)
expect "$output" core bundle-deep
reject "$output" manual-input manual-settings manual-install
# Run the actual dispatcher in clean linked fixtures, stubbing expensive commands.
git clone --quiet --shared "$PWD" "$fixture/repo"
cp macOS/scripts/release-verification.sh macOS/scripts/test-impact.sh macOS/scripts/test-groups.sh "$fixture/repo/macOS/scripts/"
mkdir -p "$fixture/repo/Core/Sources/InkFlowDomain"
cp Core/Sources/InkFlowDomain/InputPreferences.swift "$fixture/repo/Core/Sources/InkFlowDomain/"
export INKFLOW_RELEASE_LOG="$fixture/commands"
export INKFLOW_RELEASE_BARRIER="$fixture/barrier"
mkdir -p "$INKFLOW_RELEASE_BARRIER"
for name in build test check-bundle release-receipt; do
  cat > "$fixture/repo/macOS/scripts/$name.sh" <<'STUB'
#!/bin/bash
name=$(basename "$0" .sh)
echo "$name $*" >> "$INKFLOW_RELEASE_LOG"
if [[ "$name" == build ]]; then mkdir -p build; printf icon > build/AppIcon.icns; fi
if [[ "$name" == check-bundle && "${INKFLOW_VERIFY_REQUIRE_OVERLAP:-}" == 1 ]]; then
  [[ -e "$INKFLOW_RELEASE_BARRIER/core.done" && -e "$INKFLOW_RELEASE_BARRIER/release-tools.done" ]]
fi
if [[ "$name" == test ]]; then
  printf '%s\n' "$$" > "$INKFLOW_RELEASE_BARRIER/core.pid"
  trap 'touch "$INKFLOW_RELEASE_BARRIER/core.terminated"; exit 130' INT
  trap 'touch "$INKFLOW_RELEASE_BARRIER/core.terminated"; exit 143' TERM
  touch "$INKFLOW_RELEASE_BARRIER/core.ready"
  if [[ "${INKFLOW_VERIFY_CORE_HOLD:-}" == 1 ]]; then
    while :; do sleep 1; done
  fi
  if [[ "${INKFLOW_VERIFY_REQUIRE_OVERLAP:-}" == 1 ]]; then
    for _ in {1..500}; do [[ -e "$INKFLOW_RELEASE_BARRIER/release-tools.ready" ]] && break; sleep 0.01; done
    [[ -e "$INKFLOW_RELEASE_BARRIER/release-tools.ready" ]] || exit 71
  fi
  core_exit=${INKFLOW_VERIFY_CORE_EXIT:-0}
  [[ $core_exit != 0 ]] || touch "$INKFLOW_RELEASE_BARRIER/core.done"
  exit "$core_exit"
fi
STUB
done
cat > "$fixture/repo/macOS/scripts/swift-package.sh" <<'STUB'
build_swift_product() { printf installer > "$2"; echo "product $1" >> "$INKFLOW_RELEASE_LOG"; }
STUB
cat > "$fixture/repo/.agents/skills/inkflow-release/scripts/test.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ "$PWD" == "$INKFLOW_RELEASE_ISOLATED_ROOT" ]]
[[ "$PWD" != "$INKFLOW_RELEASE_CANDIDATE_ROOT" ]]
[[ "$HOME" == "$(dirname "$TMPDIR")/home" ]]
[[ "$CFFIXED_USER_HOME" == "$HOME" ]]
echo 'release-tools ' >> "$INKFLOW_RELEASE_LOG"
printf '%s\n' "$$" > "$INKFLOW_RELEASE_BARRIER/release-tools.pid"
trap 'touch "$INKFLOW_RELEASE_BARRIER/release-tools.terminated"; exit 130' INT
trap 'touch "$INKFLOW_RELEASE_BARRIER/release-tools.terminated"; exit 143' TERM
touch "$INKFLOW_RELEASE_BARRIER/release-tools.ready"
if [[ "${INKFLOW_VERIFY_RELEASE_HOLD:-}" == 1 ]]; then
  while :; do sleep 1; done
fi
if [[ "${INKFLOW_VERIFY_REQUIRE_OVERLAP:-}" == 1 ]]; then
  for _ in {1..500}; do [[ -e "$INKFLOW_RELEASE_BARRIER/core.ready" ]] && break; sleep 0.01; done
  [[ -e "$INKFLOW_RELEASE_BARRIER/core.ready" ]] || exit 72
fi
release_exit=${INKFLOW_VERIFY_RELEASE_EXIT:-0}
[[ $release_exit != 0 ]] || touch "$INKFLOW_RELEASE_BARRIER/release-tools.done"
exit "$release_exit"
STUB
chmod +x "$fixture/repo/macOS/scripts/"{build,test,check-bundle,release-receipt}.sh \
  "$fixture/repo/.agents/skills/inkflow-release/scripts/test.sh"
git -C "$fixture/repo" add macOS/scripts Core/Sources/InkFlowDomain/InputPreferences.swift .agents/skills/inkflow-release/scripts/test.sh
git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test: release dispatcher baseline'

# A Settings-only change does not start the release-tool fixture suite.
printf '\n' >> "$fixture/repo/Core/Sources/InkFlowDomain/InputPreferences.swift"
git -C "$fixture/repo" add Core/Sources/InkFlowDomain/InputPreferences.swift
git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test: settings-only release candidate'
git -C "$fixture/repo" worktree add --quiet --detach "$fixture/release-no-tools" HEAD
: > "$INKFLOW_RELEASE_LOG"
env -u INKFLOW_RELEASE_EVIDENCE_DIR \
  bash "$fixture/release-no-tools/macOS/scripts/release-verification.sh" --from HEAD~1 > "$fixture/output-no-tools"
[[ ! -e "$INKFLOW_RELEASE_BARRIER/release-tools.ready" ]]
[[ $(grep -Fxc 'release-tools ' "$INKFLOW_RELEASE_LOG" || true) == 0 ]]

# A release-workflow change runs release tools concurrently with the full suite.
printf '\n# release fixture selection\n' >> "$fixture/repo/.agents/skills/inkflow-release/scripts/test.sh"
git -C "$fixture/repo" add .agents/skills/inkflow-release/scripts/test.sh
git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test: release workflow candidate'
git -C "$fixture/repo" worktree add --quiet --detach "$fixture/release" HEAD
rm -f "$INKFLOW_RELEASE_BARRIER"/*
: > "$INKFLOW_RELEASE_LOG"
env -u INKFLOW_RELEASE_EVIDENCE_DIR INKFLOW_VERIFY_REQUIRE_OVERLAP=1 \
  bash "$fixture/release/macOS/scripts/release-verification.sh" --from HEAD~1 > "$fixture/output"
[[ $(grep -Fxc 'build ' "$INKFLOW_RELEASE_LOG") == 1 ]]
[[ $(grep -Fxc 'test all' "$INKFLOW_RELEASE_LOG") == 1 ]]
[[ $(grep -Fxc 'check-bundle --deep' "$INKFLOW_RELEASE_LOG") == 1 ]]
[[ $(grep -Fxc 'release-tools ' "$INKFLOW_RELEASE_LOG") == 1 ]]
grep -q '^Test priority: workflow$' "$fixture/output"
grep -q '^Release evidence: .*/build/release-verification-attempts/' "$fixture/output"
evidence_dir=$(sed -n 's/^Release evidence: //p' "$fixture/output")
[[ -f "$evidence_dir/release.log" && -d "$evidence_dir/test-units" ]]
[[ -f "$evidence_dir/gates/core.log" && -f "$evidence_dir/gates/core.status" ]]
[[ -f "$evidence_dir/gates/release-tools.log" && -f "$evidence_dir/gates/release-tools.status" ]]
grep -Eq $'^core\tPASS\t0\t[1-9][0-9]*\t.*/gates/core.log$' "$evidence_dir/gates/summary.tsv"
grep -Eq $'^release-tools\tPASS\t0\t[1-9][0-9]*\t.*/gates/release-tools.log$' "$evidence_dir/gates/summary.tsv"
! grep -Eq 'gui|native|keychain|--live|installer-core|test-workflow' "$INKFLOW_RELEASE_LOG"
grep -q 'PASS automated release verification' "$fixture/output"
! grep -q '^PASS release verification:' "$fixture/output"
! grep -q '^Manual acceptance pending: manual-\(input\|settings\):' "$fixture/output"
grep -q '^GUI interaction is preaccepted on entry;' "$fixture/output"

assert_stopped() {
  local name=$1 pid
  pid=$(cat "$INKFLOW_RELEASE_BARRIER/$name.pid")
  ! kill -0 "$pid" 2>/dev/null
  [[ -e "$INKFLOW_RELEASE_BARRIER/$name.terminated" ]]
}
# A core failure cancels and reaps release tools, preserving the core exit.
rm -f "$INKFLOW_RELEASE_BARRIER"/*
: > "$INKFLOW_RELEASE_LOG"
set +e
INKFLOW_VERIFY_CORE_EXIT=17 INKFLOW_VERIFY_RELEASE_HOLD=1 \
  env -u INKFLOW_RELEASE_EVIDENCE_DIR \
  bash "$fixture/release/macOS/scripts/release-verification.sh" --from HEAD~1 > "$fixture/core-failure.output" 2>&1
status=$?
set -e
[[ $status == 17 ]]
assert_stopped release-tools
[[ $(grep -Fxc 'check-bundle --deep' "$INKFLOW_RELEASE_LOG" || true) == 0 ]]

# A release-tools failure cancels and reaps the full suite, preserving its exit.
rm -f "$INKFLOW_RELEASE_BARRIER"/*
: > "$INKFLOW_RELEASE_LOG"
set +e
INKFLOW_VERIFY_CORE_HOLD=1 INKFLOW_VERIFY_RELEASE_EXIT=19 \
  env -u INKFLOW_RELEASE_EVIDENCE_DIR \
  bash "$fixture/release/macOS/scripts/release-verification.sh" --from HEAD~1 > "$fixture/release-failure.output" 2>&1
status=$?
set -e
[[ $status == 19 ]]
assert_stopped core
[[ $(grep -Fxc 'check-bundle --deep' "$INKFLOW_RELEASE_LOG" || true) == 0 ]]

# TERM cancels and reaps both process groups and removes the isolated fixture root.
rm -f "$INKFLOW_RELEASE_BARRIER"/*
release_tmp="$fixture/release-tmp"
mkdir "$release_tmp"
env -u INKFLOW_RELEASE_EVIDENCE_DIR TMPDIR="$release_tmp" \
  INKFLOW_VERIFY_CORE_HOLD=1 INKFLOW_VERIFY_RELEASE_HOLD=1 \
  bash "$fixture/release/macOS/scripts/release-verification.sh" --from HEAD~1 > "$fixture/term.output" 2>&1 &
dispatcher_pid=$!
for _ in {1..500}; do
  [[ -e "$INKFLOW_RELEASE_BARRIER/core.ready" && -e "$INKFLOW_RELEASE_BARRIER/release-tools.ready" ]] && break
  sleep 0.01
done
[[ -e "$INKFLOW_RELEASE_BARRIER/core.ready" && -e "$INKFLOW_RELEASE_BARRIER/release-tools.ready" ]]
kill -TERM "$dispatcher_pid"
set +e
wait "$dispatcher_pid"
status=$?
set -e
[[ $status == 143 ]]
assert_stopped core
assert_stopped release-tools
[[ -z $(find "$release_tmp" \( -name 'inkflow-release-gates.*' -o -name 'inkflow-release-tests.*' \) -print -quit) ]]
[[ $(find "$fixture/release-no-tools/build/release-verification-attempts" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') == 1 ]]
[[ $(find "$fixture/release/build/release-verification-attempts" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') == 4 ]]
[[ "$(snapshot_parent_evidence)" == "$parent_evidence_before" ]]
# Real version-only release changes retain build checks without a typing requirement.
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 900002' "$fixture/repo/macOS/Info.plist"
git -C "$fixture/repo" add macOS/Info.plist
git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test: version-only release'
output=$(bash "$fixture/repo/macOS/scripts/release-verification.sh" --plan-only --from HEAD~1)
expect "$output" core bundle-deep release-tools
reject "$output" manual-input manual-settings manual-install
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 99.0' "$fixture/repo/macOS/Info.plist"
git -C "$fixture/repo" add macOS/Info.plist
git -C "$fixture/repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm 'test: compatibility change'
output=$(bash "$fixture/repo/macOS/scripts/release-verification.sh" --plan-only --from HEAD~1)
expect "$output" core bundle-deep manual-install
reject "$output" manual-input manual-settings
echo 'PASS release verification: one core/deep run, preaccepted GUI policy, change-based installation handoff'
