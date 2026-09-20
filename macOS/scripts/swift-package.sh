#!/bin/bash
# Sourced from scripts that have already changed to the repository root.
swiftpm_scratch="$PWD/build/swiftpm"
swiftpm_triple="arm64-apple-macosx26.0"
swiftpm_cache="$swiftpm_scratch/cache"
swiftpm_config="$swiftpm_scratch/config"
swiftpm_security="$swiftpm_scratch/security"
export CLANG_MODULE_CACHE_PATH="$swiftpm_scratch/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$swiftpm_scratch/module-cache"

build_swift_product() {
  local product="$1" output="$2" configuration="$3"
  [[ "$configuration" == debug || "$configuration" == release ]] || {
    echo "SwiftPM configuration must be debug or release." >&2
    return 2
  }
  # Every consumer must resolve CRime's headers during explicit module scanning.
  local build_args=(--disable-sandbox --cache-path "$swiftpm_cache"
    --config-path "$swiftpm_config" --security-path "$swiftpm_security" --scratch-path "$swiftpm_scratch"
    --triple "$swiftpm_triple" --configuration "$configuration" --product "$product"
    -Xcc "-I$PWD/build/deps/dist/include")
  xcrun swift build "${build_args[@]}" || return $?
  local bin_path
  bin_path=$(xcrun swift build "${build_args[@]}" --show-bin-path) || return $?
  mkdir -p "$(dirname "$output")"
  cp "$bin_path/$product" "$output"
}
