# Debugging index

## Cursor input switcher icon disappears when selected

Observed on macOS 26.6.2, 2026-09-05. The user accepted the template-flag fix: Ink remains visible when selected and reverses colors normally.

**Fix:** Declare `TISIconIsTemplate = true` at bundle and mode level, keeping the approved `MenuIconTemplate.tiff` resource. A fresh diagnostic process confirmed the indicator's template flag changed from false to true. The filename's `Template` suffix alone did not supply this flag to the cursor switcher.

**Known limitation:** The switcher still displays the Ink badge rather than the background-free glyph used by Apple's built-in input sources. This visual difference is accepted as a known issue; no further workaround is required. The non-template fallback was not attempted because the template configuration passed visual acceptance.

**Discarded experiments and evidence:** `TISIconLabels` with `Primary = Ink` did not create a built-in label entry and was removed after acceptance. It was present in the visually accepted test build; the final package retains only the template flags.

Community references: [EurKEY-Next known issues](https://github.com/felixfoertsch/EurKEY-Next/blob/main/README.md#known-issues) reports disappearing third-party template icons on Sonoma/Sequoia; [Ukelele discussion](https://groups.google.com/g/ukelele-users/c/xRo9BwPeFpg) investigates `TISIconLabels`. These are community observations, not Apple API guarantees. Apple's [text cursor documentation](https://developer.apple.com/documentation/AppKit/adopting-the-system-text-cursor-in-custom-text-views) describes automatic accessories and their placement, not an input-method icon customization contract.

Changing `tsInputModePaletteIconFileKey` to a separate transparent glyph did not change the cursor switcher, even after `CursorUIViewService` restarted. Installed resource hashes matched the source. A fresh diagnostic process using the system's `KLInputSourceIconManager` reproduced the fallback: InkFlow has no built-in label entry, and the indicator reads `TSMInputSourcePropertyIconImage` and `TSMInputSourcePropertyIconShouldBeTemplate`. TIS returned the menu image URL, and the indicator's template flag was false. Apple's Pinyin has a built-in image entry and returns a template indicator. These private implementation details are diagnostic evidence for this OS version, not APIs to add to InkFlow.

Do not interpret the first appearance of Ink after a service restart as proof that the palette key is used. The separate palette-resource experiment was removed.

`CursorUIViewService` did not exit on TERM in this session. After KILL it eventually restarted, but the cursor switcher was absent for a noticeable interval. Do not add this disruptive refresh to routine updates or promise immediate recovery. Restarting only `TextInputMenuAgent` does not refresh the cursor service.

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
