#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

all_units=(shared-core quality-baseline quality-identity quality-store quality-timing quality-metadata quality-capture-query
  voice-session apple-voice voice-lexicon voice-controller ai-credentials ai-transport ai-runtime ai-learning ai-headless
  preparation dictionary-generator deployment engine-basic engine-options engine-english engine-context engine-custom-phrases
  controller settings personal-data dictionary-source dictionary-store dictionary-worker dictionary-activation
  startup-diagnostics local-diagnostics diagnostic-archive termination installer-core workflow)

usage() {
  echo 'Usage: test.sh quick | all | UNIT|GROUP ...'
  echo 'Groups: quick engine quality ai voice dictionary'
  echo "Units: ${all_units[*]}"
}
[[ $# -gt 0 ]] || { usage; exit 2; }
[[ $1 != --help ]] || { usage; exit 0; }

full=false
requested=' '
for arg in "$@"; do
  case "$arg" in
    all) full=true; requested+="${all_units[*]} " ;;
    quick) requested+='engine-basic engine-options engine-english engine-context controller settings quality-store ai-runtime ' ;;
    engine) requested+='engine-basic engine-options engine-english engine-context engine-custom-phrases ' ;;
    quality) requested+='quality-identity quality-store quality-timing quality-metadata quality-capture-query ' ;;
    ai) requested+='ai-credentials ai-transport ai-runtime ai-learning ai-headless ' ;;
    voice) requested+='voice-session apple-voice voice-lexicon voice-controller ' ;;
    dictionary) requested+='dictionary-source dictionary-store dictionary-worker dictionary-activation ' ;;
    *) [[ " ${all_units[*]} " == *" $arg "* ]] || { echo "Unknown test unit: $arg" >&2; usage >&2; exit 2; }
       requested+="$arg " ;;
  esac
done
units=()
for unit in "${all_units[@]}"; do [[ "$requested" != *" $unit "* ]] || units+=("$unit"); done

needs_app=false needs_shared=false needs_dependencies=false
for unit in "${units[@]}"; do
  case "$unit" in dictionary-worker|dictionary-activation|personal-data|termination) needs_app=true ;; esac
  case "$unit" in shared-core|quality-capture-query|ai-headless|deployment|engine-*|controller|voice-controller) needs_shared=true ;; esac
  case "$unit" in preparation|workflow|installer-core) ;; *) needs_dependencies=true ;; esac
done
if $needs_app && [[ ! -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]]; then
  echo 'Run build.sh first.' >&2; exit 1
fi
if $needs_dependencies || $needs_shared; then macOS/scripts/dependencies.sh; fi
if $needs_shared; then bash macOS/scripts/prepare-rime.sh build/test-shared; fi
source macOS/scripts/swift-test.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-units.XXXXXX")
trap 'for pid in ${background_pids[@]+"${background_pids[@]}"}; do kill -- "-$pid" 2>/dev/null || true; done; rm -rf "$scratch"' EXIT

# Drop librime's routine startup chatter from passing engine runs.
filter_engine_stderr() {
  grep -vE 'Logging before InitGoogleLogging|registering components from module|rime\.lua should be either' "$1" >&2 || true
}

engine_built=false
run_unit() {
  case "$1" in
    quality-baseline) bash Core/scripts/test-quality-baseline.sh ;;
    shared-core)
      bash Core/scripts/check-boundaries.sh
      if $full; then bash Core/scripts/test.sh "$PWD/build/test-shared" --skip-covered-units
      else bash Core/scripts/test.sh "$PWD/build/test-shared"
      fi ;;
    quality-capture-query)
      bash macOS/scripts/test-quality-capture.sh --prepared "$PWD/build/test-shared"
      bash macOS/scripts/test-quality-query.sh --require-engine ;;
    ai-transport) bash macOS/scripts/test-ai-suggestions.sh ;;
    preparation) bash macOS/scripts/test-prepare-rime.sh ;;
    deployment)
      build_swift_test deployment-tests build/deployment-tests
      build/deployment-tests "$PWD/build/test-shared" "$PWD"/build/deps/rime-easy-en-*/easy_en.dict.yaml ;;
    engine-*)
      if ! $engine_built; then build_swift_test engine-tests build/engine-tests; engine_built=true; fi
      mkdir -p "$scratch/$1"
      build/engine-tests "$PWD/build/test-shared" "$scratch/$1" "--${1#engine-}" 2>"$scratch/$1.stderr" || {
        local status=$?; cat "$scratch/$1.stderr" >&2; return "$status"; }
      filter_engine_stderr "$scratch/$1.stderr" ;;
    controller)
      build_swift_test controller-tests build/controller-tests
      mkdir -p "$scratch/controller"
      build/controller-tests "$PWD/build/test-shared" "$scratch/controller" ;;
    settings)
      build_swift_test settings-tests build/settings-tests
      build/settings-tests ;;
    personal-data)
      build_swift_test personal-data-tests build/personal-data-tests
      build/personal-data-tests ;;
    dictionary-source|dictionary-store|dictionary-worker)
      bash macOS/scripts/test-dictionary-updates.sh "--${1#dictionary-}" ;;
    dictionary-activation)
      bash macOS/scripts/test-dictionary-activation.sh
      bash macOS/scripts/test-serving-startup.sh ;;
    core-preparation)
      # The full suite runs shared-core with --skip-covered-units; this covers the rest.
      bash Core/scripts/test-dictionaries.sh "$PWD/build/test-shared" --preparation-only ;;
    *) bash "macOS/scripts/test-$1.sh" ;;
  esac
}

# In the full suite, the two slowest units (about 6 min each) run in the background
# while everything else runs serially. Their binaries are built first.
background=() background_pids=()
if $full; then
  background=(ai-learning dictionary-activation)
  units=("${units[@]/ai-learning}"); units=("${units[@]/dictionary-activation}")
  units+=(core-preparation)
  for product in ai-pronunciation-tests ai-adoption-learning-tests dictionary-activation-tests serving-startup-tests; do
    build_swift_test "$product" "build/$product"
  done
  set -m  # own process group per job, so a failure can stop the whole job
  for unit in "${background[@]}"; do
    echo "BEGIN $unit (background)"
    ( (set -e; export INKFLOW_TEST_PREBUILT=1; run_unit "$unit") > "$scratch/$unit.log" 2>&1
      echo $? > "$scratch/$unit.status" ) &
    background_pids+=($!)
  done
  set +m
fi

passed=()
for unit in "${units[@]}"; do
  [[ -n "$unit" ]] || continue
  echo "BEGIN $unit"
  began=$SECONDS
  # set -e only applies inside the subshell when it is not an if/|| condition.
  set +e
  (set -e; run_unit "$unit")
  status=$?
  set -e
  if [[ $status != 0 ]]; then
    echo "FAIL $unit ($((SECONDS - began))s)" >&2
    echo "Passed: ${passed[*]:-none}" >&2
    exit 1
  fi
  echo "END $unit ($((SECONDS - began))s)"
  passed+=("$unit")
done
wait
for unit in ${background[@]+"${background[@]}"}; do
  cat "$scratch/$unit.log"
  [[ $(cat "$scratch/$unit.status") == 0 ]] || { echo "FAIL $unit (background)" >&2; echo "Passed: ${passed[*]}" >&2; exit 1; }
  echo "END $unit (background)"
  passed+=("$unit")
done
echo "PASS ${#passed[@]} units: ${passed[*]}"
