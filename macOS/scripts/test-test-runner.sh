#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-test-runner.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/macOS/scripts" "$fixture/build/test-shared"
touch "$fixture/build/test-shared/inkflow_pinyin.schema.yaml"
cp macOS/scripts/test.sh macOS/scripts/test-groups.sh "$fixture/macOS/scripts/"
export INKFLOW_RUNNER_LOG="$fixture/commands.log"
for script in dependencies prepare-rime test-quality-identity test-quality-store test-quality-timing test-quality-metadata \
  test-prepare-rime test-dictionary-generator test-quality-capture test-quality-query \
  test-dictionary-updates test-dictionary-activation test-serving-startup test-termination test-installer-core \
  test-ai-suggestions test-ai-statistics test-ai-statistics-query test-ai-runtime test-ai-learning test-ai-headless \
  test-startup-diagnostics test-test-runner test-test-affected test-workflow; do
  cat > "$fixture/macOS/scripts/$script.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
name=$(basename "$0" .sh)
args=${*//${PWD}/REPO}
echo "$name $args" >> "$INKFLOW_RUNNER_LOG"
if [[ "$name" == "${INKFLOW_RUNNER_FAIL:-}" ]]; then exit 17; fi
STUB
  chmod +x "$fixture/macOS/scripts/$script.sh"
done
cat > "$fixture/macOS/scripts/swift-test.sh" <<'STUB'
build_swift_test() {
  echo "build $1" >> "$INKFLOW_RUNNER_LOG"
  cat > "$2" <<'PROGRAM'
#!/bin/bash
name=$(basename "$0")
echo "run $name ${3:-}" >> "$INKFLOW_RUNNER_LOG"
case "$name" in engine-tests|controller-tests)
  [[ -d "$2" && ! -e "$2/used" ]] || exit 23
  touch "$2/used"
  echo "$2" >> "$INKFLOW_RUNNER_LOG.paths" ;;
esac
PROGRAM
  chmod +x "$2"
}
STUB
run() {
  : > "$INKFLOW_RUNNER_LOG"
  : > "$INKFLOW_RUNNER_LOG.paths"
  bash "$fixture/macOS/scripts/test.sh" "$@" > "$fixture/output.log" 2>&1
}
expect() { printf '%s\n' "$@" > "$fixture/expected.log"; diff -u "$fixture/expected.log" "$INKFLOW_RUNNER_LOG"; }
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
run ai-learning
expect 'dependencies ' 'test-ai-learning '
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
run
cp "$INKFLOW_RUNNER_LOG" "$fixture/default.log"
run all
cmp "$fixture/default.log" "$INKFLOW_RUNNER_LOG"
for required in test-quality-identity test-quality-store test-quality-timing test-quality-metadata \
  test-quality-capture test-quality-query test-ai-suggestions test-ai-runtime test-ai-statistics \
  test-ai-statistics-query test-ai-learning test-ai-headless test-prepare-rime test-dictionary-generator \
  test-dictionary-activation test-serving-startup test-startup-diagnostics test-termination \
  test-installer-core test-test-runner test-test-affected test-workflow; do
  [[ $(grep -c "^$required " "$INKFLOW_RUNNER_LOG") == 1 ]]
done
for required in 'run deployment-tests ' 'run engine-tests --basic' 'run engine-tests --options' \
  'run engine-tests --english' 'run engine-tests --context' 'run engine-tests --custom-phrases' \
  'run controller-tests ' 'run settings-tests ' \
  'test-dictionary-updates --source' 'test-dictionary-updates --store' 'test-dictionary-updates --worker'; do
  [[ $(grep -Fxc "$required" "$INKFLOW_RUNNER_LOG") == 1 ]]
done
[[ $(grep -c '^prepare-rime ' "$INKFLOW_RUNNER_LOG") == 1 ]]
! grep -E 'gui|keychain|--live' "$INKFLOW_RUNNER_LOG"
export INKFLOW_RUNNER_FAIL=test-ai-runtime
if run ai-runtime settings; then exit 1; else status=$?; fi
[[ $status == 17 ]]
expect 'dependencies ' 'test-ai-runtime '
grep -q 'Not executed: settings' "$fixture/output.log"
unset INKFLOW_RUNNER_FAIL
# Standalone source/store preparation must not inspect the installed app or worker.
rm -rf "$fixture/build/InkFlow.app"
cp macOS/scripts/test-dictionary-updates.sh "$fixture/macOS/scripts/"
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
echo 'PASS test runner: groups, isolated roots, preparation, default coverage and failure propagation'
