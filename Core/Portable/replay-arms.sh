#!/bin/bash
# Arms for engine-mode replay (README: "Engine-mode replay and the octagram arms"). Each arm is one
# prepared resources directory that differs from the others only in the schema's `grammar` node and
# the .gram file in shared/; the cache is compiled again for it. The `off` arm is another binary
# (build-native.py --without-octagram), and `lotem` records `bgc-lotem`, the one arm that is not a
# resource: it needs an engine whose runtime patch lacks max_homophones and max_homographs.
#   replay-arms.sh PREPARED_RESOURCES ARMS_DIRECTORY       builds plugin, bgc and bgw
#   replay-arms.sh lotem ARMS_DIRECTORY CASES RECORD_FILE  records bgc-lotem on the bgc arm
set -euo pipefail
cd "$(dirname "$0")/../.."
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
# lotem/rime-octagram-data (LGPL-3.0) at the commit resource-dependencies.sh pins for bgc. The bgw
# model is only ever fetched here, for the measurement, and is never bundled.
bgw_sha=d3cb2438c1fdcd6a855dd6ca8f5c1060a29273c6b64c2c2c69af67cd71b6aa7e
octagram_data=https://raw.githubusercontent.com/lotem/rime-octagram-data/f8ce3b534733e489a8470a7c2adf5a154e8ea069
bgw=build/replay/zh-hans-t-essay-bgw.gram
sha256=(shasum -a 256)
if command -v sha256sum >/dev/null
then
  sha256=(sha256sum)
fi

fail() {
  echo "$1" >&2
  exit 2
}

fetch_bgw() {
  mkdir -p build/replay
  if [[ ! -f "$bgw" ]]
  then
    curl --fail --location --proto '=https' --connect-timeout 20 --max-time 300 --retry 2 \
      "$octagram_data/zh-hans-t-essay-bgw.gram" -o "$bgw.part"
    mv "$bgw.part" "$bgw"
  fi
  printf '%s  %s\n' "$bgw_sha" "$bgw" | "${sha256[@]}" -c -
}

# One arm: a copy of the prepared shared/ with the grammar node of LANGUAGE (none if empty), then its cache.
make_arm() {
  local name=$1 language=$2 model=$3 directory="$arms/$1"
  mkdir -p "$directory"
  cp -R "$resources/shared" "$directory/shared"
  if [[ -n "$model" && ! -f "$directory/shared/$language.gram" ]]
  then
    cp "$model" "$directory/shared/$language.gram"
  fi
  python3 - "$directory/shared/inkflow_pinyin.schema.yaml" "$language" <<'PY'
import sys
path, language = sys.argv[1:]
kept = []
skipping = False
for line in open(path).read().splitlines(keepends=True):
    if line.startswith('grammar:'):
        skipping = True
        continue
    if skipping and line[:1] in ' \t':
        continue
    skipping = False
    kept.append(line)
text = ''.join(kept)
if text and not text.endswith('\n'):
    text += '\n'
if language:
    text += f'grammar:\n  language: {language}\n  collocation_max_length: 5\n  collocation_min_length: 2\n'
open(path, 'w').write(text)
PY
  build/portable/cargo/release/prepare-resources "$directory/shared" "$directory/prepared" > /dev/null
  echo "arm $name: ${language:-no grammar node}"
}

if [[ ${1:-} == lotem ]]
then
  arms=${2:?Usage: replay-arms.sh lotem ARMS_DIRECTORY CASES RECORD_FILE}
  cases=${3:?Usage: replay-arms.sh lotem ARMS_DIRECTORY CASES RECORD_FILE}
  record=${4:?Usage: replay-arms.sh lotem ARMS_DIRECTORY CASES RECORD_FILE}
  [[ -f "$arms/bgc/prepared/complete" ]] || fail "No bgc arm in $arms; run replay-arms.sh first."
  # The same engine sources minus the two limits, built against the same native prefix in a scratch
  # tree, so the repository stays untouched and the engine gets no replay-only switch.
  tree=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-replay-lotem.XXXXXX")
  trap 'rm -rf "$tree"' EXIT
  mkdir -p "$tree/Core" "$tree/build"
  cp -R Core/Portable "$tree/Core/Portable"
  cp rust-toolchain.toml "$tree/"
  ln -s "$PWD/build/portable" "$tree/build/portable"
  python3 - "$tree/Core/Portable/src/engine.rs" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
limits = '''\\
             \\n  max_homophones: 7\\n  max_homographs: 7"'''
assert text.count(limits) == 1
open(path, 'w').write(text.replace(limits, '"'))
PY
  CARGO_TARGET_DIR="$tree/target" cargo build --locked --release \
    --manifest-path "$tree/Core/Portable/Cargo.toml" --bin replay
  "$tree/target/release/replay" engine "$cases" --arm "bgc-lotem=$arms/bgc" --record "bgc-lotem=$record"
  exit 0
fi

resources=${1:?Usage: replay-arms.sh PREPARED_RESOURCES ARMS_DIRECTORY}
arms=${2:?Usage: replay-arms.sh PREPARED_RESOURCES ARMS_DIRECTORY}
[[ -f "$resources/prepared/complete" ]] || fail "Not a prepared resources directory: $resources"
[[ -f "$resources/shared/zh-hans-t-essay-bgc.gram" ]] || fail "No bgc model in $resources/shared."
[[ ! -e "$arms" ]] || fail "$arms exists; choose a new directory."
resources=$(cd "$resources" && pwd)
fetch_bgw
cargo build --locked --release --manifest-path Core/Portable/Cargo.toml --bin prepare-resources --bin replay
mkdir -p "$arms"
arms=$(cd "$arms" && pwd)
make_arm plugin "" ""
make_arm bgc zh-hans-t-essay-bgc ""
make_arm bgw zh-hans-t-essay-bgw "$bgw"
echo "--arm plugin=$arms/plugin --arm bgc=$arms/bgc --arm bgw=$arms/bgw"
