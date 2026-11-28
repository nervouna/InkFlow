#!/bin/bash
build_package_product() {
  local package="$1" scratch="$2" product="$3" output="$4" configuration="$5"
  [[ "$configuration" == debug || "$configuration" == release ]] || {
    echo "SwiftPM configuration must be debug or release." >&2
    return 2
  }
  bash Core/scripts/build-dictionary-generator.sh || return $?
  [[ "${INKFLOW_PORTABLE_BUILT:-}" == 1 ]] || bash Core/scripts/build-portable.sh || return $?
  local args=(--package-path "$package" --disable-sandbox
    --scratch-path "$scratch" --cache-path "$scratch/cache"
    --config-path "$scratch/config" --security-path "$scratch/security"
    --triple arm64-apple-macosx26.0 --configuration "$configuration" --product "$product")
  export CLANG_MODULE_CACHE_PATH="$scratch/module-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache"
  xcrun swift build "${args[@]}" || return $?
  local binaries
  binaries=$(xcrun swift build "${args[@]}" --show-bin-path) || return $?
  mkdir -p "$(dirname "$output")"
  cp "$binaries/$product" "$output"
}

build_core_product() {
  build_package_product "$PWD/Core" "$PWD/build/core-swiftpm" "$1" "$2" "${3:-debug}"
}
