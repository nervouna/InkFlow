#!/usr/bin/env python3
"""Install a local InkFlow package without root or changes to personal dictionaries."""
import argparse
import base64
import configparser
from contextlib import contextmanager
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import tempfile


RELEASE = re.compile(r"[0-9a-f]{12}-[0-9a-f]{12}\Z")
REQUIRED = {
    "lib/fcitx5/libinkflow.so", "lib/inkflow/librime.so.1",
    "share/fcitx5/inputmethod/inkflow-pinyin.conf",
    "share/inkflow/rime/prepared/complete",
    "share/inkflow/rime/shared/pinyin_simp.context.bin",
}
CACHE = "share/inkflow/rime/prepared/cache/"
SHARED = "share/inkflow/rime/shared/"
REQUIRED |= {CACHE + name for name in ("default.yaml", "inkflow_pinyin.schema.yaml",
                                      "easy_en.schema.yaml", "inkflow_mixed.schema.yaml")}
REQUIRED |= {CACHE + name + suffix for name in ("pinyin_simp", "easy_en", "inkflow_mixed")
             for suffix in (".table.bin", ".prism.bin", ".reverse.bin")}
REQUIRED |= {CACHE + f"inkflow_spelling_{mask}" + suffix for mask in range(32)
             for suffix in (".prism.bin", ".schema.yaml")}
REQUIRED |= {SHARED + "lua/" + name + ".lua" for name in (
    "inkflow_ai_learning", "inkflow_channel", "inkflow_english", "inkflow_input_coverage",
    "inkflow_mixed", "inkflow_short_conflict")}
REQUIRED |= {SHARED + "opencc/" + name for name in (
    "STCharacters.txt", "STPhrases.txt", "inkflow_emoji.json", "inkflow_s2t.json", "emoji.txt")}


def validate(package):
    manifest_path = package / "package.json"
    if manifest_path.is_symlink():
        raise ValueError("Package manifest must not be a symlink")
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    if manifest.get("format") != 1 or manifest.get("architecture") != platform.machine():
        raise ValueError("Unsupported package format or CPU architecture")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("revision", "")):
        raise ValueError("Package must identify its source revision")
    files = manifest.get("files", {})
    if not isinstance(files, dict) or not REQUIRED <= files.keys():
        raise ValueError("Package is missing required files")
    actual = set()
    for path in package.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"Package symlinks are not supported: {path}")
        if path.is_file() and path != manifest_path:
            actual.add(path.relative_to(package).as_posix())
    if actual != files.keys():
        raise ValueError("Package inventory does not match its manifest")
    for name, digest in files.items():
        relative = PurePosixPath(name)
        if relative.is_absolute() or ".." in relative.parts or str(relative) != name:
            raise ValueError(f"Invalid package path: {name}")
        if hashlib.sha256((package / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Package checksum mismatch: {name}")
    identifier = manifest["revision"][:12] + "-" + hashlib.sha256(raw).hexdigest()[:12]
    return identifier


def check_libraries(package):
    result = subprocess.run(["ldd", "-r", str(package / "lib/fcitx5/libinkflow.so")],
                            text=True, capture_output=True)
    if result.returncode or any(s in result.stdout + result.stderr for s in ("not found", "undefined symbol")):
        raise RuntimeError("Fcitx5 or native dependencies are missing:\n" + result.stdout + result.stderr)


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".inkflow-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def atomic_link(path, target):
    temporary = path.with_name(path.name + ".new")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    os.replace(temporary, path)


def edit_profile(path, enable):
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    if path.exists():
        config.read_string(path.read_text())
    groups = [s for s in config.sections() if re.fullmatch(r"Groups/[0-9]+", s)]
    if not groups and enable:
        groups = ["Groups/0"]
        config[groups[0]] = {"Name": "Default", "Default Layout": "us", "DefaultIM": "keyboard-us"}
        config["GroupOrder"] = {"0": "Default"}
    for group in groups:
        items = [s for s in config.sections() if re.fullmatch(re.escape(group) + r"/Items/[0-9]+", s)]
        entries = [dict(config[s]) for s in sorted(items, key=lambda s: int(s.rsplit("/", 1)[1]))
                   if enable or config[s].get("Name") != "inkflow-pinyin"]
        if not any(e.get("Name", "").startswith("keyboard-") for e in entries):
            entries.insert(0, {"Name": "keyboard-us", "Layout": ""})
        if enable and not any(e.get("Name") == "inkflow-pinyin" for e in entries):
            entries.append({"Name": "inkflow-pinyin", "Layout": ""})
        elif not enable and config[group].get("DefaultIM") == "inkflow-pinyin":
            config[group]["DefaultIM"] = entries[0]["Name"]
        for item in items:
            config.remove_section(item)
        for index, entry in enumerate(entries):
            config[f"{group}/Items/{index}"] = entry
    text = io.StringIO()
    config.write(text, space_around_delimiters=False)
    return text.getvalue().encode()


class Desktop:
    def __init__(self, service=None, resume=False):
        self.service = service if resume else None
        candidates = [service] if service else ["omarchy-fcitx5.service", "fcitx5.service", "plasma-fcitx5.service"]
        if not self.service:
            for candidate in candidates:
                if subprocess.run(["systemctl", "--user", "is-active", "--quiet", candidate],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
                    self.service = candidate
                    break
        if self.running() and not self.service:
            raise RuntimeError("Quit Fcitx5 first, or pass --service NAME for its active user service")

    @staticmethod
    def running():
        return subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "fcitx5"],
                              stdout=subprocess.DEVNULL).returncode == 0

    def stop(self):
        if self.service:
            subprocess.run(["systemctl", "--user", "stop", self.service], check=False)
        if self.running():
            raise RuntimeError("Fcitx5 is still running; stop it before retrying or recovering")

    def start(self):
        if self.service:
            subprocess.run(["systemctl", "--user", "start", self.service], check=True)


class Installer:
    def __init__(self, data, config):
        self.root = data / "inkflow"
        self.releases = self.root / "releases"
        self.paths = {
            "current": self.root / "current",
            "state": self.root / "installation.json",
            "addon": data / "fcitx5/addon/inkflow.conf",
            "entry": data / "fcitx5/inputmethod/inkflow-pinyin.conf",
            "profile": config / "fcitx5/profile",
        }
        self.journal = self.root / "installation-backup.json"
        self.manual = self.root / "manual-installation.json"

    @contextmanager
    def locked(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.root / ".installation.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def state(self):
        state = json.loads(self.paths["state"].read_text()) if self.paths["state"].exists() else {}
        for name in ("current", "previous"):
            if state.get(name) is not None and not RELEASE.fullmatch(state[name]):
                raise ValueError("Invalid installation state")
        return state

    def snapshot(self):
        result = {}
        for name, path in self.paths.items():
            if path.is_symlink():
                result[name] = {"link": os.readlink(path)}
            elif path.exists():
                result[name] = {"bytes": base64.b64encode(path.read_bytes()).decode()}
            else:
                result[name] = None
        return result

    def restore(self, backup):
        for name, value in backup.items():
            path = self.paths[name]
            if value is None:
                path.unlink(missing_ok=True)
            elif "link" in value:
                atomic_link(path, value["link"])
            else:
                atomic_write(path, base64.b64decode(value["bytes"]))

    @contextmanager
    def transaction(self, desktop):
        if self.journal.exists():
            raise RuntimeError("An interrupted operation needs the recover command first")
        backup = self.snapshot()
        record = {"files": backup, "service": desktop.service}
        atomic_write(self.journal, json.dumps(record).encode())
        try:
            desktop.stop()
            # Fcitx5 can flush its profile during shutdown.
            backup = self.snapshot()
            record["files"] = backup
            atomic_write(self.journal, json.dumps(record).encode())
            yield
            desktop.start()
            self.journal.unlink()
        except BaseException:
            desktop.stop()
            self.restore(backup)
            desktop.start()
            self.journal.unlink()
            raise

    def recover(self, desktop):
        if not self.journal.exists():
            raise RuntimeError("No interrupted operation to recover")
        desktop.stop()
        self.restore(json.loads(self.journal.read_text())["files"])
        desktop.start()
        self.journal.unlink()

    def restore_manual(self, desktop):
        if not self.manual.exists():
            raise RuntimeError("No saved manual-installation registration")
        with self.transaction(desktop):
            self.restore(json.loads(self.manual.read_text()))
        print("Restored the prior manual registration; profile and personal data were kept.")

    def activate(self, identifier, previous):
        atomic_link(self.paths["current"], "releases/" + identifier)
        library = self.paths["current"] / "lib/fcitx5/libinkflow"
        descriptor = ("[Addon]\nName=InkFlow\nComment=InkFlow Pinyin\nCategory=InputMethod\n"
                      f"Library={library}\nType=SharedLibrary\nOnDemand=True\nConfigurable=True\n")
        atomic_write(self.paths["addon"], descriptor.encode())
        entry = self.releases / identifier / "share/fcitx5/inputmethod/inkflow-pinyin.conf"
        atomic_write(self.paths["entry"], entry.read_bytes())
        atomic_write(self.paths["profile"], edit_profile(self.paths["profile"], True))
        atomic_write(self.paths["state"], json.dumps({"current": identifier, "previous": previous}).encode())

    def install(self, package, desktop):
        if self.journal.exists():
            raise RuntimeError("An interrupted operation needs the recover command first")
        identifier = validate(package)
        check_libraries(package)
        state = self.state()
        if state.get("current") == identifier:
            validate(self.releases / identifier)
            print("Already installed:", identifier)
            return
        self.releases.mkdir(parents=True, exist_ok=True)
        target = self.releases / identifier
        if not target.exists():
            staging = Path(tempfile.mkdtemp(prefix=".stage-", dir=self.releases))
            try:
                shutil.copytree(package, staging, dirs_exist_ok=True)
                if validate(staging) != identifier:
                    raise ValueError("Package changed while being copied")
                staging.rename(target)
            finally:
                if staging.exists():
                    shutil.rmtree(staging)
        elif validate(target) != identifier:
            raise ValueError("Installed release does not match its name")
        with self.transaction(desktop):
            if not state and self.paths["addon"].exists() and self.paths["entry"].exists():
                baseline = {name: value for name, value in self.snapshot().items() if name != "profile"}
                atomic_write(self.manual, json.dumps(baseline).encode())
            self.activate(identifier, state.get("current"))
        print("Installed:", identifier)

    def rollback(self, desktop):
        state = self.state()
        previous = state.get("previous")
        if not previous:
            raise RuntimeError("No previous managed release; use uninstall for a first installation")
        package = self.releases / previous
        if validate(package) != previous:
            raise ValueError("Previous release is damaged")
        check_libraries(package)
        with self.transaction(desktop):
            self.activate(previous, state["current"])
        print("Restored:", previous)

    def uninstall(self, desktop):
        state = self.state()
        if not state:
            raise RuntimeError("No managed installation")
        with self.transaction(desktop):
            atomic_write(self.paths["profile"], edit_profile(self.paths["profile"], False))
            for name in ("current", "addon", "entry", "state"):
                self.paths[name].unlink(missing_ok=True)
        shutil.rmtree(self.releases)
        print("Uninstalled. Personal dictionaries and conf/inkflow.conf were kept.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["install", "rollback", "uninstall", "recover", "restore-manual", "status"])
    parser.add_argument("package", nargs="?", type=Path)
    parser.add_argument("--service", help="existing Fcitx5 user service, stopped and restarted during changes")
    args = parser.parse_args()
    if (args.command == "install") != (args.package is not None):
        parser.error("Only install takes a package directory")
    home = Path.home()
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local/share")).absolute()
    config = Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")).absolute()
    installer = Installer(data, config)
    with installer.locked():
        if args.command == "status":
            print(json.dumps(installer.state(), indent=2))
        else:
            service = args.service
            if args.command == "recover" and installer.journal.exists():
                service = json.loads(installer.journal.read_text())["service"] or service
            desktop = Desktop(service, resume=args.command == "recover")
            if args.command == "install":
                installer.install(args.package.resolve(), desktop)
            else:
                getattr(installer, args.command.replace("-", "_"))(desktop)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"{error}\nIf installation-backup.json remains, fix the error and run recover; "
                         "Fcitx5 may be stopped until recovery succeeds.")
