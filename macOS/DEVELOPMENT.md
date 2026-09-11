# macOS development

The application, settings interface, registration tool, and test scenarios are written in Swift. The shell build uses Swift 6 language mode, warnings as errors, and an explicit `arm64-apple-macosx26.0` deployment target. Use Xcode command-line tools with the macOS 26 SDK and support for Swift's `isolated deinit` (Swift 6.2 or newer).

## Source boundaries

- `Engine.swift` owns librime sessions and converts C data to `EngineSnapshot` values. It preserves librime's byte cursor as a UTF-16 offset for the text client. Shared schema changes and session calls stay on the main actor. Paths are borrowed only during initialization; `app_name` uses static storage because glog retains it.
- `Context.swift` requests at most 16 UTF-16 units before the current selection or owned marked range through public `IMKTextInput.string(from:actualRange:)`. It validates ranges, permits surrogate adjustments of one UTF-16 unit at either end, and rejects missing, malformed, foreign-mark, or secure-input context. It does not query document length or keep a document/client cache. The per-session prefix is discarded when composition ends.
- `IFContextRanker` loads phrase frequencies from the already bundled `pinyin_simp.dict.yaml` once. It matches only complete dictionary phrases across a contiguous Han prefix and an equal-length alternative to the current page's original first candidate. Longer matching prefixes precede frequency, then original order breaks ties. Eligible Han candidates reorder only within their original slots; non-Han and other ineligible candidates remain fixed barriers. The expanded Chinese dictionary includes longer phrases; the context index admits phrases of two through eight characters. This is nearby phrase matching, not sentence semantics. No network service, added model, or context-history store is used.
- The engine owns the displayed-to-native candidate permutation and synchronizes librime's highlight through its public C API. Digits, clicks, arrows, space, punctuation and composition flushes use the displayed selection. `snapshot()` has no mutation side effects. Rime's Return behavior still commits raw input. Once `composition.sel_start > 0`, an already selected segment separates the document prefix from the remaining candidates, so external reranking is disabled. Candidate text length is a conservative filter because the public candidate API exposes no consumed-input span.
- `InputController.swift` connects synchronous InputMethodKit callbacks to the engine and system candidate panel. It requests key-down and modifier-change events so a standalone left Shift press-release toggles the requested Chinese/English mode; right Shift and left Shift used with another key do not toggle. Because that event mask disables InputMethodKit's key-down-only default mouse handling, the controller explicitly commits an owned composition when the client reports a click outside its marked range, returns the click to the client, and leaves inside-range clicks composing. `@objc(InkFlowInputController)` preserves the runtime name in `Info.plist`. The legacy superclass lacks actor annotations, so callback entry points use checked, synchronous `MainActor.assumeIsolated` scopes. The explicit Sendable conformance and local unsafe callback aliases do not permit background access to the controller's state.
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

AI input suggestions are split between `AISettings.swift` / `AIChatCompletions.swift` (BYOK settings and compatible transport), `AIContext.swift` (bounded document access), `AISuggestionCoordinator.swift` (debounce and stale-result checks), and `AISuggestionPanel.swift` (passive AppKit presentation). `InputController.swift` owns client lifecycle and Tab delivery. Engine request identity includes raw input, caret and selected prefix, excluding candidate pages, highlights and display preedit. Controller-authored display range changes retain the input deadline; externally changed client ranges invalidate it. Full document context is captured only at dispatch, response validation and acceptance, never by the 100 ms position tracker.

`bash macOS/scripts/test-ai-runtime.sh` tests real 0.5-second debounce timing, changed display ranges during navigation, late services that ignore cancellation, repeated compositions, context and configuration invalidation, secure/foreign marks, UTF-16 boundaries, and reentrant document reads. It uses in-memory credentials, synthetic context and an injected service. The `ai` group in `test.sh` includes this suite plus transport, settings, statistics and adoption-learning tests.

`bash macOS/scripts/test-ai-native.sh` requires a logged-in GUI session. Its separate app uses real Rime, IMK candidate windows and the production controller with a recording document client; the existing framework-initialization/client-lookup shim supplies the synthetic client because IMK normally requires its own cross-process proxy. It checks passive window geometry/focus, ordinary space/digit/click selection, partial composition prefixes, exact-once Tab, delivery leases under synchronous client reentry, and stale lifecycle events. It neither registers an input source nor changes production preferences or Keychain entries. The script requires a final acceptance marker as well as a successful exit code.

For explicitly authorized paid verification, run `bash macOS/scripts/test-ai-live.sh /absolute/path/to/ignored/.env` for transport fixtures or `bash macOS/scripts/test-ai-native.sh --live /absolute/path/to/ignored/.env` for one complete production API-to-panel-to-Tab fixture. The file must be untracked and Git-ignored and contain `LLM_BASE_URL`, `LLM_API_KEY`, and `LLM_MODEL`; the parser treats it as data and never executes shell contents. Live fixtures require official DeepSeek and `deepseek-v4-flash`, use synthetic text only, and never print credentials. No retries or benchmarks are implicit.

Real typing acceptance remains separate: configure and enable smart prediction, pause with candidates visible, browse pages, accept with Tab, and compare ordinary space/digit/click behavior in the user's text editor and browser. Verify composition edits, moving the insertion point, input-source switching, service failure and disabling the feature while a request is pending. Build and native harness results do not establish this user-owned acceptance.

### Before formal installation or release

A formal installation replaces the input method used day to day, regardless of Debug or Developer ID signing. Temporary installations specifically for diagnosis do not establish formal acceptance. `install.sh` does not enforce the test gate; the caller must complete it before formal installation.

Run the following full verification sequence from the repository root before formal installation or release. The GUI checks require a logged-in, unlocked macOS desktop session and the runner's existing Accessibility access; their bounded public accessibility initialization does not change system settings.

```sh
bash macOS/scripts/build.sh
bash macOS/scripts/test.sh
bash macOS/scripts/check-bundle.sh
bash macOS/scripts/test-controller-initialization.sh
bash macOS/scripts/test-serving-startup.sh --native
bash macOS/scripts/test-settings-ui.sh
bash macOS/scripts/test-installer-window.sh
bash macOS/scripts/check-installer-core.sh
bash .agents/skills/inkflow-release/scripts/test.sh
```

For GUI-evidence recording and reuse, follow the same-machine, source-tree and environment requirements in [the release skill](../.agents/skills/inkflow-release/SKILL.md#2-verify-the-release-contents). A successful `gui-verification.sh check` may replace rerunning the two GUI suites above; missing or invalid evidence requires a fresh recording. Full non-GUI checks must still run for formal installation or release. Releases additionally require all release-skill checks, including signing, notarization, and final artifact verification. Do not proceed with missing or failed required checks. Real installed-input-method typing acceptance remains a separate user-owned step.

### Test coverage and focused entry points

The `dictionary-activation` group includes `test-serving-startup.sh`: the production
startup entry point serves its packaged fallback while actual recovery is gated,
then switches at all-client idle. It checks saved journal/date preservation,
failure/retry/shutdown, read-only cache bytes, all spelling profiles, custom phrases,
and user-root reopen. Run `test-serving-startup.sh --native` for the focused host,
native candidate panel and two-client delivery variant. Its IMK initialization and
client-lookup shim is the same synthetic-client boundary used by the AI native
harness. External application routing remains separate. Each run retains its own
ignored `build/serving-startup-run.*/run.log`; a failed host-focus prerequisite is
unsuccessful evidence, not a product assertion or PASS. This new startup check is
not covered by previously recorded Settings/controller GUI evidence.

`test.sh` accepts one or more groups, runs each once in the existing suite order, and rejects unknown arguments before running checks. No arguments or `all` retains the full non-GUI suite; do not combine `all` with group names. Use `--help` to list groups.

```sh
bash macOS/scripts/test.sh settings
bash macOS/scripts/test.sh engine controller
bash macOS/scripts/test-test-runner.sh # Isolated test-runner regression checks
```

| Group | Coverage and prerequisites |
| --- | --- |
| `quality` | Store, metadata, engine capture, then query tests against freshly captured evidence |
| `ai` | Suggestion transport, statistics, runtime coordination and adoption learning, with dependencies and prepared Rime test data |
| `preparation` | Rime preparation policy fixtures |
| `dictionary-generator` | Dictionary generation, with dependency preparation |
| `deployment` | Deployment scenarios, with dependencies and test dictionaries |
| `engine` | Engine scenarios, with dependencies and test dictionaries |
| `controller` | Headless controller scenarios, with dependencies and test dictionaries |
| `settings` | Settings logic, with librime compilation dependencies; no built app or test dictionaries required |
| `dictionary-updates` | Update/worker scenarios; run `build.sh` first for a current app and generated dictionary sources |
| `dictionary-activation` | Native activation/recovery; run `build.sh` first for a current app and generated dictionary sources |
| `termination` | Graceful input-method shutdown and timeout handling |
| `installer-core` | Transactional installation, validation, rollback, and state reporting |

Group selection does not infer affected modules from Git changes. The worker existence check does not prove build freshness; rebuild when its source or resource inputs have changed. GUI suites remain separate.

The test scenarios are Swift executables. `Tests/NativeTestSupport.m` contains the small Objective-C runtime/exception helper needed to inspect native font rendering and accessibility objects, and to intercept framework initialization/teardown and supplied-client lookup in the headless controller test. Swift controllers always run their real initializers. Settings tests use isolated defaults suites; the production initializer test overrides only its process-local argument domain.

`test.sh` reuses the previously built application/worker and includes dictionary generation, source/update preparation, and native activation/recovery suites, plus `test-termination.sh` and `test-installer-core.sh`. `test-settings-ui.sh` exercises the Dictionary pane through native accessibility button/disclosure actions, real window close/reopen, all error stages, background progress, engine rollback/unavailability and minimum/enlarged layout. Its backend is explicitly injected with synthetic transport results, temporary dictionary/user roots and a captured diagnostic sink; it never contacts update repositories or reads real learning/preferences. The default unconfigured Settings window remains inert. Native engine/worker correctness has separate lower-layer tests; UI assertions do not substitute for those tests or for the real-client checks in [DICTIONARIES.md](DICTIONARIES.md#manual-acceptance).

Custom phrase tests cover normalized CRUD, stable IDs and persistence, duplicate/control rejection, corrupt-data preservation, real Rime priority/deduplication and ordinary candidates, exact matching, multiple pages and native selection, composing-session isolation, settings notifications, pending-commit preservation, deletion after selection, engine restart, failed writes/retry, temporary-file removal and unchanged deployed schema bytes. The GUI harness starts Personalization explicitly to check native table/control layout and empty state at minimum/enlarged sizes. For interactive acceptance, navigate to Personalization, add two phrases under one code, reject an invalid/duplicate entry, cancel an editor, edit and delete the selection, then reopen settings and inspect the list. The harness uses an isolated preferences suite.

Context regressions use the real bundled dictionary for ordering and selection, plus a tiny test-only dictionary for frequency/tie rules. A headless document client verifies UTF-16 and adjusted ranges, selection replacement, marked text, unreadable/secure clients, settings and session isolation. It also verifies that a client losing context or moving its selection before a selection/flush event cannot silently change the candidate already displayed. The test helper preserves the initializer's client for actual click/highlight callbacks. Existing librime user-dictionary learning still applies, so session-isolation checks compare against a contemporaneous no-context engine rather than assuming a permanent first candidate.

For interactive UI inspection, `bash macOS/scripts/test-settings-ui.sh --hold` leaves an isolated settings harness open after its checks. It never launches the installed input method. `--dump-accessibility` prints its accessibility tree for layout diagnosis.

`bash macOS/scripts/test-settings-ui.sh --input-only --dump-accessibility` checks the compact Input page through native fuzzy/radio/popup actions, mutual exclusion, disabled mapping preservation and error display, then exits before unrelated pane scenarios.

Bundle verification checks the runtime controller name, metadata, icons, resources, arm64 architecture, and system/bundled dynamic-library closure. These checks do not establish installed-IME typing acceptance, signing, or behavior on an older macOS host.

## Native installer packaging

`Installer/CoreAPI.md` describes the core/window/payload boundary. Compile the core
and registration CLI with `bash macOS/scripts/check-installer-core.sh`. The full
regression includes isolated termination and installer transaction/state tests.
`test-installer-window.sh` exercises an isolated native window with fake backends;
it needs an unlocked desktop and never operates the daily input source. Formal GUI
evidence now requires this suite as well as controller initialization and Settings.

`bash macOS/scripts/build-installer.sh /absolute/path/to/InkFlow.zip /new/output.app`
compiles the installer and copies version/build from `macOS/Info.plist` without
signing, registration or installation. The output path must not exist. After
Developer ID signing, execute `"/new/output.app/Contents/MacOS/InkFlowInstaller" --check-payload`
to check extraction of the embedded ZIP and app metadata, print payload version/build,
then clean up temporary files. Signature and notarization checks remain separate release QA. This read-only probe does not use TIS or start
the input method. Local signed, unnotarized fixtures do not prove release trust.

The release helper uses `package.sh prepare` then `package.sh finish`. Between them,
explicitly submit the retained input-method ZIP through the existing notary wrapper,
wait for acceptance, and staple/validate the input-method app. Finish creates a fresh
ZIP of that app, builds/signs the installer, checks arm64 and system dependency
closure, runs its actual `--check-payload`, and creates a DMG containing only the
installer and Chinese instructions. `check-bundle.sh [app]` checks either the normal
build or an explicitly supplied payload with the existing resource/engine checks.
The final DMG requires its own external notarization and stapling. See the
[release workflow](../.agents/skills/inkflow-release/SKILL.md) for commands and recovery.

Release acceptance additionally requires trusted downloaded/quarantined DMG launch,
extraction of the inner app with its ticket intact and independent signature/stapler
assessment, clean-user installation and old-version upgrade, and actual client typing.
Builds, fixture tests and the read-only payload probe establish none of those runtime
outcomes. Do not run native GUI suites on a locked screen or replace daily installation
acceptance with a temporary diagnostic installation.
