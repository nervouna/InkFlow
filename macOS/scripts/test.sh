#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
groups=(quality ai preparation dictionary-generator deployment engine controller settings dictionary-updates dictionary-activation termination installer-core)
usage() {
  echo 'Usage: test.sh [all | GROUP ...]'
  echo "Groups: ${groups[*]}"
  echo 'No arguments runs all groups. Groups run once in the order listed above.'
  echo 'dictionary-updates and dictionary-activation require a fresh build.sh run first.'
}
if [[ $# -eq 1 && "$1" == --help ]]; then usage; exit 0; fi
selected=" $* "
if [[ $# -eq 0 || ( $# -eq 1 && "$1" == all ) ]]; then
  selected=" ${groups[*]} "
else
  for group in "$@"; do
    case "$group" in
      quality|ai|preparation|dictionary-generator|deployment|engine|controller|settings|dictionary-updates|dictionary-activation|termination|installer-core) ;;
      *) echo "Unknown test group: $group" >&2; usage >&2; exit 2 ;;
    esac
  done
fi
has() { [[ "$selected" == *" $1 "* ]]; }
if has dictionary-updates || has dictionary-activation; then
  [[ -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]] || { echo 'Run build.sh first.' >&2; exit 1; }
fi
if has quality; then
  bash macOS/scripts/test-quality-store.sh
  bash macOS/scripts/test-quality-timing.sh
  bash macOS/scripts/test-quality-metadata.sh
fi
if has ai || has dictionary-generator || has deployment || has engine || has controller || has settings || has dictionary-activation; then
  macOS/scripts/dependencies.sh
fi
if has preparation; then bash macOS/scripts/test-prepare-rime.sh; fi
if has dictionary-generator; then bash macOS/scripts/test-dictionary-generator.sh; fi
if has ai || has deployment || has engine || has controller; then
  bash macOS/scripts/prepare-rime.sh build/test-shared
fi
source macOS/scripts/swift-common.sh
if has ai; then
  bash macOS/scripts/test-ai-suggestions.sh
  bash macOS/scripts/test-ai-statistics.sh
  bash macOS/scripts/test-ai-statistics-query.sh
  bash macOS/scripts/test-ai-runtime.sh
  bash macOS/scripts/test-ai-learning.sh
fi
if has quality; then
  bash macOS/scripts/test-quality-capture.sh
  bash macOS/scripts/test-quality-query.sh --require-engine
fi
if has deployment; then
  build_swift_test build/deployment-tests macOS/Tests/DeploymentTests.swift
  build/deployment-tests "$PWD/build/test-shared" "$PWD"/build/deps/rime-easy-en-*/easy_en.dict.yaml
fi
if has engine || has controller; then
  user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-tests.XXXXXX")
  trap 'rm -rf "$user_dir"' EXIT
fi
if has engine; then
  build_swift_test build/engine-tests macOS/Tests/EngineTests.swift
  build/engine-tests "$PWD/build/test-shared" "$user_dir"
fi
if has controller; then
  build_swift_test build/controller-tests macOS/Tests/ControllerTests.swift
  build/controller-tests "$PWD/build/test-shared" "$user_dir"
fi
if has settings; then
  build_swift_test build/settings-tests macOS/Tests/SettingsTests.swift
  build/settings-tests
fi
if has dictionary-updates; then bash macOS/scripts/test-dictionary-updates.sh; fi
if has dictionary-activation; then
  bash macOS/scripts/test-dictionary-activation.sh
  bash macOS/scripts/test-serving-startup.sh
fi
if has termination; then bash macOS/scripts/test-termination.sh; fi
if has installer-core; then bash macOS/scripts/test-installer-core.sh; fi
