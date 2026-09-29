#!/bin/bash
# Shared canonical order and expansion. Sourcing this file performs no preparation.
test_all_units=(shared-core quality-identity quality-store quality-timing quality-metadata quality-capture-query voice-session apple-voice voice-lexicon voice-controller ai-credentials ai-transport ai-runtime ai-learning ai-headless preparation dictionary-generator deployment engine-basic engine-options engine-english engine-context engine-custom-phrases controller settings personal-data dictionary-source dictionary-store dictionary-worker dictionary-activation startup-diagnostics local-diagnostics diagnostic-archive termination installer-core runner workflow)
expand_test_groups() {
  test_units=()
  test_full_suite=false
  local requested=' ' group unit expanded
  if [[ $# == 0 || ( $# == 1 && $1 == all ) ]]; then
    test_units=("${test_all_units[@]}"); test_full_suite=true; return 0
  fi
  for group in "$@"; do
    case "$group" in
      engine) expanded='engine-basic engine-options engine-english engine-context engine-custom-phrases' ;;
      quality) expanded='quality-identity quality-store quality-timing quality-metadata quality-capture-query' ;;
      ai) expanded='ai-credentials ai-transport ai-runtime ai-learning ai-headless' ;;
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
prioritize_test_units() {
  local canonical=("${test_units[@]}") priority=() reordered=() candidate unit seen
  expand_test_groups "$@" || return
  priority=("${test_units[@]}")
  for unit in "${priority[@]}" "${canonical[@]}"; do
    seen=false
    if [[ ${#reordered[@]} -gt 0 ]]; then
      for candidate in "${reordered[@]}"; do [[ "$candidate" != "$unit" ]] || seen=true; done
    fi
    $seen || reordered+=("$unit")
  done
  test_units=("${reordered[@]}")
  test_full_suite=true
}
ensure_test_unit_dependency_order() {
  local prerequisite=$1 dependent=$2 prerequisite_index=-1 dependent_index=-1 index unit
  local reordered=()
  for ((index = 0; index < ${#test_units[@]}; index++)); do
    [[ ${test_units[$index]} != "$prerequisite" ]] || prerequisite_index=$index
    [[ ${test_units[$index]} != "$dependent" ]] || dependent_index=$index
  done
  [[ $prerequisite_index -ge 0 && $dependent_index -ge 0 && $prerequisite_index -gt $dependent_index ]] || return 0
  for unit in "${test_units[@]}"; do
    [[ $unit != "$prerequisite" ]] || continue
    [[ $unit != "$dependent" ]] || reordered+=("$prerequisite")
    reordered+=("$unit")
  done
  test_units=("${reordered[@]}")
}
test_units_need_app() {
  local unit
  [[ ${#test_units[@]} -gt 0 ]] || return 1
  for unit in "${test_units[@]}"; do
    case "$unit" in dictionary-worker|dictionary-activation|personal-data|termination) return 0 ;; esac
  done
  return 1
}
