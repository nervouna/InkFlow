#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
prefix=${1:-$HOME/.local}
mode=${2:-smoke}
case "$mode" in
  smoke) default_im=inkflow-pinyin ;;
  --latency|--latency-samples) default_im=keyboard-us ;;
  *) echo "Usage: $0 [PREFIX] [--latency|--latency-samples]" >&2
     exit 2 ;;
esac
resources="$prefix/share/inkflow/rime"
if [[ -f "$prefix/share/inkflow/current/share/inkflow/rime/prepared/complete" ]]; then
  resources="$prefix/share/inkflow/current/share/inkflow/rime"
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-installed.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/config/fcitx5" "$scratch/data" "$scratch/cache" "$scratch/runtime"
chmod 700 "$scratch/runtime"
if [[ $mode == --latency* ]]; then
  recording=${INKFLOW_BENCH_RECORD_QUALITY:-True}
  case "$recording" in
    True|False) ;;
    *) echo 'INKFLOW_BENCH_RECORD_QUALITY requires True or False' >&2
       exit 2 ;;
  esac
  mkdir -p "$scratch/config/fcitx5/conf"
  printf 'RecordQuality=%s\n' "$recording" > "$scratch/config/fcitx5/conf/inkflow.conf"
fi
printf '[Hotkey/AltTriggerKeys]\n0=Control+Alt+F12\n' > "$scratch/config/fcitx5/config"
cat > "$scratch/config/fcitx5/profile" <<PROFILE
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=$default_im

[Groups/0/Items/0]
Name=keyboard-us

[Groups/0/Items/1]
Name=inkflow-pinyin

[GroupOrder]
0=Default
PROFILE
env -u DISPLAY -u WAYLAND_DISPLAY -u FCITX_CONFIG_HOME -u FCITX_DATA_HOME \
  INKFLOW_ISOLATED_TEST=1 INKFLOW_RESOURCES="$resources" \
  XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/data" \
  XDG_CACHE_HOME="$scratch/cache" XDG_RUNTIME_DIR="$scratch/runtime" \
  FCITX_DATA_DIRS="$prefix/share/fcitx5:/usr/share/fcitx5" \
  dbus-run-session -- "${PYTHON:-python3}" -B Linux/fcitx5/tests/installed_smoke.py "$mode"
