#!/bin/bash
source Core/scripts/swift-package.sh
swiftpm_scratch="$PWD/build/swiftpm"

build_swift_product() {
  build_package_product "$PWD" "$swiftpm_scratch" "$1" "$2" "$3"
}
