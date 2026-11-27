#!/bin/bash

inkflow_test_timing_now() {
  if [[ -x /usr/bin/perl ]]; then
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
      -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000'
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

inkflow_test_timing_report() {
  local scope=$1
  local stage=$2
  local began=$3
  local finished
  finished=$(inkflow_test_timing_now)
  printf 'TIMING\tscope=%s\tstage=%s\tduration_milliseconds=%s\n' \
    "$scope" "$stage" "$((finished - began))"
}
