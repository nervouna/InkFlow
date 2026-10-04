#!/bin/bash
set -euo pipefail
exec bash "$(dirname "$0")/../../Core/scripts/prepare-chinese.sh" "$@"
