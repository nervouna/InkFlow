#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sha256=(shasum -a 256)
if command -v sha256sum >/dev/null; then sha256=(sha256sum); fi
mkdir -p build/deps
fetch() {
  local name="$1" sha="$2" url="$3"
  if [[ ! -f "build/deps/$name" ]]; then
    curl --fail --location --proto '=https' --connect-timeout 20 --max-time 180 --retry 2 \
      "$url" -o "build/deps/$name.part"
    mv "build/deps/$name.part" "build/deps/$name"
  fi
  printf '%s  %s\n' "$sha" "build/deps/$name" | "${sha256[@]}" -c -
}
fetch pinyin.tar.gz 46f37114a7929ecc01003a236803c8b1e5198382e6a21f83fae036604a6b08bf https://codeload.github.com/rime/rime-pinyin-simp/tar.gz/0c6861ef7420ee780270ca6d993d18d4101049d0
fetch english.tar.gz 59226ae1bb6da00d8808a0094439271225ac4f533d30cf9150ac482383895461 https://codeload.github.com/BlindingDark/rime-easy-en/tar.gz/54a4a07289412efc54134092c0d945f895a71ed3
fetch emoji.txt 09e29b83ad367ea273e9ab438e572a7621649d93b36924ead28852762d2898b1 https://raw.githubusercontent.com/iDvel/rime-ice/fbb516b2786e4d5444383706d13c31c2e4d10c08/opencc/emoji.txt
# Restore source files from verified archives if extraction is missing or changed.
for entry in \
  'pinyin.tar.gz:rime-pinyin-simp-0c6861ef7420ee780270ca6d993d18d4101049d0/pinyin_simp.dict.yaml' \
  'english.tar.gz:rime-easy-en-54a4a07289412efc54134092c0d945f895a71ed3/easy_en.dict.yaml'; do
  archive=${entry%%:*}
  member=${entry#*:}
  expected=$(tar -xOf "build/deps/$archive" "$member" | "${sha256[@]}" | cut -d ' ' -f 1)
  if ! printf '%s  %s\n' "$expected" "build/deps/$member" | "${sha256[@]}" -c - >/dev/null 2>&1; then
    tar -xzf "build/deps/$archive" -C build/deps
  fi
done
