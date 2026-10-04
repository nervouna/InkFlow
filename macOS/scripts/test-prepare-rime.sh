#!/bin/bash
set -euo pipefail
exec bash "$(dirname "$0")/../../Core/scripts/test-prepare-rime.sh" "$@"
