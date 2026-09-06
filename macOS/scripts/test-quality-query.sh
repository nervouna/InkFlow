#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python_bin=$(mise which python)
"$python_bin" macOS/Tests/QualityQueryTests.py "$@"
