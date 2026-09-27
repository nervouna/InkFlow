#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-core-coverage.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/Core/scripts" "$fixture/macOS/scripts" "$fixture/build/prepared"
cp Core/scripts/test.sh "$fixture/Core/scripts/"
cp macOS/scripts/test-timing.sh "$fixture/macOS/scripts/"
export INKFLOW_CORE_COVERAGE_LOG="$fixture/commands.log"

for script in dependencies test-dictionary-generator test-ai-learning prepare-rime; do
  cat > "$fixture/macOS/scripts/$script.sh" <<'STUB'
#!/bin/bash
echo "$(basename "$0" .sh) $*" >> "$INKFLOW_CORE_COVERAGE_LOG"
STUB
done
for script in check-boundaries test-dictionaries; do
  cat > "$fixture/Core/scripts/$script.sh" <<'STUB'
#!/bin/bash
echo "$(basename "$0" .sh) $*" >> "$INKFLOW_CORE_COVERAGE_LOG"
STUB
done
cat > "$fixture/Core/scripts/swift-package.sh" <<'STUB'
build_core_product() {
  echo "build $1" >> "$INKFLOW_CORE_COVERAGE_LOG"
  mkdir -p "$(dirname "$2")"
  cat > "$2" <<'PROGRAM'
#!/bin/bash
echo "run $(basename "$0") $*" >> "$INKFLOW_CORE_COVERAGE_LOG"
PROGRAM
  chmod +x "$2"
}
STUB
chmod +x "$fixture"/Core/scripts/*.sh "$fixture"/macOS/scripts/*.sh

run_core() {
  : > "$INKFLOW_CORE_COVERAGE_LOG"
  (cd "$fixture" && bash Core/scripts/test.sh "$@") > "$fixture/output.log" 2>&1
}

# Standalone Core remains self-contained and owns every shared regression.
run_core
for required in \
  'dependencies ' 'check-boundaries --standalone' 'test-dictionary-generator ' \
  'build ranking-tests' 'build ai-pronunciation-tests' 'build voice-learning-coordinator-tests' \
  'build voice-lexicon-tests' 'build dictionary-store-tests' 'build core-engine-tests'; do
  grep -Fxq "$required" "$INKFLOW_CORE_COVERAGE_LOG"
done
[[ $(grep -c '^run core-engine-tests --' "$INKFLOW_CORE_COVERAGE_LOG") == 5 ]]
[[ $(grep -c '^test-dictionaries ' "$INKFLOW_CORE_COVERAGE_LOG") == 1 ]]
[[ $(grep -c '^test-ai-learning ' "$INKFLOW_CORE_COVERAGE_LOG") == 1 ]]

# The embedded full suite delegates platform-owned engine and dictionary coverage
# to the canonical macOS units while retaining Core-only ranking and voice learning.
run_core "$fixture/build/prepared" --skip-covered-units
for required in 'build ranking-tests' 'run ranking-tests ' \
                'build voice-learning-coordinator-tests' 'run voice-learning-coordinator-tests '; do
  [[ $(grep -Fxc "$required" "$INKFLOW_CORE_COVERAGE_LOG") == 1 ]]
done
for delegated in test-dictionary-generator ai-pronunciation-tests voice-lexicon-tests \
                 dictionary-store-tests core-engine-tests test-dictionaries test-ai-learning; do
  ! grep -q "$delegated" "$INKFLOW_CORE_COVERAGE_LOG"
done

echo 'PASS Core coverage ownership: standalone complete, embedded platform-owned regressions delegated'
