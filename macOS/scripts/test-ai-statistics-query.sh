#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $(uname -s) == Darwin ]]; then
  if [[ ${1:-} == /* ]]; then
    repository=$(pwd -P)
    writer_dir=$(cd -- "$1" && pwd -P)
    case "$writer_dir" in
      "$repository") writer_dir=. ;;
      "$repository"/*) writer_dir=${writer_dir#"$repository"/} ;;
      *) echo 'Writer fixture must be inside the selected repository.' >&2; exit 1 ;;
    esac
    shift
    set -- "$writer_dir" "$@"
  fi
  exec devbox "$PWD" -- bash macOS/scripts/test-ai-statistics-query.sh "$@"
fi
# Writer runs create UUID directories. Use the latest complete synthetic pair,
# or accept an explicit directory for reproducible focused review.
writer_dir=${1:-}
if [[ -z "$writer_dir" ]]; then
  writer_dir=$(python3 - <<'PY'
from pathlib import Path
fixtures = [path.parent for path in Path('build/ai-statistics-evidence').glob('writer-*/retained-fixture.sqlite3')
            if (path.parent / 'ai-statistics.sqlite3').is_file()]
if not fixtures:
    raise SystemExit('Run macOS/scripts/test-ai-statistics.sh first: actual writer fixtures are required.')
print(max(fixtures, key=lambda path: (path / 'retained-fixture.sqlite3').stat().st_mtime_ns))
PY
)
fi
echo "AI query actual writer fixture: $writer_dir"
python3 macOS/Tests/AIStatisticsQueryTests.py --writer-dir "$writer_dir"
