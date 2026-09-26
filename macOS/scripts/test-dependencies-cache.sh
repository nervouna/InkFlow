#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-dependencies-cache.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
repo="$fixture/repo"; bin="$fixture/bin"; mkdir -p "$repo/macOS/scripts" "$repo/build/deps" "$bin"
cp macOS/scripts/dependencies.sh "$repo/macOS/scripts/"
touch "$repo/build/deps/librime.tar.bz2" "$repo/build/deps/pinyin.tar.gz" "$repo/build/deps/english.tar.gz" "$repo/build/deps/emoji.txt" "$repo/build/deps/librime-source.tar.gz" "$repo/build/deps/librime-native-deps.tar.bz2" "$repo/build/deps/boost_1_89_0.tar.bz2"
cat > "$bin/shasum" <<'STUB'
#!/bin/bash
if [[ "$*" == *'-c -'* ]]; then cat >/dev/null; exit 0; fi
/usr/bin/shasum "$@"
STUB
cat > "$bin/tar" <<'STUB'
#!/bin/bash
echo tar >> "$EVENTS"
case "$*" in
  *librime-source*) mkdir -p build/deps/native/librime/src/rime; touch build/deps/native/librime/src/rime/translator.h
    printf '#cmakedefine RIME_ENABLE_LOGGING\n#cmakedefine RIME_DATA_DIR "@RIME_DATA_DIR@"\n' > build/deps/native/librime/src/rime/build_config.h.in ;;
  *librime-native-deps*) mkdir -p build/deps/native/deps/include/glog; touch build/deps/native/deps/include/glog/logging.h build/deps/native/deps/include/marisa.h ;;
  *boost*) mkdir -p build/deps/native/boost/boost; touch build/deps/native/boost/boost/version.hpp ;;
  *librime*) mkdir -p build/deps/dist/lib/rime-plugins; touch build/deps/dist/lib/librime.1.17.0.dylib build/deps/dist/lib/rime-plugins/librime-lua.dylib ;;
  *pinyin*) mkdir -p build/deps/rime-pinyin-simp-fixture; touch build/deps/rime-pinyin-simp-fixture/pinyin_simp.dict.yaml ;;
  *english*) mkdir -p build/deps/rime-easy-en-fixture; touch build/deps/rime-easy-en-fixture/easy_en.dict.yaml ;;
esac
STUB
chmod +x "$bin/"*
(
  cd "$repo"; export PATH="$bin:$PATH" EVENTS="$fixture/events"
  bash macOS/scripts/dependencies.sh
  [[ $(wc -l < "$EVENTS" | tr -d ' ') == 6 ]]
  bash macOS/scripts/dependencies.sh
  [[ $(wc -l < "$EVENTS" | tr -d ' ') == 6 ]]
  grep -q '#define RIME_ENABLE_LOGGING' build/deps/native/generated/rime/build_config.h
  rm -rf build/deps/dist
  bash macOS/scripts/dependencies.sh
  [[ $(wc -l < "$EVENTS" | tr -d ' ') == 12 ]]
  rm build/deps/native/boost/boost/version.hpp
  bash macOS/scripts/dependencies.sh
  [[ $(wc -l < "$EVENTS" | tr -d ' ') == 18 ]]
)
echo 'PASS dependencies cache: verified stamp skips extraction and missing output invalidates it'
