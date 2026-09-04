#!/bin/sh

set -eu

engine_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
engine_repo_root=$(CDPATH='' cd -- "${engine_script_dir}/../.." && pwd)
engine_build_dir="${engine_repo_root}/build/cmake/engine"
engine_archive="${engine_build_dir}/engine/libinkflow_engine.a"
engine_link_closure="${engine_build_dir}/engine/libinkflow_engine_link_closure.dylib"
engine_symbol_manifest="${engine_repo_root}/engine/exports/inkflow_engine.symbols"

engine_require_command() {
  if ! command -v "${1}" >/dev/null 2>&1; then
    printf '%s\n' "error: required command not found: ${1}" >&2
    exit 1
  fi
}

engine_require_command awk
engine_require_command cmake
engine_require_command cmp
engine_require_command ctest
engine_require_command nm
engine_require_command otool
engine_require_command rg
engine_require_command ruby

printf '%s\n' "Verifying exact engine dependency metadata..."
ruby "${engine_script_dir}/check_dependency_lock.rb"

printf '%s\n' "Configuring and building the real librime engine..."
cmake --preset engine -S "${engine_repo_root}"
cmake --build --preset engine --parallel
cmake --build --preset engine --target inkflow_engine_link_closure --parallel
ctest --preset engine

if [ ! -f "${engine_archive}" ] || [ ! -f "${engine_link_closure}" ]; then
  printf '%s\n' "error: engine archive or full link closure was not produced" >&2
  exit 1
fi

engine_tmp_parent=${TMPDIR:-/tmp}
engine_tmp_dir=$(mktemp -d "${engine_tmp_parent%/}/inkflow-engine.XXXXXX")
engine_cleanup() {
  case "${engine_tmp_dir}" in
    "${engine_tmp_parent%/}"/inkflow-engine.*)
      rm -rf -- "${engine_tmp_dir}"
      ;;
    *)
      printf '%s\n' \
        "warning: refusing to clean unexpected temporary path: ${engine_tmp_dir}" >&2
      ;;
  esac
}
trap engine_cleanup EXIT HUP INT TERM

if command -v ninja >/dev/null 2>&1; then
  engine_ninja=$(command -v ninja)
else
  engine_android_cmake_version=$(ruby -rjson -e \
    'print JSON.parse(File.read(ARGV.fetch(0))).dig("android", "cmakeVersion")' \
    "${engine_repo_root}/toolchains.lock.json")
  engine_android_sdk_root=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}
  engine_ninja="${engine_android_sdk_root}/cmake/${engine_android_cmake_version}/bin/ninja"
fi
if [ -x "${engine_ninja}" ]; then
  printf '%s\n' \
    "Verifying Ninja configuration after the Unix Makefiles population..."
  cmake \
    -S "${engine_repo_root}" \
    -B "${engine_tmp_dir}/ninja-preflight" \
    -G Ninja \
    "-DCMAKE_MAKE_PROGRAM=${engine_ninja}" \
    -DBUILD_TESTING=OFF \
    -DINKFLOW_ENGINE_BACKEND=rime \
    "-DINKFLOW_DEPENDENCY_CACHE_DIR=${engine_repo_root}/build/dependencies"
  printf '%s\n' "PASS generator-isolated FetchContent population"
else
  printf '%s\n' \
    "SKIP Ninja-after-Makefiles preflight (Ninja is not installed)"
fi

engine_expected_symbols="${engine_tmp_dir}/expected-symbols"
engine_actual_symbols="${engine_tmp_dir}/actual-symbols"
engine_manifest_count=$(awk 'NF { count += 1 } END { print count + 0 }' \
  "${engine_symbol_manifest}")
if [ "${engine_manifest_count}" -ne 27 ]; then
  printf '%s\n' "error: engine symbol manifest must contain 27 names" >&2
  exit 1
fi
awk 'NF { print "_" $0 }' "${engine_symbol_manifest}" | \
  sort -u >"${engine_expected_symbols}"

nm -m "${engine_archive}" | awk \
  '/ external / && !/undefined/ && !/private external/ &&
      !/automatically hidden/ && $NF ~ /^_inkflow_/ {print $NF}' | \
  sort -u >"${engine_actual_symbols}"
if ! cmp "${engine_expected_symbols}" "${engine_actual_symbols}"; then
  printf '%s\n' "error: exported engine C symbols do not match engine.h" >&2
  exit 1
fi

if nm -m "${engine_archive}" | awk '
    / external / && !/undefined/ && !/private external/ &&
        !/automatically hidden/ && $NF !~ /^_inkflow_/ {
      print
      found = 1
    }
    END { exit found ? 0 : 1 }
  '; then
  printf '%s\n' "error: engine archive exposes an undocumented text symbol" >&2
  exit 1
fi
printf '%s\n' "PASS engine archive exports exactly the 27 documented C symbols"

nm -gjU "${engine_link_closure}" | sort -u >"${engine_actual_symbols}"
if ! cmp "${engine_expected_symbols}" "${engine_actual_symbols}"; then
  printf '%s\n' \
    "error: full native link closure does not expose exactly engine.h" >&2
  exit 1
fi
if ! nm -m "${engine_link_closure}" | awk '
    /non-external/ && $NF == "_rime_get_api" { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
  printf '%s\n' "error: shared audit artifact omitted the librime closure" >&2
  exit 1
fi
printf '%s\n' \
  "PASS full native link closure exports exactly the 27 documented C symbols"

for engine_test in \
    inkflow_engine_contract_test \
    inkflow_engine_lifecycle_test \
    inkflow_engine_transcript_test; do
  engine_test_path="${engine_build_dir}/engine/${engine_test}"
  if [ ! -x "${engine_test_path}" ]; then
    printf '%s\n' "error: test executable is missing: ${engine_test}" >&2
    exit 1
  fi
  if otool -L "${engine_test_path}" | \
      rg -q '/opt/homebrew|/usr/local|librime|libboost|libopencc'; then
    printf '%s\n' \
      "error: ${engine_test} dynamically loads a machine-local engine dependency" >&2
    otool -L "${engine_test_path}" >&2
    exit 1
  fi
done
if otool -L "${engine_link_closure}" | \
    rg -q '/opt/homebrew|/usr/local|librime|libboost|libopencc'; then
  printf '%s\n' \
    "error: full native link closure loads a machine-local dependency" >&2
  otool -L "${engine_link_closure}" >&2
  exit 1
fi
printf '%s\n' "PASS host tests have no machine-local engine dynamic dependencies"

printf '%s\n' "Shared engine verification passed."
