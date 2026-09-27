#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

usage() {
  echo 'Usage: release-verification.sh [--from STABLE_TAG] [--plan-only --changed-paths FILE]'
}
from=""
plan_only=false
changed_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; from=$2; shift 2 ;;
    --plan-only) plan_only=true; shift ;;
    --changed-paths) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; changed_file=$2; shift 2 ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

source macOS/scripts/test-groups.sh
source macOS/scripts/test-impact.sh
impact_reset
classify() {
  if [[ -z "$changed_file" && -n "$from" ]]; then impact_classify_git "$1" "$from"
  else impact_classify "$1"
  fi
}

if [[ -n "$changed_file" ]]; then
  [[ -f "$changed_file" ]] || { echo 'Changed-path file does not exist.' >&2; exit 2; }
  while IFS= read -r file || [[ -n "$file" ]]; do [[ -z "$file" ]] || classify "$file"; done < "$changed_file"
else
  if [[ -z "$from" ]]; then
    while IFS= read -r tag; do
      if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then from=$tag; break; fi
    done < <(git tag --merged HEAD --sort=-version:refname)
  fi
  [[ -n "$from" ]] || { echo 'No stable release tag is an ancestor of HEAD.' >&2; exit 1; }
  from=$(git rev-parse --verify --end-of-options "$from^{commit}" 2>/dev/null) || { echo 'Unknown release baseline.' >&2; exit 2; }
  git merge-base --is-ancestor "$from" HEAD || { echo "$from is not an ancestor of HEAD." >&2; exit 1; }
  while IFS= read -r -d '' file; do classify "$file"; done < <(git diff --no-renames --name-only -z "$from..HEAD")
fi

gates=(core bundle-deep)
if $impact_release_tools; then gates+=(release-tools); fi
automated_gates=("${gates[@]}")
release_manual=()
if [[ ${#impact_manual[@]} -gt 0 ]]; then
  for item in "${impact_manual[@]}"; do
    [[ "$item" != manual-install ]] || release_manual+=("$item")
  done
fi
if [[ ${#release_manual[@]} -gt 0 ]]; then gates+=("${release_manual[@]}"); fi
if [[ "$plan_only" == true ]]; then printf '%s\n' "${gates[@]}"; exit 0; fi
[[ -z "$changed_file" ]] || { echo '--changed-paths is only valid with --plan-only.' >&2; exit 2; }
[[ -z $(git status --porcelain --untracked-files=normal) ]] || { echo 'Release verification requires a clean commit.' >&2; exit 1; }
git_dir=$(cd "$(git rev-parse --git-dir)" && pwd -P)
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
[[ "$git_dir" != "$common_dir" ]] || { echo 'Release verification must run in an isolated linked worktree.' >&2; exit 1; }
release_commit=$(git rev-parse HEAD)
if [[ -z "${INKFLOW_RELEASE_EVIDENCE_DIR:-}" ]]; then
  attempt_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  export INKFLOW_RELEASE_EVIDENCE_DIR="$PWD/build/release-verification-attempts/$attempt_id"
  mkdir -p "$INKFLOW_RELEASE_EVIDENCE_DIR/test-units"
  outer_verification_pid=''
  outer_cleanup_done=false
  cleanup_outer_verification() {
    local exit_code=$1 signal_name=$2
    if $outer_cleanup_done; then exit "$exit_code"; fi
    outer_cleanup_done=true
    trap - EXIT INT TERM
    if [[ -n "$outer_verification_pid" ]] && kill -0 "$outer_verification_pid" 2>/dev/null; then
      kill "-$signal_name" -- "-$outer_verification_pid" 2>/dev/null || \
        kill "-$signal_name" "$outer_verification_pid" 2>/dev/null || true
      wait "$outer_verification_pid" 2>/dev/null || true
    fi
    exit "$exit_code"
  }
  trap 'cleanup_outer_verification "$?" TERM' EXIT
  trap 'cleanup_outer_verification 130 INT' INT
  trap 'cleanup_outer_verification 143 TERM' TERM
  set -m
  set +e
  (
    set +e
    bash "$0" --from "$from" 2>&1 | tee "$INKFLOW_RELEASE_EVIDENCE_DIR/release.log"
    exit "${PIPESTATUS[0]}"
  ) &
  outer_verification_pid=$!
  set +m
  wait "$outer_verification_pid"
  status=$?
  outer_verification_pid=''
  exit "$status"
fi
release_evidence_dir="$INKFLOW_RELEASE_EVIDENCE_DIR"
mkdir -p "$release_evidence_dir/test-units"
export INKFLOW_TEST_EVIDENCE_DIR="$release_evidence_dir/test-units"
test_priority=""
if [[ ${#impact_groups[@]} -gt 0 ]]; then
  expand_test_groups "${impact_groups[@]}"
  test_priority="${test_units[*]}"
fi

echo "Release verification range: $from..HEAD"
echo "Release evidence: $release_evidence_dir"
echo "Test priority: ${test_priority:-canonical}"
bash macOS/scripts/build.sh
if $impact_release_tools; then
  source macOS/scripts/test-timing.sh
  gate_dir="$release_evidence_dir/gates"
  mkdir -p "$gate_dir"
  printf 'gate\tresult\texit_status\tduration_milliseconds\tlog\n' > "$gate_dir/summary.tsv"
  release_tools_runtime=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-release-gates.XXXXXX")
  core_gate_pid=''
  release_tools_gate_pid=''
  gate_cleanup_done=false
  stop_gate_group() {
    local pid=$1 signal_name=$2
    [[ -n "$pid" ]] || return 0
    if kill -0 "$pid" 2>/dev/null; then
      kill "-$signal_name" -- "-$pid" 2>/dev/null || kill "-$signal_name" "$pid" 2>/dev/null || true
    fi
  }
  cleanup_release_gates() {
    local exit_code=$1 signal_name=$2
    if $gate_cleanup_done; then exit "$exit_code"; fi
    gate_cleanup_done=true
    trap - EXIT INT TERM
    stop_gate_group "$core_gate_pid" "$signal_name"
    stop_gate_group "$release_tools_gate_pid" "$signal_name"
    [[ -z "$core_gate_pid" ]] || wait "$core_gate_pid" 2>/dev/null || true
    [[ -z "$release_tools_gate_pid" ]] || wait "$release_tools_gate_pid" 2>/dev/null || true
    rm -rf "$release_tools_runtime"
    exit "$exit_code"
  }
  trap 'cleanup_release_gates "$?" TERM' EXIT
  trap 'cleanup_release_gates 130 INT' INT
  trap 'cleanup_release_gates 143 TERM' TERM
  mkdir -p "$release_tools_runtime/home" "$release_tools_runtime/tmp"
  HOME="$release_tools_runtime/home" CFFIXED_USER_HOME="$release_tools_runtime/home" \
    git clone --quiet --shared --no-hardlinks "$PWD" "$release_tools_runtime/repo"
  sparkle_signer=build/swiftpm/artifacts/sparkle/Sparkle/bin/sign_update
  if [[ -x "$sparkle_signer" ]]; then
    mkdir -p "$release_tools_runtime/repo/$(dirname "$sparkle_signer")"
    cp "$sparkle_signer" "$release_tools_runtime/repo/$sparkle_signer"
  fi

  core_gate_began=$(inkflow_test_timing_now)
  release_tools_gate_began=$(inkflow_test_timing_now)
  candidate_root=$PWD
  echo 'BEGIN automated gate: core (parallel)'
  echo 'BEGIN automated gate: release-tools (parallel, isolated fixture)'
  set -m
  (
    set +e
    INKFLOW_TEST_PRIORITY="$test_priority" bash macOS/scripts/test.sh all > "$gate_dir/core.log" 2>&1
    gate_status=$?
    gate_ended=$(inkflow_test_timing_now)
    printf '%s\t%s\n' "$gate_status" "$((gate_ended - core_gate_began))" > "$gate_dir/core.status.tmp"
    mv "$gate_dir/core.status.tmp" "$gate_dir/core.status"
    exit 0
  ) &
  core_gate_pid=$!
  (
    set +e
    cd "$release_tools_runtime/repo" || exit 1
    env -u INKFLOW_SIGN_IDENTITY -u INKFLOW_NOTARY_PROFILE -u INKFLOW_NOTARY_AUTH \
      -u INKFLOW_NOTARY_KEY_FILE -u INKFLOW_NOTARY_KEY_ID -u INKFLOW_NOTARY_KEY_TYPE \
      -u INKFLOW_NOTARY_ISSUER -u INKFLOW_RELEASE_CONFIG \
      HOME="$release_tools_runtime/home" CFFIXED_USER_HOME="$release_tools_runtime/home" \
      TMPDIR="$release_tools_runtime/tmp" \
      INKFLOW_RELEASE_ISOLATED_ROOT="$release_tools_runtime/repo" \
      INKFLOW_RELEASE_CANDIDATE_ROOT="$candidate_root" \
      bash .agents/skills/inkflow-release/scripts/test.sh \
      > "$gate_dir/release-tools.log" 2>&1
    gate_status=$?
    gate_ended=$(inkflow_test_timing_now)
    printf '%s\t%s\n' "$gate_status" "$((gate_ended - release_tools_gate_began))" > "$gate_dir/release-tools.status.tmp"
    mv "$gate_dir/release-tools.status.tmp" "$gate_dir/release-tools.status"
    exit 0
  ) &
  release_tools_gate_pid=$!
  set +m

  # Bash 3.2 has no wait -n. Atomic status files let either failing gate stop
  # the other promptly without interleaving their deterministic output logs.
  while :; do
    if [[ -f "$gate_dir/core.status" ]]; then
      IFS=$'\t' read -r observed_status _ < "$gate_dir/core.status"
      if [[ $observed_status != 0 ]]; then stop_gate_group "$release_tools_gate_pid" TERM; break; fi
    fi
    if [[ -f "$gate_dir/release-tools.status" ]]; then
      IFS=$'\t' read -r observed_status _ < "$gate_dir/release-tools.status"
      if [[ $observed_status != 0 ]]; then stop_gate_group "$core_gate_pid" TERM; break; fi
    fi
    [[ -f "$gate_dir/core.status" && -f "$gate_dir/release-tools.status" ]] && break
    sleep 0.1
  done

  set +e
  wait "$core_gate_pid"
  core_wait_status=$?
  wait "$release_tools_gate_pid"
  release_tools_wait_status=$?
  set -e
  core_gate_pid=''
  release_tools_gate_pid=''
  if [[ ! -f "$gate_dir/core.status" ]]; then
    gate_ended=$(inkflow_test_timing_now)
    printf '%s\t%s\n' "$core_wait_status" "$((gate_ended - core_gate_began))" > "$gate_dir/core.status"
  fi
  if [[ ! -f "$gate_dir/release-tools.status" ]]; then
    gate_ended=$(inkflow_test_timing_now)
    printf '%s\t%s\n' "$release_tools_wait_status" "$((gate_ended - release_tools_gate_began))" > "$gate_dir/release-tools.status"
  fi
  IFS=$'\t' read -r core_status core_duration_ms < "$gate_dir/core.status"
  IFS=$'\t' read -r release_tools_status release_tools_duration_ms < "$gate_dir/release-tools.status"
  if [[ $core_status == 0 ]]; then core_result=PASS; else core_result=FAIL; fi
  if [[ $release_tools_status == 0 ]]; then release_tools_result=PASS; else release_tools_result=FAIL; fi
  cat "$gate_dir/core.log"
  echo "END automated gate: core ($core_result, ${core_duration_ms}ms, exit $core_status)"
  cat "$gate_dir/release-tools.log"
  echo "END automated gate: release-tools ($release_tools_result, ${release_tools_duration_ms}ms, exit $release_tools_status)"
  printf 'core\t%s\t%s\t%s\t%s\n' "$core_result" "$core_status" "$core_duration_ms" "$gate_dir/core.log" >> "$gate_dir/summary.tsv"
  printf 'release-tools\t%s\t%s\t%s\t%s\n' "$release_tools_result" "$release_tools_status" \
    "$release_tools_duration_ms" "$gate_dir/release-tools.log" >> "$gate_dir/summary.tsv"
  rm -rf "$release_tools_runtime"
  release_tools_runtime=''
  trap - EXIT INT TERM

  if [[ $core_status != 0 || $release_tools_status != 0 ]]; then
    # Prefer an originating non-signal failure over the peer's cancellation.
    failure_status=$core_status
    if [[ $failure_status == 0 || $failure_status == 130 || $failure_status == 143 ]]; then
      failure_status=$release_tools_status
    fi
    [[ $failure_status != 0 ]] || failure_status=1
    exit "$failure_status"
  fi
else
  INKFLOW_TEST_PRIORITY="$test_priority" bash macOS/scripts/test.sh all
fi
bash macOS/scripts/check-bundle.sh --deep

[[ "$(git rev-parse HEAD)" == "$release_commit" && -z $(git status --porcelain --untracked-files=normal) ]] || {
  echo 'Release source changed during verification.' >&2; exit 1;
}
source macOS/scripts/swift-package.sh
receipt_dir=build/release-verification
mkdir -p "$receipt_dir"
build_swift_product InkFlowInstaller "$receipt_dir/InkFlowInstaller" release
[[ -f build/AppIcon.icns && ! -L build/AppIcon.icns ]] || { echo 'Verified app build did not produce AppIcon.icns.' >&2; exit 1; }
cp build/AppIcon.icns "$receipt_dir/AppIcon.icns"
[[ "$(git rev-parse HEAD)" == "$release_commit" && -z $(git status --porcelain --untracked-files=normal) ]] || {
  echo 'Release source changed while building the verified installer.' >&2; exit 1;
}
bash macOS/scripts/release-receipt.sh create "$receipt_dir/InkFlowInstaller" "$receipt_dir/AppIcon.icns" "$receipt_dir/installer.plist"
printf 'PASS automated release verification: %s\n' "${automated_gates[*]}"
if [[ ${#release_manual[@]} -gt 0 ]]; then
  for item in "${release_manual[@]}"; do
    printf 'Manual acceptance pending: %s: %s\n' "$item" "$(impact_manual_description "$item")"
  done
fi
echo 'GUI interaction is preaccepted on entry; installation acceptance remains separate and is required before publication when selected.'
