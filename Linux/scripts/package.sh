#!/bin/bash
# Build a local directory package or the two versioned release archives from a clean checkout.
# Usage: bash Linux/scripts/package.sh [PREPARED_RESOURCES] | --release X.Y.Z
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $(uname -s) == Linux ]] || { echo 'Linux host required.' >&2; exit 1; }
version=""
if [[ ${1:-} == --release ]]; then
  version=${2:?Expected --release X.Y.Z}
  number='(0|[1-9][0-9]*)'
  if [[ $# != 2 || ! $version =~ ^$number\.$number\.$number$ || $(uname -m) != aarch64 ]]; then
    echo 'Release packaging requires aarch64 and a version X.Y.Z.' >&2
    exit 1
  fi
  shift 2
fi
[[ $# -le 1 ]] || { echo 'Usage: package.sh [PREPARED_RESOURCES]' >&2; exit 1; }
changes=$(git status --porcelain --untracked-files=normal)
[[ -z $changes ]] || {
  echo 'Commit source changes before packaging for exact provenance.' >&2; exit 1;
}
mkdir -p build/linux
work=$(mktemp -d "$PWD/build/linux/package-work.XXXXXX")
trap 'rm -rf "$work"' EXIT
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
python3 Core/Portable/build-native.py
bash Core/scripts/resource-dependencies.sh
bash Core/scripts/prepare-chinese.sh --sources-only
resources=${1:-$work/resources}
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
stage="$work/stage"
mkdir -p "$stage"
DESTDIR="$stage" cmake --install build/linux/cmake
cp "$resources/resources.json" "$stage/usr/share/inkflow/rime/resources.json"
# The addon loader resolves a bare library name in its configured addon paths.
sed -i 's|^Library=.*|Library=libinkflow|' "$stage/usr/share/fcitx5/addon/inkflow.conf"
python3 Linux/scripts/package-notices.py "$stage/usr" "$version"
if [[ -n $version ]]; then
  binary="InkFlow-$version-linux-aarch64"
  source="InkFlow-$version-linux-source"
  mv "$stage/usr" "$stage/$binary"
  mv "$stage/SOURCE" "$stage/$source"
  mkdir "$work/assets"
  for name in "$binary" "$source"; do
    tar -C "$stage" -cJf "$work/assets/$name.tar.xz" "$name"
  done
  (cd "$work/assets" && sha256sum *.tar.xz > SHA256SUMS-linux)
  mkdir -p build/linux/releases
  mv -T "$work/assets" "build/linux/releases/$version"
  exit 0
fi
rm -rf build/linux/package
mv "$stage/usr" build/linux/package
printf 'Package directory: %s/build/linux/package\n' "$PWD"
