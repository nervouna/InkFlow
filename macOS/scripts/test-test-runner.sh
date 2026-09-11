#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# Exercise dispatch without compiling, downloading, or touching the real app.
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-runner.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/macOS/scripts" "$fixture/build"
cp macOS/scripts/test.sh "$fixture/macOS/scripts/"
export INKFLOW_RUNNER_LOG="$fixture/commands.log"
for script in dependencies prepare-rime test-quality-identity test-quality-store test-quality-timing test-quality-metadata \
  test-prepare-rime test-dictionary-generator test-quality-capture test-quality-query \
  test-dictionary-updates test-dictionary-activation test-serving-startup test-termination test-installer-core \
  test-ai-suggestions test-ai-statistics test-ai-statistics-query test-ai-runtime test-ai-learning; do
  cat > "$fixture/macOS/scripts/$script.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
name=$(basename "$0" .sh)
echo "$name $*" >> "$INKFLOW_RUNNER_LOG"
if [[ "$name" == "${INKFLOW_RUNNER_FAIL:-}" ]]; then exit 17; fi
STUB
  chmod +x "$fixture/macOS/scripts/$script.sh"
done
cat > "$fixture/macOS/scripts/swift-test.sh" <<'STUB'
build_swift_test() {
  echo "build $1 $(basename "$2")" >> "$INKFLOW_RUNNER_LOG"
  cat > "$2" <<'PROGRAM'
#!/bin/bash
echo "run $(basename "$0")" >> "$INKFLOW_RUNNER_LOG"
PROGRAM
  chmod +x "$2"
}
STUB

run() {
  : > "$INKFLOW_RUNNER_LOG"
  bash "$fixture/macOS/scripts/test.sh" "$@" > "$fixture/output.log" 2>&1
}
expect() {
  printf '%s\n' "$@" > "$fixture/expected.log"
  diff -u "$fixture/expected.log" "$INKFLOW_RUNNER_LOG"
}

run settings
expect 'dependencies ' 'build settings-tests settings-tests' 'run settings-tests'
run controller engine controller
expect 'dependencies ' 'prepare-rime build/test-shared' \
  'build engine-tests engine-tests' 'run engine-tests' 'build controller-tests controller-tests' 'run controller-tests'
run deployment
expect 'dependencies ' 'prepare-rime build/test-shared' 'build deployment-tests deployment-tests' 'run deployment-tests'
run preparation
expect 'test-prepare-rime '
run dictionary-generator
expect 'dependencies ' 'test-dictionary-generator '
run quality
expect 'test-quality-identity ' 'test-quality-store ' 'test-quality-timing ' 'test-quality-metadata ' 'test-quality-capture ' 'test-quality-query --require-engine'
run ai
expect 'dependencies ' 'prepare-rime build/test-shared' 'test-ai-suggestions ' 'test-ai-statistics ' \
  'test-ai-statistics-query ' 'test-ai-runtime ' 'test-ai-learning '
run installer-core termination installer-core
expect 'test-termination ' 'test-installer-core '
run --help
test ! -s "$INKFLOW_RUNNER_LOG"

for invalid in --unit unknown ''; do
  if run settings "$invalid"; then echo 'FAIL: invalid argument accepted' >&2; exit 1; else status=$?; fi
  [[ "$status" -eq 2 ]]
  test ! -s "$INKFLOW_RUNNER_LOG"
done
if run all settings; then echo 'FAIL: mixed all accepted' >&2; exit 1; else status=$?; fi
[[ "$status" -eq 2 ]]
test ! -s "$INKFLOW_RUNNER_LOG"

for group in all dictionary-updates dictionary-activation; do
  if run "$group"; then echo 'FAIL: missing worker accepted' >&2; exit 1; fi
  test ! -s "$INKFLOW_RUNNER_LOG"
  grep -q 'Run build.sh first.' "$fixture/output.log"
done
mkdir -p "$fixture/build/InkFlow.app/Contents/MacOS"
touch "$fixture/build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"
chmod +x "$fixture/build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker"
run dictionary-updates
expect 'test-dictionary-updates '
run dictionary-activation
expect 'dependencies ' 'test-dictionary-activation ' 'test-serving-startup '
run
expect 'test-quality-identity ' 'test-quality-store ' 'test-quality-timing ' 'test-quality-metadata ' 'dependencies ' \
  'test-prepare-rime ' 'test-dictionary-generator ' 'prepare-rime build/test-shared' \
  'test-ai-suggestions ' 'test-ai-statistics ' 'test-ai-statistics-query ' 'test-ai-runtime ' 'test-ai-learning ' \
  'test-quality-capture ' 'test-quality-query --require-engine' \
  'build deployment-tests deployment-tests' 'run deployment-tests' 'build engine-tests engine-tests' 'run engine-tests' \
  'build controller-tests controller-tests' 'run controller-tests' 'build settings-tests settings-tests' 'run settings-tests' \
  'test-dictionary-updates ' 'test-dictionary-activation ' 'test-serving-startup ' 'test-termination ' 'test-installer-core '
cp "$INKFLOW_RUNNER_LOG" "$fixture/default.log"
run all
cmp "$fixture/default.log" "$INKFLOW_RUNNER_LOG"

export INKFLOW_RUNNER_FAIL=test-prepare-rime
if run preparation settings; then echo 'FAIL: failure ignored' >&2; exit 1; else status=$?; fi
[[ "$status" -eq 17 ]]
expect 'dependencies ' 'test-prepare-rime '
echo 'PASS test runner: selection, prerequisites, deduplication, default coverage, argument validation and failure propagation'
