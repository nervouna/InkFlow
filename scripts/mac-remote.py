#!/usr/bin/env python3
"""Run a committed source revision in a dedicated Mac checkout, without installation."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[1]
TEST_UNITS = {
    "engine", "engine-basic", "engine-options", "engine-english", "engine-context",
    "engine-custom-phrases", "controller", "quality-baseline", "ai-learning", "voice-lexicon",
}


def output(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def clean_checkout(repo):
    if output(["git", "status", "--porcelain", "--untracked-files=all"], repo):
        raise RuntimeError(f"Dirty checkout: {repo}; preserve or commit changes before retrying")


def commands(action, units, report):
    if action == "test":
        if not units or not set(units) <= TEST_UNITS:
            raise ValueError("Choose explicit supported units: " + ", ".join(sorted(TEST_UNITS)))
        return [["bash", "macOS/scripts/test.sh", *units]]
    if units:
        raise ValueError("Test units are only valid with the test action")
    if action == "build":
        return [["bash", "macOS/scripts/build.sh"],
                ["bash", "macOS/scripts/check-bundle.sh", "--fast"]]
    if action == "baseline":
        return [["bash", "Core/scripts/capture-migration-baseline.sh", str(report)]]
    raise ValueError(f"Unsupported action: {action}")


@contextmanager
def checkout_lock(root):
    root.mkdir(parents=True, exist_ok=True)
    lock = root / "run.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise RuntimeError(f"Runner active or interrupted: inspect {lock} before retrying") from None
    try:
        (lock / "owner.json").write_text(json.dumps({"pid": os.getpid(), "started": time.time()}))
        yield
    finally:
        (lock / "owner.json").unlink(missing_ok=True)
        lock.rmdir()


def prepare_checkout(root, bundle, ref, revision):
    repo = root / "checkout"
    marker = root / "runner-owned"
    if repo.exists():
        if not marker.is_file() or not (repo / ".git").is_dir():
            raise RuntimeError("Refusing to reuse a checkout not created by this runner")
        clean_checkout(repo)
    else:
        subprocess.run(["git", "init", str(repo)], check=True)
        marker.write_text("InkFlow remote runner\n")
    subprocess.run(["git", "fetch", "--no-tags", str(bundle), ref], cwd=repo, check=True)
    if output(["git", "rev-parse", "FETCH_HEAD"], repo) != revision:
        raise RuntimeError("Bundle revision does not match request")
    subprocess.run(["git", "checkout", "--detach", revision], cwd=repo, check=True)
    clean_checkout(repo)
    return repo


def worker(request_path):
    request = json.loads(request_path.read_text())
    root = Path(request["remote_root"]).expanduser().resolve()
    report = request_path.parent / "results"
    report.mkdir()
    metadata = dict(request, startedUTC=datetime.now(timezone.utc).isoformat())
    status = 1
    try:
        work = commands(request["action"], request["units"], report)
        with checkout_lock(root):
            repo = prepare_checkout(root, request_path.parent / "source.bundle",
                                    request["ref"], request["revision"])
            metadata["checkout"] = str(repo)
            metadata["commands"] = work
            for name, args in {
                "system": ["sw_vers"], "architecture": ["uname", "-m"],
                "cpu": ["sysctl", "-n", "machdep.cpu.brand_string"],
                "memoryBytes": ["sysctl", "-n", "hw.memsize"],
                "xcode": ["xcodebuild", "-version"],
                "swift": ["xcrun", "swift", "--version"],
                "rust": ["rustc", "--version"], "cargo": ["cargo", "--version"],
                "sdk": ["xcrun", "--show-sdk-version"],
            }.items():
                metadata[name] = output(args, repo)
            status = 0
            for index, cmd in enumerate(work):
                began = time.monotonic()
                with (report / f"{index:02d}-{request['action']}.log").open("w") as log:
                    log.write(shlex.join(cmd) + "\n")
                    log.flush()
                    with subprocess.Popen(cmd, cwd=repo, stdout=subprocess.PIPE,
                                          stderr=subprocess.STDOUT, text=True) as process:
                        for line in process.stdout:
                            log.write(line)
                            log.flush()
                            print(line, end="", flush=True)
                        status = process.wait()
                metadata.setdefault("steps", []).append({"command": cmd, "exitCode": status,
                                                         "elapsedSeconds": time.monotonic() - began})
                if status:
                    break
            clean_checkout(repo)
    except Exception as error:
        metadata["error"] = str(error)
        print(f"FAIL remote run: {error}", file=sys.stderr)
        status = 1
    finally:
        metadata["exitCode"] = status
        metadata["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        (report / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return status


def ssh(host, args, **kwargs):
    command = "zsh -lic " + shlex.quote(shlex.join(args))
    return subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command], **kwargs)


def run(args):
    commands(args.action, args.units, Path("results"))
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@-]*", args.host):
        raise ValueError("Use an SSH host alias or user@host")
    revision = output(["git", "rev-parse", "--verify", args.revision + "^{commit}"], ROOT)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    ref = "refs/inkflow-remote/" + run_id
    local = ROOT / "build" / "mac-remote" / run_id
    local.mkdir(parents=True)
    print(f"Revision: {revision}\nEvidence: {local}", flush=True)
    remote = None
    status = 1
    with tempfile.TemporaryDirectory(prefix="inkflow-transfer-") as scratch:
        scratch = Path(scratch)
        bundle = scratch / "source.bundle"
        subprocess.run(["git", "update-ref", ref, revision], cwd=ROOT, check=True)
        try:
            subprocess.run(["git", "bundle", "create", str(bundle), ref], cwd=ROOT, check=True)
        finally:
            subprocess.run(["git", "update-ref", "-d", ref], cwd=ROOT, check=True)
        remote = ssh(args.host, ["mktemp", "-d", "/tmp/inkflow-remote.XXXXXXXX"],
                     capture_output=True, text=True, check=True).stdout.strip()
        if not re.fullmatch(r"/tmp/inkflow-remote\.[A-Za-z0-9]+", remote):
            raise RuntimeError(f"Unexpected transfer directory: {remote!r}")
        request = dict(revision=revision, ref=ref, remote_root=args.remote_root,
                       action=args.action, units=args.units,
                       driverSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
        (scratch / "request.json").write_text(json.dumps(request))
        try:
            subprocess.run(["scp", "-q", "-o", "BatchMode=yes", str(bundle),
                            str(scratch / "request.json"), str(Path(__file__).resolve()),
                            f"{args.host}:{remote}/"], check=True)
            status = ssh(args.host, ["python3", remote + "/mac-remote.py", "--worker",
                                     remote + "/request.json"]).returncode
            copied = subprocess.run(["scp", "-q", "-r", "-o", "BatchMode=yes",
                                     f"{args.host}:{remote}/results/.", str(local)]).returncode == 0
            if not copied:
                print(f"Evidence transfer failed; retained remote files at {remote}", file=sys.stderr)
                return status or 1
            ssh(args.host, ["rm", "-rf", remote], check=True)
        except BaseException:
            print(f"Transfer/run interrupted; inspect {remote} and the remote run.lock before retrying", file=sys.stderr)
            raise
    print(f"Remote exit code: {status}\nEvidence: {local}")
    return status


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        return worker(Path(sys.argv[2]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "test", "baseline"])
    parser.add_argument("units", nargs="*")
    parser.add_argument("--host", default="tanaris")
    parser.add_argument("--remote-root", default="~/Develop/Projects/inkflow-remote")
    parser.add_argument("--revision", default="HEAD", help="Committed revision only; local edits are not sent")
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
