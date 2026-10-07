# Voice input status

Voice input shipped in InkFlow 0.4.0. This document records only the current product contract; the original experiments and performance data are archived in `docs/archive/VOICE_*.md`.

## Usage

- Hold Right Shift for about 250 ms to start dictation; release to stop.
- Double-tap Right Shift to start or stop continuous dictation; Esc cancels.
- A single short tap or Right Shift combined with other keys does not start voice; Left Shift keeps toggling Chinese/English.
- Keys are handled only within the current InkFlow input session; there is no global listener.

## Current behavior

- Apple `SpeechTranscriber` performs on-device `zh_CN` recognition. Resource preparation and microphone authorization never run on the key-event path; no audio or full transcript logs are stored.
- In-flight text uses the current client's marked text and is committed exactly once on completion. The session is cancelled when the input box, app, input-method state or secure-input state changes; late results must never be written to a new target.
- A non-empty selection does not block voice. Live preview goes to the currently focused target with its default replacement range, so selections reported on other UI surfaces are not redirected; a selection in the same field receives continuous preview and is replaced once by the final text. The public InputMethodKit client offers no in-agent UI identity, so InkFlow neither reads nor stores selected text. When a non-empty selection has already received preview, cancel, failure or an empty result performs no second client write and leaves the current marked text for the host, avoiding deletion of unknown original text or writing other surfaces' content into the focused box. InkFlow keeps no app- or surface-specific exceptions and persists no target state. It does not infer ownership of other input transactions from the client's limited `markedRange`, and does not globally block normal typing, Left Shift toggling or the next voice session because of it; these entry points keep working even if the host briefly retains a zero-length mark. Successful results still commit once to the default range; when the target, secure-input state or lifecycle no longer matches, nothing is written to the old or new target.
- The lexicon snapshot is generated from existing Rime learning data and custom phrases: read-only, bounded and prepared at idle. It can only rerank homophone candidates Apple already provided; it never creates new voice candidates or becomes a second lexicon.
- Voice polish shares the AI service configuration with Pinyin suggestions but has an independent switch, default off. Apple's final segments are used only for local stitching and live preview of the original text, not as the polish boundary. After recognition completes, the full final transcript is polished exactly once; an empty, invalid, failed or timed-out request falls back to the full final original text.
- Recognition and polish are strictly serial: no chunking, pause heuristics, retries or partial polish insertion. Diagnostics record only fixed phases, sequence numbers, durations and failure categories — never audio or transcript content.
- Offline Pinyin typing does not depend on voice resources, microphone permission or AI services.

## Verification boundary

Automated tests cover recognition scope, audio callback threading, session cancellation, focus ownership, zero-write on selection cancellation, typing recovery after the host clears marked text, cross-surface routing switches, UTF-16 marked text, lexicon reranking, polish fallback and exactly-once commit. Synthetic audio, fake clients and native test hosts cannot prove the physical-keyboard or third-party-app experience.

After changing shortcuts, marked text, target ownership or final commit logic, manually verify:

1. Hold, double-tap, stop and Esc in native editors and browsers.
2. Select text in a native editor and a browser; confirm continuous preview and a single replacement on success. After Esc, confirm InkFlow performs no second write and note how the host handles the retained marked text; normal typing, Left Shift toggling and restarting voice must all work immediately, including when the host briefly retains a zero-length marked range.
3. Keep a selection in one surface and focus another input box; confirm preview and commit go only to the focused target.
4. Switch input boxes, apps and input methods within one app without misdirected writes.
5. Multiple Apple final segments before recognition completes never trigger polish; polish off, success, failure and timeout each commit exactly once, and failure keeps the full final original text.

Research reports are historical evidence only; do not use them to judge the current branch, commits, installation or release state.
