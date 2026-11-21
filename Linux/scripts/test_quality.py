#!/usr/bin/env python3
import json
import os
from contextlib import closing
from datetime import date, timedelta
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import quality


class QualityReport(unittest.TestCase):
    def test_incomplete_export_can_be_retried(self):
        with tempfile.TemporaryDirectory() as temporary:
            dest = Path(temporary) / "quality.json"
            with patch.object(quality.os, "fsync", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    quality.export({"count": 5}, dest)
            self.assertEqual(list(dest.parent.iterdir()), [])
            quality.export({"count": 7}, dest)
            with self.assertRaises(FileExistsError):
                quality.export({"count": 0}, dest)
            self.assertEqual(list(dest.parent.iterdir()), [dest])
            self.assertEqual(json.loads(dest.read_text()), {"count": 7})

    def test_window_buckets_and_privacy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            db = root / "inkflow/quality/counts.sqlite3"
            today = date.today()
            self.assertIsNone(quality.report(db, today)["overall"]["paged_rate"])
            self.assertFalse(db.exists())
            db.parent.mkdir(parents=True)
            with closing(sqlite3.connect(db)) as con:
                con.execute("CREATE TABLE counts_v1(day,length,context,page_size,rank_bin,n)")
                for days_ago, length, context, size, rank, n in (
                        (28, 1, 0, 5, 0, 50), (27, 1, 0, 5, 0, 2), (0, 2, 1, 7, 1, 3),
                        (0, 2, 1, 7, 2, 4), (0, 3, 0, 9, 3, 1), (-1, 1, 0, 5, 0, 50)):
                    day = today - timedelta(days=days_ago)
                    con.execute("INSERT INTO counts_v1 VALUES(?,?,?,?,?,?)", (day.isoformat(), length,
                                                                             context, size, rank, n))
                con.commit()
            data = quality.report(db, today)
            score = data["overall"]
            self.assertEqual([score[key] for key in ("known_rank", "top1_selected", "top3_selected", "paged_selected")],
                             [10, 2, 5, 1])
            self.assertAlmostEqual(score["top3_wilson_low"], 0.23659, places=5)
            self.assertAlmostEqual(score["top3_wilson_high"], 0.76341, places=5)
            self.assertEqual(data["by_selection_length"]["3+"]["paged_rate"], 1)
            self.assertEqual(data["by_context"]["available"]["top3_selected"], 3)
            self.assertEqual(data["by_page_size"]["7"]["known_rank"], 7)
            self.assertIsNone(data["by_page_size"]["3"]["top1_wilson_low"])
            self.assertEqual(sum(row["known_rank"] for row in data["groups"]), 10)
            dest = root / "report.json"
            args = [sys.executable, quality.__file__, "--export", str(dest)]
            env = {**os.environ, "XDG_DATA_HOME": temporary}
            subprocess.run(args, env=env, check=True, capture_output=True)
            self.assertEqual(json.loads(dest.read_text()), data)
            self.assertEqual(dest.stat().st_mode & 0o777, 0o600)
            self.assertNotEqual(subprocess.run(args, env=env, capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
