# Debugging index

## Uppercase English drops itself and following Pinyin from mixed candidates

**Symptoms:** An admitted word works in standalone English, but mixed input such as
`woyongAPIkeyihuifuwo` or `woyongSwiftUIhenhao` keeps only the Chinese prefix in
the candidate list. `Email` can appear to work because its existing literal code
already satisfies the older four-character mixed rule.

**Cause:** The generated mixed dictionary previously retained only records whose
display text exactly equaled their code and had at least four letters. Admitted
forms such as `API` (`api` / `Api`), `SwiftUI` (`swiftui`), and the one-letter `D`
therefore had no matching mixed code. Broadly admitting short uppercase records is
also unsafe: native sentence composition can join admitted fragments such as
`WOMEN` + `S` and reconstruct an explicitly excluded `WOMENS`.

**Fix:** Keep the conservative lowercase literal rule. For already admitted
ASCII-letter records, retain sourced uppercase codes and add the exact displayed
spelling as a code when it contains uppercase letters. The mixed Lua filter then
requires each contiguous ASCII output run to be an exact admitted mixed-dictionary
entry. Do not clear the Shift modifier, append unknown raw tails, or add a global
uppercase Pinyin algebra rule; those approaches do not repair the missing-code
contract and can broaden unrelated decoding.

**Regression:** `bash macOS/scripts/test.sh` covers dictionary aliases for `D`,
`API`, and `SwiftUI`, actual Shift-modified key events, following Pinyin, backspaces
at complete Pinyin boundaries, rejected case variants, and ordinary Chinese input.
After building, `bash macOS/scripts/check-bundle.sh` verifies the generated
dictionary and Lua filter are packaged. Real-client typing remains a separate
acceptance step.

## Settings window loses its fixed width and minimum height

**Cause:** The SwiftUI migration retained `NSWindow.contentMinSize`, but the default
`NSHostingController` sizing options generated minimum-size constraints from the
current page. After layout, the appearance page replaced the intended 700 × 380
minimum with 248 × 112 on macOS 26. The required width is fixed at 700;
the height may grow from 380.

**Fix:** `SettingsHostingController` disables automatic sizing constraints and adds
explicit AppKit constraints for width 700 and height >=380 to its view. It remains
the top-level content controller to preserve native title-bar/sidebar integration.
No window property overrides or layout callback resets are needed. This follows Apple's
[SwiftUI/AppKit layout guidance](https://developer.apple.com/videos/play/wwdc2022/10075/).
The 380-point bound applies to the full-size content view, including the title-bar
region, rather than 380 points below the title bar.
The detail group declares a flexible minimum height of zero so the native split
view does not retain a taller page's minimum during dictionary state changes.

**Regression:** `bash macOS/scripts/test-settings-ui.sh` requests 500 × 200 and
900 × 560 and checks actual content-view sizes of 700 × 380 and 700 × 560 after
presentation, page replacement and close/reopen. Existing layout checks run at the
minimum and increased heights. `contentMinSize` alone does not report the effective
minimum enforced by Auto Layout.

**Discarded experiments:** Window-property overrides and layout callback resets
are not needed. A separate AppKit container changed native sidebar/title integration.
A SwiftUI root minimum of 380 instead produced a 432-point window minimum because
hosting added the title-bar inset. No fixed title-bar subtraction is used.

## English steals unfinished Pinyin candidates

**Symptoms:** `d` prefers the alias `D`; partial Chinese such as `niyebuxiangnid` or `womenshenzh` yields ASCII tails. Checking only fully typed sentences misses this regression.

**Cause:** Easy English contains many unweighted abbreviations and aliases. Admitting all literal entries into the mixed dictionary lets them consume unfinished Pinyin. A fixed mixed quality boost then overrides better Chinese sentences. Standalone English completions can similarly outrank a Chinese sentence whose native quality is zero. Rime compares covered input length before quality, so a global quality reduction alone is insufficient.

**Fix:** Apply one frequency admission gate to both supplemental dictionaries, retain the mixed dictionary's additional spelling/length restrictions, and put both streams below native Chinese at equal input coverage. This includes Chinese candidates interpreting an unfinished final syllable. Thus `email` can follow `额买了`, while the admitted English candidate remains selectable. Admitted single-letter English remains available through exact lookup; ranking keeps `d` → 的 first without deleting `a` or `i` → `I`. The original Chinese translator and learned dictionary stay intact. See `DEPENDENCIES.md` for the reproducible admission threshold and coverage rule.

**Regression:** `bash macOS/scripts/test.sh` prints every forward/backspace state for representative Chinese input, then verifies mixed composition and English selection/ranking. The baseline had 143 ASCII-first failures over the initial 415 states. Also run `bash macOS/scripts/check-bundle.sh` against a freshly built app to verify the same Lua modules and dictionaries are packaged. Actual user typing remains a separate acceptance step.

## Low-weight English still fills later Chinese candidate positions

**Symptoms:** `women` offers `WOMENS` and `womenfolk`, `tamen` offers `tameness`, `nime` offers zero-weight `Nimes`/`nimetti`/`nimetz`, and `haiti` offers `Haiti` variants, even when Chinese remains first.

**Cause:** The earlier gate filtered only automatic mixed sentences. The standalone English translator still queried the complete upstream dictionary, so exact matches, prefix completions, and later pages bypassed admission. Its weight ordering faithfully exposed unreliable upstream rankings.

**Fix:** Generate admitted `easy_en.dict.yaml` first and derive the mixed dictionary from that result. The complete upstream dictionary is a build input only. Use the pinned observed wordfreq snapshot, apply explicit exact-word overrides before the common inclusive Zipf threshold, then map admitted frequencies to English weights and apply mixed-only scaling. Missing observations cannot fall back to upstream weights. The measured `women` is intentionally retained after Chinese “我们”; low-frequency `WOMENS` and `womenfolk` are excluded. Startup runs Rime's full maintenance check so schema/dictionary changes are considered even when bundled YAML timestamps predate the user's last deployment; version changes alone cannot bypass the timestamp-only shortcut. Native content checks reuse unchanged compiled tables without deleting user dictionaries. Do not add runtime bypasses for exact words or case variants.

**Regression:** `test-prepare-rime.sh` covers both generated dictionaries, known/missing observations, boundary Zipf values, override/exclusion/case/alias behavior, scaling isolation, and failure without fallback. `DeploymentTests.swift` first deploys the full upstream English dictionary, then starts with admitted resources whose timestamps are older than `user.yaml`'s `last_build_time`; it requires rejected candidates to disappear, unchanged compiled tables to retain their bytes/mtimes on another restart, and the existing Chinese user dictionary to remain. Engine tests enumerate all pages for rejected spellings and case variants, repeat editing and selection, and check mixed boundaries. `check-bundle.sh` compares packaged resources against regenerated output and repeats the engine transcript. Inspect the installed dictionaries and restart the installed engine before real-client typing acceptance; source tests alone cannot prove deployment.

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

## Dictionary activation waits or recovers a previous version

Dictionary preparation leaves the current engine running. The final switch waits for every live session, including inactive clients, to have no composition or pending commit. A controller owns a delivery lease until its `insertText` and marked-text callbacks return, so a nested client run loop cannot activate halfway through delivery. Complete or cancel the composition in each client to release this wait.

The coordinator records a pending transaction before waiting. After an interrupted process it discards that pending choice, validates the confirmed cache, and rebuilds incompatible caches from inert dictionary data with the current app's resources. If recovery fails it tries the previous confirmed version and then the immutable bundled dictionary. Settings always reports the version and activation date of the engine that actually started. A failed rollback leaves the engine unavailable; the input menu and Settings remain reachable for retry.

Closing Settings clears its displayed diagnostic, while the process continues the task. Reopening shows current progress and does not replay earlier failures. Operational diagnostics remain in the macOS unified log:

```sh
/usr/bin/log show --last 1d --style compact --predicate 'subsystem == "io.damao.inputmethod.inkflow" AND category == "dictionary"'
```

The coordinator logs failures at error level. Large diagnostics use UTF-8-safe chunks of at most 700 payload bytes, sharing an event ID and numbered `part=i/n` fields; collect every part of that event for complete details. Details include stage, source/file identity, HTTP or helper exit status, and bounded worker diagnostics. They exclude document input/context, custom phrases and learned database contents; error payloads are never saved in the dictionary journal, manifest or preferences.

Run `bash macOS/scripts/build.sh`, then `bash macOS/scripts/test-dictionary-activation.sh` for isolated multi-session, commit-delivery, semantic-learning, failure/rollback, task-lifetime and restart-recovery checks. The tests use synthetic temporary user roots. They do not replace real-client typing acceptance.

## Settings GUI tests have no accessible content or cannot become active

Run the native Settings harness in a logged-in, unlocked desktop session. A locked
desktop can prevent keyboard focus even when a window reports itself visible.
Separately, SwiftUI initializes accessibility lazily when an assistive client connects;
an in-process walk can lack SwiftUI controls even in an active, unlocked window.

The harness starts a short-lived child process that reads only its own application's
windows through the public accessibility API. This initializes the real accessibility
tree, with a two-second messaging timeout and a five-second parent wait. The runner
needs existing Accessibility access; the test never prompts or changes global settings.
Run `bash macOS/scripts/test-settings-ui.sh` after resolving the reported prerequisite.
Keep genuine control and layout assertions enabled. Headless engine/coordinator tests
remain separate evidence and cannot substitute for native window-lifecycle acceptance.

The harness waits up to five seconds for a visible, key window and an active app,
then fails with the foreground application's bundle ID/PID and the public console/login
session flags. An activation request is asynchronous; a timeout alone does not identify
whether the desktop was locked or another application held focus.

## Dictionary disclosure contents have missing accessibility identifiers

**Symptom:** Source names, full commits and URLs are present after expanding “词库来源”,
but a lookup such as `dictionaries.source.frost-8105` fails even after additional waiting.

**Cause:** Applying `accessibilityIdentifier` to a SwiftUI `DisclosureGroup` overrides
the identifiers on its descendants on the observed macOS 26 runtime. The same pattern
affects the “错误详情” disclosure and its diagnostic text.

**Fix:** Keep identifiers on individual content elements. The native GUI test locates
each disclosure by its `AXDisclosureTriangle` role and label, presses that exact control,
and requires its expanded state to toggle. It retains independent content and layout
assertions; missing or duplicate content identifiers print the accessibility tree.

**Regression:** Run `bash macOS/scripts/test-settings-ui.sh` after building. The suite
checks all seven sources and complete diagnostics across error stages, with disclosures
expanded and collapsed and windows at minimum/enlarged sizes. It does not replace
installed-input-method typing acceptance.
