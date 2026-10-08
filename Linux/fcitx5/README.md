# Fcitx5 adapter

Minimal Fcitx5 input-method addon over the shared Rust/Rime engine for [#36](https://github.com/nervouna/InkFlow/issues/36). Targets Omarchy/Hyprland and Steam Deck Desktop Mode (KDE Plasma); GNOME/IBus is deferred. This is scaffolding for integration work, not daily-use support: the pieces below are unverified until they run on the Linux host.

## What it does

- `src/engine.cpp`: one engine per addon (`ifr_engine_create` on load, from XDG paths), one engine session per Fcitx5 input context (an `InputContextProperty`). Keys go to `ifr_session_key` synchronously on Fcitx5's thread with Rime keysyms and translated modifier masks; releases carry Rime's release mask. Every mutation ends in `refresh`: the commit is drained exactly once with `ifr_session_take_commit` and delivered with `commitString`, then the preedit (client preedit when the client declares `Preedit`, otherwise the panel) and candidate list are rebuilt from a fresh snapshot. Preedit highlight and caret come from the snapshot's UTF-8 byte offsets, which are Fcitx5's units too.
- `src/candidates.cpp`: digit selection and Up/Down are the engine's own key policy; mouse clicks and Fcitx5's paging/cursor calls go back through the ABI with the snapshot they were shown from, so a late click on a superseded page is rejected and only redraws.
- Focus and reset: a reset or focus change clears the composition; switching input methods commits it first (what the macOS frontend does on deactivation). Password and `Sensitive` contexts never compose and get raw keys, so nothing can be learned from them.
- Surrounding text: document context is read only when a composition starts and only when the client declares `SurroundingText` with valid text; otherwise the engine gets no context and keeps Rime's native order.
- Configuration (`src/config.h`, `~/.config/fcitx5/conf/inkflow.conf`, also through `fcitx5-configtool`): candidates per page (3–9), the fourteen input options under their macOS names, and custom phrases as `code=text` entries. Settings reach every live session through `ifr_session_set_configuration` and apply at the session's next composition boundary; new sessions are configured when they are created on first use.
- Personal-data import (`ImportBackup=/path/to/backup.json` in that file, then reload with `fcitx5-remote -r` or apply in the configuration tool): the addon consumes the request first so a bad file cannot repeat, parses the macOS format-1 document, logs the non-portable preferences it skips, destroys every session and the engine (Rime finalizes), imports the three dictionaries with rollback on failure, writes the backup's candidate count, options and phrases into the configuration, and recreates the engine. Compositions in progress are lost, which is why the entry point is explicit. An interrupted earlier import is recovered first.
- `src/bridge.h`: the pure helpers (XDG paths, preedit layout, modifier translation, bounded preceding text) with `tests/bridge_test.cpp`, which runs on any platform.

Resources are found at `INKFLOW_RESOURCES` (a prepared directory from `Core/Portable/prepare-resources.sh`, holding `shared/` and `prepared/cache/`), else the first `inkflow/rime` under `XDG_DATA_HOME` then `XDG_DATA_DIRS` that is prepared. User data lives in `$XDG_DATA_HOME/inkflow/rime` (default `~/.local/share/inkflow/rime`). Without resources the addon loads, logs a warning and passes every key through.

## Build on Linux

Requirements: the repository's Rust toolchain, CMake 3.20+, Ninja, a C++20 compiler, Python 3, and the Fcitx5 development files (`fcitx5` on Arch/SteamOS, `libfcitx5core-dev` plus `extra-cmake-modules` on Ubuntu). From the checkout root:

```sh
python3 Core/Portable/build-native.py
CARGO_TARGET_DIR=$PWD/build/portable/cargo cargo build --locked --release --manifest-path Core/Portable/Cargo.toml
bash Core/Portable/prepare-resources.sh   # prints PASS production resources: build/portable/resources.XXXXXX
cmake -S Linux/fcitx5 -B build/fcitx5 -G Ninja -DCMAKE_INSTALL_PREFIX=/usr/local \
  -DINKFLOW_RESOURCES=$PWD/build/portable/resources.XXXXXX
cmake --build build/fcitx5 && ctest --test-dir build/fcitx5
```

The addon links the crate's `staticlib` (which bundles the C++ bridge) and the pinned `librime.so`, installed under `<prefix>/lib/inkflow` with a matching rpath. `cmake --install build/fcitx5` places the addon in Fcitx5's addon directory, its `addon/` and `inputmethod/` descriptors in Fcitx5's data directory, and the prepared resources under `<prefix>/share/inkflow/rime`. Installing and enabling the input method change the user's input configuration: do that only with explicit approval, and keep another input method enabled while testing.

`bash Linux/fcitx5/test.sh` runs the helper tests anywhere; with `FCITX5_SOURCE=<fcitx5 source tree>` it also compiles the addon syntax-only against those headers (export headers stubbed), which is how it was checked from macOS against fcitx5 5.1.14.

## Unverified from macOS

The CMake build, `Fcitx5::Core` linkage, addon loading, and all runtime behavior (preedit rendering, candidate window, commit delivery, focus and sensitive-field handling under Hyprland and KDE Plasma, Flatpak clients) have not run. Fcitx5 5.1.14 headers need C++20; older Fcitx5 releases on SteamOS may need `FCITX_ADDON_FACTORY` (the fallback is compiled in). The configuration surface and the import entry point compile against the headers but have not run. Packaging is a later slice.
