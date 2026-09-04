#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
apple_dir=${script_dir:h}
repo_root=${apple_dir:h:h}
generated_dir="$apple_dir/Generated"
host_build_dir="$generated_dir/SchemaToolBuild"
work_dir="$generated_dir/SchemaWork"
schema_dir="$generated_dir/Schema"

cmake -S "$repo_root" -B "$host_build_dir" -G "Unix Makefiles" \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DINKFLOW_BUILD_APPLE_PACKAGING_TOOLS=ON
cmake --build "$host_build_dir" --target inkflow_apple_schema_deployer --parallel

rm -rf "$work_dir" "$schema_dir"
mkdir -p "$work_dir/user" "$work_dir/staging" "$schema_dir"
"$host_build_dir/engine/inkflow_apple_schema_deployer" \
  "$repo_root/schemas/source" \
  "$repo_root/schemas/source" \
  "$work_dir/user" \
  "$work_dir/staging"

typeset -a required
required=(
  default.yaml
  inkflow.schema.yaml
  inkflow.table.bin
  inkflow.prism.bin
  inkflow.reverse.bin
)
for file in "${required[@]}"; do
  if [[ ! -s "$work_dir/staging/$file" ]]; then
    print -u2 "Schema deployment did not produce $file"
    exit 1
  fi
  cp "$work_dir/staging/$file" "$schema_dir/$file"
done

if find "$schema_dir" -type f \( -name 'installation.yaml' -o -name 'user.yaml' \) | grep -q .; then
  print -u2 "Writable Rime state leaked into the bundled schema"
  exit 1
fi

print "Staged schema resources in $schema_dir"
