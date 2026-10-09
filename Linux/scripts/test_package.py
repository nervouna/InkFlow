#!/usr/bin/env python3
"""Exercise a real package's install/upgrade/rollback/uninstall in temporary directories."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("installer", Path(__file__).with_name("install.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class NoDesktop:
    # Each addon check starts its own private daemon; never stop the user's service.
    service = None

    def stop(self):
        pass

    def start(self):
        pass


def main():
    package = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parents[2]
    identifier = installer.validate(package)
    with tempfile.TemporaryDirectory(prefix="inkflow-package-") as temporary:
        scratch = Path(temporary)
        prefix = scratch / "prefix"
        manager = installer.Installer(prefix / "share", prefix / "config")
        desktop = NoDesktop()
        with manager.locked():
            personal = manager.root / "rime/installer-preservation-fixture"
            personal.parent.mkdir()
            personal.write_bytes(b"personal-data-fixture")
            settings = prefix / "config/fcitx5/conf/inkflow.conf"
            settings.parent.mkdir(parents=True)
            settings.write_text("CandidateCount=7\n")

            def check():
                subprocess.run(["bash", "Linux/fcitx5/test-installed.sh", str(prefix)], cwd=root, check=True)
                assert personal.read_bytes() == b"personal-data-fixture"
                assert settings.read_text() == "CandidateCount=7\n"

            manager.install(package, desktop)
            check()
            # A distinct test-only package exercises replacement using the same target binaries.
            newer = scratch / "upgrade-fixture"
            shutil.copytree(package, newer)
            marker = newer / "upgrade-fixture.txt"
            marker.write_text("Test-only package identity for the upgrade exercise.\n")
            manifest = json.loads((newer / "package.json").read_text())
            manifest["files"][marker.name] = hashlib.sha256(marker.read_bytes()).hexdigest()
            (newer / "package.json").write_text(json.dumps(manifest, sort_keys=True))
            manager.install(newer, desktop)
            assert manager.state()["previous"] == identifier
            check()
            manager.rollback(desktop)
            assert manager.state()["current"] == identifier
            check()
            manager.uninstall(desktop)
            assert not manager.paths["addon"].exists()
            assert not manager.paths["entry"].exists()
            assert not manager.paths["current"].exists()
            assert not manager.releases.exists()
            assert personal.read_bytes() == b"personal-data-fixture"
            assert settings.read_text() == "CandidateCount=7\n"
    print("PASS real package install, upgrade-fixture, rollback and uninstall; personal files preserved")


if __name__ == "__main__":
    main()
