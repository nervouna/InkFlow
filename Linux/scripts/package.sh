#!/bin/bash
# Build a directory package only. Commit tracked changes before packaging.
# Usage: bash Linux/scripts/package.sh [PREPARED_RESOURCES]
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $(uname -s) == Linux ]] || { echo 'Linux host required.' >&2; exit 1; }
[[ $# -le 1 ]] || { echo 'Usage: package.sh [PREPARED_RESOURCES]' >&2; exit 1; }
[[ -z $(git status --porcelain --untracked-files=normal) ]] || {
  echo 'Commit tracked source changes before packaging for exact provenance.' >&2; exit 1;
}
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
python3 Core/Portable/build-native.py
bash Core/scripts/resource-dependencies.sh
bash Core/scripts/prepare-chinese.sh --sources-only
resources=${1:-$PWD/build/linux/resources}
resources=$(realpath -m "$resources")
if [[ $# == 0 ]]; then
  bash Core/scripts/prepare-rime.sh "$resources/shared"
  cargo run --locked --release --manifest-path Core/Portable/Cargo.toml --bin prepare-resources -- \
    "$resources/shared" "$resources/prepared"
else
  # Compare reused resources against today's committed dictionary recipe too.
  bash Core/scripts/prepare-rime.sh build/linux/package-shared
fi
python3 Linux/scripts/package-notices.py --check-resources "$resources" "${1:+reused}"
[[ -d "$resources/shared" && -d "$resources/prepared/cache" ]] || {
  echo 'Resources must contain shared/ and target-native prepared/cache/.' >&2; exit 1;
}
cargo build --locked --release --manifest-path Core/Portable/Cargo.toml --lib
cmake -S Linux/fcitx5 -B build/linux/cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
  -DINKFLOW_ADDONDIR=lib/fcitx5 -DINKFLOW_PKGDATADIR=share/fcitx5 \
  -DINKFLOW_RESOURCES="$resources"
cmake --build build/linux/cmake --target inkflow --parallel "${CMAKE_BUILD_PARALLEL_LEVEL:-4}"
# A failed build never replaces a previously completed package.
mkdir -p build/linux
stage=$(mktemp -d "$PWD/build/linux/stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
DESTDIR="$stage" cmake --install build/linux/cmake
cp "$resources/resources.json" "$stage/usr/share/inkflow/rime/resources.json"
# The addon loader resolves a bare library name in its configured addon paths.
sed -i 's|^Library=.*|Library=libinkflow|' "$stage/usr/share/fcitx5/addon/inkflow.conf"
python3 Linux/scripts/package-notices.py "$stage/usr"
rm -rf build/linux/package
mv "$stage/usr" build/linux/package
printf 'Package directory: %s/build/linux/package\n' "$PWD"
