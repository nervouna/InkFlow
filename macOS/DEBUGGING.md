# Debugging index

## Updated name and icon remain stale in the input menu

Observed on macOS 26.6.2, 2026-09-05.

**Symptom:** The installed bundle contains the new localized name and menu icon, and TIS registration/enabled checks pass, but the input menu still shows both old values.

**Fix:** Restart only the current user's `TextInputMenuAgent`. Its system LaunchAgent has `KeepAlive` enabled. In this case, a new process plus reopening the menu made both changes visible; the user confirmed the result. No logout, input-source removal, or cache-file deletion was needed.

Routine updates now run `bash macOS/scripts/refresh-menu.sh` after successful installation and registration. The helper sends TERM once to existing current-user menu agents and waits up to 10 seconds for replacement PIDs. If no agent is running it skips the refresh. A process restart proves refresh execution, not correct visual rendering. It does not restart InkFlow's engine; functional acceptance must separately ensure the new engine is running.

## Blank name or icon in Keyboard Settings

Observed on macOS 26.6.2, 2026-09-05.

**Symptom:** Command-line TIS queries show InkFlow correctly, but Keyboard Settings shows a blank entry. Adding it does not make InkFlow selectable.

**Cause:** Keyboard Settings uses a separate input-source cache. It still referenced removed input methods and did not contain InkFlow.

**Fix:**

1. Quit System Settings and stop its `KeyboardSettings` extension using Activity Monitor.
2. Back up and remove only `com.apple.IntlDataCache.le` and `com.apple.IntlDataCache.le.kbdx` in this directory:

   ```sh
   echo "$(getconf DARWIN_USER_CACHE_DIR)/com.apple.Keyboard-Settings.extension"
   ```

3. Reopen System Settings, add InkFlow, and confirm its name, icon, and actual selection.

The cache is rebuilt automatically. No logout or reboot was needed. Leave input-source preferences and user dictionaries intact; the cache location may differ on other macOS versions.

## Enable API succeeds but the input method remains disabled

Observed on macOS 26.6.2, 2026-09-05.

**Symptom:** `TISEnableInputSource` returns success, but the parent input method remains disabled and its mode cannot be selected.

**Cause:** The third-party enable request opens System Settings without completing enablement.

**Fix:** Add InkFlow through System Settings, then check that both parent and mode are enabled:

```sh
macOS/scripts/register.sh "$HOME/Library/Input Methods/InkFlow.app" --verify-enabled
```

Select InkFlow to confirm it works as a system input source. If Settings shows a blank entry, use the preceding case.
