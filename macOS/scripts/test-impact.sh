#!/bin/bash
# Coarse domains keep daily selection reviewable. Release verification still runs all units.
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

# A version-only plist edit avoids interaction checks only when every Git state agrees.
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
    impact_rule "$1" 'version metadata' quality-metadata workflow
    impact_bundle=true; impact_release_tools=true
  else
    impact_classify "$1"
  fi
}

impact_classify() {
  local path=$1
  case "$path" in
    .agents/skills/inkflow-release/*)
      impact_rule "$path" 'release workflow' workflow
      impact_release_tools=true ;;
    *.md|docs/*|LICENSE|LICENSE.*|NOTICE)
      impact_rule "$path" 'documentation: diff check only' ;;
    macOS/scripts/probe-imk-candidate-lifetime.sh|macOS/scripts/diagnostics/IMKCandidateLifetimeProbe.m)
      impact_rule "$path" 'standalone native diagnostic: run explicitly outside daily checks' ;;
    Package.swift|macOS/Info.plist)
      impact_rule "$path" 'product and target graph: complete non-GUI coverage'
      impact_all=true; impact_bundle=true; impact_release_tools=true
      impact_manual_add manual-input manual-settings manual-install ;;

    macOS/Sources/AIStatistics*|macOS/Tests/AIStatistics*|macOS/Tools/ai-statistics.py|macOS/scripts/test-ai-statistics*.sh)
      impact_rule "$path" 'AI statistics domain' ai-transport ai-runtime ai-statistics ;;
    macOS/Sources/AI*|macOS/Sources/InputControllerAI.swift)
      impact_rule "$path" 'AI feature domain' ai voice-session settings
      impact_manual_add manual-input manual-settings ;;
    macOS/Tests/AI*|macOS/scripts/test-ai-*.sh)
      impact_rule "$path" 'AI test domain' ai ;;

    macOS/Sources/VoiceLexicon.swift)
      impact_rule "$path" 'voice lexicon and native learning bridge' voice-session apple-voice voice-lexicon voice-controller ai-learning settings ai-transport
      impact_manual_add manual-input manual-settings ;;
    macOS/Sources/*Voice*.swift)
      impact_rule "$path" 'voice feature domain' voice-session apple-voice voice-lexicon voice-controller settings ai-transport
      impact_manual_add manual-input manual-settings ;;
    macOS/Tests/*Voice*.swift|macOS/scripts/test-*voice*.sh)
      impact_rule "$path" 'voice test domain' voice-session apple-voice voice-lexicon voice-controller ;;

    macOS/Sources/Quality*|macOS/Tests/Quality*|macOS/scripts/*quality*.sh|macOS/Tools/QualityBuildMetadata.swift|tools/quality*.py)
      impact_rule "$path" 'input quality domain' quality
      case "$path" in macOS/Tools/QualityBuildMetadata.swift|macOS/scripts/*quality-metadata.sh) impact_release_tools=true ;; esac ;;
    macOS/Quality/*)
      impact_rule "$path" 'packaged quality identity' quality-metadata workflow
      impact_bundle=true; impact_release_tools=true ;;

    schemas/lua/inkflow_input_coverage.lua)
      impact_rule "$path" 'native candidate coverage bridge and consumers' preparation dictionary-generator deployment engine controller ai-headless voice-controller quality-capture-query dictionary-updates dictionary-activation settings startup-diagnostics
      impact_bundle=true
      impact_manual_add manual-input ;;
    schemas/lua/inkflow_ai_learning.lua)
      impact_rule "$path" 'native learning bridge and generated-data consumers' voice-lexicon ai-learning ai-headless preparation dictionary-generator deployment engine dictionary-updates dictionary-activation settings startup-diagnostics
      impact_bundle=true
      impact_manual_add manual-input manual-settings ;;
    macOS/Sources/PackagedCache*|macOS/Tools/PackagedCacheTool.swift|macOS/Resources/*)
      impact_rule "$path" 'packaged resources and cache consumers' preparation dictionary-generator deployment engine dictionary-updates dictionary-activation
      impact_bundle=true
      impact_manual_add manual-input ;;
    macOS/Sources/Dictionary*|macOS/DictionaryTool/*|macOS/DictionaryWorker/*|macOS/Data/*|macOS/config/*|schemas/*|config/*|Data/*|*.yaml|*.yml|macOS/scripts/prepare-*.sh)
      impact_rule "$path" 'dictionary and generated-data domain' preparation dictionary-generator deployment engine dictionary-updates dictionary-activation settings startup-diagnostics
      impact_bundle=true
      impact_manual_add manual-input manual-settings ;;
    macOS/Tests/Dictionary*|macOS/scripts/test-dictionary*.sh|macOS/scripts/build-dictionary*.sh)
      impact_rule "$path" 'dictionary test domain' dictionary-generator deployment dictionary-updates dictionary-activation ;;

    macOS/Sources/FeedbackReport.swift|macOS/Sources/FeedbackSettingsView.swift)
      impact_rule "$path" 'opt-in feedback settings path' settings
      impact_manual_add manual-settings ;;
    macOS/Sources/AboutSettingsView.swift)
      impact_rule "$path" 'about settings presentation' settings
      impact_manual_add manual-settings ;;
    macOS/Sources/Settings.swift|macOS/Sources/SmartSettingsView.swift|macOS/Sources/KeyboardShortcuts.swift)
      impact_rule "$path" 'shared settings and AI integration' settings engine-options controller voice-controller ai-transport ai-runtime ai-headless
      impact_manual_add manual-input manual-settings ;;
    macOS/Sources/AvailableUpdate.swift|macOS/Sources/GitHubRelease*.swift|macOS/Sources/SemanticVersion.swift|macOS/Sources/Update*.swift)
      impact_rule "$path" 'automatic application update domain' settings
      impact_manual_add manual-settings manual-install ;;
    macOS/Sources/*SettingsView.swift|macOS/Sources/InputPreferences.swift)
      impact_rule "$path" 'settings domain' settings engine-options controller ai-runtime voice-controller
      impact_manual_add manual-input manual-settings ;;
    macOS/Sources/EngineAI.swift)
      impact_rule "$path" 'engine and AI learning integration' engine controller ai-headless ai-learning voice-controller quality-capture-query
      impact_manual_add manual-input ;;
    macOS/Sources/CustomPhrases.swift)
      impact_rule "$path" 'custom phrases and activation integration' engine controller ai-headless voice-controller quality-capture-query settings dictionary-activation
      impact_manual_add manual-input manual-settings ;;
    macOS/Sources/Engine.swift)
      impact_rule "$path" 'shared engine integration' engine controller ai-headless ai-learning voice-controller quality-capture-query deployment dictionary-activation
      impact_manual_add manual-input ;;
    macOS/Sources/Engine*|macOS/Sources/InputController*|macOS/Sources/Context.swift|macOS/Sources/InputRankingContext.swift|macOS/Sources/CustomPhrases.swift|macOS/Sources/*Presentation.swift|macOS/Sources/*Panel.swift|macOS/Sources/NativeCandidates.*)
      impact_rule "$path" 'input engine and controller domain' engine controller ai-headless voice-controller quality-capture-query
      impact_manual_add manual-input ;;
    macOS/Tests/EngineTests.swift) impact_rule "$path" 'engine tests' engine ;;
    macOS/Tests/Controller*|macOS/scripts/test-controller*.sh) impact_rule "$path" 'controller tests' controller ai-headless ;;
    macOS/Tests/SettingsTests.swift|macOS/Tests/SettingsUITests.swift|macOS/Tests/UpdateTests.swift)
      impact_rule "$path" 'settings and application update tests' settings ;;
    macOS/Sources/StartupDiagnostics.swift|macOS/Tests/StartupDiagnosticsTests.swift|macOS/scripts/test-startup-diagnostics.sh)
      impact_rule "$path" 'startup diagnostics' startup-diagnostics ;;

    macOS/Sources/Application*|macOS/Sources/main.swift)
      impact_rule "$path" 'application lifecycle: complete non-GUI coverage'
      impact_all=true; impact_manual_add manual-input manual-settings ;;
    macOS/Installer/*|macOS/Shared/*|macOS/Tools/RegisterInputSource.swift|macOS/scripts/install.sh|macOS/scripts/register.sh|macOS/scripts/refresh-menu.sh|macOS/scripts/build-installer.sh)
      impact_rule "$path" 'installation domain' installer-core termination workflow
      impact_bundle=true; impact_manual_add manual-install ;;
    macOS/Tests/Installer*|macOS/scripts/test-installer-*.sh|macOS/scripts/check-installer-core.sh)
      impact_rule "$path" 'installer tests' installer-core workflow ;;

    macOS/Tests/TestSupport.swift|macOS/Tests/NativeTestSupport.m|macOS/Tests/include/*)
      impact_rule "$path" 'shared test support: complete non-GUI coverage'
      impact_all=true ;;
    macOS/scripts/test-groups.sh|macOS/scripts/test.sh|macOS/scripts/test-affected.sh|macOS/scripts/test-impact.sh|macOS/scripts/test-test-*.sh)
      impact_rule "$path" 'test runner' runner workflow ;;
    macOS/scripts/test-workflow.sh|macOS/scripts/test-release-*.sh|macOS/scripts/release-*.sh|macOS/scripts/test-install.sh|macOS/scripts/test-cleanup.sh|macOS/scripts/cleanup.sh)
      impact_rule "$path" 'workflow helpers' workflow
      impact_release_tools=true ;;
    macOS/scripts/build.sh|macOS/scripts/build-icon.sh|macOS/scripts/dependencies.sh|macOS/scripts/swift-package.sh|macOS/scripts/swift-test.sh|macOS/scripts/check-bundle.sh|macOS/scripts/verify-developer-id.sh|macOS/scripts/test-build-workflow.sh|macOS/scripts/test-dependencies-cache.sh|macOS/DeveloperID.entitlements)
      impact_rule "$path" 'build and package workflow' workflow
      impact_bundle=true; impact_release_tools=true ;;
    macOS/Tests/*|macOS/scripts/test-*.sh)
      impact_rule "$path" 'unclassified test: complete non-GUI coverage'
      impact_all=true ;;
    macOS/Sources/*|macOS/Shared/*|macOS/Installer/*|macOS/SwiftPM/*)
      impact_rule "$path" 'unclassified production path: complete non-GUI coverage'
      impact_all=true; impact_manual_add manual-input manual-settings manual-install ;;
    *)
      impact_rule "$path" 'unclassified path: complete non-GUI coverage'
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
