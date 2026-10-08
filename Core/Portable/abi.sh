#!/bin/bash
# Build the exported C ABI (cdylib + staticlib) and run the C consumer. Without a
# prepared resources directory only the fixture and argument checks run.
set -euo pipefail
cd "$(dirname "$0")/../.."
resources=${1:-}
if [[ -n "$resources" ]]; then
  [[ -f "$resources/prepared/complete" ]] || { echo "Not a prepared resources directory: $resources" >&2; exit 2; }
  resources=$(cd "$resources" && pwd)
fi
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
cargo build --locked --manifest-path Core/Portable/Cargo.toml
lib="$CARGO_TARGET_DIR/debug"
[[ -f "$lib/libinkflow_rime.a" ]]
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-abi.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/fixture/shared/lua" "$scratch/work"
for file in default.yaml probe.schema.yaml probe.dict.yaml lua/probe.lua; do
  cp "Core/Portable/fixtures/$file" "$scratch/fixture/shared/$file"
done
cc -std=c11 -Wall -Wextra -Werror -I Core/Portable/include Core/Portable/tests/abi.c \
  -L"$lib" -linkflow_rime -Wl,-rpath,"$lib" -o "$scratch/abi-test"
"$scratch/abi-test" "$scratch/fixture" "$scratch/work" ${resources:+"$resources"}
