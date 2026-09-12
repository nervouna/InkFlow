#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test ai-pronunciation-tests build/ai-pronunciation-tests
build/ai-pronunciation-tests
build_swift_test ai-adoption-learning-tests build/ai-adoption-learning-tests
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-ai-learning.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
if [[ $# -eq 0 ]]; then
  shared="$user_dir/fresh-shared"
  bash macOS/scripts/prepare-rime.sh "$shared"
else
  shared="$1"
fi
[[ -s "$shared/inkflow_pinyin.custom.yaml" ]] || { echo 'Missing active-schema AI patch' >&2; exit 1; }
manager="$PWD/build/deps/dist/bin/rime_dict_manager"
export DYLD_LIBRARY_PATH="$PWD/build/deps/dist/lib"
for mode in no-voice-read voice-read; do
fixture_user="$user_dir/$mode"
mkdir -p "$fixture_user"
build/ai-adoption-learning-tests "$shared" "$fixture_user" write "$mode"
build/ai-adoption-learning-tests "$shared" "$fixture_user" read "$mode"
(cd "$fixture_user" && "$manager" -e pinyin_simp learned.txt)
awk -F '\t' '
  $1 == "你好" || $1 == "再见" { exit 1 }
  $1 == "测试" { if ($2 != "ce shi" || $3 != 1) exit 1; ordinary++ }
  $1 == "星墨量" { if ($2 != "xing mo liang" || $3 != 2) exit 1; found++ }
  $1 == "星墨蓝" { if ($2 != "xing mo lan" || $3 != 1) exit 1; found++ }
  $1 == "星墨海" { if ($2 != "xing mo hai" || $3 != 1) exit 1; found++ }
  $1 == "星墨好" { if ($2 != "xing mo hao" || $3 != 1) exit 1; found++ }
  END { if (found != 4 || ordinary != 1) exit 1 }
' "$fixture_user/learned.txt"
awk -F '\t' '!/^#/ && NF == 3 { print }' "$fixture_user/learned.txt" | LC_ALL=C sort > "$fixture_user/canonical.txt"
done
cmp "$user_dir/no-voice-read/canonical.txt" "$user_dir/voice-read/canonical.txt"
echo 'PASS voice native reads: identical export with/without attempted reads during undo; actual reads deferred until safe'
echo 'PASS canonical userdb export: correct full codes only; exact adoption counts; no raw typo/abbreviation'
echo 'PASS ordinary learning: immediate Backspace undoes commits before/after AI callbacks; retained commit learns once'
echo 'PASS fresh AI learning deployment: active schema patch, new shared data, userdb write/restart/read'
