#!/bin/bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
evidence="$PWD/build/gui-verification"
fail() { echo "$*" >&2; exit 1; }
snapshot() (
  temporary_index=$(mktemp "${TMPDIR:-/tmp}/inkflow-gui-index.XXXXXX")
  trap 'rm -f "$temporary_index"' EXIT
  rm "$temporary_index"
  export GIT_INDEX_FILE="$temporary_index"
  git read-tree HEAD
  git add -A -- .
  git write-tree
)
case "${1:-}" in
  record)
    mkdir -p "$evidence"
    mkdir "$evidence/running" 2>/dev/null || fail 'GUI recording already running; inspect before retrying.'
    trap 'rmdir "$evidence/running"' EXIT
    rm -f "$evidence/passed.tree"
    tested=$(snapshot)
    # A fresh bundle avoids stale files; keep the previous build for diagnosis.
    if [[ -e build/InkFlow.app ]]; then
      backup=$(mktemp -d "$PWD/build/gui-previous.XXXXXX")
      mv build/InkFlow.app "$backup/"
    fi
    for script in build test-controller-initialization test-settings-ui; do
      if ! bash "macOS/scripts/$script.sh" > "$evidence/$script.log" 2>&1; then
        fail "GUI evidence not recorded: $script failed. See $evidence/$script.log"
      fi
    done
    [[ "$(snapshot)" == "$tested" ]] || fail 'Source changed during GUI verification.'
    printf '%s\n' "$tested" > "$evidence/passed.tree"
    echo "PASS: GUI verification recorded for $tested"
    ;;
  check)
    [[ ! -d "$evidence/running" ]] || fail 'GUI verification is still running.'
    [[ -f "$evidence/passed.tree" ]] || fail 'No passing GUI record. Run gui-verification.sh record on an unlocked desktop.'
    for script in build test-controller-initialization test-settings-ui; do
      [[ -f "$evidence/$script.log" ]] || fail 'GUI verification log is missing.'
    done
    tested=$(cat "$evidence/passed.tree")
    [[ "$tested" =~ ^[0-9a-f]{40}$ && "$(git cat-file -t "$tested" 2>/dev/null)" == tree ]] || fail 'GUI verification tree is unavailable.'
    current=$(snapshot)
    git diff --quiet "$tested" "$current" -- . ':(exclude)macOS/Info.plist' || fail 'Source differs from the GUI-tested tree.'
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-gui-evidence.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    git show "$tested:macOS/Info.plist" > "$scratch/tested.plist"
    [[ ! -L macOS/Info.plist ]] || fail 'Info.plist must be a regular file.'
    cp macOS/Info.plist "$scratch/current.plist"
    # Do not exempt permission changes or unrelated plist fields.
    [[ "$(git ls-tree "$tested" macOS/Info.plist | awk '{print $1}')" == 100644 && ! -x macOS/Info.plist ]] || fail 'Info.plist mode changed.'
    version=$(plutil -extract CFBundleShortVersionString raw "$scratch/current.plist")
    build=$(plutil -extract CFBundleVersion raw "$scratch/current.plist")
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$build" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid release version/build.'
    for file in "$scratch/tested.plist" "$scratch/current.plist"; do
      plutil -remove CFBundleShortVersionString "$file"
      plutil -remove CFBundleVersion "$file"
      plutil -convert xml1 "$file"
    done
    cmp -s "$scratch/tested.plist" "$scratch/current.plist" || fail 'Info.plist changed beyond version/build.'
    echo "PASS: reuse GUI results from $tested; only version/build differences allowed"
    ;;
  *) fail 'Usage: gui-verification.sh record|check (run inside the target checkout)' ;;
esac
