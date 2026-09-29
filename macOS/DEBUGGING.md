# Debugging index

Known failures: symptom, cause, fix, and where to look. Git history has the full investigation notes.

## Logs and incident archives

Unified log subsystem `io.damao.inputmethod.inkflow`; categories `startup`, `input`, `dictionary`, `ai`:

```sh
/usr/bin/log show --last 1h --style compact \
  --predicate 'subsystem == "io.damao.inputmethod.inkflow" AND category == "input"'
/usr/bin/log stream --style compact \
  --predicate 'subsystem == "io.damao.inputmethod.inkflow" AND category == "ai"'
ps -Ao pid=,etime=,comm= | rg '/InkFlow.app/Contents/MacOS/InkFlow$'   # match PID to the installed app
```

Logs contain only fixed labels, random correlation IDs, status and timing — never text, Pinyin, candidates, keys or URLs. Keep it that way.

- **Startup:** one `run` UUID per process; each stage has a paired begin/end `span`. A begin without an end means pending work or a process exit, not necessarily a deadlock.
- **Input:** per activation, `firstKeyEntered` → `firstKeyCompleted` (with outcome), then `deactivationEntered/BeforeSuper/AfterSuper/Finished`. A missing checkpoint points at that interval; correlate PID/time with `~/Library/Logs/DiagnosticReports/` before blaming InkFlow or macOS.
- **AI:** gate → `scheduled` → `dispatched` → HTTP status/elapsed → `shown` → `adoptionRequested` → `insertionIssued` → `insertionReturned`, all with the same attempt ID. No dispatch: check the gate reason (config, secure input, candidate visibility, mark). `insertionReturned` doesn't prove the editor displayed the text.
- **Dictionary:** errors at error level, long payloads split into `part=i/n` chunks sharing an event ID.

**Incident archive:** Settings → 反馈 → **保存问题现场** freezes the preceding 30 minutes; **导出诊断包…** exports a ZIP (open `manifest.json` first, then `events.jsonl`, `summary.json`; timestamps are UTC Unix ms). Stored in `~/Library/Application Support/InkFlow/Diagnostics/`, capped at 7 days / 50 MiB. If InkFlow can't start, copy only that directory plus matching DiagnosticReports. Archives exclude `quality.sqlite3`, preferences, document text and audio. Nothing is uploaded automatically.

## Input disappears until switching to ABC and back

**Cause:** `EXC_BAD_ACCESS` in `-[_IMKServerLegacy deactivateServer_CommonWithClientWrapper:controller:] + 368`. The IMK server keeps a non-zeroing pointer to the last `IMKCandidates`; after a controller released its panel, deactivation messaged the freed panel (`isVisible`). Seen on macOS 26.6.2 with v0.4.1 and v0.4.4.

**Fix:** `NativeCandidateLifetime` (owned by bootstrap) retains the latest registered panel per server, linked weakly via an Objective-C association. Controller teardown hides its panel and submits an empty candidate array. `test-controller-initialization.sh` covers release → native deactivation. To reproduce the OS behavior (unlocked GUI session, outside the sandbox): `probe-imk-candidate-lifetime.sh --inspect | --keep-alive | --zombie`.

## Settings disappears after first microphone authorization (GitHub #3)

**Cause:** Settings used accessory activation; the permission prompt handed activation back to the previous regular app, leaving Settings behind it.

**Fix:** `IFSettingsWindowController.present()` switches to regular activation (Dock icon and Cmd-Tab while open); closing returns to accessory. No focus retries or floating levels. Diagnostics: `test-settings-ui.sh --settings-window-lifecycle`, or `--microphone-reproduction` for a real prompt (bundle ID `io.damao.inkflow.microphone-reproduction`; reset with `tccutil reset Microphone <that ID>`, never production).

## Slow cold start vs app-switch delay

The bundled `RimePrebuilt` engine starts before the IMK server is created; the context-ranking index and downloaded-dictionary recovery build in the background and switch in only when all sessions are idle. Until then, candidate order is Rime's. Activation spans in the same run/PID are client callbacks, not a new process. `RimePrebuilt/inkflow-cache.json` binds bundled resources; an invalid packaged cache reports the engine unavailable rather than running synchronous maintenance. Tests: `test.sh startup-diagnostics dictionary-activation`; `test-serving-startup.sh --native` for a real candidate panel.

## Uppercase English drops itself and following Pinyin in mixed input

**Symptom:** `woyongAPIkeyihuifuwo` keeps only the Chinese prefix.

**Cause:** The mixed dictionary kept only lowercase literal codes of ≥4 letters, so `API`, `SwiftUI`, `D` had no mixed code. Broadly admitting short uppercase codes lets fragments rebuild excluded words (`WOMEN` + `S`).

**Fix:** For admitted ASCII words, keep sourced uppercase codes and add the exact display spelling as a code; the mixed Lua filter requires each ASCII run to be an exact admitted entry. Don't clear Shift, append raw tails or add global uppercase algebra.

## English steals unfinished Pinyin / low-weight English fills later positions

**Symptoms:** `d` prefers `D`; `womenshenzh` yields ASCII tails; `women` offers `WOMENS`, `nime` offers `Nimes`.

**Cause:** Easy English has many unweighted aliases; a fixed mixed boost outranked Chinese; the standalone English translator queried the full upstream dictionary. Rime compares coverage length before quality.

**Fix:** Generate an admitted `easy_en.dict.yaml` (pinned wordfreq snapshot, explicit overrides, one inclusive Zipf threshold) and derive the mixed dictionary from it. Both English streams sit below native Chinese at equal coverage, including unfinished final syllables. Startup runs full Rime maintenance so older bundled timestamps still replace stale caches; unchanged compiled tables are reused. Details: `DEPENDENCIES.md`. Tests: `test-prepare-rime.sh`, `DeploymentTests.swift`, `engine-english`.

## AI: local Ollama Qwen reports an incomplete suggestion (GitHub #4)

**Cause:** With `qwen3`/`qwen3.5` on Ollama, thinking consumed all 256 tokens (`finish_reason=length`, empty content).

**Fix:** For those families on loopback port 11434, send `reasoning_effort: "none"` (Ollama maps it to `think: false`). Other hosts, ports and models are unchanged.

## AI: no suggestion when document length is shorter than the mark

**Cause:** The context reader rejected `documentShorterThanMark`, so no request was sent.

**Fix:** Document length is advisory; read surrounding text once at dispatch with bounded fallbacks (256 characters per side). Headless client profiles cover zero/short/negative lengths.

## AI: Tab removes the Pinyin but the suggestion doesn't appear

**Cause:** Adoption refreshed an empty composition (clearing the client's mark) before inserting at a cached explicit offset; Codex dropped that insertion.

**Fix:** Same order as ordinary commits: clear Rime internally, release mark ownership, `insertText` once with `NSNotFound` while the mark is still present, then refresh.

## AI: candidates become visible after the last refresh

**Cause:** Eligibility discarded the composition if the candidate window was still hidden at the final refresh.

**Fix:** The 0.5 s deadline starts at the last input change; after it, wait for visible candidates while composition/client/config stay valid. Test: `test-ai-headless.sh --delayed-visibility`. Paid live check (explicit approval only): `test-ai-headless.sh --live /abs/path/ignored/.env`.

## Settings window loses its fixed width / minimum height

**Cause:** Default `NSHostingController` sizing options generated min-size constraints from the current page (248 × 112 instead of 700 × 380).

**Fix:** `SettingsHostingController` disables automatic sizing constraints and adds explicit width 700 / height ≥380; the detail group has a flexible minimum height of 0. Test: `test-settings-ui.sh`.

## Vertical candidate panel minimum width

No public API. After setting font and direction (which rebuild traits), set `lineDefaultLength = 150` through the guarded private `_private` → `candidateWindowController` → `layoutTraits` path (`double` ABI). Skipped if a selector is missing. `setPopoverMinimumSize:`, `setWindowShouldAdjustToTotalCandidateSize:` and `setWindowSizeCanShrink:` don't work.

## Candidate font setting doesn't change rendered text

`setAttributes:` stores the font but the native `itemLayout` stays at 16 pt. Also call the private `setFontSize:` (`double`) when the panel responds to it.

## Cursor input switcher icon disappears when selected

**Fix:** `TISIconIsTemplate = true` at bundle and mode level (the `Template` filename suffix isn't enough). The switcher still shows the Ink badge rather than a bare glyph — accepted. `tsInputModePaletteIconFileKey` and `TISIconLabels` have no effect. Don't kill `CursorUIViewService`.

## Updated name/icon stale in the input menu

Run `bash macOS/scripts/refresh-menu.sh` (restarts the user's `TextInputMenuAgent`), then reopen the menu. Not part of routine installs — see the next item.

## Input menu disappears after a local update (macOS 27)

**Cause:** While the bundle path was briefly missing during replacement, macOS rebuilt its private UI-order cache (`AppleInputSourcesInUIOrderPasteboard`) with only ABC. Restarting `TextInputMenuAgent` also causes a brief flicker.

**Fix:** `install.sh` uses the Installer's atomic replacement (`--commit-update`: `RENAME_SWAP` for updates, `RENAME_EXCL` for first install) so the path never disappears, and it no longer restarts the menu agent. **Manual recovery:** remove and re-add InkFlow in Keyboard Settings. AX dumps and menu-bar screenshots are unreliable detectors here.

## Blank name or icon in Keyboard Settings

Keyboard Settings has its own stale cache. Quit System Settings and its `KeyboardSettings` extension, back up and remove `com.apple.IntlDataCache.le` and `.le.kbdx` from `$(getconf DARWIN_USER_CACHE_DIR)/com.apple.Keyboard-Settings.extension`, then re-add InkFlow.

## Enable API succeeds but the input method stays disabled

`TISEnableInputSource` only opens System Settings for third-party IMEs. Add InkFlow there, then check: `macOS/scripts/register.sh "$HOME/Library/Input Methods/InkFlow.app" --verify-enabled`.

## Dictionary activation waits or falls back

The switch waits until every live session (including inactive clients) has no composition or pending commit; a controller holds a delivery lease during `insertText`/marked-text callbacks. Finish or cancel composition in each client. After an interrupted process, recovery validates the confirmed cache, then tries the previous version, then the bundled dictionary. Test: `test.sh dictionary-activation` (needs `build.sh`).

## Settings GUI tests: no accessible content or window won't activate

Run in a logged-in, unlocked session with Accessibility access. SwiftUI builds its accessibility tree lazily, so the harness reads it from a short-lived child process. A timeout reports the foreground app's bundle ID/PID.

## Settings fields ignore Command-V

Accessory apps have no main Edit menu. Settings presentation installs one standard Edit menu (nil-target actions). Test: `test-settings-ui.sh --smart-only`.

## Disabled prediction item looks clickable in the input menu

IMK serialization enables any item with an action. An unavailable item needs both `isEnabled = false` and a nil action.

## Dictionary error details missing from accessibility

An `accessibilityIdentifier` on a SwiftUI `DisclosureGroup` overrides its descendants' identifiers. Put the identifier on the diagnostic text instead.
