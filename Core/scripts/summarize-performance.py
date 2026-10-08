#!/usr/bin/env python3
"""Summarize raw headless measurements without asserting an unapproved budget."""

import hashlib
import json
import math
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys


def distribution(values):
    ordered = sorted(values)
    if not ordered or not all(math.isfinite(value) and value >= 0 for value in ordered):
        raise ValueError("Expected finite nonnegative measurements")
    return {
        "count": len(ordered),
        "median": statistics.median(ordered),
        "p95": ordered[math.ceil(len(ordered) * 0.95) - 1],
        "p99": ordered[math.ceil(len(ordered) * 0.99) - 1],
        "max": ordered[-1],
    }


def summarize(directory):
    root = Path(__file__).resolve().parents[2]
    behavior = json.loads((directory / "behavior.json").read_text())
    paths = [directory / f"performance-{trial}.json" for trial in range(1, 6)]
    trials = [json.loads(path.read_text()) for path in paths]
    expected = [(pass_index, sample["id"], offset)
                for pass_index in range(5) for sample in behavior["corpus"]["samples"]
                for offset in range(len(sample["input"]))]
    for trial in trials:
        if (trial["formatVersion"] != 1 or trial["inputOptions"] != behavior["inputOptions"]
                or trial["candidateCount"] != behavior["corpus"]["candidateCount"]
                or [(key["pass"], key["sample"], key["offset"]) for key in trial["timings"]] != expected):
            raise ValueError("Performance corpus/configuration or operation coverage differs")
    timings = [key for trial in trials for key in trial["timings"]]
    fingerprint_paths = [
        "rust-toolchain.toml", "macOS/scripts/dependencies.sh", "Core/Package.swift",
        "Core/Tests/PerformanceBaseline/PerformanceBaseline.swift",
        "Core/scripts/capture-migration-baseline.sh", "Core/scripts/summarize-performance.py",
        "build/core-tests/performance-baseline",
    ]
    result = {
        "formatVersion": 1,
        "configuration": "release",
        "target": "arm64-apple-macosx26.0",
        "sourceRevision": behavior["provenance"]["sourceRevision"],
        "behaviorProvenance": behavior["provenance"],
        "system": platform.platform(),
        "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "memoryBytes": int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True)),
        "swift": subprocess.check_output(["xcrun", "swift", "--version"], text=True).strip(),
        "rust": subprocess.check_output(["rustc", "--version"], text=True).strip() if shutil.which("rustc") else None,
        "fingerprints": {path: hashlib.sha256((root / path).read_bytes()).hexdigest()
                         for path in fingerprint_paths},
        "rawReportSHA256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                           for path in [directory / "behavior.json", *paths]},
        "protocol": {
            "processTrials": 5, "corpusPassesPerProcess": 5,
            "startup": "Prepared-cache descriptor, context index, Rime start, session creation and default configuration; excludes process launch and dictionary compilation",
            "key": "Synchronous IFEngine.input + takeCommit + snapshot; excludes platform delivery, UI, queued actor work and telemetry",
            "state": "Absent user directory per process, no commits/training, empty context and no custom phrases",
            "cache": "Fresh processes; OS filesystem cache is not flushed. First-pass and repeated-pass timings are separate",
            "memory": "Darwin getrusage ru_maxrss bytes: process peak RSS, not current resident memory or app footprint",
            "percentile": "Nearest rank; median is the midpoint average for even counts",
        },
        "startupMilliseconds": distribution([trial["startupMilliseconds"] for trial in trials]),
        "peakResidentBytesAfterStartup": distribution([trial["peakResidentBytesAfterStartup"] for trial in trials]),
        "peakResidentBytesAfterInput": distribution([trial["peakResidentBytesAfterInput"] for trial in trials]),
        "firstPassKeyMilliseconds": distribution([key["milliseconds"] for key in timings if key["pass"] == 0]),
        "repeatedPassKeyMilliseconds": distribution([key["milliseconds"] for key in timings if key["pass"] > 0]),
        "perProcess": [{
            "trial": index + 1,
            "startupMilliseconds": trial["startupMilliseconds"],
            "firstPassKeyMilliseconds": distribution([key["milliseconds"] for key in trial["timings"] if key["pass"] == 0]),
            "repeatedPassKeyMilliseconds": distribution([key["milliseconds"] for key in trial["timings"] if key["pass"] > 0]),
        } for index, trial in enumerate(trials)],
        "slowestKeys": sorted(timings, key=lambda key: key["milliseconds"], reverse=True)[:20],
    }
    (directory / "summary.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    for name in ["startupMilliseconds", "peakResidentBytesAfterInput",
                 "firstPassKeyMilliseconds", "repeatedPassKeyMilliseconds"]:
        print(name + ": " + json.dumps(result[name]))


if __name__ == "__main__":
    summarize(Path(sys.argv[1]).resolve())
