#!/bin/bash
set -euo pipefail

# Refresh only the current user's menu agent, not the input method engine.
owner_uid=$(id -u)
agent_pids() {
  local result status
  if result=$(pgrep -u "$owner_uid" -x TextInputMenuAgent); then
    printf '%s\n' "$result"
  else
    status=$?
    if [[ "$status" != 1 ]]; then
      echo 'Unable to inspect TextInputMenuAgent processes.' >&2
      return "$status"
    fi
  fi
}

old_pids=$(agent_pids)
if [[ -z "$old_pids" ]]; then
  echo 'No running input menu agent for this user; refresh skipped.'
  exit 0
fi
while IFS= read -r pid; do
  if ! kill -TERM "$pid"; then
    # Exiting between lookup and termination is harmless.
    if kill -0 "$pid" 2>/dev/null; then
      echo "Unable to terminate input menu agent $pid." >&2
      exit 1
    fi
  fi
done <<< "$old_pids"

for ((attempt=0;attempt<20;attempt++)); do
  current_pids=$(agent_pids)
  old_alive=false
  while IFS= read -r pid; do
    if [[ -n "$pid" ]] && grep -qx "$pid" <<< "$old_pids"; then old_alive=true; fi
  done <<< "$current_pids"
  if [[ -n "$current_pids" && "$old_alive" == false ]]; then
    echo "Input menu agent restarted: $current_pids"
    exit 0
  fi
  sleep 0.5
done
echo 'Input menu refresh timed out after 10 seconds; installation remains in place.' >&2
exit 1
