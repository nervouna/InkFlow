# Portable core migration

## Decision and scope

InkFlow will share its offline input behavior across Linux, macOS, Android, iOS, and Windows through a Rust core. Keep librime, Lua, OpenCC, and the existing C++ native extensions. Each platform retains a native input-method frontend.

The delivery order is Linux, macOS cutover, mobile, then Windows. Mobile implementation and device probes start after the macOS cutover; Windows work follows mobile. Android versus iOS order remains undecided. Their known constraints should inform the engine interface now, but desktop delivery does not depend on early mobile or Windows prototypes. This accepts the risk of later platform-specific changes.

The migration preserves existing macOS features and personal data. New platforms start with offline typing and portable backup/import; optional-feature parity follows separately. Cloud synchronization is out of scope.

This document records the architecture, rationale, and migration sequence. [Tracking issue #32](https://github.com/nervouna/InkFlow/issues/32) links the phase issues that own the execution roadmap and progress. Do not maintain a second progress checklist here.

## Starting point

The existing code already separates much of the engine from the macOS frontend:

- `Core/Sources/InkFlowDomain/`: preferences, custom phrases, ranking, dictionary generation, and learning models.
- `Core/Sources/InkFlowRime/`: sessions, candidate ordering, learning coordination, dictionary lifecycle, and quality recording.
- `Core/Sources/InkFlowRimeNative/`: native mixed-input translation and personal dictionary snapshots.
- `Core/Sources/CRime/` and `Core/Sources/InkFlowRimeWorker/`: native API and worker integration.
- `schemas/`: Rime configuration, Lua modules, and OpenCC resources.
- `Core/Tests/` and `Core/Fixtures/QualityBaseline/`: existing regression coverage and behavioral reference material.

Shared Swift code still imports Apple-specific facilities, and its build scripts assume macOS binaries and toolchains. Dictionary data, configuration, and source preparation now live under `Core/`; the [shared preparation recipe](shared-dictionary-preparation.md) still uses the Swift generator through the Mac toolchain. A separate Swift package does not yet constitute a Linux port.

Development started on branch `portable-core`, in `.worktrees/portable-core/`, from revision `8669c48`. Linux Rust tooling and SSH access to the Apple Silicon Mac through `ssh tanaris` were verified. No migrated engine or cross-platform performance result existed when this plan was agreed.

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

Rust is chosen for portable shared logic, explicit ownership, and native-library integration. Faster typing is not an assumed outcome. C++ remains a technically viable alternative if measured integration costs invalidate this choice.

### Engine responsibilities

Share composition/session coordination, candidate ordering and selection, input preferences, custom phrases, learning policy, dictionary validation and activation, and portable personal-data formats.

Keep Rime responsible for editing, segmentation, dictionary lookup, paging, and the learning behavior it already supplies. The migration must not introduce a replacement Pinyin engine or change ranking policy merely to fit the new language.

The interface should cover runtime/session lifetime, semantic key events and mobile editing operations, immutable composition snapshots, candidate selection, commit delivery, configuration changes, and optional bounded surrounding text.

Specify string encoding and offset units, memory ownership, error handling, and thread affinity. Do not expose Swift, COM, JNI, or GUI objects. Candidate selection must identify the relevant snapshot so delayed UI actions cannot select an unrelated entry. Errors and language-level unwinding must not cross the ABI unchecked.

Run the engine in the frontend process. Serialize access to librime and its shared configuration; do not assume independent sessions permit concurrent native calls. Keep synchronous key processing independent of `MainActor`, GLib, Android loopers, and Windows message loops. Background preparation may use platform workers or helpers without becoming a dependency of each key event.

### Frontend responsibilities

| Platform | Proposed frontend |
| --- | --- |
| Linux | Fcitx5 for Omarchy/Hyprland and Steam Deck Desktop Mode (KDE Plasma); GNOME/IBus deferred |
| macOS | Existing Swift/InputMethodKit frontend |
| Android | Kotlin `InputMethodService` and native keyboard UI |
| iOS | Swift keyboard extension and containing app |
| Windows | Native TSF integration |

Frontends own focus, input-context lifetime, preedit/commit delivery, UI, shortcuts or touch gestures, and platform privacy signals. They supply storage/resource paths and access to surrounding text. Missing or invalid context must preserve ordinary offline input and native ordering where context ranking cannot apply.

Use a small C ABI initially, with Swift and JNI adapters as needed. Add binding generation only if it reduces demonstrated maintenance work. A shared settings UI and a separate engine daemon are not part of the initial design.

### Product and data boundaries

- Offline typing must not depend on AI, telemetry, downloads, or a companion service.
- Keep network, disk preparation, and SQLite work off the key-event path. Audit existing settings and learning paths rather than copying blocking work into Rust.
- Apply settings and dictionary changes at safe composition boundaries.
- Keep quality recording observational; it must not alter ranking or input or record secrets.
- AI remains default-off. Credentials and permissions belong to the platform integration.
- Preserve supported learning data and custom phrases through explicit backup/import. Translate or reject unsupported preferences explicitly; macOS physical shortcut codes are not portable.
- Tests use isolated data directories. Never run old and new engines against the same live user database concurrently.
- Portable backups do not imply that live databases can be shared or synchronized safely.

## Design ablation

These are design comparisons, not measured implementation experiments.

| Alternative | Benefit | Cost or limitation | Decision |
| --- | --- | --- | --- |
| Keep Swift as the shared core | Reuses the most code immediately | Platform-library work and less natural Windows/Android integration remain | Preserve as the migration reference |
| Use C++ for all shared logic | Direct Rime integration and fewer language boundaries | More manual ownership and concurrency discipline | Viable fallback; prefer Rust |
| Ship schemas through stock Rime frontends | Smaller port | Does not preserve all InkFlow ranking, learning, and lifecycle behavior | Insufficient for full migration |
| Replace Rime with a Rust engine | Removes the native engine dependency eventually | Recreates mature behavior and greatly expands scope | Reject |
| Add a separate engine daemon | Process isolation | IPC and lifecycle work; poor fit for mobile extensions | Omit |
| Share UI across platforms | Potential UI reuse | Does not remove native IME integration and adds framework constraints | Native UI first |
| Generate all bindings immediately | Less handwritten glue | Another tool and abstraction before the interface is proven | Defer |
| Port every optional feature initially | Earlier feature parity | Expands dependencies and delays offline input | Defer on new platforms; preserve macOS behavior |
| Probe every platform before Linux | Earlier discovery of platform constraints | Delays the agreed desktop priority | Defer mobile until macOS cutover, Windows until last |
| Skip old/new behavioral comparisons | Less temporary tooling | Harder to detect rewrite regressions | Retain during migration |
| Add cloud sync | Automatic cross-device learning transfer | Requires conflict resolution, privacy, and network design | Exclude from this migration |

## Migration sequence

### 0. Reproducible development and baseline

Prepare a dedicated checkout on the Mac. Transfer exact revisions, prevent concurrent builds in that checkout, and return logs and exit status. Keep caches and signing credentials on their respective machines. Reject a dirty remote checkout rather than overwrite it.

Pin a common Rust toolchain and native dependency versions. Run the relevant existing macOS tests and preserve behavioral transcripts. Measure startup, resident memory, and representative key-event latency using fixed resources and isolated user data. Agree on performance acceptance criteria after obtaining the baseline.

Completion means Linux can request a reproducible, focused Mac build/test run without installing anything, and the existing engine has a usable behavioral reference. Passwordless sudo and a full CI service are unnecessary. Commands and measurement boundaries are documented in [Remote Mac builds and migration baseline](remote-mac-baseline.md).

### 1. Desktop Rust/Rime feasibility

Build the pinned engine and native extensions on Linux and macOS. Implement the minimum Rust host: initialize, create a session, process input, retrieve snapshots/commits, and destroy the session. Specify the initial ABI and serialized-access contract.

Review dependencies and resource licensing against intended distribution channels. Design for constrained hosts without promising unmeasured mobile resource usage.

Completion means the same minimal implementation produces basic composition on both desktop systems. Resolve native linking, extension registration, and resource preparation problems before migrating broader policy.

### 2. Portable offline behavior and personal data

Extract common dictionary sources, generation configuration, and preparation tools from `macOS/` as needed. Maintain one preparation pipeline; generate and verify compiled resources for the target runtime instead of copying macOS caches.

Migrate domain models and offline engine behavior incrementally, including candidate ordering, custom phrases, settings boundaries, personal learning, and the required dictionary lifecycle. Compare old and new implementations against equivalent isolated fixtures. Preserve observable behavior; do not require byte-identical databases or caches.

Define backup/import handling for supported personal data and unsupported platform preferences. Keep optional systems out of the critical input path.

Completion means relevant regression cases pass, learning survives restart, supported data imports safely, and offline input remains independent of optional services. Ranking-policy changes are separate work.

### 3. Linux daily-use frontend

Implement the Fcitx5 adapter, targeting Omarchy/Hyprland first and Steam Deck Desktop Mode with a physical keyboard. Use desktop-native candidate/preedit APIs. Handle focus/reset, modifier events, surrounding-text capabilities, sensitive fields, and exact commit delivery.

Steam Deck Gaming Mode and controller/on-screen keyboard integration are out of scope. Verify the Deck's actual SteamOS session and application compatibility, including Flatpak clients. Evaluate packaging without disabling SteamOS system protection and check persistence across OS updates. GNOME/IBus is a later adapter; the GNOME development host does not establish compatibility with either target desktop.

Add minimum daily-use configuration, personal-data import, and packaging for the chosen Linux environment. A minimal frontend may start during phase 2 to expose integration issues early.

Completion means an installable Linux build supports the agreed offline behavior with focused automated coverage. The user checks typing and focus in their browser, editor, and terminal, including switching applications mid-composition and sensitive fields.

### 4. macOS cutover

Connect the existing Swift frontend to the shared engine. Preserve settings, candidate presentation, personal data, and existing optional-feature integrations; deferring new-platform AI/voice does not authorize removing them from macOS.

Compare old and new implementations on the same MacBook. Verify real application linkage and data compatibility. Keep a known-good installation available, and install development builds only when explicitly requested.

Completion means macOS and Linux use the same offline core, with no unexplained behavioral or performance regressions. Remove superseded Swift engine code after callers and tests migrate; do not keep two production implementations indefinitely.

The user checks installed typing, focus, and Settings behavior. Remote test results do not substitute for these desktop checks.

### 5. Mobile feasibility and delivery

After macOS cutover, build minimal Android and iOS hosts and test on devices. Measure real-dictionary startup, resident memory, extension/service recreation, and persistent learning. Review current platform restrictions and resource-distribution options before implementing downloads or voice.

An iOS keyboard extension must support offline input without depending on a running containing app or network permission. Its lifecycle, secure-field restrictions, and lack of direct microphone access require platform-specific behavior. Android also requires handling service recreation and limited or sensitive editor context.

If needed, generate mobile resource profiles from shared source policy. Build touch layouts, editing gestures, candidate interaction, accessibility, and minimum settings as platform products. Android versus iOS delivery order will be chosen before this phase.

Completion is per platform: a usable offline keyboard, validated persistence/import, and measured resource behavior. Desktop feature parity is not required for the first mobile release.

### 6. Windows delivery

Build the native dependency chain and shared core for Windows, then implement TSF integration, candidate presentation, configuration, and packaging. Validate composition/focus lifetime and data compatibility in real Windows applications.

Completion means a usable offline Windows IME backed by the same core. Windows-specific build and integration risks are intentionally deferred until after mobile.

### Optional follow-up work

Track quality recording/export, dictionary downloads, AI, voice backends, and additional Linux adapters as separate issues. Implement them without changing offline input availability or privacy guarantees. Their priority can be decided independently of platform rollout.

## Validation and operating rules

Use old/new behavioral comparisons for preedit and caret position, candidate order, commits, partial selection, paging, cancellation, configuration boundaries, and learning after restart. Preserve useful reference cases as permanent regression tests when the old implementation is removed.

Compare performance on the same hardware, build configuration, and resource set. Record latency distributions and slow cases as well as typical timing; do not infer a language advantage from measurements on different machines. Use the [approved headless-core review limits](../Core/Fixtures/MigrationBaseline/README.md#approved-review-limits) for the recorded macOS protocol.

Run only relevant test units. Existing macOS commands remain `bash macOS/scripts/build.sh` and focused `bash macOS/scripts/test.sh ...` invocations. UI-only changes get a build and user inspection. Reserve the full suite for releases or explicit requests. Run Mac builds outside a sandbox.

Build/test and installation remain separate operations. Remote automation must not replace or activate the user's installed IME implicitly. Keep another keyboard input source enabled for development testing.

## Remaining choices

- Choose Android versus iOS order after the macOS cutover.
- Arrange mobile device/toolchain access and, later, Windows development/test access.

These choices do not block creating the desktop baseline or minimal shared engine.
