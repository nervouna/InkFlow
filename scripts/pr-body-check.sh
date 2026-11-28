#!/usr/bin/env bash
set -euo pipefail

if ! printf '%s\n' "${PR_BODY:-}" | grep -Eiq '(Fixes|Closes|Refs) #[0-9]+'; then
  echo "The PR body must contain Fixes #N, Closes #N or Refs #N." >&2
  exit 1
fi
