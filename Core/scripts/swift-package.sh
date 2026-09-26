#!/bin/bash
# Source from the repository root. No root package or application is resolved here.
build_core_product() {
  local product="$1" output="$2" configuration="${3:-debug}"
  [[ "$configuration" == debug || "$configuration" == release ]] || return 2
  local scratch="$PWD/build/core-swiftpm"
  local args=(--package-path "$PWD/Core" --disable-sandbox
    --scratch-path "$scratch" --cache-path "$scratch/cache"
    --config-path "$scratch/config" --security-path "$scratch/security"
    --triple arm64-apple-macosx26.0 --configuration "$configuration" --product "$product"
    -Xcc "-I$PWD/build/deps/dist/include")
  export CLANG_MODULE_CACHE_PATH="$scratch/module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache"
  xcrun swift build "${args[@]}" || return $?
  local binaries
  binaries=$(xcrun swift build "${args[@]}" --show-bin-path) || return $?
  mkdir -p "$(dirname "$output")"
  cp "$binaries/$product" "$output"
}
