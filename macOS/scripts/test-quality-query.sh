#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $(uname -s) == Darwin ]]; then
  exec devbox "$PWD" -- bash macOS/scripts/test-quality-query.sh "$@"
fi
python3 macOS/Tests/QualityQueryTests.py "$@"
