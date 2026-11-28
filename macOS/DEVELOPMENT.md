# macOS development

The application, settings interface, registration tool, and test scenarios are written in Swift. Root SwiftPM products share the production modules and use Swift 6 language mode, warnings as errors, macOS 26, and arm64; shell entry points keep their existing interfaces and use the ignored `build/swiftpm` scratch directory. Use Xcode command-line tools with the macOS 26 SDK and Swift 6.2 or newer (for Swift's `isolated deinit`).

## Workflows

### Build and try the development version

Build on macOS outside the sandbox because `iconutil` needs host access.
[macOS CI](../.github/workflows/macos.yml) runs the automated checks on GitHub-hosted macOS runners.

```sh
bash macOS/scripts/build.sh
```

`build.sh` builds the [portable core](../Core/Portable/README.md#build-and-test) and stages `build/InkFlow.app`.
Use the [focused test matrix](TESTING.md#which-tests-to-run)
for the change and the [debugging index](DEBUGGING.md) for known failures.

### Install a development build

Installing or activating requires explicit user approval. In the logged-in session outside the sandbox,
`install.sh` signs the staged app, atomically replaces `~/Library/Input Methods/InkFlow.app`, registers it
and verifies the new process. It preserves enabled input sources on update. For a first install, add InkFlow
in System Settings. Developer ID mode needs `INKFLOW_SIGN_IDENTITY` for team `T7976FL2LP`. `install.sh` reads it
only from the environment. The release setup keeps it in the ignored `.release.local.plist`; in a worktree, use
the main checkout's plist.

```sh
INKFLOW_SIGN_IDENTITY=$(plutil -extract INKFLOW_SIGN_IDENTITY raw .release.local.plist) \
  bash macOS/scripts/install.sh --developer-id
```

### Building the installer package

Use an already signed app as the input. `build.sh` leaves the app unsealed and `build-pkg.sh` requires a valid
signature. The example uses the staged app after an authorized [development installation](#install-a-development-build).
You can also pass the signed copy from the [release preparation step](../.agents/skills/inkflow-release/SKILL.md#local-release).

```sh
bash macOS/scripts/build-pkg.sh build/InkFlow.app build/InkFlow.pkg
```

`build-pkg.sh APP OUT [--sign APP_SHA1 INSTALLER_SHA1] [--notes NOTES.md]` wraps a built app in a `.pkg` that Installer.app stages in `~/Library/Caches/io.damao.inkflow.installer` without administrator rights (`Package/Distribution.xml` allows only the current user's home folder; the app is not relocatable). The package scripts ship with the `register-input-source` tool and the expected build number, and never touch `~/Library/Application Support/InkFlow`:

- `Package/preinstall` records the input-source state and quits the running InkFlow through `--prepare-update`. If that fails the install aborts before any file moves.
- `Package/postinstall` swaps the staged app into `~/Library/Input Methods` with `--commit-update` (one rename), then runs `--finish-update`: register, restore the enabled and selected state (a first install enables and selects InkFlow, or prints the System Settings steps if the system does not confirm), relaunch and check the build number. If either step fails, run the package again.

The package is unsigned by default and needs no keychain. `build-pkg.sh APP OUT --sign APP_SHA1 INSTALLER_SHA1` signs the embedded `register-input-source` with the Developer ID Application certificate (hardened runtime, secure timestamp) before it is packaged, then signs the package with the Developer ID Installer certificate (`productbuild --sign --timestamp`). Both arguments are certificate SHA-1 hashes, as in `.release.local.plist`; `productbuild` itself takes a common name, so the script looks it up in the keychain. Release packaging passes the identities and notarizes the result.

`--notes NOTES.md` generates the installer welcome page from the notes' `### 更新内容` bullets, under
`X.Y.Z 更新内容`. The script fails if the file has no such bullets. Without `--notes`, the page shows only the
version. Release packaging passes `build/public-release-notes.md`, so the notes are frozen into the package.

`test-pkg.sh` (part of `test.sh workflow`) builds packages from a fixture app and checks the domain, the non-relocatable app, the app-only payload, the scripts and the `--sign` wiring with stand-in tools; its fixture rules are in [test harness contracts](Docs/TestHarnessContracts.md#test-fixture-constraints).

### Build identity and package details

Every build reserves a new build number in `build/build-number/last`, shared across worktrees. Keep that
directory. The number changes only in the staged app's `CFBundleVersion` and needs no mention in routine build
reports. `check-bundle.sh --fast` checks the plist, architecture, library closure and signing.
`--deep` also regenerates resources. See the [build metadata contract](Docs/BuildMetadata.md) for its inputs.

Bundle checks require one source-built librime with Lua merged into it. Bundled librime license texts are outside
the dynamic-library closure.

The package distribution's minimum system version matches `LSMinimumSystemVersion` and is checked by
`test-pkg.sh`. Package assembly filters AppleDouble `._` entries produced from local provenance attributes out of
the payload, bill of materials and scripts before flattening the component. Developer ID Application
signing covers the embedded Mach-O tools with hardened runtime for notarization. Sparkle is signed
inside out, preserving any upstream Downloader entitlements.
Developer ID Installer certificates use the basic policy for identity search because they lack
code-signing usage. Identity verification exports public certificates for inspection.

The install and update lifecycle, including why the app path must stay present, is in the
[input-source lifecycle contract](Docs/InputSourceLifecycle.md).

### Publish a release

Follow the [release skill](../.agents/skills/inkflow-release/SKILL.md).

## Source boundaries

See the [architecture map](../docs/architecture.md).
