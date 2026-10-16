#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash Core/scripts/resource-dependencies.sh
