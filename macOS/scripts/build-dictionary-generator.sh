#!/bin/bash
set -euo pipefail
exec bash "$(dirname "$0")/../../Core/scripts/build-dictionary-generator.sh" "$@"
