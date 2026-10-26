#!/bin/bash
set -euo pipefail
fail() { echo "FAIL ${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]}" >&2; exit 1; }
cd "$(dirname "$0")/../.."
# macOS awk collates distinct CJK strings as equal under UTF-8 locales; compare bytes.
awk() { LC_ALL=C command awk "$@"; }
source macOS/scripts/swift-test.sh
source macOS/scripts/test-timing.sh
stage_started=$(inkflow_test_timing_now)
build_swift_test ai-pronunciation-tests build/ai-pronunciation-tests
build/ai-pronunciation-tests
build_swift_test ai-adoption-learning-tests build/ai-adoption-learning-tests
inkflow_test_timing_report ai-learning build "$stage_started"
stage_started=$(inkflow_test_timing_now)
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-ai-learning.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
if [[ $# -eq 0 ]]; then
  shared="$user_dir/fresh-shared"
  bash macOS/scripts/prepare-rime.sh "$shared"
else
  shared="$1"
fi
[[ -s "$shared/inkflow_pinyin.custom.yaml" ]] || { echo 'Missing active-schema AI patch' >&2; exit 1; }
inkflow_test_timing_report ai-learning resources "$stage_started"
# One Rime user dictionary of a closed user directory through the core's personal-data export, as
# "text<TAB>code<TAB>commits" rows with a positive count: USER NAME OUTPUT.
export_userdb() {
  build/ai-adoption-learning-tests "$shared" "$1" export "$2" "$3.raw"
  awk -F '\t' '!/^#/ && NF == 3 { split($3, packed, " "); commits = substr(packed[1], 3) + 0; code = $1
    sub(/ +$/, "", code); if (commits > 0) print $2 "\t" code "\t" commits }' "$3.raw" > "$3"
}
stage_started=$(inkflow_test_timing_now)
for mode in no-voice-read voice-read; do
fixture_user="$user_dir/$mode"
mkdir -p "$fixture_user"
build/ai-adoption-learning-tests "$shared" "$fixture_user" write "$mode"
build/ai-adoption-learning-tests "$shared" "$fixture_user" read "$mode"
export_userdb "$fixture_user" pinyin_simp "$fixture_user/learned.txt"
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
inkflow_test_timing_report ai-learning native-adoption "$stage_started"

stage_started=$(inkflow_test_timing_now)
contract_shared="$user_dir/contract-shared"
ditto "$shared" "$contract_shared"
cp macOS/scripts/fixtures/rime-learning-contract/*.yaml "$contract_shared/"
cp macOS/scripts/fixtures/rime-learning-contract/inkflow_learning_contract.lua "$contract_shared/lua/"
contract_user="$user_dir/contract-user"
mkdir -p "$contract_user"
build/ai-adoption-learning-tests "$contract_shared" "$contract_user" contract-seed
export_userdb "$contract_user" pinyin_simp "$contract_user/pinyin-before.txt"
build/ai-adoption-learning-tests "$contract_shared" "$contract_user" contract-write
export_userdb "$contract_user" pinyin_simp "$contract_user/pinyin-after.txt"
cmp "$contract_user/pinyin-before.txt" "$contract_user/pinyin-after.txt"
build/ai-adoption-learning-tests "$contract_shared" "$contract_user" contract-read
management_limit_user="$user_dir/personal-management-limit-user"
mkdir -p "$management_limit_user"
build/ai-adoption-learning-tests "$contract_shared" "$management_limit_user" contract-management-limit
export_userdb "$contract_user" inkflow_shared_english "$contract_user/shared.txt"
export_userdb "$contract_user" inkflow_voice_alias "$contract_user/voice.txt"
echo 'PASS bundled Rime contract: two isolated userdb namespaces, selection/update/undo/reopen/query, case, negative learning'
inkflow_test_timing_report ai-learning rime-contract "$stage_started"

stage_started=$(inkflow_test_timing_now)
voice_user="$user_dir/voice-correction-user"
management_user="$user_dir/personal-management-user"
mkdir -p "$management_user"
build/ai-adoption-learning-tests "$shared" "$management_user" personal-management
build/ai-adoption-learning-tests "$shared" "$management_user" personal-management-read
export_userdb "$management_user" pinyin_simp "$management_user/management-pinyin.txt"
! awk -F '\t' '!/^#/ && $3 > 0 { found=1 } END { exit found ? 0 : 1 }' "$management_user/management-pinyin.txt" || fail
mkdir -p "$voice_user"
build/ai-adoption-learning-tests "$shared" "$voice_user" voice-correction-write
build/ai-adoption-learning-tests "$shared" "$voice_user" voice-correction-read
export_userdb "$voice_user" inkflow_shared_english "$voice_user/voice-shared.txt"
export_userdb "$voice_user" inkflow_voice_alias "$voice_user/voice-alias.txt"
awk -F '\t' '$1 == "Codex" && $2 == "codex" && $3 == 1 { found++ } END { if (found != 1) exit 1 }' \
  "$voice_user/voice-shared.txt"
awk -F '\t' '$1 == "Codex" && $2 == "codux" && $3 == 1 { found++ } END { if (found != 1) exit 1 }' \
  "$voice_user/voice-alias.txt"
echo 'PASS voice correction storage: canonical shared English plus isolated exact voice alias, restart and count'

clear_user="$user_dir/voice-correction-clear-user"
mkdir -p "$clear_user"
build/ai-adoption-learning-tests "$shared" "$clear_user" voice-correction-clear
build/ai-adoption-learning-tests "$shared" "$clear_user" voice-correction-cleared-read
export_userdb "$clear_user" inkflow_shared_english "$clear_user/cleared-shared.txt"
export_userdb "$clear_user" inkflow_voice_alias "$clear_user/cleared-alias.txt"
export_userdb "$clear_user" pinyin_simp "$clear_user/retained-pinyin.txt"
! awk -F '\t' '!/^#/ && $3 > 0 { found=1 } END { exit found ? 0 : 1 }' "$clear_user/cleared-shared.txt" || fail
! awk -F '\t' '!/^#/ && $3 > 0 { found=1 } END { exit found ? 0 : 1 }' "$clear_user/cleared-alias.txt" || fail
awk -F '\t' '$1 == "测试" && $2 == "ce shi" && $3 == 1 { found=1 } END { exit found ? 0 : 1 }' "$clear_user/retained-pinyin.txt"
echo 'PASS English learning reset: both named namespaces clear across restart; pinyin userdb remains'
inkflow_test_timing_report ai-learning voice-correction "$stage_started"

stage_started=$(inkflow_test_timing_now)
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
export_userdb "$english_user" inkflow_shared_english "$english_user/keyboard-english.txt"
IFS= read -r paged < "$english_user/expected-paged-english.txt"
awk -F '\t' -v paged="$paged" '
  $1 == "hello" { if ($2 != "hello" || $3 != 3) exit 1; hello++ }
  $1 == "computer" { if ($2 != "computer" || $3 != 1) exit 1; computer++ }
  $1 == "PrivatePlugin" { if ($2 != "plugin" || $3 != 2) exit 1; private++ }
  $1 == "Hello" { if ($2 != "hello" || $3 != 1) exit 1; caseful++ }
  $1 == paged { if ($2 != tolower(paged) || $3 != 1) exit 1; paged_count++ }
  END { if (hello != 1 || computer != 1 || private != 1 || caseful != 1 || paged_count != 1) exit 1 }
' "$english_user/keyboard-english.txt"
echo 'PASS canonical keyboard English learning: first/repeated/negative/restart, paging/editing, dedup, exact/completion, fidelity, private exact admission, short conflicts, Chinese baseline'
inkflow_test_timing_report ai-learning keyboard-english "$stage_started"

stage_started=$(inkflow_test_timing_now)
mixed_user="$user_dir/mixed-user"
mkdir -p "$mixed_user"
letters_user="$user_dir/mixed-letters-user"
mkdir -p "$letters_user"
build/ai-adoption-learning-tests "$shared" "$letters_user" mixed-letter-write
build/ai-adoption-learning-tests "$shared" "$letters_user" mixed-letter-read
build/ai-adoption-learning-tests "$contract_shared" "$letters_user" contract-mixed-letters-verify
export_userdb "$letters_user" pinyin_simp "$letters_user/letters-pinyin.txt"
! awk -F '\t' '!/^#/ && $3 > 0 { found=1 } END { exit found ? 0 : 1 }' "$letters_user/letters-pinyin.txt" || fail
echo 'PASS learned letters: actual standalone A/I selection, unchanged ordinary Pinyin on every page, source preedit, technical context, restart and undo isolation'

immediate_user="$user_dir/mixed-immediate-user"
mkdir -p "$immediate_user"
build/ai-adoption-learning-tests "$contract_shared" "$immediate_user" contract-mixed-immediate
conflicts_user="$user_dir/mixed-pinyin-conflicts-user"
mkdir -p "$conflicts_user"
build/ai-adoption-learning-tests "$contract_shared" "$conflicts_user" contract-mixed-pinyin-conflicts

ranking_user="$user_dir/ranking-user"
mkdir -p "$ranking_user"
build/ai-adoption-learning-tests "$contract_shared" "$ranking_user" contract-ranking-seed
build/ai-adoption-learning-tests "$shared" "$ranking_user" mixed-ranking-read
build/ai-adoption-learning-tests "$contract_shared" "$mixed_user" contract-seed
export_userdb "$mixed_user" pinyin_simp "$mixed_user/mixed-pinyin-before.txt"
build/ai-adoption-learning-tests "$contract_shared" "$mixed_user" contract-mixed-seed
build/ai-adoption-learning-tests "$contract_shared" "$mixed_user" mixed-bounded
build/ai-adoption-learning-tests "$shared" "$mixed_user" mixed-read
build/ai-adoption-learning-tests "$shared" "$mixed_user" mixed-restart
build/ai-adoption-learning-tests "$contract_shared" "$mixed_user" contract-mixed-verify
export_userdb "$mixed_user" pinyin_simp "$mixed_user/mixed-pinyin-after.txt"
cmp "$mixed_user/mixed-pinyin-before.txt" "$mixed_user/mixed-pinyin-after.txt"
echo 'PASS mixed personal English: immediate shared exact lookup, initial/internal/final, restart, no completion, source preedit, fidelity, editing, selected prefix, paging, dedup, read-only selection, collisions, custom phrases'
inkflow_test_timing_report ai-learning mixed-input "$stage_started"
