# macOS development

The application, settings interface, registration tool, and test scenarios are written in Swift. The shell build uses Swift 6 language mode, warnings as errors, and an explicit `arm64-apple-macosx26.0` deployment target. Use Xcode command-line tools with the macOS 26 SDK and support for Swift's `isolated deinit` (Swift 6.2 or newer).

## Source boundaries

- `Engine.swift` owns librime sessions and converts C data to `EngineSnapshot` values. It preserves librime's byte cursor as a UTF-16 offset for the text client. Shared schema changes and session calls stay on the main actor. Paths are borrowed only during initialization; `app_name` uses static storage because glog retains it.
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

The test scenarios are Swift executables. `Tests/NativeTestSupport.m` contains the small Objective-C runtime/exception helper needed to inspect native font rendering and accessibility objects, and to intercept only framework initialization/teardown in the headless controller test. Swift controllers always run their real initializers. Settings tests use isolated defaults suites; the production initializer test overrides only its process-local argument domain.

For interactive UI inspection, `bash macOS/scripts/test-settings-ui.sh --hold` leaves an isolated settings harness open after its checks. It never launches the installed input method. `--dump-accessibility` prints its accessibility tree for layout diagnosis.

Bundle verification checks the runtime controller name, metadata, icons, resources, arm64 architecture, and system/bundled dynamic-library closure. These checks do not establish installed-IME typing acceptance, signing, or behavior on an older macOS host.
