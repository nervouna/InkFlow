# macOS development

The application, settings interface, registration tool, and test scenarios are written in Swift. The shell build uses Swift 6 language mode, warnings as errors, and an explicit `arm64-apple-macosx26.0` deployment target. Use Xcode command-line tools with the macOS 26 SDK and support for Swift's `isolated deinit` (Swift 6.2 or newer).

## Source boundaries

- `Engine.swift` owns librime sessions and converts C data to `EngineSnapshot` values. It preserves librime's byte cursor as a UTF-16 offset for the text client. Shared schema changes and session calls stay on the main actor. Paths are borrowed only during initialization; `app_name` uses static storage because glog retains it.
- `Context.swift` requests at most 16 UTF-16 units before the current selection or owned marked range through public `IMKTextInput.string(from:actualRange:)`. It validates ranges, permits surrogate adjustments of one UTF-16 unit at either end, and rejects missing, malformed, foreign-mark, or secure-input context. It does not query document length or keep a document/client cache. The per-session prefix is discarded when composition ends.
- `IFContextRanker` loads phrase frequencies from the already bundled `pinyin_simp.dict.yaml` once. It matches only complete dictionary phrases across a contiguous Han prefix and an equal-length alternative to the current page's original first candidate. Longer matching prefixes precede frequency, then original order breaks ties. The expanded Chinese dictionary includes longer phrases; the context index admits phrases of two through eight characters. This is nearby phrase matching, not sentence semantics. No network service, added model, or context-history store is used.
- The engine owns the displayed-to-native candidate permutation and synchronizes librime's highlight through its public C API. Digits, clicks, arrows, space, punctuation and composition flushes use the displayed selection. `snapshot()` has no mutation side effects. Rime's Return behavior still commits raw input. Once `composition.sel_start > 0`, an already selected segment separates the document prefix from the remaining candidates, so external reranking is disabled. Candidate text length is a conservative filter because the public candidate API exposes no consumed-input span.
- `InputController.swift` connects synchronous InputMethodKit callbacks to the engine and system candidate panel. `@objc(InkFlowInputController)` preserves the runtime name in `Info.plist`. The legacy superclass lacks actor annotations, so callback entry points use checked, synchronous `MainActor.assumeIsolated` scopes. The explicit Sendable conformance and local unsafe callback aliases do not permit background access to the controller's state.
- `Settings.swift` contains validated defaults, a SwiftUI `NavigationSplitView`/`Form`, the About view, and a small AppKit window/hosting shell. `DictionarySettings.swift` renders the process-owned dictionary coordinator, with scrollable metadata/diagnostics and persistent operation controls. Window delegate closure clears presented errors without cancelling work. The existing defaults keys, values, and notification name remain unchanged.
- `CustomPhrases.swift` defines the validated custom phrase value and native SwiftUI table/editor. `Settings.swift` persists its ordered JSON array under `customPhrases`, including stable UUIDs, and posts the existing settings notification only after validation and encoding succeed. Invalid stored data is preserved and surfaced in Personalization; edits cannot silently replace it.
- `NativeCandidates.m` is the only Objective-C application source. It contains the optional private font setter and the guarded minimum-width adaptation using the SDK's protected `_private` reference. Swift cannot access that protected field. The native `IMKCandidates` interface remains in use; see `DEBUGGING.md` for its compatibility limits.
- `Tools/RegisterInputSource.swift` retains the separate registration and read-only `--verify-enabled` modes. Build and test scripts do not install, register, enable, or select the application.
- `scripts/prepare-rime.sh` copies pinned dictionaries and Lua modules and generates the supplemental mixed dictionary for every build and engine-test entry point. `schemas/lua` only supplies translations; Rime retains editing, selection, and paging. See `DEPENDENCIES.md` for weighting and lookup boundaries.

## Custom phrase loading

`InputPreferences.swift` provides immutable typed composition snapshots. `IFSettings` keeps existing `input.<option>` keys and exposes canonical grouped values: any enabled fuzzy pair enables all three; paging preserves an exclusive minus/equal choice and otherwise selects brackets. Group setters persist every affected bit before one settings notification. The Input page uses unlabeled sections, one fuzzy toggle, a horizontal paging radio group aligned to the right and four punctuation dropdowns. The input-source menu shares global punctuation/traditional settings while ASCII remains session-local. Options and ASCII requests wait until the current composition commits or cancels. ASCII uses literal punctuation without modifying the saved Chinese punctuation option. Quality records include only applied input values in an optional backwards-readable field, and count paging aliases according to those applied values.

At an idle boundary, the engine replaces entire translator, custom-phrase, menu, key-binder and punctuator nodes in the shared in-memory config, selects the schema for that session, then restores the nodes. Its translator loads the selected precompiled spelling prism. Other composing sessions retain their previous components; no global engine switch or dictionary update is triggered. Undrained commits survive schema selection. Missing prism/configuration/write failures retain the prior applied settings and report an error. Startup and dictionary-worker receipts require all 32 profile schemas/prisms.

An exact code present in the session's applied custom-phrase snapshot bypasses preceding-text reranking. This preserves explicit phrase priority and insertion order, including while a deletion or edit is deferred until idle. Once that code is removed from the applied snapshot, ordinary context ranking resumes. The merge regression covers a one-character custom phrase competing with a dictionary phrase of the same length.

The schema uses `table_translator@custom_phrase` with `stabledb`, exact matching (`enable_completion: false`), no sentence generation, a priority above ordinary Pinyin candidates, and `uniquifier`. Selection, pagination and digit keys stay in Rime and InputMethodKit. Selecting a custom phrase does not add it to the learned Pinyin dictionary.

Each engine coalesces requested phrases and page size until its composition is idle, retaining ASCII mode and any undrained commit. On the main actor it writes a uniquely named, owner-readable TSV in the engine's user directory, temporarily patches `custom_phrase/user_dict` and `menu/page_size` in the shared in-memory config, recreates that session's schema synchronously, restores the config, and removes the TSV. Unique names avoid librime's shared dictionary cache while composing sessions retain their existing candidates. Page-size-only changes also reload the session's current phrase snapshot. The deployed schema and learned dictionary are never rewritten for these settings changes.

The TSV starts with `# no comment` so literal phrases beginning with `#` are supported. This header and parsing behavior are defined by [librime 1.17.0's TSV reader](https://github.com/rime/librime/blob/1.17.0/src/rime/dict/tsv.cc). Decreasing positive row weights preserve insertion order within each code. Codes are normalized lowercase ASCII letters; controls and multiline text are rejected before persistence or TSV generation. Filesystem/configuration failures appear in Personalization and logs without phrase contents. Failed temporary-file cleanup is retained for retry. A process crash during the synchronous load can leave a temporary TSV in the data directory; it is not authoritative storage and is not reused on subsequent loads.

## Verification

### Daily development

For development, commits, and local merges, run affected unit tests plus necessary related-module and integration checks. Select checks using behavior, callers, shared configuration, and resources, not only changed filenames. Build affected targets and verify the bundle when build inputs or packaged resources change. Documentation-only changes require scoped review and `git diff --check`, not application tests.

Do not run full regression or complete GUI suites by default. Changes to native windows, candidate panels, focus, or input interactions still require targeted GUI/native interaction verification. Use existing focused scripts or supported harness options, such as the Input-page check below; if no focused entry point covers the change, use the smallest existing suite that does. Respect build/resource prerequisites and do not rely on stale application or worker binaries. Broaden checks when failures or uncertain impact justify it.

Report checks run, their scope, and missing, failed, or skipped relevant checks. Passing scoped checks establishes development verification only; it does not establish readiness for formal installation or release. An unavailable GUI session leaves the affected GUI behavior unverified.

### Before formal installation or release

A formal installation replaces the input method used day to day, regardless of Debug or Developer ID signing. Temporary installations specifically for diagnosis do not establish formal acceptance. `install.sh` does not enforce the test gate; the caller must complete it before formal installation.

Run the following full verification sequence from the repository root before formal installation or release. The GUI checks require a logged-in, unlocked macOS desktop session and the runner's existing Accessibility access; their bounded public accessibility initialization does not change system settings.

```sh
bash macOS/scripts/build.sh
bash macOS/scripts/test.sh
bash macOS/scripts/check-bundle.sh
bash macOS/scripts/test-controller-initialization.sh
bash macOS/scripts/test-settings-ui.sh
```

For GUI-evidence recording and reuse, follow the same-machine, source-tree and environment requirements in [the release skill](../.agents/skills/inkflow-release/SKILL.md#2-verify-the-release-contents). A successful `gui-verification.sh check` may replace rerunning the two GUI suites above; missing or invalid evidence requires a fresh recording. Full non-GUI checks must still run for formal installation or release. Releases additionally require all release-skill checks, including signing, notarization, and final artifact verification. Do not proceed with missing or failed required checks. Real installed-input-method typing acceptance remains a separate user-owned step.

### Test coverage and focused entry points

`test.sh` accepts one or more groups, runs each once in the existing suite order, and rejects unknown arguments before running checks. No arguments or `all` retains the full non-GUI suite; do not combine `all` with group names. Use `--help` to list groups.

```sh
bash macOS/scripts/test.sh settings
bash macOS/scripts/test.sh engine controller
bash macOS/scripts/test-test-runner.sh # Isolated test-runner regression checks
```

| Group | Coverage and prerequisites |
| --- | --- |
| `quality` | Store, metadata, engine capture, then query tests against freshly captured evidence |
| `preparation` | Rime preparation policy fixtures |
| `dictionary-generator` | Dictionary generation, with dependency preparation |
| `deployment` | Deployment scenarios, with dependencies and test dictionaries |
| `engine` | Engine scenarios, with dependencies and test dictionaries |
| `controller` | Headless controller scenarios, with dependencies and test dictionaries |
| `settings` | Settings logic, with librime compilation dependencies; no built app or test dictionaries required |
| `dictionary-updates` | Update/worker scenarios; run `build.sh` first for a current app and generated dictionary sources |
| `dictionary-activation` | Native activation/recovery; run `build.sh` first for a current app and generated dictionary sources |

Group selection does not infer affected modules from Git changes. The worker existence check does not prove build freshness; rebuild when its source or resource inputs have changed. GUI suites remain separate.

The test scenarios are Swift executables. `Tests/NativeTestSupport.m` contains the small Objective-C runtime/exception helper needed to inspect native font rendering and accessibility objects, and to intercept framework initialization/teardown and supplied-client lookup in the headless controller test. Swift controllers always run their real initializers. Settings tests use isolated defaults suites; the production initializer test overrides only its process-local argument domain.

`test.sh` reuses the previously built application/worker and includes dictionary generation, source/update preparation, and native activation/recovery suites. `test-settings-ui.sh` exercises the Dictionary pane through native accessibility button/disclosure actions, real window close/reopen, all error stages, background progress, engine rollback/unavailability and minimum/enlarged layout. Its backend is explicitly injected with synthetic transport results, temporary dictionary/user roots and a captured diagnostic sink; it never contacts update repositories or reads real learning/preferences. The default unconfigured Settings window remains inert. Native engine/worker correctness has separate lower-layer tests; UI assertions do not substitute for those tests or for the real-client checks in [DICTIONARIES.md](DICTIONARIES.md#manual-acceptance).

Custom phrase tests cover normalized CRUD, stable IDs and persistence, duplicate/control rejection, corrupt-data preservation, real Rime priority/deduplication and ordinary candidates, exact matching, multiple pages and native selection, composing-session isolation, settings notifications, pending-commit preservation, deletion after selection, engine restart, failed writes/retry, temporary-file removal and unchanged deployed schema bytes. The GUI harness starts Personalization explicitly to check native table/control layout and empty state at minimum/enlarged sizes. For interactive acceptance, navigate to Personalization, add two phrases under one code, reject an invalid/duplicate entry, cancel an editor, edit and delete the selection, then reopen settings and inspect the list. The harness uses an isolated preferences suite.

Context regressions use the real bundled dictionary for ordering and selection, plus a tiny test-only dictionary for frequency/tie rules. A headless document client verifies UTF-16 and adjusted ranges, selection replacement, marked text, unreadable/secure clients, settings and session isolation. It also verifies that a client losing context or moving its selection before a selection/flush event cannot silently change the candidate already displayed. The test helper preserves the initializer's client for actual click/highlight callbacks. Existing librime user-dictionary learning still applies, so session-isolation checks compare against a contemporaneous no-context engine rather than assuming a permanent first candidate.

For interactive UI inspection, `bash macOS/scripts/test-settings-ui.sh --hold` leaves an isolated settings harness open after its checks. It never launches the installed input method. `--dump-accessibility` prints its accessibility tree for layout diagnosis.

`bash macOS/scripts/test-settings-ui.sh --input-only --dump-accessibility` checks the compact Input page through native fuzzy/radio/popup actions, mutual exclusion, disabled mapping preservation and error display, then exits before unrelated pane scenarios.

Bundle verification checks the runtime controller name, metadata, icons, resources, arm64 architecture, and system/bundled dynamic-library closure. These checks do not establish installed-IME typing acceptance, signing, or behavior on an older macOS host.
