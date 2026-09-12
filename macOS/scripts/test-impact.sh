#!/bin/bash
# Explicit impact rules shared by daily selection and release manual handoff.
# No preparation or Git reads occur when this file is sourced.
impact_reset() {
  impact_groups=()
  impact_manual=()
  impact_reasons=()
  impact_bundle=false
  impact_release_tools=false
  impact_all=false
}
impact_add() { impact_groups+=("$@"); }
impact_manual_add() {
  local item existing found
  for item in "$@"; do
    found=false
    for existing in "${impact_manual[@]}"; do [[ $existing != "$item" ]] || found=true; done
    $found || impact_manual+=("$item")
  done
}
impact_rule() {
  local path=$1 reason=$2
  shift 2
  impact_reasons+=("$path: $reason")
  impact_add "$@"
}
# Only suppress manual checks when every Git state has identical non-version keys.
# Invalid, missing or differently staged plists conservatively keep the normal rule.
impact_plist_version_only() (
  local baseline=${1:-HEAD} scratch state
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-plist-impact.XXXXXX") || return 1
  trap 'rm -rf "$scratch"' EXIT
  git show "$baseline:macOS/Info.plist" > "$scratch/base" 2>/dev/null || return 1
  git show HEAD:macOS/Info.plist > "$scratch/head" 2>/dev/null || return 1
  git show :macOS/Info.plist > "$scratch/index" 2>/dev/null || return 1
  cp macOS/Info.plist "$scratch/worktree" 2>/dev/null || return 1
  for state in base head index worktree; do
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleShortVersionString' "$scratch/$state" >/dev/null 2>&1 || return 1
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleVersion' "$scratch/$state" >/dev/null 2>&1 || return 1
    plutil -convert xml1 "$scratch/$state" >/dev/null 2>&1 || return 1
    cmp -s "$scratch/base" "$scratch/$state" || return 1
  done
)
impact_classify_git() {
  if [[ $1 == macOS/Info.plist ]] && impact_plist_version_only "${2:-HEAD}"; then
    impact_rule "$1" 'version-only plist change: build metadata and workflow' quality-metadata workflow
    impact_bundle=true; impact_release_tools=true
  else impact_classify "$1"
  fi
}
impact_classify() {
  local path=$1
  case "$path" in
    .agents/skills/inkflow-release/*)
      impact_rule "$path" 'release helper and workflow fixtures' workflow
      impact_release_tools=true ;;
    *.md|docs/*|LICENSE|LICENSE.*|NOTICE)
      impact_rule "$path" 'documentation/configuration text: diff check only' ;;
    macOS/Sources/InputPreferences.swift)
      impact_rule "$path" 'input options and controller application' settings engine-options controller
      impact_manual_add manual-input manual-settings ;;
    macOS/Sources/Settings.swift|macOS/Sources/SmartSettingsView.swift|macOS/Tests/SettingsUITests.swift)
      impact_rule "$path" 'settings controls and input preferences' settings engine-options controller voice-controller ai-transport ai-runtime ai-headless
      [[ $path != macOS/Sources/* ]] || impact_manual_add manual-settings manual-input ;;
    macOS/Sources/AppleVoiceRecognizer.swift|macOS/Tests/AppleVoiceRecognizerTests.swift|macOS/scripts/test-apple-voice.sh)
      impact_rule "$path" 'Apple voice capture and ASR lifecycle' apple-voice voice-session voice-lexicon voice-controller ;;
    macOS/Sources/InputControllerVoice.swift|macOS/Sources/VoiceSettings.swift|macOS/Sources/VoiceSettingsView.swift|macOS/Tests/VoiceControllerTests.swift|macOS/scripts/test-voice-controller.sh)
      impact_rule "$path" 'voice target ownership, preparation and independent settings' voice-controller settings
      [[ $path != macOS/Sources/* ]] || impact_manual_add manual-input manual-settings ;;
    macOS/Sources/VoiceSession.swift|macOS/Sources/VoiceCorrectionClient.swift|macOS/Tests/VoiceSessionTests.swift|macOS/scripts/test-voice-session.sh)
      impact_rule "$path" 'voice session and transport contracts' voice-session voice-controller ;;
    macOS/Sources/VoiceLexicon.swift|macOS/Tests/VoiceLexiconTests.swift|macOS/scripts/test-voice-lexicon.sh)
      impact_rule "$path" 'bounded voice lexicon and native learning preservation' voice-lexicon ai-learning ;;
    macOS/Sources/AISettings.swift)
      impact_rule "$path" 'AI configuration, invalidation and headless application' voice-session ai-transport ai-runtime ai-headless
      impact_manual_add manual-settings manual-input ;;
    macOS/Sources/AIChatCompletions.swift|macOS/Tests/AISuggestionTests.swift|macOS/scripts/test-ai-suggestions.sh)
      impact_rule "$path" 'AI transport contracts' voice-session ai-transport ;;
    macOS/Tests/AIStatisticsTestSupport.swift)
      impact_rule "$path" 'shared AI transport/runtime/statistics fixtures' ai-transport ai-runtime ai-statistics ;;
    macOS/Sources/AIStatistics.swift|macOS/Sources/AIStatisticsStore.swift)
      impact_rule "$path" 'real statistics store consumers in transport and runtime' ai-transport ai-runtime ai-statistics ;;
    macOS/Tests/AIStatistics*|macOS/Tools/ai-statistics.py|macOS/scripts/test-ai-statistics*.sh)
      impact_rule "$path" 'statistics writer and query evidence' ai-statistics ;;
    macOS/Sources/AIDiagnostics.swift|macOS/Tests/AIDiagnosticTestSupport.swift)
      impact_rule "$path" 'AI diagnostic consumers' ai-transport ai-runtime ai-headless ai-learning ;;
    macOS/Sources/AIContext.swift|macOS/Sources/AISuggestionCoordinator.swift|macOS/Tests/AIRuntime*)
      impact_rule "$path" 'AI context, cancellation and production integration' ai-runtime ai-headless
      [[ $path != macOS/Sources/* ]] || impact_manual_add manual-input ;;
    macOS/Sources/AIInputPresentation.swift|macOS/Sources/AISuggestionPanel.swift|macOS/Sources/InputControllerAI.swift)
      impact_rule "$path" 'AI presentation and delivery lifecycle' ai-runtime ai-headless
      impact_manual_add manual-input ;;
    macOS/Sources/EngineAI.swift|macOS/Sources/AIPronunciation.swift|macOS/Tests/AIPronunciationTests.swift|macOS/Tests/AIAdoptionLearningTests.swift|macOS/scripts/test-ai-learning.sh)
      impact_rule "$path" 'AI pronunciation and adoption learning' ai-learning ai-headless
      [[ $path != macOS/Sources/* ]] || impact_manual_add manual-input ;;
    macOS/Tests/AIHeadless*|macOS/Tests/AIControllerNativeTests.swift|macOS/scripts/test-ai-headless.sh|macOS/scripts/test-ai-native.sh)
      impact_rule "$path" 'production AI headless contracts; native harness remains explicit' ai-headless ;;
    macOS/scripts/test-ai-runtime.sh)
      impact_rule "$path" 'AI runtime runner' ai-runtime ;;
    macOS/Sources/InputController.swift|macOS/Sources/InputControllerCore.swift|macOS/Sources/InputStatusPanel.swift|macOS/Sources/InputStatusPresentation.swift|macOS/Sources/ThunderPanel.swift|macOS/Sources/ThunderPresentation.swift|macOS/Sources/CandidatePresentation.swift|macOS/Sources/NativeCandidates.*)
      impact_rule "$path" 'input event routing and exact-once delivery' engine-basic controller voice-controller ai-headless quality-capture-query
      impact_manual_add manual-input ;;
    macOS/Sources/InputRankingContext.swift|macOS/Sources/Context.swift)
      impact_rule "$path" 'context ranking and controller capture' engine-context controller
      impact_manual_add manual-input ;;
    macOS/Sources/CustomPhrases.swift)
      impact_rule "$path" 'custom phrase persistence and live engine application' engine-custom-phrases controller settings dictionary-activation
      impact_manual_add manual-input manual-settings ;;
    macOS/Sources/Engine.swift)
      impact_rule "$path" 'shared engine consumers' engine controller ai-headless ai-learning deployment dictionary-activation quality-capture-query
      impact_manual_add manual-input ;;
    macOS/Sources/DictionarySourceClient.swift)
      impact_rule "$path" 'dictionary download and source validation' dictionary-source ;;
    macOS/Sources/DictionaryStore.swift|macOS/Sources/DictionaryUpdateModels.swift)
      impact_rule "$path" 'dictionary transactions and activation/startup recovery' dictionary-store dictionary-worker dictionary-activation startup-diagnostics ;;
    macOS/Sources/DictionaryWorker*|macOS/DictionaryWorker/*|macOS/Tests/DictionaryWorkerFixture.swift|macOS/scripts/build-dictionary-worker.sh)
      impact_rule "$path" 'worker protocol and startup integration' dictionary-worker dictionary-activation startup-diagnostics ;;
    macOS/Sources/DictionaryCoordinator.swift|macOS/Sources/DictionaryModels.swift|macOS/Sources/DictionarySettings.swift|macOS/Tests/DictionarySettingsUITests.swift)
      impact_rule "$path" 'dictionary settings and activation contracts' settings dictionary-source dictionary-store dictionary-worker dictionary-activation
      [[ $path != macOS/Sources/* ]] || impact_manual_add manual-settings manual-input ;;
    macOS/Sources/DictionaryGenerator.swift|macOS/Sources/DictionaryToolBootstrap.swift|macOS/DictionaryTool/*|macOS/Tests/DictionaryGeneratorTests.swift|macOS/scripts/build-dictionary-generator.sh|macOS/scripts/test-dictionary-generator.sh)
      impact_rule "$path" 'generated dictionary contract and deployment' dictionary-generator deployment engine dictionary-worker dictionary-activation
      impact_bundle=true
      case "$path" in macOS/Sources/*|macOS/DictionaryTool/*) impact_manual_add manual-input ;; esac ;;
    schemas/lua/inkflow_ai_learning.lua)
      impact_rule "$path" 'native learning bridge and schema consumers' voice-lexicon ai-learning ai-headless preparation dictionary-generator deployment engine dictionary-worker dictionary-activation
      impact_bundle=true
      impact_manual_add manual-input ;;
    macOS/Sources/PackagedCache*|macOS/Tools/PackagedCacheTool.swift|macOS/scripts/prepare-*.sh|macOS/Data/*|macOS/config/*|macOS/Resources/*|schemas/*|config/*|Data/*|*.yaml|*.yml)
      impact_rule "$path" 'schema/generated resources and deployment consumers' preparation dictionary-generator deployment engine dictionary-worker dictionary-activation
      impact_bundle=true
      impact_manual_add manual-input ;;
    macOS/Quality/*)
      impact_rule "$path" 'production ranking fingerprint inputs and packaged metadata' quality-metadata workflow
      impact_bundle=true; impact_release_tools=true ;;
    macOS/Sources/QualityRecords.swift|macOS/Tests/QualityIdentityTests.swift|macOS/scripts/test-quality-identity.sh)
      impact_rule "$path" 'quality record identity and persistence consumers' quality-identity quality-store quality-capture-query ;;
    macOS/Sources/QualityStore.swift|macOS/Tests/QualityStoreTests.swift|macOS/scripts/test-quality-store.sh)
      impact_rule "$path" 'quality persistence and query compatibility' quality-store quality-capture-query ;;
    macOS/Sources/QualityRecorder.swift|macOS/Tests/QualityTimingTests.swift|macOS/scripts/test-quality-timing.sh)
      impact_rule "$path" 'quality collection must not change input timing or capture' quality-timing quality-capture-query ;;
    macOS/Tests/QualityCaptureTests.swift|macOS/Tests/QualityControllerTimingTests.swift|macOS/Tests/QualityQueryTests.py|macOS/scripts/test-quality-capture.sh|macOS/scripts/test-quality-query.sh|tools/quality*.py)
      impact_rule "$path" 'fresh quality capture and dependent queries' quality-capture-query ;;
    macOS/Tools/QualityBuildMetadata.swift|macOS/scripts/quality-metadata.sh|macOS/Tests/MetadataTests.swift|macOS/scripts/test-quality-metadata.sh)
      impact_rule "$path" 'build metadata and release receipts' quality-metadata workflow
      impact_release_tools=true ;;
    macOS/Sources/StartupDiagnostics.swift|macOS/Tests/StartupDiagnosticsTests.swift|macOS/scripts/test-startup-diagnostics.sh)
      impact_rule "$path" 'startup diagnostics' startup-diagnostics ;;
    macOS/Sources/ApplicationLifecycle.swift)
      impact_rule "$path" 'shutdown and cancellation' termination ai-headless dictionary-activation ;;
    macOS/Tests/TerminationTests.swift|macOS/scripts/test-termination.sh)
      impact_rule "$path" 'termination subprocess modes using bundled Rime' termination ;;
    macOS/Sources/ApplicationBootstrap.swift|macOS/Sources/main.swift)
      impact_rule "$path" 'application startup and service integration' dictionary-activation startup-diagnostics controller ai-headless
      impact_manual_add manual-input manual-settings ;;
    macOS/Installer/*|macOS/Shared/*|macOS/Tools/RegisterInputSource.swift|macOS/scripts/install.sh|macOS/scripts/register.sh|macOS/scripts/refresh-menu.sh|macOS/scripts/build-installer.sh)
      impact_rule "$path" 'installation transaction and workflow fixtures' installer-core termination workflow
      impact_bundle=true
      impact_manual_add manual-install ;;
    macOS/Tests/Installer*|macOS/scripts/test-installer-*.sh|macOS/scripts/check-installer-core.sh)
      impact_rule "$path" 'installer core; window harness remains explicit' installer-core workflow ;;
    macOS/Tests/NativeTestSupport.m|macOS/Tests/include/*)
      impact_rule "$path" 'native support consumers' controller ai-headless quality-capture-query dictionary-activation ;;
    macOS/Tests/TestSupport.swift)
      impact_add voice-controller
      impact_rule "$path" 'shared Swift assertions/settings isolation: all consumers'
      impact_all=true ;;
    macOS/Tests/EngineTests.swift) impact_rule "$path" 'engine scenario collection' engine ;;
    macOS/Tests/ControllerTests.swift|macOS/Tests/ControllerInitializationTests.swift|macOS/scripts/test-controller-initialization.sh)
      impact_rule "$path" 'controller contracts' controller ai-headless ;;
    macOS/Tests/SettingsTests.swift) impact_rule "$path" 'settings rules' settings ;;
    macOS/Tests/DictionaryUpdateTests.swift|macOS/scripts/test-dictionary-updates.sh)
      impact_rule "$path" 'dictionary source/store/worker scenarios' dictionary-updates ;;
    macOS/Tests/DictionaryActivationTests.swift|macOS/Tests/ServingStartup*|macOS/scripts/test-dictionary-activation.sh|macOS/scripts/test-serving-startup.sh)
      impact_rule "$path" 'activation and serving startup' dictionary-activation ;;
    macOS/Tests/DeploymentTests.swift) impact_rule "$path" 'deployment contracts' deployment ;;
    macOS/scripts/test-groups.sh|macOS/scripts/test.sh|macOS/scripts/test-affected.sh|macOS/scripts/test-impact.sh|macOS/scripts/test-test-*.sh)
      impact_rule "$path" 'test selection and shared release mapping regressions' runner workflow ;;
    macOS/scripts/test-workflow.sh|macOS/scripts/test-release-*.sh|macOS/scripts/release-*.sh|macOS/scripts/test-install.sh|macOS/scripts/test-cleanup.sh|macOS/scripts/cleanup.sh)
      impact_rule "$path" 'workflow and release helper fixtures' workflow
      impact_release_tools=true ;;
    macOS/scripts/build.sh|macOS/scripts/build-icon.sh|macOS/scripts/dependencies.sh|macOS/scripts/swift-package.sh|macOS/scripts/swift-test.sh|macOS/scripts/check-bundle.sh|macOS/scripts/verify-developer-id.sh|macOS/scripts/test-build-workflow.sh|macOS/scripts/test-dependencies-cache.sh|macOS/DeveloperID.entitlements)
      impact_rule "$path" 'build/package structure and workflow fixtures' workflow
      impact_bundle=true
      impact_release_tools=true ;;
    Package.swift|macOS/Info.plist)
      impact_rule "$path" 'shared build/product contract: complete non-GUI suite'
      impact_all=true; impact_bundle=true; impact_release_tools=true
      impact_manual_add manual-input manual-settings manual-install ;;
    macOS/Sources/*|macOS/Shared/*|macOS/Installer/*|macOS/SwiftPM/*)
      impact_rule "$path" 'unclassified production path: conservative complete coverage'
      impact_all=true
      impact_manual_add manual-input manual-settings manual-install ;;
    *)
      impact_rule "$path" 'unclassified non-documentation path: conservative complete coverage'
      impact_all=true ;;
  esac
}
impact_expand() {
  if $impact_all; then expand_test_groups all
  elif [[ ${#impact_groups[@]} -gt 0 ]]; then expand_test_groups "${impact_groups[@]}"
  else test_units=()
  fi
}
impact_manual_description() {
  case "$1" in
    manual-input) echo 'typing, candidate selection, focus and cross-App input' ;;
    manual-settings) echo 'affected settings controls, persistence and reopen behavior' ;;
    manual-install) echo 'installation/upgrade result and installed application state' ;;
  esac
}
