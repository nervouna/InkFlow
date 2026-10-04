#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


remote = load("mac_remote", ROOT / "scripts/mac-remote.py")
performance = load("performance", ROOT / "Core/scripts/summarize-performance.py")


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.source / "tracked").write_text("first\n")
        self.git("add", "tracked")
        self.git("commit", "-qm", "first")
        self.revision = self.git("rev-parse", "HEAD")
        self.ref = "refs/heads/fixture"
        self.git("update-ref", self.ref, self.revision)
        self.bundle = self.root / "source.bundle"
        self.git("bundle", "create", str(self.bundle), self.ref)
        self.runner = self.root / "runner"

    def git(self, *args):
        return remote.output(["git", *args], self.source)

    def checkout(self):
        return remote.prepare_checkout(self.runner, self.bundle, self.ref, self.revision)

    def test_exact_revision_and_detached_checkout(self):
        self.runner.mkdir()
        repo = self.checkout()
        self.assertEqual(remote.output(["git", "rev-parse", "HEAD"], repo), self.revision)
        self.assertEqual(remote.output(["git", "rev-parse", "--abbrev-ref", "HEAD"], repo), "HEAD")
        self.assertEqual(self.checkout(), repo)

    def test_dirty_tracked_and_untracked_files_are_preserved(self):
        self.runner.mkdir()
        repo = self.checkout()
        for filename in ["tracked", "untracked"]:
            path = repo / filename
            path.write_text("do not overwrite\n")
            with self.assertRaisesRegex(RuntimeError, "Dirty checkout"):
                self.checkout()
            self.assertEqual(path.read_text(), "do not overwrite\n")
            if filename == "tracked":
                path.write_text("first\n")
            else:
                path.unlink()

    def test_unowned_checkout_is_rejected(self):
        (self.runner / "checkout").mkdir(parents=True)
        with self.assertRaisesRegex(RuntimeError, "not created by this runner"):
            self.checkout()

    def test_bundle_mismatch_is_rejected(self):
        self.runner.mkdir()
        with self.assertRaisesRegex(RuntimeError, "does not match"):
            remote.prepare_checkout(self.runner, self.bundle, self.ref, "0" * 40)

    def test_lock_conflict_and_exception_cleanup(self):
        with remote.checkout_lock(self.runner):
            with self.assertRaisesRegex(RuntimeError, "active or interrupted"):
                with remote.checkout_lock(self.runner):
                    self.fail("acquired another run's lock")
            self.assertTrue((self.runner / "run.lock/owner.json").is_file())
        self.assertFalse((self.runner / "run.lock").exists())
        with self.assertRaisesRegex(ValueError, "fixture"):
            with remote.checkout_lock(self.runner):
                raise ValueError("fixture")
        self.assertFalse((self.runner / "run.lock").exists())

    def test_action_allowlist(self):
        self.assertEqual(remote.commands("test", ["engine"], self.root),
                         [["bash", "macOS/scripts/test.sh", "engine"]])
        for action, units in [("install", []), ("test", ["all"]), ("test", []),
                              ("test", ["engine; touch bad"]), ("build", ["engine"])]:
            with self.assertRaises(ValueError):
                remote.commands(action, units, self.root)

    def test_worker_retains_failure_logs_status_and_releases_lock(self):
        request = self.root / "request.json"
        request.write_text(json.dumps(dict(remote_root=str(self.runner), ref=self.ref,
                                           revision=self.revision, action="test", units=["engine"])))
        real_output = remote.output

        def metadata_or_git(args, cwd=None):
            return real_output(args, cwd) if args[0] == "git" else "fixture toolchain"

        command = [sys.executable, "-c", "print('failure evidence'); raise SystemExit(7)"]
        with patch.object(remote, "commands", return_value=[command]), \
                patch.object(remote, "output", side_effect=metadata_or_git):
            self.assertEqual(remote.worker(request), 7)
        report = json.loads((self.root / "results/run.json").read_text())
        self.assertEqual(report["exitCode"], 7)
        self.assertEqual(report["revision"], self.revision)
        self.assertIn("failure evidence", (self.root / "results/00-test.log").read_text())
        self.assertFalse((self.runner / "run.lock").exists())


class PerformanceTests(unittest.TestCase):
    def test_nearest_rank_and_median(self):
        self.assertEqual(performance.distribution([4, 1, 3, 2]),
                         dict(count=4, median=2.5, p95=4, p99=4, max=4))
        result = performance.distribution(list(range(1, 101)))
        self.assertEqual((result["p95"], result["p99"]), (95, 99))

    def test_invalid_measurements(self):
        for values in [[], [-1], [float("nan")], [float("inf")]]:
            with self.assertRaises(ValueError):
                performance.distribution(values)


if __name__ == "__main__":
    unittest.main()
