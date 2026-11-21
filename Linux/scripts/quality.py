#!/usr/bin/env python3
"""Report the last 28 local calendar days of content-free Linux Chinese candidate decisions."""
import argparse
from contextlib import closing
from datetime import date, timedelta
import json
import math
import os
from pathlib import Path
import sqlite3
import sys
import tempfile


def wilson(hits, total):
    if not total:
        return None, None, None
    z = 1.959963984540054
    p = hits / total
    center = p + z * z / (2 * total)
    spread = z * math.sqrt((p * (1 - p) + z * z / (4 * total)) / total)
    denom = 1 + z * z / total
    return p, max(0, (center - spread) / denom), min(1, (center + spread) / denom)


def score(bins):
    total = sum(bins)
    result = {"known_rank": total}
    for name, count in (("top1", bins[0]), ("top3", bins[0] + bins[1]), ("paged", bins[3])):
        result[name + "_selected"] = count
        rate, low, high = wilson(count, total)
        result[name + "_rate"] = rate
        result[name + "_wilson_low"] = low
        result[name + "_wilson_high"] = high
    return result


def report(database, today):
    start = today - timedelta(days=27)
    total = [0] * 4
    groups = {
        "by_selection_length": {key: [0] * 4 for key in ("1", "2", "3+")},
        "by_context": {key: [0] * 4 for key in ("unavailable", "available")},
        "by_page_size": {str(size): [0] * 4 for size in range(3, 10)},
    }
    cells = {}
    try:
        database.stat()
    except FileNotFoundError:
        rows = []
    else:
        with closing(sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=1)) as db:
            rows = db.execute(
                "SELECT length, context, page_size, rank_bin, sum(n) FROM counts_v1 WHERE day BETWEEN ? AND ? "
                "GROUP BY length, context, page_size, rank_bin ORDER BY length, context, page_size, rank_bin",
                (start.isoformat(), today.isoformat())).fetchall()
    for length, context, size, rank, n in rows:
        if length not in (1, 2, 3) or context not in (0, 1) or not 3 <= size <= 9 or rank not in range(4) or n < 1:
            raise ValueError("Invalid quality aggregate")
        length_key = ("1", "2", "3+")[length - 1]
        context_key = ("unavailable", "available")[context]
        total[rank] += n
        groups["by_selection_length"][length_key][rank] += n
        groups["by_context"][context_key][rank] += n
        groups["by_page_size"][str(size)][rank] += n
        cells.setdefault((length_key, context_key, size), [0] * 4)[rank] += n
    result = {"format": 1, "start_day": start.isoformat(), "end_day": today.isoformat(), "overall": score(total)}
    result.update({name: {key: score(bins) for key, bins in values.items()} for name, values in groups.items()})
    result["groups"] = [{"selection_length": length, "context": context, "page_size": size, **score(bins)}
                        for (length, context, size), bins in cells.items()]
    return result


def display(data):
    print(f"Chinese candidate selections · {data['start_day']} to {data['end_day']} (local days)")
    print("Group                      Known   Top 1 / 95% CI        Top 3 / 95% CI        Paged / 95% CI")

    def row(label, values):
        fields = []
        for field in ("top1", "top3", "paged"):
            hits = values[field + "_selected"]
            p = values[field + "_rate"]
            if p is None:
                fields.append("0 · unavailable")
            else:
                low, high = (values[field + suffix] for suffix in ("_wilson_low", "_wilson_high"))
                fields.append(f"{hits} · {p:.1%} [{low:.1%},{high:.1%}]")
        print(f"{label:25} {values['known_rank']:5}   " + "  ".join(f"{item:<20}" for item in fields))

    row("Overall", data["overall"])
    for group, label in (("by_selection_length", "Length"), ("by_context", "Context"), ("by_page_size", "Page size")):
        for key, values in data[group].items():
            row(f"{label} {key}", values)


def export(data, destination):
    with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, prefix=".inkflow-quality-", delete=False) as out:
        temporary = Path(out.name)
        try:
            json.dump(data, out, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
            out.close()
            os.link(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="Print machine-readable counts and rates")
    output.add_argument("--export", type=Path, metavar="FILE", help="Write the JSON report to a new private file")
    args = parser.parse_args()
    data_home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local/share")
    try:
        data = report(Path(data_home) / "inkflow/quality/counts.sqlite3", date.today())
        if args.export:
            export(data, args.export)
            print(f"Exported {args.export}")
        elif args.json:
            print(json.dumps(data, indent=2))
        else:
            display(data)
    except (OSError, sqlite3.Error, ValueError) as error:
        print(f"Quality report unavailable: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
