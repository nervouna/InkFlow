#!/bin/sh

set -eu

bootstrap_script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
bootstrap_repo_root=$(CDPATH='' cd -- "${bootstrap_script_dir}/../.." && pwd)

if ! command -v git >/dev/null 2>&1; then
  printf '%s\n' "error: git is required" >&2
  exit 1
fi

printf '%s\n' "Initializing exact recursive source dependencies..."
git -C "${bootstrap_repo_root}" submodule sync --recursive
git -C "${bootstrap_repo_root}" submodule update --init --recursive

exec "${bootstrap_repo_root}/tools/verify/foundation.sh"
