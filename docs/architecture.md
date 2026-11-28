# Architecture map and governance

This page is the map of module ownership and dependency direction, the rules CI enforces, and the
architecture-entropy task pool. Component behavior stays in the component docs linked below.

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

The comment lint rejects new code comments ([comment cleanup](comment-cleanup.md)).

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

## Task pool

Status: `done` (committed on the governance branch), `open` (safe, not started), `dropped` (examined, not
worth changing), `pending` (needs a decision, see #254).

| ID | Area | Change | Status |
| --- | --- | --- | --- |
| T1 | Tooling | Delete the unused Swift `DictionaryGeneratorTool`, its bootstrap and the macOS wrapper script | done |
| T2 | Tooling | Fix stale lines: retired remote-runner tests in TESTING.md, the missing DictionaryTool prefix | done |
| T3 | Tooling | Delete the unread `INKFLOW_TEST_DEPENDENCIES_PREPARED` knob | done |
| M1 | macOS | Delete the `IFPackageInput*` mirror left by the deleted installer | done |
| M2 | macOS | Delete the saved-incident backend whose UI was removed in 6264576; leftover files still expire | done |
| M3 | macOS | Delete the unused `qualityRecordingStatus` | done |
| B1 | Build | Root manifest keeps only targets it builds; Core tests and tools live in `Core/Package.swift` | done |
| B2 | Build | `QualityBuildMetadataTool` depends on `InkFlowRime` only | done |
| B3 | Build | Personal-data restore goes through `IFPortablePersonalData`; `InkFlowCore` drops `InkFlowPortable` | done |
| B4 | Build | Each macOS app and tool target is a directory: no source lists, `#import` shim or duplicate header | done |
| S1 | Source of truth | One user-data root and worker path on macOS | done |
| S2 | Source of truth | Backup validation reads the `IFSettings` bounds and the shared dictionary names | done |
| S3 | Source of truth | One unified-log subsystem constant; the archive reads the module list from the enum | done |
| S4 | Source of truth | Personal-data worker status re-encoded three times | dropped: each encoding translates between exit status, error text and diagnostic number |
| S5 | Shallow layers | Preparation calls `IFPortableResources` directly; Swift no longer parses Rust probe text | done |
| S6 | Shallow layers | The worker bootstrap moves into the worker; `IFUpdateDiagnosticOutcome` mirror deleted | done |
| S7 | Tests | Shared `check`/`fails`/`asyncFails` | dropped: the copies differ in failure mode and optional codes |
| S8 | Tooling | Core scripts stop sourcing macOS scripts | done |
| S9 | Tooling | One SwiftPM build function for the root and Core packages | done |
| S10 | Tooling | `quality_exchange.py` moves next to the analysis skill that imports it | done |
| R1 | Rust | Delete `InputSession::engine`, `Runtime::deploy`, the raw-session snapshot tokens, duplicated option codes | done |
| R2 | Rust | Share the ABI release and guarded getter bodies; one prepared-resources `Configuration` | done |
| G1 | Swift | Drop always-true `#if SWIFT_PACKAGE` guards | done |
| D1 | Domain | Delete `schemaPatch`, `IFSpellingGenerator.write`, `sourceURL`; one definition of the catalog constants | done |
| E1 | Enforcement | `check-boundaries.sh` asserts the dependency rules above | done |
| P7 | Fix | Backup export writes the user-dictionary format version that import accepts | done |
| P8 | macOS | Delete the one-time pre-Sparkle preference migration | done |
| P13 | Docs | The Chinese dictionary notice names the Rust generator and the catalog file | done |
| O1 | Linux | One option table for both directions in `Linux/fcitx5/src/engine.cpp` | done (#261) |
| O1b | Linux | `package.sh` calls `prepare-resources.sh`, which writes the one `resources.json` report | done |
| O2 | Release | One app signing sequence shared by `install.sh` and the release skill's `package.sh` | dropped: `sign_sparkle` is shared; the rest differs on purpose |
| O3 | Source of truth | One custom-phrase message table for `CustomPhrase.swift` and `EnginePortable.swift` | done (#277, with P6) |
| O4 | Source of truth | One list of compiled resource files for the receipts and engine checks | done (#264, with P12) |
| O5 | Shallow layers | Move test-only production helpers into tests | done (#262); folding `EngineChannel.swift` dropped: `VoiceLexicon` uses it too |
| O6 | Docs | Test-fixture contracts in `macOS/Docs`; callers run the Core `prepare-*` scripts directly | done (#263) |
| P1 | Rust | Delete the unused mutation observer ABI | done (#256) |
| P5 | Tooling | Freeze the Swift dictionary reference generator as fixtures | done (#257) |
| P9 | macOS | One sandboxed launcher for both workers | done (#260) |
| P10 | Tooling | Retire `cleanup.sh`, the AI native panel experiment and the Swift migration-baseline chain | done (#259) |
| P11 | Build | One directory per macOS test target | done (#271) |
| P12 | Rust | Engine creation checks the one compiled-file list | done (#264) |
| P15 | macOS | One shortcut write gate; startup messages through the unified log | done (#258) |
| P2 | macOS | Run macOS backup and import through Rust `personal.rs` | dropped: `personal.rs` is a subset (no shortcuts, display or voice settings, no committed phase or preference rollback, no path hardening) and macOS never runs its import or recover |
| P3 | Swift | Drop Swift's learning revision and size checks | dropped: Swift's revision outlives engine restarts and its busy check also waits for commit delivery |
| P4 | Source of truth | Read option defaults from `ifr_input_options_default` | dropped: the defaults agree and `InkFlowDomain` cannot import the ABI; the paging default became square brackets only everywhere (#278) |
| P6 | Source of truth | One custom-phrase validator, in Rust | done (#277) |
| P14 | Lua | One Rime `Memory` helper in `inkflow_channel.lua`; drop the unread `inkflow_short_conflict/inputs` key | done |

The remaining Core→macOS edges: `Core/scripts/test.sh` runs the macOS dictionary-generator and AI-learning
scripts, `build-portable.sh` reads `macOS/Info.plist` for the deployment target, and `portable-notices.py`
writes `macOS/Licenses`.

## Decisions

Decisions that need the owner, their outcome and their issues are tracked in
[#254](https://github.com/nervouna/InkFlow/issues/254).

## Log

| Date | Change |
| --- | --- |
| 2026-11-28 | Inventory of the macOS app, shared Swift, Rust core and toolchain at ed799ec |
| 2026-11-28 | Decisions moved to #254; P7, P8 and P13 done |
| 2026-11-28 | Governance pass: the task pool rows marked done; the ranking source fingerprint moves once (Rust engine files, `InputPreferences.swift`, `DictionaryGenerator.swift`) with no ranking change |
| 2026-11-28 | Decided items delivered (#256–#264, #271); P2, P3, P4 and P6 reopened in #254; the ranking source fingerprint moves again (`engine.rs`, `CandidateRanking.swift`) with no ranking change |
| 2026-11-28 | Owner decisions: P2, P3 and P4 dropped; P6 done with Rust's rules (#277); paging defaults to square brackets only (#278). ABI version 4 |
