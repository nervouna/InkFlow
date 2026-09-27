#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/test-groups.sh
source macOS/scripts/test-timing.sh
report_successful_engine_stderr() {
  awk '
    $0 == "WARNING: Logging before InitGoogleLogging() is written to STDERR" { next }
    /modules\.cc:[0-9]+\] registering components from module '\''lua'\''\.$/ { next }
    /modules\.cc:[0-9]+\] rime\.lua info: rime\.lua should be either in the rime user data directory or in the rime shared data directory$/ { next }
    /grammar_module\.cc:[0-9]+\] registering components from module '\''grammar'\''\.$/ { next }
    { print }
  ' "$1" >&2
}
if [[ $# == 1 && $1 == --help ]]; then
  echo 'Usage: test.sh [all | GROUP ...]'
  echo 'Parents: quality ai engine dictionary-updates'
  echo "Units: ${test_all_units[*]}"
  echo 'No arguments runs all non-GUI units once in canonical order.'
  exit 0
fi
expand_test_groups "$@"
if $test_full_suite && [[ -n "${INKFLOW_TEST_PRIORITY:-}" ]]; then
  read -r -a priority_groups <<< "$INKFLOW_TEST_PRIORITY"
  prioritize_test_units "${priority_groups[@]}"
fi
if test_units_need_app; then
  [[ -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]] || { echo 'Run build.sh first.' >&2; exit 1; }
fi
needs_shared=false
needs_dependencies=false
for unit in "${test_units[@]}"; do
  case "$unit" in shared-core|quality-capture-query|ai-headless|deployment|engine-*|controller|voice-controller) needs_shared=true ;; esac
  case "$unit" in preparation|runner|workflow|installer-core) ;; *) needs_dependencies=true ;; esac
done
if $needs_shared || $needs_dependencies; then macOS/scripts/dependencies.sh; fi
if $needs_shared; then bash macOS/scripts/prepare-rime.sh build/test-shared; fi
source macOS/scripts/swift-test.sh
parallel_pids=()
current_foreground_pid=''
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-units.XXXXXX")
shared_core_status_file="$scratch/shared-core.status"
publish_shared_core_status() {
  local status=$1 temporary="$shared_core_status_file.${BASHPID:-$$}"
  printf '%s\n' "$status" > "$temporary"
  mv "$temporary" "$shared_core_status_file"
}
cleanup_done=false
cleanup_runner() {
  local exit_code=$1 signal_name=$2 pid
  if $cleanup_done; then exit "$exit_code"; fi
  cleanup_done=true
  trap - EXIT INT TERM
  if [[ -n "$current_foreground_pid" ]] && kill -0 "$current_foreground_pid" 2>/dev/null; then
    kill "-$signal_name" -- "-$current_foreground_pid" 2>/dev/null || \
      kill "-$signal_name" "$current_foreground_pid" 2>/dev/null || true
  fi
  if ((${#parallel_pids[@]} > 0)); then
    for pid in "${parallel_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "-$signal_name" -- "-$pid" 2>/dev/null || kill "-$signal_name" "$pid" 2>/dev/null || true
      fi
    done
    [[ -z "$current_foreground_pid" ]] || wait "$current_foreground_pid" 2>/dev/null || true
    for pid in "${parallel_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  elif [[ -n "$current_foreground_pid" ]]; then
    wait "$current_foreground_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
  exit "$exit_code"
}
trap 'cleanup_runner "$?" TERM' EXIT
trap 'cleanup_runner 130 INT' INT
trap 'cleanup_runner 143 TERM' TERM
remaining=("${test_units[@]}")
engine_built=false
run_test_unit() {
  case "$unit" in
    shared-core)
      if bash Core/scripts/check-boundaries.sh && {
        if $test_full_suite; then bash Core/scripts/test.sh "$PWD/build/test-shared" --skip-covered-units
        else bash Core/scripts/test.sh "$PWD/build/test-shared"
        fi
      }; then core_status=0; else core_status=$?; fi
      if $test_full_suite; then publish_shared_core_status "$core_status"; fi
      return "$core_status" ;;
    quality-capture-query)
      bash macOS/scripts/test-quality-capture.sh --prepared "$PWD/build/test-shared"
      bash macOS/scripts/test-quality-query.sh --require-engine ;;
    apple-voice) bash macOS/scripts/test-apple-voice.sh ;;
    voice-session) bash macOS/scripts/test-voice-session.sh ;;
    ai-credentials) bash macOS/scripts/test-ai-credentials.sh ;;
    ai-transport) bash macOS/scripts/test-ai-suggestions.sh ;;
    ai-statistics)
      bash macOS/scripts/test-ai-statistics.sh
      bash macOS/scripts/test-ai-statistics-query.sh ;;
    preparation) bash macOS/scripts/test-prepare-rime.sh ;;
    deployment)
      build_swift_test deployment-tests build/deployment-tests
      build/deployment-tests "$PWD/build/test-shared" "$PWD"/build/deps/rime-easy-en-*/easy_en.dict.yaml ;;
    engine-*)
      if ! $engine_built; then build_swift_test engine-tests build/engine-tests; engine_built=true; fi
      mkdir -p "$scratch/$unit"
      engine_stderr="$scratch/$unit.stderr"
      if build/engine-tests "$PWD/build/test-shared" "$scratch/$unit" "--${unit#engine-}" 2>"$engine_stderr"; then
        report_successful_engine_stderr "$engine_stderr"
      else
        status=$?
        cat "$engine_stderr" >&2
        exit "$status"
      fi ;;
    controller)
      build_swift_test controller-tests build/controller-tests
      mkdir -p "$scratch/controller"
      build/controller-tests "$PWD/build/test-shared" "$scratch/controller" ;;
    settings)
      build_swift_test settings-tests build/settings-tests
      build/settings-tests ;;
    dictionary-source|dictionary-store|dictionary-worker)
      bash macOS/scripts/test-dictionary-updates.sh "--${unit#dictionary-}" ;;
    dictionary-activation)
      bash macOS/scripts/test-dictionary-activation.sh
      bash macOS/scripts/test-serving-startup.sh
      if $test_full_suite; then
        while [[ ! -f "$shared_core_status_file" ]]; do sleep 0.05; done
        read -r core_status < "$shared_core_status_file"
        [[ $core_status == 0 ]] || return "$core_status"
        bash Core/scripts/test-dictionaries.sh "$PWD/build/test-shared" --preparation-only
      fi ;;
    runner)
      env -u INKFLOW_TEST_EVIDENCE_DIR bash macOS/scripts/test-test-runner.sh
      env -u INKFLOW_TEST_EVIDENCE_DIR bash macOS/scripts/test-test-affected.sh ;;
    workflow) env -u INKFLOW_TEST_EVIDENCE_DIR bash macOS/scripts/test-workflow.sh ;;
    *) bash "macOS/scripts/test-$unit.sh" ;;
  esac
}
run_test_unit_isolated() (
  set -e
  run_test_unit
)
run_serial_unit_tracked() {
  local output=$1 tracked_status
  # A background job with monitor mode gets an owned process group while the
  # immediate wait preserves the existing serial execution semantics.
  set -m
  (run_test_unit_isolated > "$output" 2>&1) &
  current_foreground_pid=$!
  set +m
  wait "$current_foreground_pid"
  tracked_status=$?
  current_foreground_pid=''
  return "$tracked_status"
}

# Only these full-suite units are allowed to overlap. Their SwiftPM products are
# built serially first; execution owns separate temp/user roots and treats the
# app and shared Rime resources as read-only inputs.
parallel_units=(ai-learning dictionary-worker dictionary-activation)
parallel_began_ms=()
parallel_prepare_ms=()
parallel_prepare_logs=()
parallel_run_logs=()
parallel_status_files=()
parallel_collected=()
parallel_enabled=false
parallel_index() {
  local candidate index
  for ((index = 0; index < ${#parallel_units[@]}; index++)); do
    candidate=${parallel_units[$index]}
    [[ "$candidate" != "$1" ]] || { echo "$index"; return 0; }
  done
  return 1
}
prepare_parallel_units() {
  local began prepare_log unit_began unit_duration prepare_status unit_log
  began=$(inkflow_test_timing_now)
  for unit in "${parallel_units[@]}"; do
    prepare_log="$scratch/$unit.prepare.log"
    : > "$prepare_log"
    unit_began=$(inkflow_test_timing_now)
    set +e
    case "$unit" in
      ai-learning)
        build_swift_test ai-pronunciation-tests build/ai-pronunciation-tests >> "$prepare_log" 2>&1
        prepare_status=$?
        if [[ $prepare_status == 0 ]]; then
          build_swift_test ai-adoption-learning-tests build/ai-adoption-learning-tests >> "$prepare_log" 2>&1
          prepare_status=$?
        fi ;;
      dictionary-worker)
        build_swift_test dictionary-worker-fixture build/dictionary-worker-fixture >> "$prepare_log" 2>&1
        prepare_status=$?
        if [[ $prepare_status == 0 ]]; then
          build_swift_test dictionary-update-tests build/dictionary-update-tests >> "$prepare_log" 2>&1
          prepare_status=$?
        fi ;;
      dictionary-activation)
        build_swift_test dictionary-activation-tests build/dictionary-activation-tests >> "$prepare_log" 2>&1
        prepare_status=$?
        if [[ $prepare_status == 0 ]]; then
          build_swift_test serving-startup-tests build/serving-startup-tests >> "$prepare_log" 2>&1
          prepare_status=$?
        fi ;;
    esac
    set -e
    unit_duration=$(($(inkflow_test_timing_now) - unit_began))
    printf 'TIMING\tscope=test-runner\tstage=parallel-prebuild-%s\tduration_milliseconds=%s\n' \
      "$unit" "$unit_duration" >> "$prepare_log"
    if [[ $prepare_status != 0 ]]; then
      cat "$prepare_log"
      echo "END test unit: $unit (FAIL, $((unit_duration / 1000))s)"
      if [[ -n "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]]; then
        unit_log="$INKFLOW_TEST_EVIDENCE_DIR/$unit.log"
        cp "$prepare_log" "$unit_log"
        printf '%s\tFAIL\t%s\t%s\t%s\n' \
          "$unit" "$((unit_duration / 1000))" "$unit_log" "$unit_duration" >> "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
      fi
      echo "FAIL test unit: $unit prebuild (exit $prepare_status)" >&2
      echo "Not executed: ${remaining[*]:-none}" >&2
      exit "$prepare_status"
    fi
    parallel_prepare_ms+=("$unit_duration")
    parallel_prepare_logs+=("$prepare_log")
  done
  inkflow_test_timing_report test-runner parallel-prebuild "$began"
}
start_parallel_units() {
  local index scheduled_unit run_log status_file
  # Monitor mode gives each background wrapper its own process group. Cleanup
  # can then terminate the wrapper and every test subprocess it currently owns.
  set -m
  for ((index = 0; index < ${#parallel_units[@]}; index++)); do
    scheduled_unit=${parallel_units[$index]}
    run_log="$scratch/$scheduled_unit.run.log"
    status_file="$scratch/$scheduled_unit.status"
    parallel_run_logs+=("$run_log")
    parallel_status_files+=("$status_file")
    parallel_began_ms+=("$(inkflow_test_timing_now)")
    parallel_collected+=(false)
    echo "BEGIN test unit: $scheduled_unit (parallel)"
    (
      unit=$scheduled_unit
      set +e
      INKFLOW_SWIFT_TEST_PREBUILT=1 INKFLOW_TEST_DEPENDENCIES_PREPARED=1 \
        run_test_unit_isolated > "$run_log" 2>&1
      parallel_status=$?
      printf '%s\t%s\n' "$parallel_status" "$(inkflow_test_timing_now)" > "$status_file"
      exit 0
    ) &
    parallel_pids+=("$!")
  done
  set +m
}
collect_parallel_unit() {
  local index=$1 scheduled_unit completed_ms duration_ms duration result unit_log status
  scheduled_unit=${parallel_units[$index]}
  wait "${parallel_pids[$index]}"
  IFS=$'\t' read -r status completed_ms < "${parallel_status_files[$index]}"
  duration_ms=$((${parallel_prepare_ms[$index]} + completed_ms - ${parallel_began_ms[$index]}))
  duration=$((duration_ms / 1000))
  if [[ $status == 0 ]]; then result=PASS; else result=FAIL; fi
  cat "${parallel_prepare_logs[$index]}" "${parallel_run_logs[$index]}"
  echo "END test unit: $scheduled_unit ($result, ${duration}s)"
  if [[ -n "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]]; then
    unit_log="$INKFLOW_TEST_EVIDENCE_DIR/$scheduled_unit.log"
    cat "${parallel_prepare_logs[$index]}" "${parallel_run_logs[$index]}" > "$unit_log"
    printf '%s\t%s\t%s\t%s\t%s\n' "$scheduled_unit" "$result" "$duration" "$unit_log" "$duration_ms" >> "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
  fi
  parallel_collected[$index]=true
  collected_status=$status
}
collect_unreported_parallel_units() {
  local index
  for ((index = 0; index < ${#parallel_units[@]}; index++)); do
    [[ "${parallel_collected[$index]}" == true ]] || collect_parallel_unit "$index"
  done
}
remove_started_parallel_from_remaining() {
  local candidate scheduled_unit retained=()
  for candidate in "${remaining[@]}"; do
    scheduled_unit=false
    parallel_index "$candidate" >/dev/null && scheduled_unit=true
    $scheduled_unit || retained+=("$candidate")
  done
  remaining=("${retained[@]}")
}
report_failure() {
  local failed_status=$1 failed_unit=$unit
  if $parallel_enabled; then
    if [[ ! -f "$shared_core_status_file" ]]; then publish_shared_core_status "$failed_status"; fi
    collect_unreported_parallel_units
    remove_started_parallel_from_remaining
  fi
  echo "FAIL test unit: $failed_unit (exit $failed_status)" >&2
  echo "Not executed: ${remaining[*]:-none}" >&2
  exit "$failed_status"
}
if [[ -n "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$INKFLOW_TEST_EVIDENCE_DIR"
  printf 'unit\tstatus\tduration_seconds\tlog\tduration_milliseconds\n' > "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
fi
if $test_full_suite && [[ "${INKFLOW_TEST_DISABLE_PARALLEL:-}" != 1 ]]; then
  prepare_parallel_units
  parallel_enabled=true
  start_parallel_units
fi
for unit in "${test_units[@]}"; do
  remaining=("${remaining[@]:1}")
  if $parallel_enabled && parallel_slot=$(parallel_index "$unit"); then
    collect_parallel_unit "$parallel_slot"
    status=$collected_status
    [[ $status == 0 ]] || report_failure "$status"
    continue
  fi
  began_ms=$(inkflow_test_timing_now)
  echo "BEGIN test unit: $unit"
  unit_log="${INKFLOW_TEST_EVIDENCE_DIR:-}/$unit.log"
  if [[ -n "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]]; then serial_output=$unit_log
  else serial_output="$scratch/$unit.log"
  fi
  set +e
  run_serial_unit_tracked "$serial_output"
  status=$?
  set -e
  cat "$serial_output"
  duration_ms=$(($(inkflow_test_timing_now) - began_ms))
  duration=$((duration_ms / 1000))
  if [[ $status == 0 ]]; then result=PASS; else result=FAIL; fi
  echo "END test unit: $unit ($result, ${duration}s)"
  if [[ -n "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$unit" "$result" "$duration" "$unit_log" "$duration_ms" >> "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
  fi
  [[ $status == 0 ]] || report_failure "$status"
done
