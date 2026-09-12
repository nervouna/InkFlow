# Test responsibility and selection

Core coverage means explicit behavior, boundary and failure-path assertions. This is a responsibility inventory, not a line-coverage claim. Product behavior stays in production code; test runners select scenarios and isolate mutable data.

## Responsibility table

| Core rule | Primary automated assertions | Necessary integration | Human boundary |
| --- | --- | --- | --- |
| Editing, candidate indexes and exact-once commit | `EngineTests.runCases`, `punctuation`, `emojiCandidates`; `engine-basic` | `ControllerTests.deliveryAndRecovery`, `outsideCompositionClick`, `leftShiftSwitching`; `controller` | Real editor/browser input, outside clicks, focus and App switching |
| English admission, ranking and context | `EngineTests.englishAdmission`, `conservativeChinesePrefixes`, `contextReranking`, `rankingRules`; `engine-english`, `engine-context` | `ControllerTests.contextReranking` verifies controller capture/selection | Visible candidate behavior when ranking changes |
| Preferences apply at safe input boundaries | `SettingsTests.groupedInputPreferences`; `settings`; `EngineTests.inputSettings`; `engine-options` | `ControllerTests.inputSettings` checks marked ranges and preserved pending input | Affected Settings controls and actual input |
| Custom phrase persistence and engine priority | `SettingsTests.customPhrases`; `EngineTests.customPhrases`; `settings`, `engine-custom-phrases` | `ControllerTests.customPhraseFailure`; startup/activation preserve phrases | Personalization controls when changed |
| Source validation and transactional dictionary storage | `DictionaryUpdateTests.networkTests`, `storeTests`, `cleanupTests`; `dictionary-source`, `dictionary-store` | `runnerFailures`, `workerSuccess`, `workerNativeFailures`; `dictionary-worker` | Download/update UI when changed |
| Offline fallback, recovery and idle switching | `DictionaryActivationTests.nativeLifecycle`, `transactionFailures`, `recovery`; `dictionary-activation` | `ServingStartupTests.run`, `packagedReadOnly` verify real serving startup and read-only resources | Actual multi-App input while updating |
| AI default-off, debounce, cancellation and invalidation | `AISuggestionTests`; `AIRuntimeTests.contextChecks`, `debounceChecks`, `invalidationChecks`, `reentrantChecks`; `ai-transport`, `ai-runtime` | `AIHeadlessPipelineTests.effect`, `profiles`, `visibilityLifecycle`, `adoptionLearning`; `ai-headless`; `ai-learning` checks pronunciation and real Rime learning | Visible panel, Tab acceptance, focus and real service experience |
| Telemetry preserves input and bounded durable data | `QualityStoreTests.v1Migration`, `atomicityAndReaders`, `busyLocks`, `fatalFaults`, `nonDestructiveSchemaAndOpen`; `quality-store`; identity/timing/metadata units | `quality-capture-query` owns controller timing, real capture and queries against that fresh evidence | No extra typing checklist for internal telemetry-only changes |
| AI statistics writer/query consistency | `AIStatisticsTests`, `AIStatisticsQueryTests`; `ai-statistics` | Production store changes also run `AISuggestionTests.statisticsResponses` and `AIRuntimeTests.statisticsChecks`; unknown usage remains unknown | No automatic paid API calls |
| Startup diagnostics and shutdown | `StartupDiagnosticsTests`, `TerminationTests`; `startup-diagnostics`, `termination` | Activation/headless consumers selected for lifecycle source changes | Installed process behavior when changed |
| Installer validation, rollback and delivery | `InstallerCoreTests`; `installer-core`; receipt/install/build fixtures in `workflow` | Fast/deep bundle checks validate artifact structure and transcript | Installation/upgrade and installed version acceptance |
| Test entry points and release selection | `test-test-runner.sh`, `test-test-affected.sh`; `runner`; release matrix in `workflow` | Real temporary Git fixtures and stub commands check selections and ordering | None |

No unique assertions are removed by the initial restructuring. Similar inputs across Engine, Controller and AI headless tests retain different responsibilities. Before removing a future duplicate, identify the retained assertion that proves the same contract; share fixture inputs, never a common expected-result algorithm.

## Daily use

```sh
bash macOS/scripts/test-affected.sh                 # staged + unstaged + untracked plan
bash macOS/scripts/test-affected.sh --from main     # also include main..HEAD
bash macOS/scripts/test-affected.sh --from main --run
bash macOS/scripts/test.sh engine-options controller settings
bash macOS/scripts/test.sh ai-statistics
bash macOS/scripts/test.sh dictionary-source
```

`test-affected.sh` uses explicit rules in `scripts/test-impact.sh`, including callers and shared resources. It reports paths, reasons, selected units, preparation and pending human checks. Unknown non-documentation changes select the full non-GUI set; unknown production changes also request conservative human checks. Pure documentation runs only Git whitespace checks. Version-only changes in the app plist select metadata/workflow, build and fast bundle checks; the exemption requires identical non-version keys across the baseline, HEAD, index and working copy.

`--run` executes the printed selection serially, building first when a selected unit needs the app/worker or packaged build inputs changed. Failure stops subsequent steps and reports what did not run. Test preparation/compilation remains owned by existing runners. Do not infer freshness from a binary's existence. Review the plan for newly introduced dependencies and extend the mapping and its regression test together.

`test.sh` has a stable canonical execution order. No arguments and `all` run the complete non-GUI set. Existing parent groups expand into these units, deduplicated before preparation:

| Parent | Units |
| --- | --- |
| `engine` | `engine-basic`, `engine-options`, `engine-english`, `engine-context`, `engine-custom-phrases` |
| `ai` | `ai-transport`, `ai-runtime`, `ai-statistics`, `ai-learning`, `ai-headless` |
| `quality` | `quality-identity`, `quality-store`, `quality-timing`, `quality-metadata`, `quality-capture-query` |
| `dictionary-updates` | `dictionary-source`, `dictionary-store`, `dictionary-worker` |

Other units are `preparation`, `dictionary-generator`, `deployment`, `controller`, `settings`, `dictionary-activation` (including serving startup), `startup-diagnostics`, `termination`, `installer-core`, `runner`, and `workflow`. Unknown groups fail before resource preparation. `dictionary-source` prepares source fixtures without an app/worker; `dictionary-store` uses synthetic resources and a fixed fingerprint. `dictionary-worker`, `dictionary-activation` and `termination` require a current app built with `build.sh`; termination uses its bundled Rime resources.

Engine behavior units and Controller receive separate temporary writable roots, removed on exit. Their settings are isolated. Shared Rime preparation runs once per `test.sh` invocation; adoption learning intentionally retains its separate fresh deployment, and restart/recovery scenarios share state only inside their own test. Capture and its dependent query stay one unit to avoid stale evidence.

## Human and release checks

GUI scripts remain available only for explicit diagnostics. `test-ai-credentials.sh` is a separate Keychain/environment check; live API scripts require explicit paid-call authorization. None is selected automatically by daily or release runners.

For changes that affect interaction, hand off only relevant operations and expected outcomes: input selection/focus/App switching, affected Settings controls, or installation/upgrade. Record unperformed steps as pending. Headless or native harness success does not establish real typing acceptance. Do not recover focus in a loop or run GUI checks on a locked desktop.

Release verification builds once, runs `test.sh all` once and one deep bundle check, plus applicable release-helper fixtures. Entering the release workflow assumes affected input and Settings GUI interaction has already been manually accepted, so these daily-development checklist items are neither printed as release pending work nor publication gates. Release verification prints only a change-based installation/upgrade item and freezes the verified installer/icon for packaging. Automated verification and packaging can complete while that installation result is pending. The release skill requires the explicit result before public publication when installation is affected, recorded in the existing `build/release-notes.md` with version, scope, outcome and commit. Later changes to delivery behavior or artifacts invalidate that acceptance.
