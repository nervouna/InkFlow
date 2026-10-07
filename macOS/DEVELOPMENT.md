# macOS development

The application, settings interface, registration tool, and test scenarios are written in Swift. Root SwiftPM products share the production modules and use Swift 6 language mode, warnings as errors, macOS 26, and arm64; shell entry points keep their existing interfaces and use the ignored `build/swiftpm` scratch directory. Use Xcode command-line tools with the macOS 26 SDK and Swift 6.2 or newer (for Swift's `isolated deinit`).

## Source boundaries

- `../Core/Package.swift` builds the shared `InkFlowDomain` and `InkFlowRime` sources used by the root package. Dictionary source validation, generation, storage, preparation and activation policy live in Core; macOS owns worker process/sandbox execution, bundle/path discovery, command-line framing, logging adapters and UI.
- `../Core/Sources/InkFlowRime/Engine.swift` owns librime sessions and converts C data to `EngineSnapshot` values; `Sources/EngineEvent.swift` adapts macOS events to semantic engine input. Shared schema changes and session calls stay on the main actor.
- `Context.swift` reads bounded surrounding text through public `IMKTextInput`; `IFContextRanker` reorders Han candidates within their slots from bundled phrase frequencies.
- `InputController.swift` connects InputMethodKit callbacks to the engine and the system candidate panel.
- `Settings.swift` holds validated defaults and the SwiftUI settings UI; Sparkle (`IFUpdaterAccess`) owns updater preferences.
- `NativeCandidates.m` is the only Objective-C source: private candidate-panel adaptations (see `DEBUGGING.md`).
- `Tools/RegisterInputSource.swift` registers and verifies the input source; build and test scripts never install, register or select it.
- `scripts/prepare-rime.sh` delegates to the [shared dictionary preparation](../docs/shared-dictionary-preparation.md); see [DEPENDENCIES.md](DEPENDENCIES.md) for pins.

## Workflows

### Build and try the development version

```sh
bash macOS/scripts/build.sh
bash macOS/scripts/install.sh --developer-id     # needs INKFLOW_SIGN_IDENTITY (team T7976FL2LP)
```

Every `build.sh` reserves a new build number (shared across worktrees via `build/build-number/last`; keep that directory); only the staged app's `CFBundleVersion` changes. Run builds and installs outside the sandbox in the logged-in session. `install.sh` swaps the app atomically, preserves enabled input sources and verifies the new PID; first installs need InkFlow added in System Settings. `check-bundle.sh --fast` checks plist, architecture, library closure and signing; `--deep` also regenerates resources.

### Publish a release

Follow the [release skill](../.agents/skills/inkflow-release/SKILL.md). `release-verification.sh` builds once, runs `test.sh all`, runs one deep bundle check, and freezes the Installer receipt for packaging.

Testing: see [TESTING.md](TESTING.md). Debugging: see [DEBUGGING.md](DEBUGGING.md).

## Native installer

`Installer/CoreAPI.md` describes the core/window/payload boundary; `check-installer-core.sh` compiles the core and registration CLI; `build-installer.sh /abs/InkFlow.zip /new/output.app` builds an unsigned installer. Packaging (`package.sh prepare`, then the release runner) signs, notarizes and staples the app, assembles the installer and builds the DMG.
