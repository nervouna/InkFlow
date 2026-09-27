#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/test-groups.sh
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
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-units.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
remaining=("${test_units[@]}")
report_failure() {
  local status=$1
  echo "FAIL test unit: $unit (exit $status)" >&2
  echo "Not executed: ${remaining[*]:-none}" >&2
  exit "$status"
}
engine_built=false
run_test_unit() {
  case "$unit" in
    shared-core)
      bash Core/scripts/check-boundaries.sh
      if $test_full_suite; then bash Core/scripts/test.sh "$PWD/build/test-shared" --skip-ai-learning
      else bash Core/scripts/test.sh "$PWD/build/test-shared"
      fi ;;
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
      bash macOS/scripts/test-serving-startup.sh ;;
    runner)
      bash macOS/scripts/test-test-runner.sh
      bash macOS/scripts/test-test-affected.sh ;;
    workflow) bash macOS/scripts/test-workflow.sh ;;
    *) bash "macOS/scripts/test-$unit.sh" ;;
  esac
}
run_test_unit_isolated() (
  set -e
  run_test_unit
)
if [[ -n "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$INKFLOW_TEST_EVIDENCE_DIR"
  printf 'unit\tstatus\tduration_seconds\tlog\n' > "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
fi
for unit in "${test_units[@]}"; do
  remaining=("${remaining[@]:1}")
  began=$(date +%s)
  echo "BEGIN test unit: $unit"
  unit_log="${INKFLOW_TEST_EVIDENCE_DIR:-}/$unit.log"
  set +e
  if [[ -n "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]]; then
    run_test_unit_isolated 2>&1 | tee "$unit_log"
    status=${PIPESTATUS[0]}
  else
    run_test_unit_isolated
    status=$?
  fi
  set -e
  duration=$(($(date +%s) - began))
  if [[ $status == 0 ]]; then result=PASS; else result=FAIL; fi
  echo "END test unit: $unit ($result, ${duration}s)"
  if [[ -n "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$unit" "$result" "$duration" "$unit_log" >> "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
  fi
  [[ $status == 0 ]] || report_failure "$status"
done
