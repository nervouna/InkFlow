#!/bin/bash
# Requires dbus-next in PYTHON; never connects to the desktop's D-Bus or user data.
set -euo pipefail
cd "$(dirname "$0")/../.."
prefix=${1:-$HOME/.local}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-installed.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/config/fcitx5" "$scratch/data" "$scratch/cache" "$scratch/runtime"
chmod 700 "$scratch/runtime"
printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=inkflow-pinyin\n\n[Groups/0/Items/0]\nName=keyboard-us\n\n[Groups/0/Items/1]\nName=inkflow-pinyin\n\n[GroupOrder]\n0=Default\n' > "$scratch/config/fcitx5/profile"
env -u DISPLAY -u WAYLAND_DISPLAY -u FCITX_CONFIG_HOME -u FCITX_DATA_HOME \
  INKFLOW_ISOLATED_TEST=1 INKFLOW_RESOURCES="$prefix/share/inkflow/rime" \
  XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data" \
  XDG_CACHE_HOME="$scratch/cache" XDG_RUNTIME_DIR="$scratch/runtime" \
  FCITX_DATA_DIRS="$prefix/share/fcitx5:/usr/share/fcitx5" \
  dbus-run-session -- "${PYTHON:-python3}" Linux/fcitx5/tests/installed_smoke.py
