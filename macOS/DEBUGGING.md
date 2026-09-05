# Local debugging and input-source registration

Build and test with `build.sh`, `test.sh`, and `check-bundle.sh`. `install.sh --debug` uses ad-hoc signing with debugger permission. Final `--developer-id` installation uses explicit empty entitlements and the selected Developer ID certificate. Neither signing mode replaces real system UI checks.

`register.sh` registers the installed app with Launch Services and TIS, then checks the exact named `.Hans` keyboard mode. Registration success is not enabled-state or selection proof. Add the mode through System Settings, then inspect its persistent enabled state in a fresh process:

```sh
macOS/scripts/register.sh "$HOME/Library/Input Methods/InkFlow.app" --verify-enabled
```

The helper never calls enable/select APIs. On this macOS version, public enable requests can open System Settings without changing persistent state even when the call returns success. Confirm that the input menu offers the mode. Actual typing acceptance remains a separate check.

## Blank name or icon in Keyboard Settings

If TIS reports the expected named mode but Keyboard Settings displays a blank row, its extension-local input-source cache may be stale. Do not change bundle identity, dictionary data, or global preferences to address this discrepancy.

1. Quit System Settings and ensure its Keyboard Settings extension has stopped. Identify only those processes with Activity Monitor; do not terminate all preference or input-method services.
2. Inspect the two files below under the current user's cache directory. Back up both existing files to a new temporary directory before removing either one.
3. Reopen System Settings, add InkFlow, and re-run the independent enabled-state check above.

The following deliberately touches only the two Keyboard Settings extension cache files. Run it only after the extension has stopped and the mismatch above has been confirmed:

```sh
cache_dir="$(getconf DARWIN_USER_CACHE_DIR)/com.apple.Keyboard-Settings.extension"
cache_backup=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-keyboard-cache.XXXXXX")
for name in com.apple.IntlDataCache.le com.apple.IntlDataCache.le.kbdx; do
  if [ -f "$cache_dir/$name" ]; then
    cp -p "$cache_dir/$name" "$cache_backup/$name" || exit 1
  fi
done
for name in com.apple.IntlDataCache.le com.apple.IntlDataCache.le.kbdx; do
  if [ -f "$cache_backup/$name" ]; then rm "$cache_dir/$name" || exit 1; fi
done
printf 'Cache backup: %s\n' "$cache_backup"
```

Do not clear the entire cache directory, reset global input-source preferences, remove user dictionaries, or delete system-owned files. This recovery is optional troubleshooting and is never run by the installer. Old installation archives stay outside `Input Methods`, preventing duplicate app discovery.
