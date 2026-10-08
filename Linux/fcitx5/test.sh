#!/bin/bash
# Platform-independent checks of the Fcitx5 adapter: the pure bridge helpers, and a
# syntax-only compile of the addon when FCITX5_SOURCE points at an fcitx5 source tree
# (its generated export headers are stubbed). The real build runs on Linux via CMake.
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-fcitx5.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
c++ -std=c++17 -Wall -Wextra -Werror -I Linux/fcitx5/src Linux/fcitx5/tests/bridge_test.cpp -o "$scratch/bridge_test"
"$scratch/bridge_test"
if [[ -n "${FCITX5_SOURCE:-}" ]]; then
  mkdir -p "$scratch/exports/fcitx" "$scratch/exports/fcitx-utils" "$scratch/exports/fcitx-config"
  for pair in fcitx:fcitxcore:FCITXCORE fcitx-utils:fcitxutils:FCITXUTILS fcitx-config:fcitxconfig:FCITXCONFIG; do
    IFS=: read -r dir base macro <<<"$pair"
    printf '#define %s_EXPORT\n#define %s_NO_EXPORT\n#define %s_DEPRECATED\n#define %s_DEPRECATED_EXPORT\n' \
      "$macro" "$macro" "$macro" "$macro" > "$scratch/exports/$dir/${base}_export.h"
  done
  for file in engine.cpp candidates.cpp; do
    c++ -std=c++20 -fsyntax-only -Wall -Wextra -Werror -I Core/Portable/include -I Linux/fcitx5/src \
      -I "$scratch/exports" -I "$FCITX5_SOURCE/src/lib" "Linux/fcitx5/src/$file"
  done
  echo "PASS fcitx5 addon syntax against $FCITX5_SOURCE"
fi
