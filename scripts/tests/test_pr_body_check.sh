#!/usr/bin/env bash
set -euo pipefail

check="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pr-body-check.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PR_BODY=$'## Summary\n\nFixes #295\n' bash "$check" || fail "Fixes #N was rejected"
PR_BODY='closes #7' bash "$check" || fail "closes #N was rejected"
PR_BODY='Refs #12' bash "$check" || fail "Refs #N was rejected"
! PR_BODY=$'## Summary\n\nFixes #\n' bash "$check" 2>/dev/null || fail "Fixes # without a number passed"
! PR_BODY='Fixes 295' bash "$check" 2>/dev/null || fail "Fixes without # passed"
! PR_BODY='' bash "$check" 2>/dev/null || fail "an empty body passed"
! env -u PR_BODY bash "$check" 2>/dev/null || fail "an unset body passed"
echo "pr-body-check tests passed"
