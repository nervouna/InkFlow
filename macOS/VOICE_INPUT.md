# Voice input

Shipped in 0.4.0. Experiments and measurements are in the git history of the removed docs archive folder.

## Usage

- Hold Right Shift for about 250 ms to dictate; release to stop.
- Double-tap Right Shift to start or stop continuous dictation; Esc cancels.
- A short tap or Right Shift with other keys does nothing; Left Shift keeps toggling Chinese/English.
- Keys are handled only inside the current InkFlow session; there is no global listener.

## Contract

- Apple `SpeechTranscriber` recognizes `zh_CN` on device. Resource preparation and microphone authorization never run on the key-event path; audio and transcripts are never logged.
- In-flight text is the focused client's marked text and commits exactly once. Changing the input box, app, input-method state or secure input cancels the session; late results are never written to a new target.
- A selection in the focused field is previewed over and replaced once by the final text. On cancel, failure or an empty result after preview, InkFlow does not write again and leaves the marked text to the host. InkFlow never reads selected text, keeps no per-app exceptions and persists no target state. A zero-length mark left by the host must not block typing, Left Shift or the next voice session.
- The voice lexicon snapshot is built at idle from Rime learning data and custom phrases. It only reranks homophones Apple already returned.
- Voice polish shares the AI service configuration but has its own switch, default off. The full final transcript is polished once after recognition; any failure falls back to the original text. No chunking, retries or partial insertion.
- Offline Pinyin typing does not depend on voice resources, microphone permission or AI.

## Manual check

After changing shortcuts, marked text, target ownership or commit logic: hold, double-tap and Esc in a native editor and a browser, including over a selection and while switching boxes or apps.

## Adapter and controller invariants

The ASR feed is deliberately off-main. Lock converter access and stream termination together.
The input callback consumes a borrowed tap buffer only within the locked synchronous conversion;
no borrowed buffer escapes. Signal real end-of-stream to drain converter priming and trailing samples.
Stop the feed explicitly even when `SpeechAnalyzer.start` returns after analysis begins. Validate the
transcriber's range contract before correction or insertion. Final segments arrive once and in order.
The volatile text is the unfinished suffix. Finalize only after the result stream and audio
finalization have both ended. A completion callback can synchronously start the next session.

InputMethodKit can activate a replacement controller before deactivating the old one. Only the
synchronous notification for the original client can address it, and no later cleanup retains that
client. Range reads, native input identifiers, diagnostic sinks and service cancellation can reenter
the controller. Remove the token before cancelling the service, recheck ownership after each external
call, and relinquish transcript ownership before delivering a commit. Recheck focus, epoch, app and
secure input after the native identifier lookup. The optional TSM document interface can leave the
selection unknown without blocking typing. Selected-text transactions leave the mark with the host
and perform no post-delivery read for learning. Unknown learned values keep their generation for ASR
fallback invalidation.

A chord modifier release ends held dictation without counting as a tap, and taps can release them
between presses. Pass through a reentrant edit while preserving the release edge of a held key.
The platform schedules wakes, and the core owns the deadline so an early wake can be rescheduled.
Preparation is explicit or uses the authorized startup task. The process-only diagnostic fixture opens
neither audio nor network resources. Production voice correction sends the finalized transcript on
its own transport and excludes document context, Pinyin and prediction statistics. Cancelling the
task stops oversized or unsuccessful response bodies. Voice diagnostics retain fixed names, random
session IDs and elapsed time, with each repeated reason rate-limited.
