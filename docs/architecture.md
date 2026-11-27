# Architecture map and governance

This page is the map of module ownership and dependency direction, the rules CI enforces, and the
architecture-entropy task pool. Component behavior stays in the component docs linked below.

## Modules and dependency direction

Dependencies point down. A module never imports one above it.

| Layer | Module | Location | Owns |
| --- | --- | --- | --- |
| Frontend | `InkFlowApp`, `InkFlowCore`, `InkFlowNative` | `macOS/Sources`, `macOS/SwiftPM` | IMK controller, settings UI and UserDefaults, AI, voice, diagnostics, macOS personal-data backup |
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

## Enforced rules

`Core/scripts/check-boundaries.sh` runs in CI and fails on:

- A Core Swift target that imports a platform UI framework, depends on a package outside Core, uses `@testable`,
  `@_spi` or `Process`.
- Drift between a target declared in both the root and the Core manifest.

The comment lint rejects new code comments ([comment cleanup](comment-cleanup.md)).

## Task pool

Status: `done` (committed on the governance branch), `open` (safe, not started), `pending` (needs a decision).

| ID | Area | Change | Status |
| --- | --- | --- | --- |
| T1 | Tooling | Delete the unused Swift `DictionaryGeneratorTool`, its bootstrap and the macOS wrapper script | open |
| T2 | Tooling | Fix stale lines: retired remote-runner tests in TESTING.md, the missing `macOS/DictionaryTool/` prefix | open |
| T3 | Tooling | Delete the unread `INKFLOW_TEST_DEPENDENCIES_PREPARED` knob | open |
| M1 | macOS | Delete the `IFPackageInput*` mirror left by the deleted installer | open |
| M2 | macOS | Delete the saved-incident backend whose UI was removed in 6264576 | open |
| M3 | macOS | Delete the unused `qualityRecordingStatus` | open |
| B1 | Build | Root manifest keeps only targets it builds; Core-only tests and tools live in `Core/Package.swift` | open |
| B2 | Build | `QualityBuildMetadataTool` depends on `InkFlowRime` only | open |
| B3 | Build | macOS personal-data restore goes through the `IFPortablePersonalData` facade; `InkFlowCore` drops `InkFlowPortable` | open |
| B4 | Build | Each macOS target is a directory: no hand-kept source lists, no `#import` shim, no duplicate header | open |
| S1 | Source of truth | One user-data root and worker path on macOS | open |
| S2 | Source of truth | Backup validation reads the `IFSettings` bounds and the shared dictionary names | open |
| S3 | Source of truth | One unified-log subsystem constant; the archive reads the module list from the enum | open |
| S4 | Source of truth | Personal-data worker status carried as a number, not re-encoded three times | open |
| S5 | Shallow layers | Preparation calls `IFPortableResources` directly; Swift stops parsing Rust error text for probe numbers | open |
| S6 | Shallow layers | Inline `DictionaryWorkerBootstrap` and `IFUpdateDiagnostics` into their only callers | open |
| S7 | Tests | One nonisolated `check`/`fails`/`asyncFails` in Core test support | open |
| S8 | Tooling | Core scripts stop sourcing macOS scripts | open |
| S9 | Tooling | One SwiftPM argument builder for the root and Core packages | open |
| S10 | Tooling | `quality_exchange.py` moves next to the analysis skill that imports it | open |
| R1 | Rust | Delete dead or test-only items: `InputSession::engine`, `Runtime::deploy`, duplicated option codes, Swift `schemaPatch`; ranking fingerprint moves once | open |
| R2 | Rust | Share the ABI release and string helpers; one prepared-resources `Configuration` | open |
| E1 | Enforcement | `check-boundaries.sh` asserts the dependency rules this pass establishes | open |

## Pending decisions

| ID | Question | Evidence |
| --- | --- | --- |
| P1 | Implement [#91](https://github.com/nervouna/InkFlow/issues/91) (quality through the Rust mutation observer) or delete the observer ABI | No frontend installs `ifr_engine_set_observer`; both frontends diff snapshots themselves |
| P2 | Port macOS backup and import to Rust `personal.rs`, or keep two implementations | `PersonalDataBackup.swift` and `PersonalDataTransaction.swift` reimplement `personal.rs`; the journals share a path with incompatible schemas |
| P3 | Remove Swift's own learning revision and too-large checks | `EnginePersonalLearning.swift` and `VoiceLexicon.swift` re-check what `engine.rs` enforces |
| P4 | Adopt or delete `ifr_input_options_default` | Option defaults live in Rust, Swift, the Linux config and the schema |
| P5 | Freeze the Swift dictionary reference generator as fixtures, as was done for the Swift engine | Every generator rule is written twice (361d2d3, b3b7399) |
| P6 | Align custom-phrase validation between Swift and Rust | Swift rejects format characters and lowercases Unicode; Rust rejects controls and lowercases ASCII |
| P7 | Export and import must agree on the Rime version | Export writes `IFEngine.version`, validation requires `1.17.0`; a librime bump breaks macOS export |
| P8 | Delete the one-time pre-Sparkle update-preference migration | `Info.plist` already defaults both keys to off |
| P9 | One sandboxed worker launcher for dictionary and personal-data workers | Two launchers differ in timeout, environment and stderr capture |
| P10 | Retire `cleanup.sh`, `macOS/Experiments/AINativePanel` and the migration-baseline performance chain | No caller outside their own tests |
| P11 | One directory per macOS test target | Removes the remaining test source lists; about 45 moves |
| P12 | Move the compiled-file checks into Rust engine creation | Changes Linux engine-creation errors |
| P13 | Correct the generator paths in `macOS/Licenses/chinese-dictionaries-NOTICE.txt` | Shipped licence text names deleted Swift files |
| P14 | Share Lua channel helpers and drop the unread `inkflow_short_conflict/inputs` key | Changes resource bytes and the ranking fingerprint |
| P15 | Derive `personalDataRecoveryRequired` from `IFSettings`; route startup `NSLog` through the unified log | Settings gating and diagnostics the user checks |

## Log

| Date | Change |
| --- | --- |
| 2026-11-28 | Inventory of the macOS app, shared Swift, Rust core and toolchain at ed799ec |
