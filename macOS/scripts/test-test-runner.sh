#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-runner.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/macOS/scripts" "$fixture/build/test-shared"
touch "$fixture/build/test-shared/inkflow_pinyin.schema.yaml"
cp macOS/scripts/test.sh macOS/scripts/test-groups.sh macOS/scripts/test-timing.sh "$fixture/macOS/scripts/"
export INKFLOW_RUNNER_LOG="$fixture/commands.log"
for script in dependencies prepare-rime test-quality-identity test-quality-store test-quality-timing test-quality-metadata \
  test-prepare-rime test-dictionary-generator test-quality-capture test-quality-query \
  test-dictionary-updates test-dictionary-activation test-serving-startup test-termination test-installer-core \
  test-voice-session test-apple-voice test-voice-lexicon test-voice-controller test-ai-credentials test-ai-suggestions test-ai-statistics test-ai-statistics-query test-ai-runtime test-ai-learning test-ai-headless \
  test-startup-diagnostics test-local-diagnostics test-diagnostic-archive test-test-runner test-test-affected test-workflow; do
  cat > "$fixture/macOS/scripts/$script.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
name=$(basename "$0" .sh)
args=${*//${PWD}/REPO}
echo "$name $args" >> "$INKFLOW_RUNNER_LOG"
if [[ -n "${INKFLOW_RUNNER_PARALLEL_DIR:-}" ]]; then
  parallel_key=''
  case "$name $*" in
    'test-quality-metadata --prebuilt') parallel_key=quality-metadata ;;
    'test-ai-headless --prebuilt') parallel_key=ai-headless ;;
    'test-ai-learning '*) parallel_key=ai-learning ;;
    'test-dictionary-updates --worker') parallel_key=dictionary-worker ;;
    'test-dictionary-activation '*) parallel_key=dictionary-activation ;;
  esac
  if [[ -n "$parallel_key" ]]; then
    [[ "${INKFLOW_SWIFT_TEST_PREBUILT:-}" == 1 ]] || exit 41
    [[ "$parallel_key" != dictionary-worker || "${INKFLOW_TEST_DEPENDENCIES_PREPARED:-}" == 1 ]] || exit 42
    touch "$INKFLOW_RUNNER_PARALLEL_DIR/$parallel_key"
    for _ in {1..200}; do
      [[ $(find "$INKFLOW_RUNNER_PARALLEL_DIR" -type f | wc -l | tr -d ' ') == 5 ]] && break
      sleep 0.01
    done
    [[ $(find "$INKFLOW_RUNNER_PARALLEL_DIR" -type f | wc -l | tr -d ' ') == 5 ]] || exit 43
    if [[ -n "${INKFLOW_RUNNER_HOLD_DIR:-}" ]]; then
      printf '%s\n' "$$" > "$INKFLOW_RUNNER_HOLD_DIR/$parallel_key.pid"
      trap 'touch "$INKFLOW_RUNNER_HOLD_DIR/'"$parallel_key"'.terminated"; exit 130' INT
      trap 'touch "$INKFLOW_RUNNER_HOLD_DIR/'"$parallel_key"'.terminated"; exit 143' TERM
      touch "$INKFLOW_RUNNER_HOLD_DIR/$parallel_key.ready"
      while :; do sleep 1; done
    fi
  fi
fi
if [[ "$name" == test-quality-identity && -n "${INKFLOW_RUNNER_SERIAL_HOLD_DIR:-}" ]]; then
  serial_key=serial-quality-identity
  printf '%s\n' "$$" > "$INKFLOW_RUNNER_SERIAL_HOLD_DIR/$serial_key.pid"
  trap 'touch "$INKFLOW_RUNNER_SERIAL_HOLD_DIR/serial-quality-identity.terminated"; exit 130' INT
  trap 'touch "$INKFLOW_RUNNER_SERIAL_HOLD_DIR/serial-quality-identity.terminated"; exit 143' TERM
  touch "$INKFLOW_RUNNER_SERIAL_HOLD_DIR/$serial_key.ready"
  while :; do sleep 1; done
fi
case "$name" in
  test-test-runner|test-test-affected|test-workflow)
    [[ -z "${INKFLOW_TEST_EVIDENCE_DIR:-}" ]] || {
      echo "nested fixture inherited parent evidence: $name" >&2
      exit 31
    }
    echo "fixture output: $name" ;;
esac
if [[ "$name" == "${INKFLOW_RUNNER_FAIL:-}" ]]; then
  echo "fixture failure diagnostic: $name" >&2
  exit 17
fi
STUB
  chmod +x "$fixture/macOS/scripts/$script.sh"
done
mkdir -p "$fixture/Core/scripts"
for script in check-boundaries test test-dictionaries; do
  cat > "$fixture/Core/scripts/$script.sh" <<'STUB'
#!/bin/bash
name="core-$(basename "$0" .sh)"
args=${*//${PWD}/REPO}
echo "$name $args" >> "$INKFLOW_RUNNER_LOG"
[[ "$name" != "${INKFLOW_RUNNER_FAIL:-}" ]] || exit 17
STUB
done
cat > "$fixture/macOS/scripts/swift-test.sh" <<'STUB'
build_swift_test() {
  if [[ "${INKFLOW_SWIFT_TEST_PREBUILT:-}" == 1 ]]; then
    [[ -x "$2" ]] || return 44
    return 0
  fi
  echo "build $1" >> "$INKFLOW_RUNNER_LOG"
  if [[ "$1" == "${INKFLOW_SWIFT_BUILD_FAIL:-}" ]]; then
    echo "prebuild diagnostic: $1" >&2
    return 37
  fi
  cat > "$2" <<'PROGRAM'
#!/bin/bash
name=$(basename "$0")
echo "run $name ${3:-}" >> "$INKFLOW_RUNNER_LOG"
if [[ "$name" == "${INKFLOW_SWIFT_FAIL:-}" ]]; then
  echo 'WARNING: Logging before InitGoogleLogging() is written to STDERR' >&2
  echo 'engine failure diagnostic' >&2
  exit 29
fi
if [[ "$name" == engine-tests && "${INKFLOW_ENGINE_STDERR:-}" == known ]]; then
  echo 'WARNING: Logging before InitGoogleLogging() is written to STDERR' >&2
  echo "I20260913 12:38:08.481146 0x1 modules.cc:96] registering components from module 'lua'." >&2
  echo 'I20260913 12:38:08.482306 0x1 modules.cc:87] rime.lua info: rime.lua should be either in the rime user data directory or in the rime shared data directory' >&2
  echo "I20260913 12:38:09.221615 0x1 grammar_module.cc:15] registering components from module 'grammar'." >&2
  echo 'unexpected engine warning' >&2
fi
case "$name" in engine-tests|controller-tests)
  [[ -d "$2" && ! -e "$2/used" ]] || exit 23
  touch "$2/used"
  echo "$2" >> "$INKFLOW_RUNNER_LOG.paths" ;;
esac
PROGRAM
  chmod +x "$2"
}
build_swift_product() {
  echo "build-product $1 $3" >> "$INKFLOW_RUNNER_LOG"
  if [[ "$1" == "${INKFLOW_SWIFT_BUILD_FAIL:-}" ]]; then
    echo "product prebuild diagnostic: $1" >&2
    return 38
  fi
  mkdir -p "$(dirname "$2")"
  cp /usr/bin/true "$2"
}
STUB
run() {
  : > "$INKFLOW_RUNNER_LOG"
  : > "$INKFLOW_RUNNER_LOG.paths"
  bash "$fixture/macOS/scripts/test.sh" "$@" > "$fixture/output.log" 2>&1
}
expect() { printf '%s\n' "$@" > "$fixture/expected.log"; diff -u "$fixture/expected.log" "$INKFLOW_RUNNER_LOG"; }
run shared-core shared-core
expect 'dependencies ' 'prepare-rime build/test-shared' 'core-check-boundaries ' 'core-test REPO/build/test-shared'
export INKFLOW_RUNNER_FAIL=core-check-boundaries
if run shared-core settings; then exit 1; else status=$?; fi
[[ $status == 17 ]]
expect 'dependencies ' 'prepare-rime build/test-shared' 'core-check-boundaries '
grep -q 'Not executed: settings' "$fixture/output.log"
unset INKFLOW_RUNNER_FAIL
run ai-runtime ai-runtime
expect 'dependencies ' 'test-ai-runtime '
run settings
expect 'dependencies ' 'build settings-tests' 'run settings-tests '
run controller engine-options controller
expect 'dependencies ' 'prepare-rime build/test-shared' 'build engine-tests' 'run engine-tests --options' 'build controller-tests' 'run controller-tests '
while IFS= read -r path; do [[ ! -e "$path" ]]; done < "$INKFLOW_RUNNER_LOG.paths"
run engine engine-options
[[ $(grep -c '^build engine-tests$' "$INKFLOW_RUNNER_LOG") == 1 ]]
[[ $(grep -c '^run engine-tests ' "$INKFLOW_RUNNER_LOG") == 5 ]]
export INKFLOW_ENGINE_STDERR=known
run engine-english
! grep -q 'InitGoogleLogging\|modules.cc\|grammar_module.cc' "$fixture/output.log"
grep -q 'unexpected engine warning' "$fixture/output.log"
unset INKFLOW_ENGINE_STDERR
export INKFLOW_SWIFT_FAIL=engine-tests
if run engine-english; then exit 1; else status=$?; fi
[[ $status == 29 ]]
grep -q 'InitGoogleLogging' "$fixture/output.log"
grep -q 'engine failure diagnostic' "$fixture/output.log"
unset INKFLOW_SWIFT_FAIL
run ai-learning
expect 'dependencies ' 'test-ai-learning '
run voice-lexicon voice-lexicon
expect 'dependencies ' 'test-voice-lexicon '
run voice-controller
expect 'dependencies ' 'prepare-rime build/test-shared' 'test-voice-controller '
run quality-capture-query
expect 'dependencies ' 'prepare-rime build/test-shared' 'test-quality-capture --prepared REPO/build/test-shared' 'test-quality-query --require-engine'
run dictionary-source dictionary-store
expect 'dependencies ' 'test-dictionary-updates --source' 'test-dictionary-updates --store'
run preparation
expect 'test-prepare-rime '
run --help
[[ ! -s "$INKFLOW_RUNNER_LOG" ]]
for invalid in --unit unknown ''; do
  if run settings "$invalid"; then exit 1; else status=$?; fi
  [[ $status == 2 && ! -s "$INKFLOW_RUNNER_LOG" ]]
done
if run all settings; then exit 1; else status=$?; fi
[[ $status == 2 && ! -s "$INKFLOW_RUNNER_LOG" ]]
for group in all dictionary-worker dictionary-updates dictionary-activation termination; do
  if run "$group"; then echo 'FAIL: missing worker accepted' >&2; exit 1; fi
  [[ ! -s "$INKFLOW_RUNNER_LOG" ]]
  grep -q 'Run build.sh first.' "$fixture/output.log"
done
mkdir -p "$fixture/build/InkFlow.app/Contents/MacOS"
touch "$fixture/build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"
chmod +x "$fixture/build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"
run personal-data
expect 'dependencies ' 'build personal-data-tests' 'run personal-data-tests '
export INKFLOW_RUNNER_PARALLEL_DIR="$fixture/parallel"
mkdir "$INKFLOW_RUNNER_PARALLEL_DIR"
run
cp "$INKFLOW_RUNNER_LOG" "$fixture/default.log"
[[ $(find "$INKFLOW_RUNNER_PARALLEL_DIR" -type f | wc -l | tr -d ' ') == 5 ]]
rm -f "$INKFLOW_RUNNER_PARALLEL_DIR"/*
run all
LC_ALL=C sort "$fixture/default.log" > "$fixture/default.sorted"
LC_ALL=C sort "$INKFLOW_RUNNER_LOG" > "$fixture/commands.sorted"
cmp "$fixture/default.sorted" "$fixture/commands.sorted"
grep -Fxq 'core-test REPO/build/test-shared --skip-covered-units' "$INKFLOW_RUNNER_LOG"
[[ $(grep -Fxc 'core-test REPO/build/test-shared --skip-covered-units' "$INKFLOW_RUNNER_LOG") == 1 ]]
grep -Fxq 'core-test-dictionaries REPO/build/test-shared --preparation-only' "$INKFLOW_RUNNER_LOG"
[[ $(grep -Fxc 'core-test-dictionaries REPO/build/test-shared --preparation-only' "$INKFLOW_RUNNER_LOG") == 1 ]]
[[ $(grep -Fxc 'build-product quality-build-metadata release' "$INKFLOW_RUNNER_LOG") == 1 ]]
[[ $(grep -Fxc 'test-quality-metadata --prebuilt' "$INKFLOW_RUNNER_LOG") == 1 ]]
[[ $(grep -Fxc 'build ai-headless-tests' "$INKFLOW_RUNNER_LOG") == 1 ]]
[[ $(grep -Fxc 'test-ai-headless --prebuilt' "$INKFLOW_RUNNER_LOG") == 1 ]]
for required in core-check-boundaries core-test test-quality-identity test-quality-store test-quality-timing test-quality-metadata \
  test-quality-capture test-quality-query test-voice-session test-apple-voice test-voice-lexicon test-voice-controller test-ai-credentials test-ai-suggestions test-ai-runtime test-ai-statistics \
  test-ai-statistics-query test-ai-learning test-ai-headless test-prepare-rime test-dictionary-generator \
  test-dictionary-activation test-serving-startup test-startup-diagnostics test-local-diagnostics test-diagnostic-archive test-termination \
  test-installer-core test-test-runner test-test-affected test-workflow; do
  [[ $(grep -c "^$required " "$INKFLOW_RUNNER_LOG") == 1 ]]
done
for required in 'run deployment-tests ' 'run engine-tests --basic' 'run engine-tests --options' \
  'run engine-tests --english' 'run engine-tests --context' 'run engine-tests --custom-phrases' \
  'run controller-tests ' 'run settings-tests ' 'run personal-data-tests ' \
  'test-dictionary-updates --source' 'test-dictionary-updates --store' 'test-dictionary-updates --worker'; do
  [[ $(grep -Fxc "$required" "$INKFLOW_RUNNER_LOG") == 1 ]]
done
[[ $(grep -c '^prepare-rime ' "$INKFLOW_RUNNER_LOG") == 1 ]]
! grep -E 'gui|keychain|--live' "$INKFLOW_RUNNER_LOG"
unset INKFLOW_RUNNER_PARALLEL_DIR
export INKFLOW_TEST_PRIORITY='quality-store ai-runtime'
run all
quality_line=$(grep -n '^test-quality-store ' "$INKFLOW_RUNNER_LOG" | cut -d: -f1)
core_line=$(grep -n '^core-check-boundaries ' "$INKFLOW_RUNNER_LOG" | cut -d: -f1)
runtime_line=$(grep -n '^test-ai-runtime ' "$INKFLOW_RUNNER_LOG" | cut -d: -f1)
[[ $quality_line -lt $core_line && $runtime_line -lt $core_line ]]
unset INKFLOW_TEST_PRIORITY
run_priority_dependency_case() {
  local mode=$1 dependency_pid status core_end activation_end
  : > "$INKFLOW_RUNNER_LOG"
  : > "$INKFLOW_RUNNER_LOG.paths"
  rm -rf "$fixture/priority-dependency-parallel"
  export INKFLOW_TEST_PRIORITY=dictionary-activation
  if [[ $mode == parallel ]]; then
    export INKFLOW_RUNNER_PARALLEL_DIR="$fixture/priority-dependency-parallel"
    mkdir "$INKFLOW_RUNNER_PARALLEL_DIR"
    unset INKFLOW_TEST_DISABLE_PARALLEL
  else
    unset INKFLOW_RUNNER_PARALLEL_DIR
    export INKFLOW_TEST_DISABLE_PARALLEL=1
  fi
  bash "$fixture/macOS/scripts/test.sh" all > "$fixture/output.log" 2>&1 &
  dependency_pid=$!
  for _ in {1..500}; do
    kill -0 "$dependency_pid" 2>/dev/null || break
    sleep 0.01
  done
  if kill -0 "$dependency_pid" 2>/dev/null; then
    kill -TERM "$dependency_pid" 2>/dev/null || true
    wait "$dependency_pid" 2>/dev/null || true
    echo "FAIL: priority dependency deadlocked in $mode mode" >&2
    exit 1
  fi
  set +e
  wait "$dependency_pid"
  status=$?
  set -e
  [[ $status == 0 ]]
  [[ $(grep -Fxc 'core-test-dictionaries REPO/build/test-shared --preparation-only' "$INKFLOW_RUNNER_LOG") == 1 ]]
  core_end=$(grep -n '^END test unit: shared-core ' "$fixture/output.log" | cut -d: -f1)
  activation_end=$(grep -n '^END test unit: dictionary-activation ' "$fixture/output.log" | cut -d: -f1)
  [[ $core_end -lt $activation_end ]]
  unset INKFLOW_TEST_PRIORITY INKFLOW_TEST_DISABLE_PARALLEL INKFLOW_RUNNER_PARALLEL_DIR
}
run_priority_dependency_case parallel
run_priority_dependency_case serial
# A failed embedded Core unit must release the parallel dictionary unit instead
# of leaving it waiting forever for Core SwiftPM ownership.
: > "$INKFLOW_RUNNER_LOG"
: > "$INKFLOW_RUNNER_LOG.paths"
export INKFLOW_RUNNER_PARALLEL_DIR="$fixture/core-failure-parallel"
mkdir "$INKFLOW_RUNNER_PARALLEL_DIR"
export INKFLOW_RUNNER_FAIL=core-test
export INKFLOW_TEST_PRIORITY=dictionary-activation
bash "$fixture/macOS/scripts/test.sh" all > "$fixture/output.log" 2>&1 &
core_failure_pid=$!
for _ in {1..500}; do
  kill -0 "$core_failure_pid" 2>/dev/null || break
  sleep 0.01
done
if kill -0 "$core_failure_pid" 2>/dev/null; then
  kill -TERM "$core_failure_pid" 2>/dev/null || true
  wait "$core_failure_pid" 2>/dev/null || true
  echo 'FAIL: shared-core failure deadlocked dictionary-activation' >&2
  exit 1
fi
set +e
wait "$core_failure_pid"
status=$?
set -e
[[ $status == 17 ]]
! grep -q '^core-test-dictionaries ' "$INKFLOW_RUNNER_LOG"
unset INKFLOW_RUNNER_FAIL INKFLOW_RUNNER_PARALLEL_DIR INKFLOW_TEST_PRIORITY
export INKFLOW_TEST_EVIDENCE_DIR="$fixture/evidence"
run ai-runtime
grep -Fxq $'unit\tstatus\tduration_seconds\tlog\tduration_milliseconds' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -Eq $'^ai-runtime\tPASS\t[0-9]+\t.*/ai-runtime.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
awk -F '\t' 'NR == 2 { exit !($4 ~ /\/ai-runtime\.log$/ && $5 ~ /^[0-9]+$/ && $5 > 0) }' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
[[ -f "$INKFLOW_TEST_EVIDENCE_DIR/ai-runtime.log" ]]
run runner workflow
grep -Fxq $'unit\tstatus\tduration_seconds\tlog\tduration_milliseconds' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
[[ $(wc -l < "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv" | tr -d ' ') == 3 ]]
grep -Eq $'^runner\tPASS\t[0-9]+\t.*/runner.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -Eq $'^workflow\tPASS\t[0-9]+\t.*/workflow.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
awk -F '\t' '
  NR > 1 {
    expected = "/" $1 ".log$"
    if ($4 !~ expected || $5 !~ /^[0-9]+$/ || $5 <= 0) exit 1
  }
' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -Fxq 'fixture output: test-test-runner' "$INKFLOW_TEST_EVIDENCE_DIR/runner.log"
grep -Fxq 'fixture output: test-test-affected' "$INKFLOW_TEST_EVIDENCE_DIR/runner.log"
grep -Fxq 'fixture output: test-workflow' "$INKFLOW_TEST_EVIDENCE_DIR/workflow.log"
unset INKFLOW_TEST_EVIDENCE_DIR
export INKFLOW_TEST_EVIDENCE_DIR="$fixture/prebuild-failure-evidence"
export INKFLOW_SWIFT_BUILD_FAIL=ai-pronunciation-tests
if run all; then exit 1; else status=$?; fi
[[ $status == 37 ]]
grep -q 'prebuild diagnostic: ai-pronunciation-tests' "$fixture/output.log"
grep -Eq $'^ai-learning\tFAIL\t[0-9]+\t.*/ai-learning.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -q 'prebuild diagnostic: ai-pronunciation-tests' "$INKFLOW_TEST_EVIDENCE_DIR/ai-learning.log"
! grep -q ' (parallel)' "$fixture/output.log"
unset INKFLOW_SWIFT_BUILD_FAIL INKFLOW_TEST_EVIDENCE_DIR
export INKFLOW_TEST_EVIDENCE_DIR="$fixture/quality-metadata-prebuild-failure-evidence"
export INKFLOW_SWIFT_BUILD_FAIL=quality-build-metadata
if run all; then exit 1; else status=$?; fi
[[ $status == 38 ]]
grep -q 'product prebuild diagnostic: quality-build-metadata' "$fixture/output.log"
grep -Eq $'^quality-metadata\tFAIL\t[0-9]+\t.*/quality-metadata.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -q 'product prebuild diagnostic: quality-build-metadata' "$INKFLOW_TEST_EVIDENCE_DIR/quality-metadata.log"
! grep -q ' (parallel)' "$fixture/output.log"
unset INKFLOW_SWIFT_BUILD_FAIL INKFLOW_TEST_EVIDENCE_DIR
export INKFLOW_RUNNER_FAIL=test-ai-runtime
if run ai-runtime settings; then exit 1; else status=$?; fi
[[ $status == 17 ]]
expect 'dependencies ' 'test-ai-runtime '
grep -q 'Not executed: settings' "$fixture/output.log"
unset INKFLOW_RUNNER_FAIL
export INKFLOW_TEST_EVIDENCE_DIR="$fixture/failure-evidence"
export INKFLOW_RUNNER_PARALLEL_DIR="$fixture/failure-parallel"
mkdir "$INKFLOW_RUNNER_PARALLEL_DIR"
export INKFLOW_RUNNER_FAIL=test-ai-learning
if run all; then exit 1; else status=$?; fi
[[ $status == 17 ]]
grep -Eq $'^ai-learning\tFAIL\t[0-9]+\t.*/ai-learning.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -Eq $'^ai-headless\tPASS\t[0-9]+\t.*/ai-headless.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -Eq $'^dictionary-worker\tPASS\t[0-9]+\t.*/dictionary-worker.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -Eq $'^dictionary-activation\tPASS\t[0-9]+\t.*/dictionary-activation.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -q '^Not executed: preparation' "$fixture/output.log"
! grep -q 'Not executed: .*ai-headless\|Not executed: .*dictionary-worker\|Not executed: .*dictionary-activation' "$fixture/output.log"
unset INKFLOW_RUNNER_FAIL INKFLOW_RUNNER_PARALLEL_DIR INKFLOW_TEST_EVIDENCE_DIR
export INKFLOW_TEST_EVIDENCE_DIR="$fixture/quality-metadata-failure-evidence"
export INKFLOW_RUNNER_PARALLEL_DIR="$fixture/quality-metadata-failure-parallel"
mkdir "$INKFLOW_RUNNER_PARALLEL_DIR"
export INKFLOW_RUNNER_FAIL=test-quality-metadata
if run all; then exit 1; else status=$?; fi
[[ $status == 17 ]]
grep -Eq $'^quality-metadata\tFAIL\t[0-9]+\t.*/quality-metadata.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -Fxq 'fixture failure diagnostic: test-quality-metadata' "$INKFLOW_TEST_EVIDENCE_DIR/quality-metadata.log"
[[ $(grep -Fxc 'test-quality-metadata --prebuilt' "$INKFLOW_RUNNER_LOG") == 1 ]]
unset INKFLOW_RUNNER_FAIL INKFLOW_RUNNER_PARALLEL_DIR INKFLOW_TEST_EVIDENCE_DIR
export INKFLOW_TEST_EVIDENCE_DIR="$fixture/ai-headless-failure-evidence"
export INKFLOW_RUNNER_PARALLEL_DIR="$fixture/ai-headless-failure-parallel"
mkdir "$INKFLOW_RUNNER_PARALLEL_DIR"
export INKFLOW_RUNNER_FAIL=test-ai-headless
if run all; then exit 1; else status=$?; fi
[[ $status == 17 ]]
grep -Eq $'^ai-headless\tFAIL\t[0-9]+\t.*/ai-headless.log\t[1-9][0-9]*$' "$INKFLOW_TEST_EVIDENCE_DIR/summary.tsv"
grep -Fxq 'fixture failure diagnostic: test-ai-headless' "$INKFLOW_TEST_EVIDENCE_DIR/ai-headless.log"
[[ $(grep -Fxc 'test-ai-headless --prebuilt' "$INKFLOW_RUNNER_LOG") == 1 ]]
unset INKFLOW_RUNNER_FAIL INKFLOW_RUNNER_PARALLEL_DIR INKFLOW_TEST_EVIDENCE_DIR
signal_tmp="$fixture/signal-tmp"
signal_parallel="$fixture/signal-parallel"
signal_hold="$fixture/signal-hold"
mkdir "$signal_tmp" "$signal_parallel" "$signal_hold"
export INKFLOW_RUNNER_PARALLEL_DIR="$signal_parallel"
export INKFLOW_RUNNER_HOLD_DIR="$signal_hold"
export INKFLOW_RUNNER_SERIAL_HOLD_DIR="$signal_hold"
TMPDIR="$signal_tmp" bash "$fixture/macOS/scripts/test.sh" all > "$fixture/signal-output.log" 2>&1 &
runner_pid=$!
for _ in {1..500}; do
  [[ $(find "$signal_hold" -name '*.ready' -type f | wc -l | tr -d ' ') == 6 ]] && break
  sleep 0.01
done
[[ $(find "$signal_hold" -name '*.ready' -type f | wc -l | tr -d ' ') == 6 ]]
signal_began=$(bash -c 'source macOS/scripts/test-timing.sh; inkflow_test_timing_now')
kill -TERM "$runner_pid"
set +e
wait "$runner_pid"
runner_status=$?
set -e
[[ $runner_status == 143 ]]
signal_duration=$(( $(bash -c 'source macOS/scripts/test-timing.sh; inkflow_test_timing_now') - signal_began ))
[[ $signal_duration -lt 2000 ]]
for pid_file in "$signal_hold"/*.pid; do
  held_pid=$(cat "$pid_file")
  ! kill -0 "$held_pid" 2>/dev/null
done
[[ $(find "$signal_hold" -name '*.terminated' -type f | wc -l | tr -d ' ') == 6 ]]
[[ -z $(find "$signal_tmp" -name 'inkflow-test-units.*' -type d -print -quit) ]]
! grep -Eq 'No such file|status.*(missing|not found)|unbound variable' "$fixture/signal-output.log"
echo "PASS runner TERM cleanup: serial plus parallel process groups reaped in ${signal_duration} ms"
unset INKFLOW_RUNNER_PARALLEL_DIR INKFLOW_RUNNER_HOLD_DIR INKFLOW_RUNNER_SERIAL_HOLD_DIR
export INKFLOW_TEST_DISABLE_PARALLEL=1
run all
! grep -q 'parallel-prebuild\| (parallel)' "$fixture/output.log"
[[ $(grep -Fxc 'test-quality-metadata ' "$INKFLOW_RUNNER_LOG") == 1 ]]
! grep -q '^test-quality-metadata --prebuilt$' "$INKFLOW_RUNNER_LOG"
[[ $(grep -Fxc 'test-ai-headless ' "$INKFLOW_RUNNER_LOG") == 1 ]]
! grep -q '^test-ai-headless --prebuilt$' "$INKFLOW_RUNNER_LOG"
[[ $(grep -c '^test-ai-learning ' "$INKFLOW_RUNNER_LOG") == 1 ]]
[[ $(grep -c '^test-dictionary-updates --worker$' "$INKFLOW_RUNNER_LOG") == 1 ]]
[[ $(grep -c '^test-dictionary-activation ' "$INKFLOW_RUNNER_LOG") == 1 ]]
unset INKFLOW_TEST_DISABLE_PARALLEL
# Standalone source/store preparation must not inspect the installed app or worker.
rm -rf "$fixture/build/InkFlow.app"
cp macOS/scripts/test-dictionary-updates.sh "$fixture/macOS/scripts/"
cp macOS/scripts/test-timing.sh "$fixture/macOS/scripts/"
cp "$fixture/macOS/scripts/dependencies.sh" "$fixture/macOS/scripts/prepare-chinese.sh"
: > "$INKFLOW_RUNNER_LOG"
bash "$fixture/macOS/scripts/test-dictionary-updates.sh" --source
[[ $(grep -c '^prepare-chinese ' "$INKFLOW_RUNNER_LOG") == 1 ]]
! grep -q 'dictionary-worker-fixture' "$INKFLOW_RUNNER_LOG"
: > "$INKFLOW_RUNNER_LOG"
bash "$fixture/macOS/scripts/test-dictionary-updates.sh" --store
! grep -Eq 'prepare-chinese|dictionary-worker-fixture' "$INKFLOW_RUNNER_LOG"
: > "$INKFLOW_RUNNER_LOG"
if bash "$fixture/macOS/scripts/test-dictionary-updates.sh" --unknown >/dev/null 2>&1; then exit 1; else status=$?; fi
[[ $status == 2 && ! -s "$INKFLOW_RUNNER_LOG" ]]
timing_output=$(bash -c 'source macOS/scripts/test-timing.sh; began=$(inkflow_test_timing_now); inkflow_test_timing_report contract fixture "$began"')
grep -Eq $'^TIMING\tscope=contract\tstage=fixture\tduration_milliseconds=[0-9]+$' <<< "$timing_output"
echo 'PASS test runner: groups, isolated roots, preparation, default coverage and failure propagation'
