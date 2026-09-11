#!/bin/bash
# Sourced from test scripts that have already changed to the repository root.
source macOS/scripts/swift-package.sh

build_swift_test() {
  local product="$1" output="$2"
  build_swift_product "$product" "$output" debug
}
