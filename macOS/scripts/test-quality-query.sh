#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python=${INKFLOW_PYTHON:-python3}
mkdir -p build
swiftc -module-cache-path "$PWD/build/quality-export-module-cache" -swift-version 6 -warnings-as-errors macOS/Sources/QualityExport.swift macOS/Tests/QualityExportFixture.swift -lsqlite3 -o build/quality-export-fixture
export INKFLOW_QUALITY_EXPORT_FIXTURE="$PWD/build/quality-export-fixture"
"$python" macOS/Tests/QualityQueryTests.py "$@"
