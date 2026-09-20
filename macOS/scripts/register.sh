#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
/bin/ps -p "$$" -o pid= >/dev/null || { echo 'Desktop process access unavailable; input-source state is unknown. Run outside the restricted sandbox.' >&2; exit 1; }
mkdir -p build
source macOS/scripts/swift-package.sh
build_swift_product register-input-source build/register-input-source debug
if [[ $# == 0 ]]; then set -- "$HOME/Library/Input Methods/InkFlow.app"; fi
diagnostics=$(mktemp "${TMPDIR:-/tmp}/inkflow-registration.XXXXXX")
trap 'rm -f "$diagnostics"' EXIT
result=0
build/register-input-source "$@" 2>"$diagnostics" || result=$?
cat "$diagnostics" >&2
if LC_ALL=C grep -Eiq 'Connection invalid|connection.*(failed|interrupted)|Failed to connect|Sandbox.*deny' "$diagnostics"; then
  echo 'Input-source service connection failed; enabled state is unknown.' >&2
  exit 1
fi
exit "$result"
