#!/bin/bash
# Shared canonical order and expansion. Sourcing this file performs no preparation.
test_all_units=(quality-identity quality-store quality-timing quality-metadata quality-capture-query voice-session apple-voice voice-lexicon voice-controller ai-transport ai-runtime ai-statistics ai-learning ai-headless preparation dictionary-generator deployment engine-basic engine-options engine-english engine-context engine-custom-phrases controller settings dictionary-source dictionary-store dictionary-worker dictionary-activation startup-diagnostics termination installer-core runner workflow)
expand_test_groups() {
  test_units=()
  local requested=' ' group unit expanded
  if [[ $# == 0 || ( $# == 1 && $1 == all ) ]]; then
    test_units=("${test_all_units[@]}"); return 0
  fi
  for group in "$@"; do
    case "$group" in
      engine) expanded='engine-basic engine-options engine-english engine-context engine-custom-phrases' ;;
      quality) expanded='quality-identity quality-store quality-timing quality-metadata quality-capture-query' ;;
      ai) expanded='ai-transport ai-runtime ai-statistics ai-learning ai-headless' ;;
      dictionary-updates) expanded='dictionary-source dictionary-store dictionary-worker' ;;
      *)
        expanded=''
        for unit in "${test_all_units[@]}"; do [[ "$group" != "$unit" ]] || expanded="$unit"; done
        if [[ -z "$expanded" ]]; then echo "Unknown test group: $group" >&2; return 2; fi ;;
    esac
    requested+="$expanded "
  done
  for unit in "${test_all_units[@]}"; do
    [[ "$requested" != *" $unit "* ]] || test_units+=("$unit")
  done
}
test_units_need_app() {
  local unit
  for unit in "${test_units[@]}"; do
    case "$unit" in dictionary-worker|dictionary-activation|termination) return 0 ;; esac
  done
  return 1
}
