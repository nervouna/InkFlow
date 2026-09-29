# macOS development

The application, settings interface, registration tool, and test scenarios are written in Swift. Root SwiftPM products share the production modules and use Swift 6 language mode, warnings as errors, macOS 26, and arm64. Shell entry points keep their existing interfaces and use the ignored `build/swiftpm` scratch directory. Use Xcode command-line tools with the macOS 26 SDK and support for Swift's `isolated deinit` (Swift 6.2 or newer).

## Source boundaries

- `../Core/Package.swift` builds the shared `InkFlowDomain` and `InkFlowRime` sources independently; the root package uses those same files. Dictionary source validation, generation, storage, preparation and activation policy live in Core. macOS retains worker process/sandbox execution, bundle/path discovery, command-line framing, logging adapters and UI.
- `../Core/Sources/InkFlowRime/Engine.swift` owns librime sessions and converts C data to `EngineSnapshot` values. It preserves librime's byte cursor as a UTF-16 offset for the text client. `Sources/EngineEvent.swift` adapts macOS events to semantic engine input. Shared schema changes and session calls stay on the main actor. Paths are borrowed only during initialization; `app_name` uses static storage because glog retains it.
- `Context.swift` requests at most 16 UTF-16 units before the current selection or owned marked range through public `IMKTextInput.string(from:actualRange:)`. It validates ranges, permits surrogate adjustments of one UTF-16 unit at either end, and rejects missing, malformed, foreign-mark, or secure-input context. It does not query document length or keep a document/client cache. The per-session prefix is discarded when composition ends.
- `IFContextRanker` loads phrase frequencies from the already bundled `pinyin_simp.dict.yaml` once. It matches only complete dictionary phrases across a contiguous Han prefix and an equal-length alternative to the current page's original first candidate. Longer matching prefixes precede frequency, then original order breaks ties. Eligible Han candidates reorder only within their original slots; non-Han and other ineligible candidates remain fixed barriers. The expanded Chinese dictionary includes longer phrases; the context index admits phrases of two through eight characters. This is nearby phrase matching, not sentence semantics. No network service, added model, or context-history store is used.
- The engine owns the displayed-to-native candidate permutation and synchronizes librime's highlight through its public C API. Digits, clicks, arrows, space, punctuation and composition flushes use the displayed selection. `snapshot()` has no mutation side effects. Rime's Return behavior still commits raw input. Once `composition.sel_start > 0`, an already selected segment separates the document prefix from the remaining candidates, so external reranking is disabled. Context ranking requires identical native start/end input offsets to the original first candidate, alongside the equal-text-length/Han checks. A no-output Lua translator reads only the already materialized page (at most nine candidates) through a synchronous property observer. The bridge carries numeric offsets only, creates no learning `Memory`, and clears its request/response immediately. Missing or invalid coverage preserves native order; it never guesses from text or prepares more translations.
- `InputController.swift` connects synchronous InputMethodKit callbacks to the engine and system candidate panel. It requests key-down, key-up and modifier-change events. The default standalone left Shift press-release toggles Chinese/English; configurable mode, punctuation, script and voice bindings use the cached `KeyboardShortcuts` model. Modifier taps do not toggle when combined with another key. Plain Tab remains fixed for AI acceptance. Because that event mask disables InputMethodKit's key-down-only default mouse handling, the controller explicitly commits an owned composition when the client reports a click outside its marked range, returns the click to the client, and leaves inside-range clicks composing. `@objc(InkFlowInputController)` preserves the runtime name in `Info.plist`. The legacy superclass lacks actor annotations, so callback entry points use checked, synchronous `MainActor.assumeIsolated` scopes. The explicit Sendable conformance and local unsafe callback aliases do not permit background access to the controller's state.
- `Settings.swift` contains validated input defaults, a SwiftUI `NavigationSplitView`/`Form`, the About view, and a small AppKit window/hosting shell. `DictionarySettings.swift` renders the process-owned dictionary coordinator as a compact status, entry count, one contextual action and collapsed diagnostics. Window delegate closure clears presented errors without cancelling work. Non-updater defaults and the settings notification name remain unchanged; Sparkle owns updater preferences after the one-time legacy migration.
- `main.swift` embeds Sparkle's standard updater controller and routes its public settings, check action, lifecycle callbacks and bounded local diagnostics through `IFUpdaterAccess`. Sparkle owns update discovery, scheduling, download, signature validation, caching, installation and relaunch. Automatic checks and automatic download/install remain off unless the user enables them; the automatic-install setting is explicitly described as installation when InkFlow exits. `Settings.swift` performs a one-time migration of the legacy auto-check choice, while later preferences live only in Sparkle. Release tooling keeps the notarized Installer DMG for existing clients and publishes a separately signed ZIP containing only `InkFlow.app` with the generated appcast.
- `../Core/Sources/InkFlowDomain/CustomPhrase.swift` defines the validated custom phrase value; `Sources/CustomPhrases.swift` contains its native SwiftUI table/editor. `Settings.swift` persists its ordered JSON array under `customPhrases`, including stable UUIDs, and posts the existing settings notification only after validation and encoding succeed. Invalid stored data is preserved and surfaced in Personalization; edits cannot silently replace it.
- `NativeCandidates.m` is the only Objective-C application source. It contains the optional private font setter and the guarded minimum-width adaptation using the SDK's protected `_private` reference. Swift cannot access that protected field. The native `IMKCandidates` interface remains in use; see `DEBUGGING.md` for its compatibility limits.
- `Tools/RegisterInputSource.swift` retains the separate registration and read-only `--verify-enabled` modes. Build and test scripts do not install, register, enable, or select the application.
- `scripts/prepare-rime.sh` copies pinned dictionaries and Lua modules and generates the supplemental mixed dictionary for every build and engine-test entry point. Lua supplies public translations, bounded native metadata access, and the existing adoption-learning bridge; the shared native translator composes exact personal English over real Rime spans; Rime retains editing, selection, and paging. See `DEPENDENCIES.md` for weighting and lookup boundaries.

## Shortcut settings

`KeyboardShortcuts.swift` stores five action bindings as physical key codes, modifier flags and display labels in the existing UserDefaults domain. Changes persist explicit unassigned values, reject invalid or conflicting bindings, and cancel pending voice gestures. Hold and double-tap voice actions may share one binding. The recorder captures events only while its native button is first responder; Escape cancels and Delete clears. Common reserved combinations are rejected, but system-wide shortcut conflict detection is not exhaustive.

For UI review without running assertions or starting Rime, use `bash macOS/scripts/test-settings-ui.sh --preview`. This mode uses temporary preferences and a voice fixture, and removes its preferences when the window closes. Normal harness modes retain their existing checks.

## Native candidate lifetime

Native candidate panels remain per-controller. Application bootstrap keeps a
`NativeCandidateLifetime` through the event loop to retain only the latest panel
registered with its server, because the observed legacy server borrows that
pointer. Controllers still release normally, and older panels release when replaced
and no longer controller-owned. The server's association back to the lifetime owner
is weak to avoid the panel-to-server retain cycle. Native diagnostic hosts must
create the same lifetime owner before constructing production controllers and keep
it until their input callbacks finish. See `DEBUGGING.md` for the regression and
installed-input acceptance boundary.

## Custom phrase loading

`InputPreferences.swift` provides immutable typed composition snapshots. `IFSettings` keeps existing `input.<option>` keys and exposes canonical grouped values: any enabled fuzzy pair enables all three; paging preserves an exclusive minus/equal choice and otherwise selects brackets. Group setters persist every affected bit before one settings notification. The Input page uses unlabeled sections, one fuzzy toggle, a horizontal paging radio group aligned to the right and four punctuation dropdowns. The input-source menu shares global punctuation/traditional settings while ASCII remains session-local. Options and ASCII requests wait until the current composition commits or cancels. ASCII uses literal punctuation without modifying the saved Chinese punctuation option. Quality records include only applied input values in an optional backwards-readable field, and count paging aliases according to those applied values.

At an idle boundary, the engine replaces entire translator, custom-phrase, menu, key-binder and punctuator nodes in the shared in-memory config, selects the schema for that session, then restores the nodes. Its translator loads the selected precompiled spelling prism. Other composing sessions retain their previous components; no global engine switch or dictionary update is triggered. Undrained commits survive schema selection. Missing prism/configuration/write failures retain the prior applied settings and report an error. Startup and dictionary-worker receipts require all 32 profile schemas/prisms.

`IFSpellingGenerator` derives the legal full-syllable inventory from the generated Chinese dictionary, including normal equivalent spellings and each profile's explicitly enabled fuzzy pairs. Native Rime algebra applies ordered typo transformations to temporary marked copies, removes their final collisions with that inventory, then strips the marker. Original spellings, abbreviation, fuzzy properties and combined noncolliding typos retain native semantics. Legal-to-legal typos intentionally lose that automatic alias; this is a syllable boundary, not a promise to resolve every sentence ambiguity. Build preparation and both downloaded/rebuilt dictionary paths generate identical schemas before compilation. The main schema includes profile 2's algebra, so it cannot retain an unguarded fallback. All file work stays in preparation or the isolated worker.

An exact code present in the session's applied custom-phrase snapshot bypasses preceding-text reranking. This preserves explicit phrase priority and insertion order, including while a deletion or edit is deferred until idle. Once that code is removed from the applied snapshot, ordinary context ranking resumes. The merge regression covers a one-character custom phrase competing with a dictionary phrase of the same length.

The schema uses `table_translator@custom_phrase` with `stabledb`, exact matching (`enable_completion: false`), no sentence generation, a priority above ordinary Pinyin candidates, and `uniquifier`. Selection, pagination and digit keys stay in Rime and InputMethodKit. Selecting a custom phrase does not add it to the learned Pinyin dictionary.

Each engine coalesces requested phrases and page size until its composition is idle, retaining ASCII mode and any undrained commit. On the main actor it writes a uniquely named, owner-readable TSV in the engine's user directory, temporarily patches `custom_phrase/user_dict` and `menu/page_size` in the shared in-memory config, recreates that session's schema synchronously, restores the config, and removes the TSV. Unique names avoid librime's shared dictionary cache while composing sessions retain their existing candidates. Page-size-only changes also reload the session's current phrase snapshot. The deployed schema and learned dictionary are never rewritten for these settings changes.

The TSV starts with `# no comment` so literal phrases beginning with `#` are supported. This header and parsing behavior are defined by [librime 1.17.0's TSV reader](https://github.com/rime/librime/blob/1.17.0/src/rime/dict/tsv.cc). Decreasing positive row weights preserve insertion order within each code. Codes are normalized lowercase ASCII letters; controls and multiline text are rejected before persistence or TSV generation. Filesystem/configuration failures appear in Personalization and logs without phrase contents. Failed temporary-file cleanup is retained for retry. A process crash during the synchronous load can leave a temporary TSV in the data directory; it is not authoritative storage and is not reused on subsequent loads.

## Personal data backup

Backups reuse the dictionary worker through `--personal-data`, which only sees closed copies under `PersonalData/staging/<UUID>`. Snapshot parsing and full native-map equality are checked before any live replacement. A rollback-first journal covers the three user dictionaries and allowlisted preferences while input sessions are suspended; startup recovery runs before Settings or Rime initialize. This covers process interruption, not power loss. Staging files can contain personal words.

## AI suggestions

`AISettings.swift` / `AIChatCompletions.swift` (BYOK settings and OpenAI-compatible transport), `AIContext.swift` (bounded document reads), `AISuggestionCoordinator.swift` (debounce, stale-result checks), `AISuggestionPanel.swift` (passive presentation). `InputControllerAI.swift` owns Tab delivery. Request identity is raw input + caret + selected prefix; paging and highlighting don't reset the 0.5 s deadline. Document context is read only at dispatch, never by the 100 ms tracker.

## Workflows

### Install a released version

Download the latest DMG from [Releases](https://github.com/nervouna/InkFlow/releases/latest), open `InkFlow Installer.app`, choose Install and Enable.

### Try the current development version

```sh
bash macOS/scripts/build.sh
bash macOS/scripts/install.sh --developer-id     # needs INKFLOW_SIGN_IDENTITY (team T7976FL2LP)
```

Every `build.sh` reserves a new build number (shared across worktrees via `build/build-number/last`; keep that directory). Only the staged app's `CFBundleVersion` changes. Run builds and installs outside the sandbox in the logged-in session. `install.sh` swaps the app atomically, preserves enabled/selected input sources, waits for the old process to exit, and verifies the new PID and build. First installs need InkFlow added in System Settings. `install.sh --debug` is for debugging only.

`check-bundle.sh --fast` checks plist, architecture, library closure and signed structure; `--deep` also regenerates resources and runs the bundled-engine transcript (release verification runs it once).

### Publish a release

Follow the [release skill](../.agents/skills/inkflow-release/SKILL.md). `release-verification.sh` builds once, runs `test.sh all`, runs one deep bundle check, and freezes the Installer executable/icon receipt for packaging.

Testing: see [TESTING.md](TESTING.md).

## Native installer

`Installer/CoreAPI.md` describes the core/window/payload boundary; `check-installer-core.sh` compiles the core and registration CLI. `build-installer.sh /abs/InkFlow.zip /new/output.app` builds an unsigned installer; after signing, `.../Contents/MacOS/InkFlowInstaller --check-payload` verifies the embedded ZIP. Packaging (`package.sh prepare`, then the release runner) signs, notarizes and staples the app, assembles the installer from the verified receipt, and builds a DMG with the installer and Chinese instructions; the DMG is notarized separately.
