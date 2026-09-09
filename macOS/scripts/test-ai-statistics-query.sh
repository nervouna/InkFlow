#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python_bin=$(mise which python)
# Writer runs create UUID directories. Use the latest complete synthetic pair,
# or accept an explicit directory for reproducible focused review.
writer_dir=${1:-}
if [[ -z "$writer_dir" ]]; then
  writer_dir=$("$python_bin" - <<'PY'
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
"$python_bin" macOS/Tests/AIStatisticsQueryTests.py --writer-dir "$writer_dir"
