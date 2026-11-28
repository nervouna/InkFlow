# Fcitx5 adapter

Fcitx5 input-method addon over the shared Rust/Rime engine. Targets Omarchy/Hyprland and Steam Deck Desktop Mode (KDE Plasma); GNOME/IBus and Steam Deck validation are deferred.

## What it does

- `src/engine.cpp`: one engine per addon (`ifr_engine_create` on load, from XDG paths), one engine session per Fcitx5 input context (an `InputContextProperty`). Keys go to `ifr_session_key` synchronously on Fcitx5's thread with Rime keysyms and translated modifier masks; releases carry Rime's release mask. Every mutation ends in `refresh`: the commit is drained exactly once with `ifr_session_take_commit` and delivered with `commitString`, then the preedit (client preedit when the client declares `Preedit`, otherwise the panel) and candidate list are rebuilt from a fresh snapshot. Preedit highlight and caret come from the snapshot's UTF-8 byte offsets, which are Fcitx5's units too.
- `src/candidates.cpp`: digit selection and Up/Down are the engine's own key policy; mouse clicks and Fcitx5's paging/cursor calls go back through the ABI with the snapshot they were shown from, so a late click on a superseded page is rejected and only redraws.
- Focus and reset: a reset or focus change clears the composition; switching input methods commits it first (what the macOS frontend does on deactivation). Client preedit uses `DontCommit` so Fcitx5 does not commit raw Pinyin before the focus-out handler runs. Password and `Sensitive` contexts never compose and get raw keys, so nothing can be learned from them.
- Surrounding text: document context is read only when a composition starts and only when the client declares `SurroundingText` with valid text; otherwise the engine gets no context and keeps Rime's native order.
  When replacing selected text, either selection direction uses the text strictly before the selection.
  The first contextual Han candidate can come from the first nine native candidates at any display size (3–9).
- Configuration (`src/config.h`, `~/.config/fcitx5/conf/inkflow.conf`, also through `fcitx5-configtool`): candidates per page (3–9), the fourteen input options under their macOS names, and custom phrases as `code=text` entries. Settings reach every live session through `ifr_session_set_configuration` and apply at the session's next composition boundary; new sessions are configured when they are created on first use.
- Personal-data import (`ImportBackup=/path/to/backup.json` in that file, then reload with `fcitx5-remote -r` or apply in the configuration tool): the addon consumes the request first so a bad file cannot repeat, parses the macOS format-1 document, logs the non-portable preferences it skips, destroys every session and the engine (Rime finalizes), imports the three dictionaries with rollback on failure, writes the backup's candidate count, options and phrases into the configuration, and recreates the engine. Compositions in progress are lost, which is why the entry point is explicit. An interrupted earlier import is recovered first.
- `src/bridge.h`: the pure helpers (XDG paths, preedit layout, modifier translation, bounded preceding text) with `tests/bridge_test.cpp`, which runs on any platform.

Resources are found at `INKFLOW_RESOURCES` (a prepared directory from `Core/Portable/prepare-resources.sh`, holding `shared/` and `prepared/cache/`), then the managed installation at `$XDG_DATA_HOME/inkflow/current/share/inkflow/rime`, then the first prepared `inkflow/rime` under `XDG_DATA_HOME` or `XDG_DATA_DIRS`. User data lives in `$XDG_DATA_HOME/inkflow/rime` (default `~/.local/share/inkflow/rime`). Without resources the addon loads, logs a warning and passes every key through.

## Build on Linux

Requirements: the repository's Rust toolchain, CMake 3.31.6 and Ninja 1.11.1.4 for the pinned native build, a C++20 compiler, Python 3, and the Fcitx5 development files (`fcitx5` on Arch/SteamOS, `libfcitx5core-dev` plus `extra-cmake-modules` on Ubuntu 26.04). Resource preparation uses `sha256sum` when available, otherwise `shasum -a 256`. From the checkout root:

```sh
python3 Core/Portable/build-native.py
CARGO_TARGET_DIR=$PWD/build/portable/cargo cargo build --locked --release --manifest-path Core/Portable/Cargo.toml
bash Core/Portable/prepare-resources.sh build/portable/resources
cmake -S Linux/fcitx5 -B build/fcitx5 -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DINKFLOW_RESOURCES=$PWD/build/portable/resources
cmake --build build/fcitx5 && ctest --test-dir build/fcitx5
```

The addon links the crate's `staticlib` (which bundles the C++ bridge) and the pinned `librime.so`, installed under `<prefix>/lib/inkflow` with a matching rpath. `cmake --install build/fcitx5` places the addon in Fcitx5's addon directory, its `addon/` and `inputmethod/` descriptors in Fcitx5's data directory, and the prepared resources under `<prefix>/share/inkflow/rime`. Installing and enabling the input method change the user's input configuration: do that only with explicit approval, and keep another input method enabled while testing.

`bash Linux/fcitx5/test.sh` runs the helper tests anywhere; with `FCITX5_SOURCE=<fcitx5 source tree>` it also compiles the addon syntax-only against those headers (export headers stubbed), which is how it was checked from macOS against fcitx5 5.1.14. Headers from 5.1.14 need C++20; older Fcitx5 releases are unverified and may need `FCITX_ADDON_FACTORY` (the fallback is compiled in).

## Continuous integration

CI builds and links the addon and runs CTest; see [macOS testing](../../macOS/TESTING.md#continuous-integration). CTest runs only the pure bridge helpers, so installed-addon behavior, real application input, focus, personal-data migration, upgrade and rollback need the installed-addon tests below and target-device validation. Steam Deck/KDE Plasma validation remains deferred.

## User-local installation and installed-addon test

Packaging, installation, the service restart, symlink layout and XDG paths are in [Linux installation](../README.md). Ordinary builds and tests never install or activate the addon.

The installed-addon test requires `dbus-run-session` and Python with `dbus-next==0.2.3`:

```sh
PYTHON=/path/to/test-venv/bin/python bash Linux/fcitx5/test-installed.sh "$HOME/.local"
```

It starts a private Fcitx5 daemon on a separate D-Bus with temporary configuration and personal data. It checks real addon loading, preedit/candidate signals, mouse and space selection, exactly-once commits, focus/reset cancellation, sensitive-field pass-through, configuration reload, custom phrases, text-free warnings, and explicit backup import with engine recreation. It does not type into desktop applications or import into live user dictionaries.

### Frontend latency

Run the same checkout's harness against each release prefix on the same target, using matching production
resources and the default five candidates. Record the package revisions, CPU and Fcitx5 version with the output.

```sh
PYTHON=/path/to/test-venv/bin/python bash Linux/fcitx5/test-installed.sh "$HOME/.local" --latency
```

Each invocation starts a fresh private daemon and user directory. The first measurement starts when the focused
client switches from the US keyboard to InkFlow and ends when the first nonempty candidate panel signal arrives
for `n`. Daemon startup, OS cache eviction and screen painting are outside this interval. Each short or long
spelling then gets one warmup and 12 measured repetitions, with a reset between repetitions. The JSON reports
client-side D-Bus key-call round trips in milliseconds (nearest-rank p50/p95/p99) and panel signal counts for
presses and releases separately. Repeat invocations to compare first activations across fresh processes.
Use `--latency-samples` to include each completed key-call duration in nanoseconds for pooled percentiles.

Compare `long_with_context` with `words.niyebuxiangnidepengyoushangxin` for the same long spelling.
The contextual trial supplies `今天` with the cursor at its end before timing each repetition.

The latency probe also types and confirms 120 instances of `nihao` with Space after the spelling-only
measurements. Its `space_commit` percentiles time the confirming key until the client receives its D-Bus
reply. Compare recording on and off with the same package and disposable profile:

```sh
export PYTHON=/path/to/test-venv/bin/python
INKFLOW_BENCH_RECORD_QUALITY=False bash Linux/fcitx5/test-installed.sh PREFIX --latency
INKFLOW_BENCH_RECORD_QUALITY=True bash Linux/fcitx5/test-installed.sh PREFIX --latency
```

## Frontend invariants

Candidate navigation can replace the panel's candidate list before its callback returns.
The callback copies the engine and input context it needs before requesting navigation.
A key release with an unchanged snapshot keeps the old page selectable and records no new quality decision.
Fcitx5's panel emptiness test excludes the input-method overlay, which lets switch-trigger releases keep the overlay.

The ABI guarantees preedit offsets on UTF-8 character boundaries. Inconsistent bounds omit highlighting and
put the caret at the end. Fcitx5 surrounding-text offsets count code points. The frontend captures up to 32
code points to cover combining sequences within the engine's 16-grapheme context. Invalid text and out-of-range
offsets yield empty context. Both Mod4 and GTK's virtual Super map to Rime's Super. In the default Shift
gesture, a left Shift press without Control, Alt or Super arms ASCII toggling. Another key cancels it before
release. The private-daemon tests clear Fcitx5's global AltTriggerKeys so the addon receives that gesture.

Addon teardown releases the engine handle before Fcitx5 unregisters its property factory. The factory drops
the sessions, and the last reference finalizes Rime. Explicit backup import drops every session and the engine
before replacing dictionaries. Startup restores any interrupted import before opening Rime. If recovery
fails, the addon passes keys through to avoid mixing dictionaries from two versions.

Quality recording sends bounded numeric decisions from the Fcitx5 event thread to an optional writer.
Only that writer loads the sibling SQLite module and prepares the timezone. Pausing or shutting down wakes the
writer to drain pending counts. A segmented choice counts only when the committed text matches the selected
prefix and candidate, with optional punctuation excluded from the measurement. ICU generates Unicode ranges
at build time to match macOS text classification.

The private-daemon tests cover a client taking over the panel mid-composition, a Shift+Left chord that
cancels standalone Shift toggling, and the privacy boundary when recording starts during a composition.
The latency probe makes a round trip to the same daemon before timing each trial to drain earlier panel messages.
