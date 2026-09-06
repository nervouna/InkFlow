# macOS development

The application, settings interface, registration tool, and test scenarios are written in Swift. The shell build uses Swift 6 language mode, warnings as errors, and an explicit `arm64-apple-macosx26.0` deployment target. Use Xcode command-line tools with the macOS 26 SDK and support for Swift's `isolated deinit` (Swift 6.2 or newer).

## Source boundaries

- `Engine.swift` owns librime sessions and converts C data to `EngineSnapshot` values. It preserves librime's byte cursor as a UTF-16 offset for the text client. Shared schema changes and session calls stay on the main actor. Paths are borrowed only during initialization; `app_name` uses static storage because glog retains it.
- `Context.swift` requests at most 16 UTF-16 units before the current selection or owned marked range through public `IMKTextInput.string(from:actualRange:)`. It validates ranges, permits surrogate adjustments of one UTF-16 unit at either end, and rejects missing, malformed, foreign-mark, or secure-input context. It does not query document length or keep a document/client cache. The per-session prefix is discarded when composition ends.
- `IFContextRanker` loads phrase frequencies from the already bundled `pinyin_simp.dict.yaml` once. It matches only complete dictionary phrases across a contiguous Han prefix and an equal-length alternative to the current page's original first candidate. Longer matching prefixes precede frequency, then original order breaks ties. The pinned dictionary has phrases of at most four characters; this is nearby phrase matching, not sentence semantics. No network service, added model, or context-history store is used.
- The engine owns the displayed-to-native candidate permutation and synchronizes librime's highlight through its public C API. Digits, clicks, arrows, space, punctuation and composition flushes use the displayed selection. `snapshot()` has no mutation side effects. Rime's Return behavior still commits raw input. Once `composition.sel_start > 0`, an already selected segment separates the document prefix from the remaining candidates, so external reranking is disabled. Candidate text length is a conservative filter because the public candidate API exposes no consumed-input span.
- `InputController.swift` connects synchronous InputMethodKit callbacks to the engine and system candidate panel. `@objc(InkFlowInputController)` preserves the runtime name in `Info.plist`. The legacy superclass lacks actor annotations, so callback entry points use checked, synchronous `MainActor.assumeIsolated` scopes. The explicit Sendable conformance and local unsafe callback aliases do not permit background access to the controller's state.
- `Settings.swift` contains validated defaults, a SwiftUI `NavigationSplitView`/`Form`, the About view, and a small AppKit window/hosting shell. The existing defaults keys, values, and notification name remain unchanged.
- `NativeCandidates.m` is the only Objective-C application source. It contains the optional private font setter and the guarded minimum-width adaptation using the SDK's protected `_private` reference. Swift cannot access that protected field. The native `IMKCandidates` interface remains in use; see `DEBUGGING.md` for its compatibility limits.
- `Tools/RegisterInputSource.swift` retains the separate registration and read-only `--verify-enabled` modes. Build and test scripts do not install, register, enable, or select the application.

## Verification

Run the following scripts sequentially from the repository root. The GUI checks require a logged-in macOS desktop session.

```sh
bash macOS/scripts/build.sh
bash macOS/scripts/test.sh
bash macOS/scripts/check-bundle.sh
bash macOS/scripts/test-controller-initialization.sh
bash macOS/scripts/test-settings-ui.sh
```

The test scenarios are Swift executables. `Tests/NativeTestSupport.m` contains the small Objective-C runtime/exception helper needed to inspect native font rendering and accessibility objects, and to intercept framework initialization, client access and teardown in the headless controller test. Swift controllers always run their real initializers. Settings tests use isolated defaults suites; the production initializer test overrides only its process-local argument domain.

Context regressions use the real bundled dictionary for ordering and selection, plus a tiny test-only dictionary for frequency/tie rules. A headless document client verifies UTF-16 and adjusted ranges, selection replacement, marked text, unreadable/secure clients, settings and session isolation. It also verifies that a client losing context or moving its selection before a selection/flush event cannot silently change the candidate already displayed. The test helper preserves the initializer's client for actual click/highlight callbacks. Existing librime user-dictionary learning still applies, so session-isolation checks compare against a contemporaneous no-context engine rather than assuming a permanent first candidate.

For interactive UI inspection, `bash macOS/scripts/test-settings-ui.sh --hold` leaves an isolated settings harness open after its checks. It never launches the installed input method. `--dump-accessibility` prints its accessibility tree for layout diagnosis.

Bundle verification checks the runtime controller name, metadata, icons, resources, arm64 architecture, and system/bundled dynamic-library closure. These checks do not establish installed-IME typing acceptance, signing, or behavior on an older macOS host.
