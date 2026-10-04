#!/usr/bin/env python3
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
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
        self.assertEqual(remote.commands("test", ["preparation", "dictionary-generator", "quality-metadata"], self.root),
                         [["bash", "macOS/scripts/test.sh", "preparation", "dictionary-generator", "quality-metadata"]])
        self.assertEqual(remote.commands("portable", [], self.root),
                         [["bash", "Core/Portable/test.sh", str(self.root)]])
        for action, units in [("install", []), ("test", ["all"]), ("test", []),
                              ("test", ["engine; touch bad"]), ("build", ["engine"]),
                              ("portable", ["engine"])]:
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

    def test_disconnected_stdout_keeps_logging_until_command_finishes(self):
        request = self.root / "request.json"
        request.write_text(json.dumps(dict(remote_root=str(self.runner), ref=self.ref,
                                           revision=self.revision, action="test", units=["engine"])))
        real_output = remote.output
        command = [sys.executable, "-c", "print('retained after disconnect'); raise SystemExit(8)"]
        with patch.object(remote, "commands", return_value=[command]), \
                patch.object(remote, "output", side_effect=lambda args, cwd=None:
                             real_output(args, cwd) if args[0] == "git" else "fixture"), \
                patch("builtins.print", side_effect=BrokenPipeError):
            self.assertEqual(remote.worker(request), 8)
        report = json.loads((self.root / "results/run.json").read_text())
        self.assertEqual(report["exitCode"], 8)
        self.assertTrue(report["stdoutDisconnected"])
        self.assertIn("retained after disconnect", (self.root / "results/00-test.log").read_text())
        self.assertFalse((self.runner / "run.lock").exists())

    def test_error_status_survives_disconnected_stderr(self):
        request = self.root / "request.json"
        request.write_text(json.dumps(dict(remote_root=str(self.runner), ref=self.ref,
                                           revision=self.revision, action="test", units=["engine"])))
        with patch.object(remote, "prepare_checkout", side_effect=RuntimeError("fixture failure")), \
                patch("builtins.print", side_effect=BrokenPipeError):
            self.assertEqual(remote.worker(request), 1)
        report = json.loads((self.root / "results/run.json").read_text())
        self.assertEqual(report["exitCode"], 1)
        self.assertEqual(report["error"], "fixture failure")

    def test_interrupted_action_does_not_record_success(self):
        request = self.root / "request.json"
        request.write_text(json.dumps(dict(remote_root=str(self.runner), ref=self.ref,
                                           revision=self.revision, action="test", units=["engine"])))
        with patch.object(remote, "prepare_checkout", return_value=self.source), \
                patch.object(remote, "output", return_value="fixture"), \
                patch.object(remote.subprocess, "Popen", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                remote.worker(request)
        report = json.loads((self.root / "results/run.json").read_text())
        self.assertEqual(report["exitCode"], 1)
        self.assertFalse((self.runner / "run.lock").exists())

    def run_client(self, status, transform=None, copy_status=0):
        calls = []
        transferred = {}
        real_run = subprocess.run
        remote_path = "/tmp/inkflow-remote.fixture123"

        def transport(host, args, **kwargs):
            calls.append(args)
            if args[0] == "mktemp":
                return subprocess.CompletedProcess(args, 0, stdout=remote_path + "\n")
            if args[0] == "python3":
                return subprocess.CompletedProcess(args, status)
            self.assertEqual(args, ["rm", "-rf", remote_path])
            return subprocess.CompletedProcess(args, 0)

        def subprocess_or_copy(args, **kwargs):
            if args[0] != "scp":
                return real_run(args, **kwargs)
            if "-r" not in args:
                request_path = next(Path(arg) for arg in args if arg.endswith("/request.json"))
                transferred["request"] = json.loads(request_path.read_text())
                return subprocess.CompletedProcess(args, 0)
            local = Path(args[-1])
            transferred["local"] = local
            if copy_status == 0:
                (local / "00-test.log").write_text("copied output, possibly still growing remotely\n")
                receipt = dict(transferred["request"], exitCode=status,
                               startedUTC="2026-10-04T18:00:00+00:00",
                               finishedUTC="2026-10-04T18:01:00+00:00")
                if transform is not None:
                    receipt = transform(receipt)
                if receipt is not None:
                    text = receipt if isinstance(receipt, str) else json.dumps(receipt)
                    (local / "run.json").write_text(text)
            return subprocess.CompletedProcess(args, copy_status)

        args = remote.argparse.Namespace(action="test", units=["engine"], host="fixture",
                                         remote_root="~/fixture-runner", revision="HEAD")
        messages = io.StringIO()
        with patch.object(remote, "ROOT", self.source), \
                patch.object(remote, "ssh", side_effect=transport), \
                patch.object(remote.subprocess, "run", side_effect=subprocess_or_copy), \
                redirect_stdout(messages), redirect_stderr(messages):
            result = remote.run(args)
        return result, calls, messages.getvalue(), transferred["local"]

    def test_client_disconnect_then_partial_copy_retains_live_evidence(self):
        status, calls, messages, local = self.run_client(255, transform=lambda receipt: None)
        self.assertEqual(status, 255)
        self.assertTrue((local / "00-test.log").is_file())
        self.assertFalse((local / "run.json").exists())
        self.assertFalse(any(call[0] == "rm" for call in calls))
        self.assertIn("retained remote files at /tmp/inkflow-remote.fixture123", messages)
        self.assertIn("may be incomplete", messages)

    def test_client_transport_failure_retains_even_with_a_receipt(self):
        for status in [255, -15]:
            with self.subTest(status=status):
                result, calls, messages, _ = self.run_client(status)
                self.assertEqual(result, status)
                self.assertFalse(any(call[0] == "rm" for call in calls))
                self.assertIn("SSH transport failed", messages)

    def test_client_requires_a_complete_receipt_even_after_ssh_success(self):
        for receipt in [None, "{", [], {}, {"exitCode": 0}]:
            with self.subTest(receipt=receipt):
                status, calls, messages, _ = self.run_client(0, transform=lambda _: receipt)
                self.assertEqual(status, 1)
                self.assertFalse(any(call[0] == "rm" for call in calls))
                self.assertIn("retained remote files at /tmp/inkflow-remote.fixture123", messages)

    def test_client_rejects_mismatched_or_unfinished_receipts(self):
        changes = [
            ("revision", "0" * 40), ("ref", "refs/inkflow-remote/another-run"),
            ("action", "build"), ("units", ["controller"]), ("remote_root", "~/other"),
            ("driverSHA256", "different-driver"), ("exitCode", 7), ("exitCode", False),
            ("finishedUTC", None), ("finishedUTC", ""), ("startedUTC", "invalid"),
            ("finishedUTC", "2026-10-04T17:00:00+00:00"),
            ("finishedUTC", "2026-10-04T18:01:00"),
        ]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                status, calls, messages, _ = self.run_client(0, transform=lambda receipt: dict(receipt, **{key: value}))
                self.assertEqual(status, 1)
                self.assertFalse(any(call[0] == "rm" for call in calls))
                self.assertIn("retained remote files", messages)

    def test_client_cleans_only_completed_matching_runs(self):
        for exit_code in [0, 7]:
            with self.subTest(exit_code=exit_code):
                status, calls, _, local = self.run_client(exit_code)
                self.assertEqual(status, exit_code)
                self.assertEqual(calls[-1], ["rm", "-rf", "/tmp/inkflow-remote.fixture123"])
                self.assertTrue((local / "run.json").is_file())

    def test_client_copy_failure_retains_remote_evidence(self):
        status, calls, messages, _ = self.run_client(0, copy_status=1)
        self.assertEqual(status, 1)
        self.assertFalse(any(call[0] == "rm" for call in calls))
        self.assertIn("Evidence transfer failed; retained remote files", messages)


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
