#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python=${INKFLOW_PYTHON:-python3}
"$python" macOS/Tests/QualityQueryTests.py "$@"
