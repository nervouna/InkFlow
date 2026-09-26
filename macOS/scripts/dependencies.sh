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
fetch emoji.txt 09e29b83ad367ea273e9ab438e572a7621649d93b36924ead28852762d2898b1 https://raw.githubusercontent.com/iDvel/rime-ice/fbb516b2786e4d5444383706d13c31c2e4d10c08/opencc/emoji.txt
# The native translator links the existing runtime. Its C++ declarations and
# template types must come from the same release, not host Homebrew headers.
fetch librime-source.tar.gz d3f48c2c58f718402229031d8d95fde9cac07ababa8fecf7d18b91946f27fee6 https://codeload.github.com/rime/librime/tar.gz/33e78140250125871856cdc5b42ddc6a5fcd3cd4
fetch librime-native-deps.tar.bz2 dfe6047e87be271963d7466bd1a6e3d9e660c30e5e73e4bb94e8782c0a6ac8df https://github.com/rime/librime/releases/download/1.17.0/rime-deps-33e7814-macOS-universal.tar.bz2
fetch boost_1_89_0.tar.bz2 85a33fa22621b4f314f8e85e1a5e2a9363d22e4f4992925d4bb3bc631b5a0c7a https://archives.boost.io/release/1.89.0/source/boost_1_89_0.tar.bz2
stamp=build/deps/.extracted.sha256
fingerprint=$(printf '%s\n' \
  'librime 11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850' \
  'pinyin 46f37114a7929ecc01003a236803c8b1e5198382e6a21f83fae036604a6b08bf' \
  'english 59226ae1bb6da00d8808a0094439271225ac4f533d30cf9150ac482383895461' \
  'librime-source d3f48c2c58f718402229031d8d95fde9cac07ababa8fecf7d18b91946f27fee6' \
  'librime-native-deps dfe6047e87be271963d7466bd1a6e3d9e660c30e5e73e4bb94e8782c0a6ac8df' \
  'boost 85a33fa22621b4f314f8e85e1a5e2a9363d22e4f4992925d4bb3bc631b5a0c7a' | shasum -a 256 | awk '{print $1}')
outputs_valid=false
native=build/deps/native
if [[ -f build/deps/dist/lib/librime.1.17.0.dylib && -f build/deps/dist/lib/rime-plugins/librime-lua.dylib \
  && -f "$native/librime/src/rime/translator.h" && -f "$native/boost/boost/version.hpp" \
  && -f "$native/deps/include/glog/logging.h" && -f "$native/deps/include/marisa.h" \
  && -f "$native/generated/rime/build_config.h" ]] && \
   compgen -G 'build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml' >/dev/null && \
   compgen -G 'build/deps/rime-easy-en-*/easy_en.dict.yaml' >/dev/null; then outputs_valid=true; fi
if [[ "$outputs_valid" == true && -f "$stamp" && "$(cat "$stamp")" == "$fingerprint" ]]; then
  echo 'Dependencies already extracted.'
  exit 0
fi
tar -xjf build/deps/librime.tar.bz2 -C build/deps
tar -xzf build/deps/pinyin.tar.gz -C build/deps
tar -xzf build/deps/english.tar.gz -C build/deps
mkdir -p "$native/librime" "$native/deps" "$native/boost" "$native/generated/rime"
tar -xzf build/deps/librime-source.tar.gz -C "$native/librime" --strip-components=1
tar -xjf build/deps/librime-native-deps.tar.bz2 -C "$native/deps" include
tar -xjf build/deps/boost_1_89_0.tar.bz2 -C "$native/boost" --strip-components=1 boost_1_89_0/boost boost_1_89_0/LICENSE_1_0.txt
# Render the upstream configuration template with its default logging/path
# settings. No API declarations or engine implementation are copied or patched.
sed -e 's/^#cmakedefine RIME_ENABLE_LOGGING$/#define RIME_ENABLE_LOGGING/' \
  -e 's/^#cmakedefine RIME_ALSO_LOG_TO_STDERR$/\/\* #undef RIME_ALSO_LOG_TO_STDERR \*\//' \
  -e 's|^#cmakedefine RIME_DATA_DIR.*$|#define RIME_DATA_DIR "rime-data"|' \
  -e 's|^#cmakedefine RIME_PLUGINS_DIR.*$|#define RIME_PLUGINS_DIR "rime-plugins"|' \
  "$native/librime/src/rime/build_config.h.in" > "$native/generated/rime/build_config.h"
printf '%s\n' "$fingerprint" > "$stamp.part"
mv "$stamp.part" "$stamp"
