# Debugging index

## English steals unfinished Pinyin candidates

**Symptoms:** `d` prefers the alias `D`; partial Chinese such as `niyebuxiangnid` or `womenshenzh` yields ASCII tails. Checking only fully typed sentences misses this regression.

**Cause:** Easy English contains many unweighted abbreviations and aliases. Admitting all literal entries into the mixed dictionary lets them consume unfinished Pinyin. A fixed mixed quality boost then overrides better Chinese sentences. Standalone English completions can similarly outrank a Chinese sentence whose native quality is zero. Rime compares covered input length before quality, so a global quality reduction alone is insufficient.

**Fix:** Apply one source-weight admission gate to both supplemental dictionaries, retain the mixed dictionary's additional spelling/length restrictions, and put both streams below native Chinese at equal input coverage. This includes Chinese candidates interpreting an unfinished final syllable. Thus `email` can follow `额买了`, while the admitted English candidate remains selectable. Admitted single-letter English remains available through exact lookup; ranking keeps `d` → 的 first without deleting `a` or `i` → `I`. The original Chinese translator and learned dictionary stay intact. See `DEPENDENCIES.md` for the reproducible admission threshold and coverage rule.

**Regression:** `bash macOS/scripts/test.sh` prints every forward/backspace state for representative Chinese input, then verifies mixed composition and English selection/ranking. The baseline had 143 ASCII-first failures over the initial 415 states. Also run `bash macOS/scripts/check-bundle.sh` against a freshly built app to verify the same Lua modules and dictionaries are packaged. Actual user typing remains a separate acceptance step.

## Low-weight English still fills later Chinese candidate positions

**Symptoms:** `women` offers `WOMENS` and `womenfolk`, `tamen` offers `tameness`, `nime` offers zero-weight `Nimes`/`nimetti`/`nimetz`, and `haiti` offers `Haiti` variants, even when Chinese remains first.

**Cause:** The earlier gate filtered only automatic mixed sentences. The standalone English translator still queried the complete upstream dictionary, so exact matches, prefix completions, and later pages bypassed admission. Its weight ordering faithfully exposed unreliable upstream rankings.

**Fix:** Generate admitted `easy_en.dict.yaml` first and derive the mixed dictionary from that result. The complete upstream dictionary is a build input only. Apply separately configured zero-weight corrections before the common inclusive threshold; keep unscaled effective English weights and mixed-only scaling. Startup runs Rime's full maintenance check so schema/dictionary changes are considered even when bundled YAML timestamps predate the user's last deployment; version changes alone cannot bypass the timestamp-only shortcut. Native content checks reuse unchanged compiled tables without deleting user dictionaries. Do not add runtime bypasses for exact words or case variants.

**Regression:** `test-prepare-rime.sh` covers both generated dictionaries, boundary weights, correction/case/alias behavior, divisor isolation, and failure without fallback. `DeploymentTests.swift` first deploys the full upstream English dictionary, then starts with admitted resources whose timestamps are older than `user.yaml`'s `last_build_time`; it requires rejected candidates to disappear, unchanged compiled tables to retain their bytes/mtimes on another restart, and the existing Chinese user dictionary to remain. Engine tests enumerate all pages for rejected spellings and case variants, repeat editing and selection, and check mixed boundaries. `check-bundle.sh` compares packaged resources against regenerated output and repeats the engine transcript. Inspect the installed dictionaries and restart the installed engine before real-client typing acceptance; source tests alone cannot prove deployment.

## Minimum width for the vertical candidate panel

Observed on macOS 26.6.2 (25G83), arm64, 2026-09-06.

**Requirement:** The vertical panel has a minimum width of 150 points. Preserve the native height behavior and horizontal layout; longer candidates may make the panel wider.

**Compatibility fix:** The [public IMKCandidates API](https://developer.apple.com/documentation/inputmethodkit/imkcandidates) does not expose a minimum window width. After applying font and direction, use the SDK's protected `_private` reference and guarded, typed `candidateWindowController` / `layoutTraits` accessors to set `lineDefaultLength` to 150 (`double` ABI). This changes the native vertical layout's minimum width before it sizes and positions the window. Font and direction setters rebuild these traits, so the width must be applied afterward. No height parameter is changed.

**Limitation:** These accessors and the layout setter are private implementation details. If any selector is unavailable, the adjustment is skipped and the native width is retained. This compatibility path is verified only on the OS above.

**Regression:** Run `bash macOS/scripts/test-settings-ui.sh` after building, in a logged-in GUI session. Actual candidate frames verify width >=150 for all allowed font sizes, stable height as 1/3/5/9 candidates grow and shrink, expansion for longer text, unchanged horizontal sizing after direction switches, and preserved candidate identifiers / selection keys. At 14 points with one short candidate, the baseline was 47x247 and the fix is 150x247. Evidence for this session is under `/private/tmp/inkflow-panel-size/width-{red,green}.log`.

**Discarded experiments:** `setPopoverMinimumSize:` affects a popover controller rather than this native window. `setWindowShouldAdjustToTotalCandidateSize:`, `setWindowSizeCanShrink:`, and changing selection-key counts did not enforce the requested dimensions in the isolated probe. They are not part of the fix.

## Candidate font setting changes but rendered text stays the same

Observed on macOS 26.6.2 (25G83), arm64, 2026-09-06.

**Cause:** `IMKCandidates setAttributes:` stores `NSFontAttributeName`, but the native candidate window's `itemLayout` title font stays at 16 points in both orientations, even when the attributes getter returns 14 or 36. A getter round-trip alone does not verify rendering.

**Compatibility fix:** Keep the documented attributes call, then call the existing private `setFontSize:` only when the panel responds to that selector. A typed category declares its scalar argument as `double`, matching the observed runtime ABI. This setter rebuilds the native font layout on the observed OS. Production code does not traverse private objects or use KVC for this fix.

**Limitation:** The setter is absent from public SDK headers and may change or disappear on another macOS version. If unavailable, InkFlow skips it and retains the documented attributes path; actual font rendering is not guaranteed by this fallback or by selector availability on untested OS versions.

**Regression:** After building, run `bash macOS/scripts/test-settings-ui.sh` in a logged-in GUI session. Test-only private layout inspection checks all allowed sizes (14/16/18/24/36), 14→36→14 in each orientation, direction switches, and preservation of composition and digit keys. A simulated unavailable selector verifies that public attributes still apply without calling the private setter. If the diagnostic layout path changes, the test fails explicitly and needs investigation. Baseline public-only behavior failed 18 of 20 layout checks, retaining 16 points; the requested-16 checks passed. Diagnosis and exact RED/GREEN logs are under `/private/tmp/inkflow-font-diagnosis` and `/private/tmp/inkflow-font-fix` for this session.

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
