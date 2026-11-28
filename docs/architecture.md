# Architecture map and governance

This page is the map of module ownership and dependency direction, the rules CI enforces, and the options
considered and rejected. Component behavior stays in the component docs linked below.

## Modules and dependency direction

Dependencies point down. A module never imports one above it.

| Layer | Module | Location | Owns |
| --- | --- | --- | --- |
| Frontend | `InkFlowApp`, `InkFlowCore`, `InkFlowNative` | `macOS/App`, `macOS/Sources`, `macOS/SwiftPM` | IMK controller, settings UI and UserDefaults, AI, voice, diagnostics, macOS personal-data backup |
| Frontend | `InkFlowDictionaryWorker` | `macOS/DictionaryWorker` | Sandboxed dictionary and personal-data worker process |
| Frontend | `InkFlowInputSources`, `register-input-source` | `macOS/Shared`, `macOS/Tools/RegisterInputSource` | Input-source registration and the update lifecycle |
| Frontend | Fcitx5 addon | `Linux/fcitx5` | Linux input context, UI and configuration |
| Shared Swift | `InkFlowRime` | `Core/Sources/InkFlowRime` | `IFEngine` facade over `ifr_*`, dictionary store and activation, quality store and recorder, voice lexicon |
| Shared Swift | `InkFlowDomain` | `Core/Sources/InkFlowDomain` | Pure value types: input preferences, custom phrases, voice learning, dictionary catalog |
| C modules | `InkFlowPortable`, `InkFlowDictionary` | `Core/Sources` | Swift views of the two Rust static libraries |
| Rust | `inkflow_rime` | `Core/Portable/src` | Sessions, candidate order, input options, custom phrases, portable backup, resource compile and probe |
| Rust | `inkflow_dictionary` | `Core/Portable/dictionary` | Dictionary source validation and generation |
| Native | librime, Lua, OpenCC, extension | `Core/Portable/native`, `Core/Sources/InkFlowRimeNative` | Editing, lookup, paging and Rime's own learning |
| Data | Schemas and Lua | `schemas` | Rime schema, filters and the Lua channel |

The [engine facade](../Core/Docs/engine-facade.md), [portable runtime](../Core/Portable/README.md),
[dictionary lifecycle](../Core/Docs/dictionary-lifecycle.md), [quality recording](../Core/Docs/quality-recording.md)
and [application contracts](../macOS/Docs/ApplicationContracts.md) describe each component.

## State ownership

| State | Authority | Other readers |
| --- | --- | --- |
| Rime user dictionaries `pinyin_simp`, `inkflow_shared_english`, `inkflow_voice_alias` | librime through the Rust engine | Backups snapshot them closed |
| Input options and candidate count | `IFSettings` on macOS, the Fcitx5 config on Linux | Sent to the engine as a full configuration |
| Custom phrases | `IFSettings`; written by the engine as Rime's `custom_phrase.txt` | |
| Quality records | `QualityStore` (SQLite, macOS); the Linux backend | Analysis skill reads exports |
| Prepared resources | The dictionary store's active generation | Engine reads them read-only |
| macOS personal backup and restore | `PersonalDataBackup.swift` and `PersonalDataTransaction.swift` | Linux imports macOS backups through `personal.rs`, a subset that skips the macOS-only settings |

## Enforced rules

`Core/scripts/check-boundaries.sh` runs in CI and fails on:

- A Core Swift target that imports a platform UI framework, depends on a package outside Core, uses `@testable`,
  `@_spi` or `Process`.
- Drift between a target declared in both the root and the Core manifest.
- A root-manifest target under `Core/` that `Core/Package.swift` does not declare. Core tests and tools are
  defined once, in the Core manifest; the root re-declares only the libraries the app links.
- A root-manifest target with a `sources` or `exclude` list. Each target is its directory,
  so a new file cannot silently compile into no target.
- `import InkFlowPortable` outside `InkFlowRime` and the ABI smoke test. Swift reaches the Rust core through the
  `IFEngine`, `IFPortableResources` and `IFPortablePersonalData` facades.
- `#if SWIFT_PACKAGE` in any Swift source. Everything builds through SwiftPM.
- A file bundled from `schemas/` that `macOS/Quality/ranking-resources.txt` does not list, so the
  `rankingResourcesSHA256` fingerprint covers every bundled schema, Lua and OpenCC file.
- A `Memory(` in `schemas/lua/` outside `inkflow_channel.lua` other than `env.memory = Memory(`. Short-lived
  memories go through `channel.with_memory`, which disconnects them under `pcall`.
- A `macOS/scripts/test-*.sh` that no `test.sh` unit reaches and `manual_harnesses` in `test.sh` does not list.

- `scripts/docs-lint.py` fails on a broken documentation link or anchor, a command, flag or test unit that names no
  script, and a skill whose `name` or `description` front matter is wrong.
- `scripts/style-lint.py` fails on added or edited lines over 120 columns, with more than one statement, or, in shell
  tests, with an assertion outside the forms in [TESTING.md](../macOS/TESTING.md#shell-test-assertions).
- `RUSTFLAGS="-D warnings"` in `Core/Portable/test.sh` and `Core/Portable/dictionary/test.sh` turns Rust warnings
  into errors.
- `scripts/pr-body-check.sh` fails a pull request whose body has no `Fixes #N`, `Closes #N` or `Refs #N`.
- `scripts/comment-lint.py` rejects new code comments ([comment cleanup](comment-cleanup.md)).

## Single sources of truth

| Concept | Defined in |
| --- | --- |
| macOS user-data root and dictionary-worker path | `IFApplicationPaths` |
| Unified-log subsystem | `LocalDiagnosticEvent.logSubsystem` |
| Diagnostic modules listed in archives | `LocalDiagnosticEvent.Module` |
| Personal dictionary names (Swift) | `IFPortablePersonalData.names` |
| Candidate-count and font-size bounds | `IFSettings.candidateCounts`, `IFSettings.fontSizes` |
| Dictionary recipe version, source size limit, source catalog | `IFDictionaryCatalog`, read from the Rust generator |
| Engine configuration error codes | `ConfigurationError::code` and `PhraseError::code` in Rust |
| Resource probe cases and messages | `resources.rs`; Swift reports the message as-is |
| SwiftPM build flags for both manifests | `Core/scripts/swift-package.sh` |
| Test timing helpers | `Core/scripts/test-timing.sh` |
| Compiled Rime resource files | `resources::compiled_files` in Rust, read by Swift through `ifr_compiled_file_*` |
| Dictionary generator reference | `Core/Portable/dictionary/fixtures`, re-recorded from Rust with `test.sh --record` |
| Sandboxed worker launch | `IFSandboxedWorkerLauncher` |
| Fcitx5 option to bit mapping | `kOptionBits` in `Linux/fcitx5/src/engine.cpp` |
| Custom-phrase rules | `phrases.rs`; Swift calls it through `IFPhraseRules`, messages in `configurationMessage` |

The remaining Core→macOS edges: `Core/scripts/test.sh` runs the macOS dictionary-generator and AI-learning
scripts, `build-portable.sh` reads `macOS/Info.plist` for the deployment target, and `portable-notices.py`
writes `macOS/Licenses`.

## Considered and rejected

Do not propose these again.

- **Personal-data worker status, encoded three times (S4).** Each encoding translates between exit status, error
  text and diagnostic number.
- **Shared `check`/`fails`/`asyncFails` test helpers (S7).** The copies differ in failure mode and optional codes.
- **One app signing sequence for `install.sh` and the release skill's `package.sh` (O2).** `sign_sparkle` is shared;
  the rest differs on purpose.
- **macOS backup and import through Rust `personal.rs` (P2).** `personal.rs` is a subset: no shortcuts, display or
  voice settings, no committed phase or preference rollback, no path hardening. macOS never runs its import or recover.
- **Dropping Swift's learning revision and size checks (P3).** Swift's revision outlives engine restarts and its
  busy check also waits for commit delivery.
- **Reading option defaults from `ifr_input_options_default` (P4).** The defaults agree and `InkFlowDomain` cannot
  import the ABI.
