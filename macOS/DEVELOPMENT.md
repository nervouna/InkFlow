# macOS development

The application, settings interface, registration tool, and test scenarios are written in Swift. Root SwiftPM products share the production modules and use Swift 6 language mode, warnings as errors, macOS 26, and arm64; shell entry points keep their existing interfaces and use the ignored `build/swiftpm` scratch directory. Use Xcode command-line tools with the macOS 26 SDK and Swift 6.2 or newer (for Swift's `isolated deinit`).

## Source boundaries

- `../Core/Package.swift` builds the shared `InkFlowDomain` and `InkFlowRime` sources used by the root package. Dictionary source validation, generation, storage, preparation and activation policy live in Core; macOS owns worker process/sandbox execution, bundle/path discovery, command-line framing, logging adapters and UI.
- `../Core/Sources/InkFlowRime/Engine.swift` is the `IFEngine` facade over the Rust core's C ABI (`../Core/Portable/include/inkflow_rime.h`, linked as `InkFlowPortable`): sessions, key policy, candidate order, custom phrases and input preferences are the core's (`../Core/Portable/src`); the facade keeps the delivery lease, idle signalling, voice-lexicon gating, quality recording and Settings errors, and converts snapshots to `EngineSnapshot` values. `Sources/EngineEvent.swift` adapts macOS events to semantic engine input. Session calls stay on the main actor.
- `Context.swift` reads bounded surrounding text through public `IMKTextInput`; the Rust core reorders Han candidates within their slots from the bundled context index.
- `InputController.swift` connects InputMethodKit callbacks to the engine and the system candidate panel.
- `Settings.swift` holds validated defaults and the SwiftUI settings UI; Sparkle (`IFUpdaterAccess`) owns updater preferences.
- `NativeCandidates.m` is the only Objective-C source: private candidate-panel adaptations (see `DEBUGGING.md`).
- `Tools/RegisterInputSource.swift` registers and verifies the input source and runs the update lifecycle (stop the old process, restore the enabled and selected state, relaunch); `Shared/` holds its code, which `install.sh` and the package scripts use. Build and test scripts never install, register or select it. `test.sh input-source-lifecycle` covers `Shared/`.
- `scripts/prepare-rime.sh` delegates to the [shared dictionary preparation](../docs/shared-dictionary-preparation.md); see [DEPENDENCIES.md](DEPENDENCIES.md) for pins.

## Workflows

### Build and try the development version

```sh
bash macOS/scripts/build.sh
bash macOS/scripts/install.sh --developer-id     # needs INKFLOW_SIGN_IDENTITY (team T7976FL2LP)
```

`build.sh` first builds the portable core (`Core/scripts/build-portable.sh`: librime from source with Lua merged in, and the release Rust archive), which needs CMake and Ninja on `PATH`, then ships only `build/portable/prefix/lib/librime.1.dylib`; the first run takes about 4 minutes longer. Every `build.sh` reserves a new build number (shared across worktrees via `build/build-number/last`; keep that directory); only the staged app's `CFBundleVersion` changes. Run builds and installs outside the sandbox in the logged-in session. `install.sh` swaps the app atomically, preserves enabled input sources and verifies the new PID; first installs need InkFlow added in System Settings. `check-bundle.sh --fast` checks plist, architecture, library closure and signing; `--deep` also regenerates resources.

### Building the installer package

```sh
bash macOS/scripts/build.sh
bash macOS/scripts/build-pkg.sh build/InkFlow.app build/InkFlow.pkg
```

The app must be signed before it is packaged: `build.sh` leaves it unsealed, and `build-pkg.sh` refuses an app whose `codesign --verify --deep --strict` fails. Sign it first with `install.sh` or the release flow.

`build-pkg.sh APP OUT` wraps a built app in a `.pkg` that Installer.app stages in `~/Library/Caches/io.damao.inkflow.installer` without administrator rights (`Package/Distribution.xml` allows only the current user's home folder; the app is not relocatable). The package scripts ship with the `register-input-source` tool and the expected build number, and never touch `~/Library/Application Support/InkFlow`:

- `Package/preinstall` records the input-source state and quits the running InkFlow through `--prepare-update`. If that fails the install aborts before any file moves.
- `Package/postinstall` swaps the staged app into `~/Library/Input Methods` with `--commit-update` (one rename, so the installed path never goes missing), then runs `--finish-update`: register, restore the enabled and selected state (a first install enables and selects InkFlow, or prints the System Settings steps if the system does not confirm), relaunch and check the build number. If either step fails, run the package again.

The package is unsigned by default and needs no keychain. `build-pkg.sh APP OUT --sign APP_SHA1 INSTALLER_SHA1` signs the embedded `register-input-source` with the Developer ID Application certificate (hardened runtime, secure timestamp) before it is packaged, then signs the package with the Developer ID Installer certificate (`productbuild --sign --timestamp`). Both arguments are certificate SHA-1 hashes, as in `.release.local.plist`; `productbuild` itself takes a common name, so the script looks it up in the keychain. Release packaging passes the identities and notarizes the result.

`test-pkg.sh` (part of `test.sh workflow`) builds packages from a fixture app and checks the domain, the non-relocatable app, the app-only payload, the scripts and the `--sign` wiring with stand-in `codesign` and `security` tools; it installs nothing and touches no keychain.

### Build identity and package details

The build verifies the generator's declared dictionary inputs before taking the identity snapshot.
It bootstraps the snapshot tool with SwiftPM and re-enters SwiftPM afterward so a source edit during
bootstrap cannot leave the embedded metadata tool out of sync. Bundle checks require one source-built
librime with Lua merged into it. Bundled librime license texts are outside the dynamic-library closure.

Installer scripts run as the logged-in user with that user's home directory. Preinstall requests a
graceful application shutdown through the lifecycle tool so the incumbent app can run its termination
handler. Postinstall can remove the staging directory after either swap outcome. It contains the old
app after success or the staged app after a failure. The atomic swap keeps the registered path
continuously present, which macOS 27's input menu requires. The package distribution's minimum
system version matches `LSMinimumSystemVersion` and is checked by `test-pkg.sh`.

Package assembly filters AppleDouble `._` entries produced from local provenance attributes out of
the payload, bill of materials and scripts before flattening the component. Developer ID Application
signing covers the embedded Mach-O tools with hardened runtime for notarization. Sparkle is signed
inside out, preserving any upstream Downloader entitlements. The signing checks use here-strings
with `grep -q` so a successful early match cannot give a pipe producer SIGPIPE under `pipefail`.
Developer ID Installer certificates use the basic policy for identity search because they lack
code-signing usage. Identity verification exports public certificates for inspection.

Local update checks process and input-source observations in the real login session. It checks for
an installed-app replacement even when the helper exits before confirming success. It preserves the
menu agent during the upgrade because restarting that agent can make the input menu disappear.
`refresh-menu.sh` is a separate current-user diagnostic for that agent.

The dictionary corresponding-source script accepts `OUTPUT.tar.gz [BUILD]`. It archives the
recipe as committed at HEAD along with pinned upstream data, notices and the generation manifest.
It writes `git archive` to a file before extraction because reading from a pipe could stop at
tar's end marker and deliver SIGPIPE upstream. Chinese inputs are verified against the generator
catalog, and other archive inputs against the pinned dependency digests. Frequency snapshotting
looks up exact stored wordfreq keys. The provider's estimated multi-token, punctuation and digit
frequencies are outside the data snapshot.

### Publish a release

Follow the [release skill](../.agents/skills/inkflow-release/SKILL.md).

Testing: see [TESTING.md](TESTING.md). Debugging: see [DEBUGGING.md](DEBUGGING.md).
