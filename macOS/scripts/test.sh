#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/test-groups.sh
if [[ $# == 1 && $1 == --help ]]; then
  echo 'Usage: test.sh [all | GROUP ...]'
  echo 'Parents: quality ai engine dictionary-updates'
  echo "Units: ${test_all_units[*]}"
  echo 'No arguments runs all non-GUI units once in canonical order.'
  exit 0
fi
expand_test_groups "$@"
if test_units_need_app; then
  [[ -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]] || { echo 'Run build.sh first.' >&2; exit 1; }
fi
needs_shared=false
needs_dependencies=false
for unit in "${test_units[@]}"; do
  case "$unit" in quality-capture-query|ai-headless|deployment|engine-*|controller|voice-controller) needs_shared=true ;; esac
  case "$unit" in preparation|runner|workflow|installer-core) ;; *) needs_dependencies=true ;; esac
done
if $needs_shared || $needs_dependencies; then macOS/scripts/dependencies.sh; fi
if $needs_shared; then bash macOS/scripts/prepare-rime.sh build/test-shared; fi
source macOS/scripts/swift-test.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-units.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
remaining=("${test_units[@]}")
report_failure() {
  local status=$?
  echo "FAIL test unit: $unit (exit $status)" >&2
  echo "Not executed: ${remaining[*]:-none}" >&2
  exit "$status"
}
trap report_failure ERR
set -E
engine_built=false
for unit in "${test_units[@]}"; do
  remaining=("${remaining[@]:1}")
  case "$unit" in
    quality-capture-query)
      bash macOS/scripts/test-quality-capture.sh --prepared "$PWD/build/test-shared"
      bash macOS/scripts/test-quality-query.sh --require-engine ;;
    apple-voice) bash macOS/scripts/test-apple-voice.sh ;;
    voice-session) bash macOS/scripts/test-voice-session.sh ;;
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
      build/engine-tests "$PWD/build/test-shared" "$scratch/$unit" "--${unit#engine-}" ;;
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
done
