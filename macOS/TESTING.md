# Test responsibility and selection

Core coverage means explicit behavior, boundary and failure-path assertions. This is a responsibility inventory, not a line-coverage claim. Product behavior stays in production code; test runners select scenarios and isolate mutable data.

## Responsibility table

| Core rule | Primary automated assertions | Necessary integration | Human boundary |
| --- | --- | --- | --- |
| Editing, candidate indexes and exact-once commit | `EngineTests.runCases`, `punctuation`, `emojiCandidates`; `engine-basic` | `ControllerTests.deliveryAndRecovery`, `outsideCompositionClick`, `leftShiftSwitching`; `controller` | Real editor/browser input, outside clicks, focus and App switching |
| English admission, ranking and context | `EngineTests.englishAdmission`, `conservativeChinesePrefixes`, `contextReranking`, `rankingRules`; `engine-english`, `engine-context` | `ControllerTests.contextReranking` verifies controller capture/selection | Visible candidate behavior when ranking changes |
| Preferences apply at safe input boundaries | `SettingsTests.groupedInputPreferences`; `settings`; `EngineTests.inputSettings`; `engine-options` | `ControllerTests.inputSettings` checks marked ranges and preserved pending input | Affected Settings controls and actual input |
| Custom phrase persistence and engine priority | `SettingsTests.customPhrases`; `EngineTests.customPhrases`; `settings`, `engine-custom-phrases` | `ControllerTests.customPhraseFailure`; startup/activation preserve phrases | Personalization controls when changed |
| Source validation and transactional dictionary storage | `verifyDictionarySources`, `verifyDictionaryStore` in `Core/Tests/InkFlowDictionaryTestSupport`; `shared-core`, `dictionary-source`, `dictionary-store` | Shared `DictionaryPreparationRegression` runs real compilation/probing through both hosts; the full suite retains `NativePreparationFixture` inside the parallel `dictionary-activation` unit while canonical macOS units own duplicate source/store assertions; `DictionaryUpdateTests.runnerFailures` verifies the macOS sandbox/process adapter | Download/update UI when changed |
| Offline fallback, recovery and idle switching | Shared `DictionaryActivationRegression.nativeLifecycle`, `transactionFailures`, `recovery`; `shared-core`, `dictionary-activation` | The macOS wrapper uses the real app worker; `ServingStartupTests.run`, `packagedReadOnly` verify serving startup and read-only resources | Actual multi-App input while updating |
| AI default-off, credentials, debounce, cancellation and invalidation | `AICredentialTests` uses a random Keychain service and synthetic keys; `AISuggestionTests`; `AIRuntimeTests.contextChecks`, `debounceChecks`, `invalidationChecks`, `reentrantChecks`; `ai-credentials`, `ai-transport`, `ai-runtime` | `AIHeadlessPipelineTests.effect`, `profiles`, `visibilityLifecycle`, `adoptionLearning`; `ai-headless`; `ai-learning` checks pronunciation and real Rime learning | Visible panel, Tab acceptance, focus and real service experience |
| Telemetry preserves input and bounded durable data | `QualityStoreTests.v1Migration`, `atomicityAndReaders`, `busyLocks`, `fatalFaults`, `schemaAndOpenFailures`; `quality-store`; identity/timing/metadata units | `quality-capture-query` owns controller timing, real capture and queries against that fresh evidence | No extra typing checklist for internal telemetry-only changes |
| Quality recording pause, clear and retention | `QualityStoreTests.recordingControls`, `queuedControlBarrier`, `retentionAndRollback`; `SettingsTests` persists pause across instances | `QualityCaptureTests.recordingControlComposition` suppresses old text; recording on/off/paused preserves the real controller transcript | Pause/resume and clear in Settings; reopen/restart persistence; next-composition timing; normal learning and daily typing remain usable |
| AI statistics writer/query consistency | `AIStatisticsTests`, `AIStatisticsQueryTests`; `ai-statistics` | Production store changes also run `AISuggestionTests.statisticsResponses` and `AIRuntimeTests.statisticsChecks`; unknown usage remains unknown | No automatic paid API calls |
| Startup diagnostics and shutdown | `StartupDiagnosticsTests`, `TerminationTests`; `startup-diagnostics`, `termination` | Activation/headless consumers selected for lifecycle source changes | Installed process behavior when changed |
| Sparkle application updates | `UpdateTests` through `settings` covers one-time legacy auto-check migration, refusal to inherit old download consent, default-off automatic install and Sparkle as the sole preference source; `test-release-appcast.sh` verifies generated feed metadata and EdDSA signatures | The isolated Sparkle 2.10.0 compatibility sample exercises manual/automatic updates and normal-termination handoff; Settings UI tests exercise native controls with an injected updater and no network | Real InputMethodKit installation, cross-App activation and typing remain Stage 5 acceptance |
| Installer validation, rollback and delivery | `InstallerCoreTests`; `installer-core`; receipt/install/build fixtures in `workflow` | Fast/deep bundle checks validate artifact structure and transcript | Installation/upgrade and installed version acceptance |
| Test entry points and release selection | `test-test-runner.sh`, `test-test-affected.sh`; `runner`; release matrix in `workflow` | Real temporary Git fixtures and stub commands check selections and ordering | None |

No unique assertions are removed by the initial restructuring. Similar inputs across Engine, Controller and AI headless tests retain different responsibilities. Before removing a future duplicate, identify the retained assertion that proves the same contract; share fixture inputs, never a common expected-result algorithm.

In an embedded full-suite run, the standalone Core package remains a compilation owner for all of its executable test products. Ranking and voice-learning coordination execute there because they are Core-only. AI pronunciation, voice lexicon, dictionary store and engine behavior execute in their canonical macOS units. Core's native dictionary-preparation process adapter still runs its focused preparation regression exactly once inside the parallel `dictionary-activation` unit because the macOS worker path cannot cover that host boundary. It starts only after embedded Core compilation publishes a successful status, so the two processes never write the Core SwiftPM scratch concurrently.

Voice coverage is split into `voice-session` (serial correction/fallback/cancellation), `apple-voice` (synthetic audio feed and ASR range contract), `voice-lexicon` plus `ai-learning` (bounded learned views and native undo preservation), and `voice-controller` (fake recognition through the real controller initializer, target identity, selected-text preview and cancellation no-write behavior, preedit-clear recovery despite a stale finite zero-length marked range, UTF-16 marks, reentrant cancellation and exact-once insertion). These tests do not request microphone permission or contact DeepSeek. Authorize microphone access once in Settings; later launches prepare recognition automatically. Manually accept right-Shift hold/double-tap input, selected-text success/Escape followed immediately by ordinary Chinese typing, left-Shift switching and a later voice restart, including after the host clears preedit but briefly retains a zero-length marked range; also check focus/App switches in a native editor and browser, and retain a selection in one surface while dictating into another focused field. Codex is only one cross-surface acceptance scenario and has no product-specific path. Unknown learned lexicon readiness permits voice start with the captured snapshot and existing ASR fallback, while preserving explicit custom phrases and generation-based invalidation.

## Daily use

`bash macOS/scripts/test.sh personal-data` exercises the allowlisted backup format,
atomic shortcut swaps, isolated native full-map snapshots (including empty metadata,
deleted rows and weight values), bounded synthetic scale, malformed files, subprocess
interruption at each dictionary rename, idempotent startup recovery, preference
persistence with an independent reader, and production coordinator/restore sessions.
The suite uses random defaults suites and temporary synthetic dictionaries; it never
reads production learning data or credentials. Its engine lifecycle fixture uses the
existing app's immutable bundled resources, so build the app before running it.
Manual acceptance remains pending for export/import panels, restore confirmation,
cross-app input resumption and preservation of destination AI/privacy preferences.

```sh
bash macOS/scripts/test-affected.sh                 # staged + unstaged + untracked plan
bash macOS/scripts/test-affected.sh --from main     # also include main..HEAD
bash macOS/scripts/test-affected.sh --from main --run
bash macOS/scripts/test.sh engine-options controller settings
bash macOS/scripts/test.sh ai-statistics
bash macOS/scripts/test.sh dictionary-source
bash Core/scripts/test.sh                         # standalone shared modules, no app build
bash Core/scripts/test-dictionaries.sh            # focused source/preparation/native activation
```

The standalone Core package uses the same production sources and assertion helpers as the macOS package. Dictionary tests build private resources and genuine native caches, then compile/probe updates in a test-only child process so a serving Rime runtime remains isolated. They require the pinned native dependencies and run on the current macOS host without AppKit, InputMethodKit or an application bundle; they do not establish an iOS binary or device-runtime result.

`test-affected.sh` uses explicit rules in `scripts/test-impact.sh`, including callers and shared resources. It reports paths, reasons, selected units, preparation and pending human checks. Unknown non-documentation changes select the full non-GUI set; unknown production changes also request conservative human checks. Pure documentation runs only Git whitespace checks. Version-only changes in the app plist select metadata/workflow, build and fast bundle checks; the exemption requires identical non-version keys across the baseline, HEAD, index and working copy.

`TestSupport.swift` and other shared test support select the complete non-GUI suite. `test-test-affected.sh` locks that conservative boundary. `Package.swift` remains full-suite because it can alter any product or target graph. `EngineTests.swift` remains the full `engine` parent because all five engine units share that source file and a path-only selector cannot safely infer which scenario changed.

`--run` executes the printed selection serially, building first when a selected unit needs the app/worker or packaged build inputs changed. Failure stops subsequent steps and reports what did not run. Test preparation/compilation remains owned by existing runners. Do not infer freshness from a binary's existence. Review the plan for newly introduced dependencies and extend the mapping and its regression test together.

`test.sh` has a stable canonical execution order. No arguments and `all` run the complete non-GUI set. Existing parent groups expand into these units, deduplicated before preparation:

| Parent | Units |
| --- | --- |
| `engine` | `engine-basic`, `engine-options`, `engine-english`, `engine-context`, `engine-custom-phrases` |
| `ai` | `ai-credentials`, `ai-transport`, `ai-runtime`, `ai-statistics`, `ai-learning`, `ai-headless` |
| `quality` | `quality-identity`, `quality-store`, `quality-timing`, `quality-metadata`, `quality-capture-query` |
| `dictionary-updates` | `dictionary-source`, `dictionary-store`, `dictionary-worker` |

Other units are `preparation`, `dictionary-generator`, `deployment`, `controller`, `settings`, `dictionary-activation` (including serving startup), `startup-diagnostics`, `termination`, `installer-core`, `runner`, and `workflow`. Unknown groups fail before resource preparation. `ai-credentials` exercises the production Keychain adapter without UI using a unique temporary service, synthetic keys and isolated defaults; it never addresses the production service. `dictionary-source` prepares source fixtures without an app/worker; `dictionary-store` uses synthetic resources and a fixed fingerprint. `dictionary-worker`, `dictionary-activation` and `termination` require a current app built with `build.sh`; termination uses its bundled Rime resources.

Complete suites serially prebuild Swift products, then overlap only `quality-metadata`, `ai-learning`, `ai-headless`, `dictionary-worker`, and `dictionary-activation`. `quality-metadata` and `ai-headless` reuse their validated prebuilt executables without writing the shared SwiftPM scratch during execution; metadata repositories, app/signing fixtures, Rime user data, result logs, and settings suites remain unit-owned temporary state. The other overlapped units likewise own separate temporary user roots and use the app/shared resources read-only. All other units remain serial, partial selections remain serial, and result collection stays deterministic. Each overlapped unit retains its own log, status, and build-plus-execution duration; a failure waits for already-started units and reports only units that truly did not execute. Interrupts terminate and reap the current serial unit plus the five owned parallel process groups before removing their scratch data. Set `INKFLOW_TEST_DISABLE_PARALLEL=1` for a serial diagnostic comparison, not as release evidence.

Engine behavior units and Controller receive separate temporary writable roots, removed on exit. Their settings are isolated. Shared Rime preparation runs once per `test.sh` invocation; adoption learning intentionally retains its separate fresh deployment, and restart/recovery scenarios share state only inside their own test. Capture and its dependent query stay one unit to avoid stale evidence.

## Human and release checks

GUI scripts remain available only for explicit diagnostics. The noninteractive `test-ai-credentials.sh` regression is selected for `AISettings.swift` and as part of the `ai` group; it owns a random Keychain service and never uses production credentials. Live API scripts require explicit paid-call authorization and are never selected automatically by daily or release runners.

For changes that affect interaction, hand off only relevant operations and expected outcomes: input selection/focus/App switching, affected Settings controls, or installation/upgrade. Record unperformed steps as pending. Headless or native harness success does not establish real typing acceptance. Do not recover focus in a loop or run GUI checks on a locked desktop.

Release verification builds once, runs `test.sh all` once and one deep bundle check, plus applicable release-helper fixtures. Entering the release workflow assumes affected input and Settings GUI interaction has already been manually accepted, so these daily-development checklist items are neither printed as release pending work nor publication gates. Release verification prints only a change-based installation/upgrade item and freezes the verified installer/icon for packaging. Automated verification and packaging can complete while that installation result is pending. The release skill requires the explicit result before public publication when installation is affected, recorded in the existing `build/release-notes.md` with version, scope, outcome and commit. Later changes to delivery behavior or artifacts invalidate that acceptance.

## Portable Python query checks

`test-quality-query.sh` and `test-ai-statistics-query.sh` use `python3` from `PATH`
on macOS and Linux. Set `INKFLOW_PYTHON` to another Python executable name or path
when needed; both query suites use only the standard library. No container or
project Python environment is required.

Explicit AI writer fixture directories may be relative or absolute paths. The
existing Swift capture/writer tests run on macOS and create synthetic evidence
beneath `build/`; query tests read those files directly.

`test-ai-statistics.sh` supplies the AI writer fixture pair, while the quality
capture/query unit owns fresh engine evidence for `--require-engine`. Existing
fixtures do not replace fresh writer/capture checks when their production code
changes. These test entry points use synthetic fixtures, not production telemetry
databases or credentials.
