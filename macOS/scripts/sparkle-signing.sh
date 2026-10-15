#!/bin/bash
# Sparkle 2.10 ships these nested targets. Keep its upstream bundle intact.
# Source this helper; signing flags are supplied by the caller's artifact mode.
sparkle_components() {
  local framework="$1/Contents/Frameworks/Sparkle.framework"
  printf '%s\n' "$framework/Versions/B/XPCServices/Installer.xpc" \
    "$framework/Versions/B/XPCServices/Downloader.xpc" \
    "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"
}

check_sparkle_components() {
  local component
  while IFS= read -r component; do
    [[ -e "$component" ]] || { echo "Missing Sparkle signing component: $component" >&2; return 1; }
  done < <(sparkle_components "$1")
}

sign_sparkle() {
  local app=$1 component
  shift
  check_sparkle_components "$app" || return 1
  # Inside out; Downloader can carry upstream entitlements of its own.
  while IFS= read -r component; do
    if [[ "$component" == */Downloader.xpc ]]; then
      codesign --force "$@" --preserve-metadata=entitlements "$component" || return 1
    else
      codesign --force "$@" "$component" || return 1
    fi
  done < <(sparkle_components "$app")
}

verify_sparkle_developer_id() {
  local app=$1 expected_team=$2 component metadata
  check_sparkle_components "$app" || return 1
  while IFS= read -r component; do
    codesign --verify --strict "$component" || return 1
    metadata=$(codesign -dvvv "$component" 2>&1) || return 1
    # Here-strings, not pipes: grep -q exits at the match, and under pipefail the writer's SIGPIPE fails the check.
    grep -Fxq "TeamIdentifier=$expected_team" <<< "$metadata" || {
      echo "Unexpected Sparkle signing team: $component" >&2; return 1;
    }
    grep -Fq 'Authority=Developer ID Application:' <<< "$metadata" || {
      echo "Expected Developer ID Application signature. Sparkle component: $component" >&2; return 1;
    }
  done < <(sparkle_components "$app")
}
