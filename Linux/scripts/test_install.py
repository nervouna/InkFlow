#!/usr/bin/env python3
"""Installer tests use temporary XDG directories and never contact a desktop."""
import configparser
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class Desktop:
    def __init__(self):
        self.stops = self.starts = 0
        self.fail_start = False
        self.service = "fixture-fcitx5.service"

    def stop(self):
        self.stops += 1

    def start(self):
        self.starts += 1
        if self.fail_start:
            self.fail_start = False
            raise RuntimeError("fixture service failed to start")


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.manager = installer.Installer(self.root / "data", self.root / "config")
        self.manager.root.mkdir(parents=True)
        self.desktop = Desktop()
        self.libraries = patch.object(installer, "check_libraries")
        self.libraries.start()
        self.addCleanup(self.libraries.stop)
        profile = self.manager.paths["profile"]
        profile.parent.mkdir(parents=True)
        profile.write_text("[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=pinyin\n"
                           "[Groups/0/Items/0]\nName=keyboard-us\n"
                           "[Groups/0/Items/1]\nName=pinyin\n"
                           "[GroupOrder]\n0=Default\n")
        self.learning = self.manager.root / "rime/pinyin_simp.userdb/fixture"
        self.learning.parent.mkdir(parents=True)
        self.learning.write_bytes(b"personal-learning-must-survive")
        self.settings = profile.parent / "conf/inkflow.conf"
        self.settings.parent.mkdir()
        self.settings.write_text("CandidateCount=7\n[CustomPhrases]\n0=dz=private-fixture\n")

    def package(self, revision):
        package = self.root / revision
        package.mkdir()
        for name in installer.REQUIRED:
            path = package / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(revision + "\n")
        (package / "share/fcitx5/inputmethod/inkflow-pinyin.conf").write_text(
            "[InputMethod]\nName=InkFlow Pinyin\nAddon=inkflow\n")
        self.manifest(package, revision)
        return package

    def manifest(self, package, revision):
        manifest = {"format": 1, "architecture": platform.machine(), "revision": revision * 40,
                    "files": {p.relative_to(package).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in package.rglob("*") if p.is_file() and p.name != "package.json"}}
        (package / "package.json").write_text(json.dumps(manifest))

    def profile(self):
        profile = configparser.ConfigParser(interpolation=None)
        profile.read(self.manager.paths["profile"])
        return profile

    def assert_personal_data(self):
        self.assertEqual(self.learning.read_bytes(), b"personal-learning-must-survive")
        self.assertIn("private-fixture", self.settings.read_text())

    def test_install_upgrade_rollback_and_uninstall(self):
        first, second = self.package("a"), self.package("b")
        first_id, second_id = installer.validate(first), installer.validate(second)
        self.manager.install(first, self.desktop)
        self.assertEqual(self.manager.state(), {"current": first_id, "previous": None})
        self.assertEqual(self.profile()["Groups/0"]["DefaultIM"], "pinyin")
        self.assertEqual(self.profile()["Groups/0/Items/2"]["Name"], "inkflow-pinyin")
        self.manager.install(second, self.desktop)
        self.assertEqual(self.manager.state(), {"current": second_id, "previous": first_id})
        self.manager.rollback(self.desktop)
        self.assertEqual(self.manager.paths["current"].resolve(), self.manager.releases / first_id)
        self.assertEqual(self.manager.state(), {"current": first_id, "previous": second_id})
        self.manager.install(second, self.desktop)
        self.manager.uninstall(self.desktop)
        self.assertFalse(self.manager.paths["current"].exists())
        self.assertFalse(self.manager.paths["addon"].exists())
        self.assertFalse(self.manager.releases.exists())
        self.assertEqual(self.profile()["Groups/0/Items/1"]["Name"], "pinyin")
        self.assertNotIn("inkflow-pinyin", self.manager.paths["profile"].read_text())
        self.assert_personal_data()
        self.assertEqual(self.desktop.stops, self.desktop.starts)

    def test_same_package_is_idempotent(self):
        package = self.package("a")
        self.manager.install(package, self.desktop)
        before = self.manager.snapshot()
        self.manager.install(package, self.desktop)
        self.assertEqual(before, self.manager.snapshot())
        self.assertEqual(self.desktop.stops, 1)

    def test_modified_package_and_architecture_are_rejected_before_stopping(self):
        package = self.package("a")
        (package / "lib/fcitx5/libinkflow.so").write_text("corrupt")
        with self.assertRaises(ValueError):
            self.manager.install(package, self.desktop)
        self.manifest(package, "a")
        manifest = json.loads((package / "package.json").read_text())
        manifest["architecture"] = "other-cpu"
        (package / "package.json").write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            self.manager.install(package, self.desktop)
        self.assertEqual(self.desktop.stops, 0)
        self.assert_personal_data()

    def test_symlinks_and_extra_files_are_rejected(self):
        package = self.package("a")
        (package / "extra").write_text("unlisted")
        with self.assertRaises(ValueError):
            installer.validate(package)
        (package / "extra").unlink()
        (package / "escape").symlink_to(self.learning.parent, target_is_directory=True)
        with self.assertRaises(ValueError):
            installer.validate(package)

    def test_write_failure_restores_old_installation(self):
        self.manager.install(self.package("a"), self.desktop)
        before = self.manager.snapshot()
        write = installer.atomic_write
        failed = False

        def fail_once(path, data):
            nonlocal failed
            if path == self.manager.paths["entry"] and not failed:
                failed = True
                raise OSError("fixture full disk")
            write(path, data)

        with patch.object(installer, "atomic_write", side_effect=fail_once):
            with self.assertRaises(OSError):
                self.manager.install(self.package("b"), self.desktop)
        self.assertEqual(self.manager.snapshot(), before)
        self.assertFalse(self.manager.journal.exists())
        self.assert_personal_data()

    def test_service_start_failure_restores_old_installation(self):
        self.manager.install(self.package("a"), self.desktop)
        before = self.manager.snapshot()
        self.desktop.fail_start = True
        with self.assertRaises(RuntimeError):
            self.manager.install(self.package("b"), self.desktop)
        self.assertEqual(self.manager.snapshot(), before)
        self.assertFalse(self.manager.journal.exists())

    def test_interrupted_install_recovers_before_retry(self):
        package = self.package("a")
        self.manager.install(package, self.desktop)
        before = self.manager.snapshot()
        self.manager.journal.write_text(json.dumps({"files": before, "service": self.desktop.service}))
        self.manager.paths["addon"].write_text("interrupted")
        with self.assertRaises(RuntimeError):
            self.manager.install(package, self.desktop)
        self.manager.recover(self.desktop)
        self.assertEqual(self.manager.snapshot(), before)
        self.assertFalse(self.manager.journal.exists())

    def test_manual_registration_can_be_restored_without_replacing_later_profile_changes(self):
        for name, content in (("addon", b"original custom addon"), ("entry", b"original custom entry")):
            self.manager.paths[name].parent.mkdir(parents=True, exist_ok=True)
            self.manager.paths[name].write_bytes(content)
        self.manager.install(self.package("a"), self.desktop)
        self.manager.install(self.package("b"), self.desktop)
        profile = self.manager.paths["profile"]
        with profile.open("a") as output:
            output.write("[Groups/0/Items/3]\nName=other-ime\n")
        self.manager.restore_manual(self.desktop)
        self.assertEqual(self.manager.paths["addon"].read_bytes(), b"original custom addon")
        self.assertEqual(self.manager.paths["entry"].read_bytes(), b"original custom entry")
        self.assertIn("Name=other-ime", profile.read_text())
        self.assertFalse(self.manager.paths["current"].exists())
        self.assertEqual(self.manager.state(), {})
        self.assert_personal_data()

    def test_persistent_restore_failure_keeps_journal_and_service_stopped(self):
        self.manager.install(self.package("a"), self.desktop)
        starts = self.desktop.starts
        write = installer.atomic_write

        def persistent_failure(path, data):
            if path == self.manager.paths["addon"]:
                raise OSError("fixture persistent I/O failure")
            write(path, data)

        with patch.object(installer, "atomic_write", side_effect=persistent_failure):
            with self.assertRaises(OSError):
                self.manager.install(self.package("b"), self.desktop)
            self.assertTrue(self.manager.journal.exists())
            self.assertEqual(self.desktop.starts, starts)
            with self.assertRaises(OSError):
                self.manager.recover(self.desktop)
            self.assertEqual(self.desktop.starts, starts)
        self.manager.recover(self.desktop)
        self.assertFalse(self.manager.journal.exists())
        self.assertEqual(self.desktop.starts, starts + 1)

    def test_journal_records_service_before_shutdown(self):
        original = self.desktop.stop

        def inspect_stop():
            record = json.loads(self.manager.journal.read_text())
            self.assertEqual(record["service"], "fixture-fcitx5.service")
            self.assertIn("files", record)
            original()

        with patch.object(self.desktop, "stop", side_effect=inspect_stop):
            self.manager.install(self.package("a"), self.desktop)

    def test_recovery_before_mutations_preserves_shutdown_profile_flush(self):
        self.manager.journal.write_text(json.dumps({"files": None, "service": self.desktop.service}))
        profile = self.manager.paths["profile"]
        profile.write_text(profile.read_text() + "[Groups/0/Items/2]\nName=recently-added-ime\n")
        after_shutdown = profile.read_bytes()
        self.manager.recover(self.desktop)
        self.assertEqual(profile.read_bytes(), after_shutdown)
        self.assertEqual(self.desktop.starts, 1)

    def test_partial_manual_registration_is_saved(self):
        package = self.package("a")
        for name in ("addon", "entry"):
            with self.subTest(name=name):
                manager = installer.Installer(self.root / name / "data", self.root / name / "config")
                with manager.locked():
                    path = manager.paths[name]
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("manual override")
                    manager.install(package, self.desktop)
                    manager.restore_manual(self.desktop)
                    self.assertEqual(path.read_text(), "manual override")
                    absent = "entry" if name == "addon" else "addon"
                    self.assertFalse(manager.paths[absent].exists())

    def test_atomic_updates_sync_the_containing_directory(self):
        path = self.manager.root / "durability-fixture"
        with patch.object(installer, "sync_directory", wraps=installer.sync_directory) as sync:
            installer.atomic_write(path, b"fixture")
            sync.assert_called_with(path.parent)
            sync.reset_mock()
            installer.durable_unlink(path)
            sync.assert_called_once_with(path.parent)

    def test_missing_compiled_resource_is_rejected_even_with_fresh_hashes(self):
        package = self.package("a")
        (package / (installer.CACHE + "inkflow_spelling_31.prism.bin")).unlink()
        self.manifest(package, "a")
        with self.assertRaises(ValueError):
            self.manager.install(package, self.desktop)
        self.assertEqual(self.desktop.stops, 0)

    def test_rollback_rejects_damaged_previous_release(self):
        self.manager.install(self.package("a"), self.desktop)
        previous = self.manager.paths["current"].resolve()
        self.manager.install(self.package("b"), self.desktop)
        before = self.manager.snapshot()
        (previous / "lib/fcitx5/libinkflow.so").write_text("damaged")
        with self.assertRaises(ValueError):
            self.manager.rollback(self.desktop)
        self.assertEqual(before, self.manager.snapshot())

    def test_uninstall_selects_keyboard_if_inkflow_was_default(self):
        self.manager.install(self.package("a"), self.desktop)
        profile = self.manager.paths["profile"]
        profile.write_text(profile.read_text().replace("DefaultIM=pinyin", "DefaultIM=inkflow-pinyin"))
        self.manager.uninstall(self.desktop)
        self.assertEqual(self.profile()["Groups/0"]["DefaultIM"], "keyboard-us")
        self.assert_personal_data()

    def test_second_group_and_later_user_entries_survive(self):
        profile = self.manager.paths["profile"]
        with profile.open("a") as stream:
            stream.write("[Groups/1]\nName=Other\nDefault Layout=de\nDefaultIM=keyboard-de\n"
                         "[Groups/1/Items/0]\nName=keyboard-de\n")
        self.manager.install(self.package("a"), self.desktop)
        with profile.open("a") as stream:
            stream.write("[Groups/0/Items/3]\nName=other-ime\n")
        self.manager.install(self.package("b"), self.desktop)
        self.manager.rollback(self.desktop)
        self.assertIn("Name=other-ime", profile.read_text())
        self.manager.uninstall(self.desktop)
        self.assertIn("Name=other-ime", profile.read_text())
        self.assertEqual(self.profile()["Groups/1/Items/0"]["Name"], "keyboard-de")
        self.assertEqual(self.profile()["Groups/1"]["DefaultIM"], "keyboard-de")

    def test_fresh_profile_has_keyboard_fallback(self):
        self.manager.paths["profile"].unlink()
        self.manager.install(self.package("a"), self.desktop)
        self.assertEqual(self.profile()["Groups/0/Items/0"]["Name"], "keyboard-us")
        self.assertEqual(self.profile()["Groups/0/Items/1"]["Name"], "inkflow-pinyin")


class DesktopTests(unittest.TestCase):
    def test_recovery_remembers_inactive_service(self):
        with patch.object(installer.Desktop, "running", return_value=False), \
             patch.object(installer.subprocess, "run") as run:
            desktop = installer.Desktop("omarchy-fcitx5.service", resume=True)
            desktop.start()
            run.assert_called_once_with(
                ["systemctl", "--user", "start", "omarchy-fcitx5.service"], check=True)

    def test_nonzero_stop_is_safe_only_when_process_is_gone(self):
        with patch.object(installer.Desktop, "running", return_value=False), \
             patch.object(installer.subprocess, "run") as run:
            run.return_value.returncode = 1
            desktop = installer.Desktop("omarchy-fcitx5.service", resume=True)
            desktop.stop()
            with patch.object(installer.Desktop, "running", return_value=True):
                with self.assertRaises(RuntimeError):
                    desktop.stop()
            self.assertFalse(any("start" in call.args[0] for call in run.call_args_list))


if __name__ == "__main__":
    unittest.main()
