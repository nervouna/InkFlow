# Portable core migration

## Decision and scope

InkFlow shares its offline input behavior across Linux, macOS, Android, iOS, and Windows through a Rust core. Keep librime, Lua, OpenCC, and the existing C++ native extensions. Each platform retains a native input-method frontend.

Linux/Fcitx5 and the macOS cutover are done. Mobile comes next, then Windows, then the GNOME/IBus adapter. Android versus iOS order remains undecided.

The migration preserves existing macOS features and personal data. New platforms start with offline typing and portable backup/import; optional-feature parity follows separately. Cloud synchronization is out of scope.

This document records the architecture, rationale, and remaining work; [Core/Portable/README.md](../Core/Portable/README.md) describes the runtime as built. The issues own the roadmap and progress: phases 0–4 (#33–#37: reproducible baseline, desktop runtime, portable offline behavior, Linux frontend, macOS cutover) are done and recorded in the closed [tracking issue #32](https://github.com/nervouna/InkFlow/issues/32); mobile is #38, Windows #39, Steam Deck #70, and Linux parity with macOS #153. Do not maintain a second progress checklist here.

## Architecture

```text
Native input-method frontend
    |
Small synchronous engine interface / C ABI
    |
Rust session coordination and InkFlow policy
    |
Rime C API + narrow C++ extension bridge
    |
Pinned librime, Lua, OpenCC, prepared dictionaries
```

Use librime's public C API where sufficient. Retain the existing native extension code where it needs C++ internals; do not wrap librime's whole C++ object model. Build native extensions against matching pinned engine sources and dependencies.

Rust is chosen for portable shared logic, explicit ownership, and native-library integration. Faster typing is not an assumed outcome.

### Engine responsibilities

Share composition/session coordination, candidate ordering and selection, input preferences, custom phrases, learning policy, dictionary validation and activation, and portable personal-data formats.

Keep Rime responsible for editing, segmentation, dictionary lookup, paging, and the learning behavior it already supplies. Do not introduce a replacement Pinyin engine or change ranking policy merely to fit a new language or platform.

The interface should cover runtime/session lifetime, semantic key events and mobile editing operations, immutable composition snapshots, candidate selection, commit delivery, configuration changes, and optional bounded surrounding text.

Specify string encoding and offset units, memory ownership, error handling, and thread affinity. Do not expose Swift, COM, JNI, or GUI objects. Candidate selection must identify the relevant snapshot so delayed UI actions cannot select an unrelated entry. Errors and language-level unwinding must not cross the ABI unchecked.

Run the engine in the frontend process. Serialize access to librime and its shared configuration; do not assume independent sessions permit concurrent native calls. Keep synchronous key processing independent of `MainActor`, GLib, Android loopers, and Windows message loops. Background preparation may use platform workers or helpers without becoming a dependency of each key event.

### Frontend responsibilities

| Platform | Frontend |
| --- | --- |
| Linux | Fcitx5 for Omarchy/Hyprland and Steam Deck Desktop Mode (KDE Plasma); GNOME/IBus deferred until after Windows |
| macOS | Swift/InputMethodKit |
| Android | Kotlin `InputMethodService` and native keyboard UI |
| iOS | Swift keyboard extension and containing app |
| Windows | Native TSF integration |

Frontends own focus, input-context lifetime, preedit/commit delivery, UI, shortcuts or touch gestures, and platform privacy signals. They supply storage/resource paths and access to surrounding text. Missing or invalid context must preserve ordinary offline input and native ordering where context ranking cannot apply.

Use a small C ABI, with Swift and JNI adapters as needed. Add binding generation only if it reduces demonstrated maintenance work. A shared settings UI and a separate engine daemon are not part of the design.

### Product and data boundaries

The product rules in [AGENTS.md](../AGENTS.md) apply to every platform. In addition:

- Audit existing settings and learning paths rather than copying blocking work into Rust.
- Apply settings and dictionary changes at safe composition boundaries.
- Credentials and permissions belong to the platform integration.
- Preserve supported learning data and custom phrases through explicit backup/import. Translate or reject unsupported preferences explicitly; macOS physical shortcut codes are not portable.
- Tests use isolated data directories.
- Portable backups do not imply that live databases can be shared or synchronized safely.

## Rejected alternatives

| Alternative | Cost or limitation | Decision |
| --- | --- | --- |
| Ship schemas through stock Rime frontends | Does not preserve InkFlow's ranking, learning, and lifecycle behavior | Insufficient |
| Replace Rime with a Rust engine | Recreates mature behavior and greatly expands scope | Reject |
| Add a separate engine daemon | IPC and lifecycle work; poor fit for mobile extensions | Omit |
| Share UI across platforms | Does not remove native IME integration and adds framework constraints | Native UI first |
| Generate all bindings immediately | Another tool and abstraction before the interface is proven | Defer |
| Port every optional feature initially | Expands dependencies and delays offline input | Defer on new platforms; preserve macOS behavior |
| Add cloud sync | Requires conflict resolution, privacy, and network design | Exclude from this migration |

## Remaining work

### Mobile (#38)

Build minimal Android and iOS hosts and test on devices. Measure real-dictionary startup, resident memory, extension/service recreation, and persistent learning. Review current platform restrictions, resource-distribution options, and dependency licensing before implementing downloads or voice.

An iOS keyboard extension must support offline input without depending on a running containing app or network permission. Its lifecycle, secure-field restrictions, and lack of direct microphone access require platform-specific behavior. Android also requires handling service recreation and limited or sensitive editor context.

If needed, generate mobile resource profiles from shared source policy; compile and verify resources for the target runtime through the one preparation pipeline ([shared preparation recipe](shared-dictionary-preparation.md)) instead of copying macOS caches. Build touch layouts, editing gestures, candidate interaction, accessibility, and minimum settings as platform products. Choose the Android versus iOS order before starting.

Completion is per platform: a usable offline keyboard, validated persistence/import, and measured resource behavior. Desktop feature parity is not required for the first mobile release.

### Windows (#39)

Build the native dependency chain and shared core for Windows, then implement TSF integration, candidate presentation, configuration, and packaging. Validate composition/focus lifetime and data compatibility in real Windows applications.

Completion means a usable offline Windows IME backed by the same core. Windows-specific build and integration risks are intentionally deferred until after mobile.

### Linux

- Steam Deck Desktop Mode (#70) with a physical keyboard: verify the actual SteamOS session and Flatpak client compatibility; package without disabling SteamOS system protection and check persistence across OS updates. Gaming Mode and controller/on-screen keyboard integration are out of scope.
- GNOME/IBus follows Windows. The GNOME development host does not establish compatibility with either target desktop.
- Parity with the macOS feature set is backlog #153.

### Optional follow-up work

Track quality recording/export, dictionary downloads, AI, voice backends, and additional Linux adapters as separate issues; #153 lists the Linux ones. Implement them without changing offline input availability or privacy guarantees. Their priority can be decided independently of platform rollout.

## Validation and operating rules

Check each platform against the shared regression cases for preedit and caret position, candidate order, commits, partial selection, paging, cancellation, configuration boundaries, and learning after restart. The recorded Swift-engine results are frozen references ([Core/Portable/README.md](../Core/Portable/README.md)). Preserve observable behavior; do not require byte-identical databases or caches.

Compare performance on the same hardware, build configuration, and resource set. Record latency distributions and slow cases as well as typical timing; do not infer a language advantage from measurements on different machines. Use the [approved headless-core review limits](../Core/Fixtures/MigrationBaseline/README.md#approved-review-limits) for the recorded macOS protocol; the measurement boundaries are in [Remote Mac builds and migration baseline](remote-mac-baseline.md).

Build, test and installation follow [AGENTS.md](../AGENTS.md). Keep another keyboard input source enabled for development testing.

## Remaining choices

- Choose Android versus iOS order.
- Arrange mobile device/toolchain access and, later, Windows development/test access.
