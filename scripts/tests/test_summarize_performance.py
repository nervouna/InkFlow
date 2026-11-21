#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("performance", ROOT / "Core/scripts/summarize-performance.py")
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class PerformanceTests(unittest.TestCase):
    def test_nearest_rank_and_median(self):
        self.assertEqual(
            performance.distribution([4, 1, 3, 2]),
            dict(count=4, median=2.5, p95=4, p99=4, max=4),
        )
        result = performance.distribution(list(range(1, 101)))
        self.assertEqual((result["p95"], result["p99"]), (95, 99))

    def test_invalid_measurements(self):
        for values in [[], [-1], [float("nan")], [float("inf")]]:
            with self.assertRaises(ValueError):
                performance.distribution(values)


if __name__ == "__main__":
    unittest.main()
