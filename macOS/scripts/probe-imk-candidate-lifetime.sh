#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mode=${1:---inspect}
if [[ $# -gt 1 || ( "$mode" != --inspect && "$mode" != --keep-alive && "$mode" != --zombie ) ]]; then
    echo 'Usage: probe-imk-candidate-lifetime.sh [--inspect|--keep-alive|--zombie]' >&2
    exit 64
fi
# Temporary executable only; no installation, input-source registration or defaults writes.
probe_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-candidate-lifetime.XXXXXX")
trap 'rm -rf "$probe_dir"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -g -framework Cocoa -framework InputMethodKit \
    macOS/scripts/diagnostics/IMKCandidateLifetimeProbe.m -o "$probe_dir/probe"
case "$mode" in
    --inspect) "$probe_dir/probe" ;;
    --keep-alive) "$probe_dir/probe" --keep-alive ;;
    --zombie)
        # An intentional diagnostic breakpoint is expected; LLDB exit zero is not a PASS.
        xcrun lldb --batch -o 'settings set target.env-vars NSZombieEnabled=YES' \
            -o 'run --trigger' -k bt "$probe_dir/probe"
        ;;
esac
