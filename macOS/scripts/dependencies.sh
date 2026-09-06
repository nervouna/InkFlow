#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/deps
fetch() {
  local name="$1" sha="$2" url="$3"
  if [[ ! -f "build/deps/$name" ]]; then
    curl --fail --location --retry 2 "$url" -o "build/deps/$name.part"
    mv "build/deps/$name.part" "build/deps/$name"
  fi
  echo "$sha  build/deps/$name" | shasum -a 256 -c -
}
fetch librime.tar.bz2 11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850 https://github.com/rime/librime/releases/download/1.17.0/rime-33e7814-macOS-universal.tar.bz2
fetch pinyin.tar.gz 46f37114a7929ecc01003a236803c8b1e5198382e6a21f83fae036604a6b08bf https://codeload.github.com/rime/rime-pinyin-simp/tar.gz/0c6861ef7420ee780270ca6d993d18d4101049d0
fetch english.tar.gz 59226ae1bb6da00d8808a0094439271225ac4f533d30cf9150ac482383895461 https://codeload.github.com/BlindingDark/rime-easy-en/tar.gz/54a4a07289412efc54134092c0d945f895a71ed3
tar -xjf build/deps/librime.tar.bz2 -C build/deps
tar -xzf build/deps/pinyin.tar.gz -C build/deps
tar -xzf build/deps/english.tar.gz -C build/deps
