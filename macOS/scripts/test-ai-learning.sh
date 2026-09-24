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

contract_shared="$user_dir/contract-shared"
ditto "$shared" "$contract_shared"
cp macOS/scripts/fixtures/rime-learning-contract/*.yaml "$contract_shared/"
cp macOS/scripts/fixtures/rime-learning-contract/inkflow_learning_contract.lua "$contract_shared/lua/"
contract_user="$user_dir/contract-user"
mkdir -p "$contract_user"
build/ai-adoption-learning-tests "$contract_shared" "$contract_user" contract-seed
(cd "$contract_user" && "$manager" -e pinyin_simp pinyin-before.txt)
build/ai-adoption-learning-tests "$contract_shared" "$contract_user" contract-write
(cd "$contract_user" && "$manager" -e pinyin_simp pinyin-after.txt)
cmp "$contract_user/pinyin-before.txt" "$contract_user/pinyin-after.txt"
build/ai-adoption-learning-tests "$contract_shared" "$contract_user" contract-read
(cd "$contract_user" && "$manager" -e inkflow_shared_english shared.txt)
(cd "$contract_user" && "$manager" -e inkflow_voice_alias voice.txt)
echo 'PASS bundled Rime contract: two isolated userdb namespaces, selection/update/undo/reopen/query, case, negative learning'

voice_user="$user_dir/voice-correction-user"
mkdir -p "$voice_user"
build/ai-adoption-learning-tests "$shared" "$voice_user" voice-correction-write
build/ai-adoption-learning-tests "$shared" "$voice_user" voice-correction-read
(cd "$voice_user" && "$manager" -e inkflow_shared_english voice-shared.txt)
(cd "$voice_user" && "$manager" -e inkflow_voice_alias voice-alias.txt)
awk -F '\t' '$1 == "Codex" && $2 == "codex" && $3 == 1 { found++ } END { if (found != 1) exit 1 }' \
  "$voice_user/voice-shared.txt"
awk -F '\t' '$1 == "Codex" && $2 == "codux" && $3 == 1 { found++ } END { if (found != 1) exit 1 }' \
  "$voice_user/voice-alias.txt"
echo 'PASS voice correction storage: canonical shared English plus isolated exact voice alias, restart and count'

english_negative_user="$user_dir/english-negative-user"
mkdir -p "$english_negative_user"
build/ai-adoption-learning-tests "$shared" "$english_negative_user" english-negative
build/ai-adoption-learning-tests "$contract_shared" "$english_negative_user" contract-keyboard-negative

english_user="$user_dir/english-user"
mkdir -p "$english_user"
build/ai-adoption-learning-tests "$shared" "$english_user" english-write
build/ai-adoption-learning-tests "$contract_shared" "$english_user" contract-keyboard-read
build/ai-adoption-learning-tests "$contract_shared" "$english_user" contract-personal-seed
build/ai-adoption-learning-tests "$shared" "$english_user" english-read
(cd "$english_user" && "$manager" -e inkflow_shared_english keyboard-english.txt)
IFS= read -r paged < "$english_user/expected-paged-english.txt"
awk -F '\t' -v paged="$paged" '
  $1 == "hello" { if ($2 != "hello" || $3 != 3) exit 1; hello++ }
  $1 == "computer" { if ($2 != "computer" || $3 != 1) exit 1; computer++ }
  $1 == "PrivatePlugin" { if ($2 != "plugin" || $3 != 2) exit 1; private++ }
  $1 == "Hello" { if ($2 != "hello" || $3 != 1) exit 1; caseful++ }
  $1 == paged { if ($2 != paged || $3 != 1) exit 1; paged_count++ }
  END { if (hello != 1 || computer != 1 || private != 1 || caseful != 1 || paged_count != 1) exit 1 }
' "$english_user/keyboard-english.txt"
echo 'PASS canonical keyboard English learning: first/repeated/negative/restart, paging/editing, dedup, exact/completion, fidelity, private exact admission, short conflicts, Chinese baseline'

mixed_user="$user_dir/mixed-user"
mkdir -p "$mixed_user"
ranking_user="$user_dir/ranking-user"
mkdir -p "$ranking_user"
build/ai-adoption-learning-tests "$contract_shared" "$ranking_user" contract-ranking-seed
build/ai-adoption-learning-tests "$shared" "$ranking_user" mixed-ranking-read
build/ai-adoption-learning-tests "$contract_shared" "$mixed_user" contract-mixed-seed
build/ai-adoption-learning-tests "$contract_shared" "$mixed_user" mixed-bounded
build/ai-adoption-learning-tests "$shared" "$mixed_user" mixed-read
build/ai-adoption-learning-tests "$shared" "$mixed_user" mixed-restart
build/ai-adoption-learning-tests "$contract_shared" "$mixed_user" contract-mixed-verify
echo 'PASS mixed personal English: shared exact lookup, initial/internal/final, restart, no completion, fidelity, editing, paging, dedup, selection, collisions, custom phrases'
