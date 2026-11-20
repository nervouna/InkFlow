# Linux installation

InkFlow uses Fcitx5 on Linux. ARM64 Omarchy/Hyprland is working; Steam Deck, KDE Plasma and Flatpak application checks are deferred. This installs the offline Rust/Rime engine. Linux AI and voice features are outside this build.

## Download the ARM64 Omarchy package

In [Linux releases](https://github.com/nervouna/InkFlow/releases?q=linux-v), choose a published
`linux-vX.Y.Z` for ARM64 Omarchy/Hyprland. Download the aarch64 archive and `SHA256SUMS-linux` to the same
directory. The separate `InkFlow-X.Y.Z-linux-source.tar.xz` contains the corresponding source and rebuild instructions.
With Fcitx5 and Python 3.11.4 or newer installed, replace the example version below:

```sh
version=0.1.0
package="InkFlow-$version-linux-aarch64"
sha256sum --check --ignore-missing SHA256SUMS-linux &&
  tar -xf "$package.tar.xz" &&
  python3 "$package/install.py" install "$package"
```

Select **InkFlow Pinyin** in Fcitx5. Installing preserves your other input methods, settings and personal dictionaries.

## Build a local package

Use a committed checkout and the [native build requirements](../Core/Portable/README.md#build-and-test), plus the Fcitx5 development files (`fcitx5` on Arch, `libfcitx5core-dev` on Ubuntu). Python 3.11 or newer, `ldd`, `pgrep` and an existing Fcitx5 installation are required on the installation target.

```sh
bash Linux/scripts/package.sh
# Or reuse production resources prepared on this target:
bash Linux/scripts/package.sh /absolute/path/to/prepared-resources
```

The result is `build/linux/package/`. It contains the addon, pinned librime, compiled resources, notices, dictionary corresponding source, `install.py`, and `package.json` with file hashes and the source revision. Packaging downloads pinned inputs if they are not already cached; it does not install or change the desktop.

Reused resources are checked against the committed dictionary recipe before packaging.
Packaging stages output before publishing it to keep a previous package intact if the build fails.
Staging destinations are relative. The uninstalled descriptor uses a bare library name and the installer
writes the absolute path of the active copy. The source archive includes the committed project and matching
dictionary inputs. Notice collection preserves embedded header notices, covers both locked Rust dependency
graphs, and dereferences installed library aliases when hashing delivered bytes.

Build on the target distribution and CPU architecture. The package uses the target's Fcitx5, ICU, C/C++ runtime and other system libraries; it is not a distribution-independent binary. The installer checks architecture, hashes and library dependencies before changing anything. Hashes detect damaged files, not a malicious publisher: install packages only from a trusted source.

The Linux build also uses ICU and SQLite development files (`icu` and `sqlite` on Arch,
`libicu-dev` and `libsqlite3-dev` on Ubuntu). ICU generates the Unicode classification ranges
at build time. SQLite belongs to the optional statistics module.

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
The installer stops Fcitx5 before taking the profile backup because the daemon can flush that file on
shutdown. It persists the new package payload before updating the durable `current` link.

## Update

Run the installed package's updater to fetch the latest published stable Linux version for this CPU:

```sh
python3 ~/.local/share/inkflow/current/install.py update
# A specific release, or another Fcitx5 service:
python3 ~/.local/share/inkflow/current/install.py update --tag linux-vX.Y.Z --service NAME
```

Update uses the network only when you run it; there is no background or automatic check. It downloads the release's package and `SHA256SUMS-linux` over HTTPS, verifies the archive's SHA-256 before extracting it, and then runs that package's own `install.py install`. If the installed version already matches the release, it reports that and downloads nothing else. The exit status is the install's.

## Roll back or uninstall

```sh
python3 Linux/scripts/install.py status
python3 Linux/scripts/install.py rollback
python3 Linux/scripts/install.py uninstall
```

Rollback switches to the previous managed package without restoring an old copy of personal data. There is no previous managed release after the first install. When replacing a manual installation, the installer saves its original registration separately; `python3 Linux/scripts/install.py restore-manual` restores those descriptors and the original release pointer without replacing the current profile or personal data.

If a write or service restart fails, the installer restores the prior descriptors, profile and release pointer automatically. If restoration itself fails, it leaves Fcitx5 stopped and retains the recovery record. Fix the reported filesystem or service error, then run `python3 Linux/scripts/install.py recover` before retrying. Recovery remembers and restarts the service that was active before an interrupted operation.

Uninstall removes managed releases, InkFlow's Fcitx5 descriptors and its profile entries. It keeps personal dictionaries, custom phrases and settings. If InkFlow was the default input method, another remaining entry becomes the default. Files from an earlier manual CMake installation are not owned or removed by this installer.

## Local Chinese selection quality

Run the packaged reporter from your installed release. It shows the last 28 local calendar days,
including today, and can export the same aggregate data to a new private JSON file.

```sh
python3 ~/.local/share/inkflow/current/quality.py
python3 ~/.local/share/inkflow/current/quality.py --export inkflow-quality.json
```

Export publishes a fully written private file through a hard link. Two exports targeting the same path
cannot overwrite one another.

The Fcitx5 **Record local Chinese selection counts** option is on by default. Uncheck it in the addon
configuration to pause recording, or set `RecordQuality=False` in `conf/inkflow.conf` and reload
the addon. Pausing and resuming discards evidence from an in-progress composition.

The report counts displayed ranks for Chinese choices made with Space, a digit or a click, including
segment selections that survive through a proven commit to the client. It shows top-1, top-3 and paged
choices over known-rank decisions with Wilson 95% intervals. Length counts Unicode scalars. The context
group means the client supplied a usable prefix at composition start. Page size is the active setting
when the candidate was chosen. Unknown selections, interrupted input and sensitive contexts are excluded.
An empty denominator is shown as unavailable. A selection accepted with Space still counts if the user
later corrects the inserted text.

The optional worker writes only daily counts by length, context availability, page size and rank group
to `$XDG_DATA_HOME/inkflow/quality/counts.sqlite3` (default `~/.local/share`). The first proven selection creates the database.
The writer prunes older days on updates. Text, key sequences, times of day and application identifiers
are never stored. The writer batches nearby selections over up to 40 ms. Storage failures and a full queue can leave gaps.
Typing keeps working if the worker or SQLite is unavailable. Restore writable storage
and toggle recording off and on to retry. `--json` prints all counts, their denominators and joint groups.

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

## Prepare a Linux release

Run **Linux Release** in GitHub Actions on `main` and enter an independent `X.Y.Z` version. The native ARM64
runner builds against the Omarchy ARM stable mirror, checks both archives, loads the extracted addon on a private
D-Bus, and exercises install, upgrade, rollback and uninstall. A successful run links its GitHub Release draft
in the run summary. The CI container uses Arch4Edu's import of the upstream generic Arch Linux ARM
rootfs. On upload failure, rerun the failed job to resume with the same verified artifact. The job keeps
completed uploads and clears an empty GitHub starter asset before retrying it.

For input-path changes, compare the previous published package and the draft on the same target using the
[frontend latency probe](fcitx5/README.md#frontend-latency).

While signed in, open the draft and follow its install instructions on an ARM64 Omarchy/Hyprland machine.
Check that selecting InkFlow Pinyin and committing a candidate work. After confirming the install, edit the draft,
leave **Set as the latest release** unchecked and publish it. Alternatively, promote it with
`gh release edit linux-vX.Y.Z --draft=false --latest=false`. This keeps the repository's Latest link on macOS.
The Linux updater discovers the published Linux tag.

## Focused checks

```sh
python3 -B Linux/scripts/test_install.py
bash Linux/fcitx5/test.sh
PYTHON=/path/to/python-with-dbus-next bash Linux/fcitx5/test-installed.sh
PYTHON=/path/to/python-with-dbus-next python3 -B Linux/scripts/test_package.py build/linux/package
```

Run release verification on the target userspace from a clean checkout with the final archives.
`Linux/scripts/preflight.sh` is read-only and can inspect the target over SSH as the desktop user.

The installer tests use temporary directories and a fake service. The real-package test installs into a temporary prefix, upgrades to a test-only package identity containing the same binaries, rolls back, and uninstalls. It loads the addon after each switch and checks that personal files survive. The installed-addon tests use a private D-Bus, disposable configuration and personal data; they do not type into desktop applications. See [the adapter README](fcitx5/README.md) for coverage and the remaining target checks.
