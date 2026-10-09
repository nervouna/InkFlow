# Linux installation

InkFlow uses Fcitx5 on Linux. ARM64 Omarchy/Hyprland is working; Steam Deck, KDE Plasma and Flatpak application checks are deferred. This installs the offline Rust/Rime engine. Linux AI and voice features are outside this build.

## Build a package

Use a committed checkout and the [native build requirements](../Core/Portable/README.md#build-and-test), plus the Fcitx5 development files (`fcitx5` on Arch, `libfcitx5core-dev` on Ubuntu). Python 3.11 or newer, `ldd`, `pgrep` and an existing Fcitx5 installation are required on the installation target.

```sh
bash Linux/scripts/package.sh
# Or reuse production resources prepared on this target:
bash Linux/scripts/package.sh /absolute/path/to/prepared-resources
```

The result is `build/linux/package/`. It contains the addon, pinned librime, compiled resources, notices, dictionary corresponding source, `install.py`, and `package.json` with file hashes and the source revision. Packaging downloads pinned inputs if they are not already cached; it does not install or change the desktop.

Build on the target distribution and CPU architecture. The package uses the target's Fcitx5, ICU, C/C++ runtime and other system libraries; it is not a distribution-independent binary. The installer checks architecture, hashes and library dependencies before changing anything. Hashes detect damaged files, not a malicious publisher: install packages only from a trusted source.

## Install or upgrade

Keep another input method enabled and finish any current composition before running the installer. Installation briefly restarts an active Fcitx5 user service.

```sh
python3 Linux/scripts/install.py install build/linux/package
# The package also carries the installer:
python3 /path/to/package/install.py install /path/to/package
```

No sudo or network access is used during installation. The installer recognizes `omarchy-fcitx5.service`, `fcitx5.service` and `plasma-fcitx5.service`. For another service, append `--service NAME`. If Fcitx5 is running without a recognized service, quit it first; the installer refuses to overwrite files beneath a running unmanaged daemon. When no daemon is running, start Fcitx5 after installing.

The installer adds **InkFlow Pinyin** while preserving the existing input-method entries and default. Select it in Fcitx5, or run:

```sh
fcitx5-remote -s inkflow-pinyin
```

Installing a new package with the same command upgrades the installation. Reinstalling the same package is a no-op. Releases are stored separately and a `current` symlink selects the active one; an update never overwrites a loaded library. The previous managed release stays available for rollback.

## Roll back or uninstall

```sh
python3 Linux/scripts/install.py status
python3 Linux/scripts/install.py rollback
python3 Linux/scripts/install.py uninstall
```

Rollback switches to the previous managed package without restoring an old copy of personal data. There is no previous managed release after the first install. When replacing a manual installation, the installer saves its original registration separately; `python3 Linux/scripts/install.py restore-manual` restores those descriptors and the original release pointer without replacing the current profile or personal data.

If a write or service restart fails, the installer restores the prior descriptors, profile and release pointer automatically. If restoration itself fails, it leaves Fcitx5 stopped and retains the recovery record. Fix the reported filesystem or service error, then run `python3 Linux/scripts/install.py recover` before retrying. Recovery remembers and restarts the service that was active before an interrupted operation.

Uninstall removes managed releases, InkFlow's Fcitx5 descriptors and its profile entries. It keeps personal dictionaries, custom phrases and settings. If InkFlow was the default input method, another remaining entry becomes the default. Files from an earlier manual CMake installation are not owned or removed by this installer.

## Files

Paths below use the default XDG directories; `XDG_DATA_HOME` and `XDG_CONFIG_HOME` are supported.

| Path | Contents |
| --- | --- |
| `~/.local/share/inkflow/releases/` | Managed packages, including resources, notices and source |
| `~/.local/share/inkflow/current` | Active package symlink |
| `~/.local/share/inkflow/installation.json` | Current and previous package IDs |
| `~/.local/share/inkflow/manual-installation.json` | Prior manual registration, when one existed |
| `~/.local/share/inkflow/rime/` | Personal dictionaries; never removed by the installer |
| `~/.local/share/fcitx5/addon/inkflow.conf` | Addon descriptor pointing at the active package |
| `~/.local/share/fcitx5/inputmethod/inkflow-pinyin.conf` | Input-method entry |
| `~/.config/fcitx5/conf/inkflow.conf` | Options, custom phrases and explicit backup-import request |

## Focused checks

```sh
python3 -B Linux/scripts/test_install.py
bash Linux/fcitx5/test.sh
PYTHON=/path/to/python-with-dbus-next bash Linux/fcitx5/test-installed.sh
PYTHON=/path/to/python-with-dbus-next python3 -B Linux/scripts/test_package.py build/linux/package
```

The installer tests use temporary directories and a fake service. The real-package test installs into a temporary prefix, upgrades to a test-only package identity containing the same binaries, rolls back, and uninstalls. It loads the addon after each switch and checks that personal files survive. The installed-addon tests use a private D-Bus, disposable configuration and personal data; they do not type into desktop applications. See [the adapter README](fcitx5/README.md) for coverage and the remaining target checks.
