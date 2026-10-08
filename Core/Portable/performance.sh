#!/bin/bash
# Capture the Rust engine with the recorded macOS headless protocol: five fresh release
# processes, absent user directories, the quality corpus typed five times. Reports the
# distributions beside the approved review limits; it does not fail on them.
set -euo pipefail
cd "$(dirname "$0")/../.."
resources=${1:?Usage: performance.sh RESOURCES_DIRECTORY [OUTPUT_DIRECTORY]}
[[ -f "$resources/prepared/complete" ]] || { echo "Not a prepared resources directory: $resources" >&2; exit 2; }
resources=$(cd "$resources" && pwd)
output=${2:-build/portable/performance}
mkdir -p "$output"; output=$(cd "$output" && pwd)
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
cargo build --locked --release --manifest-path Core/Portable/Cargo.toml --bin performance-baseline
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-portable-performance.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
for trial in 1 2 3 4 5; do
  build/portable/cargo/release/performance-baseline "$resources" "$scratch/user-$trial" \
    Core/Fixtures/QualityBaseline/corpus.json "$output/performance-$trial.json" 2>/dev/null
done
python3 - "$output" <<'PY'
import json, math, sys
from pathlib import Path
output = Path(sys.argv[1])
trials = [json.loads((output / f"performance-{trial}.json").read_text()) for trial in range(1, 6)]
def distribution(values):
    ordered = sorted(values)
    return {"count": len(ordered), "median": round(float(__import__('statistics').median(ordered)), 3),
            "p95": round(ordered[math.ceil(len(ordered) * 0.95) - 1], 3),
            "p99": round(ordered[math.ceil(len(ordered) * 0.99) - 1], 3), "max": round(ordered[-1], 3)}
keys = [key for trial in trials for key in trial["timings"]]
summary = {
    "protocol": "Core/Tests/PerformanceBaseline/PerformanceBaseline.swift on the Rust engine: release build, five processes, five corpus passes, absent user directory, no commits",
    "startupMilliseconds": distribution([t["startupMilliseconds"] for t in trials]),
    "peakResidentMiBAfterInput": distribution([t["peakResidentBytesAfterInput"] / 1048576 for t in trials]),
    "firstPassKeyMilliseconds": distribution([k["milliseconds"] for k in keys if k["pass"] == 0]),
    "repeatedPassKeyMilliseconds": distribution([k["milliseconds"] for k in keys if k["pass"] > 0]),
    "firstKeyPerProcessMilliseconds": [round(t["timings"][0]["milliseconds"], 3) for t in trials],
}
# Core/Fixtures/MigrationBaseline/README.md, approved review limits.
limits = [("startup median", summary["startupMilliseconds"]["median"], 2300),
          ("peak RSS after input max MiB", summary["peakResidentMiBAfterInput"]["max"], 344),
          ("repeated-pass key p95", summary["repeatedPassKeyMilliseconds"]["p95"], 1.8),
          ("repeated-pass key p99", summary["repeatedPassKeyMilliseconds"]["p99"], 2.3),
          ("first-pass key p99", summary["firstPassKeyMilliseconds"]["p99"], 2.6),
          ("max first key", max(summary["firstKeyPerProcessMilliseconds"]), 25)]
summary["approvedLimits"] = [{"metric": m, "value": v, "limit": l, "withinLimit": v <= l} for m, v, l in limits]
(output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
for name in ["startupMilliseconds", "peakResidentMiBAfterInput", "firstPassKeyMilliseconds", "repeatedPassKeyMilliseconds", "firstKeyPerProcessMilliseconds"]:
    print(f"{name}: {json.dumps(summary[name])}")
for item in summary["approvedLimits"]:
    print(f"{'ok ' if item['withinLimit'] else 'OVER'} {item['metric']}: {item['value']} (limit {item['limit']})")
PY
