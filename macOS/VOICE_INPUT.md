# Voice input

Shipped in 0.4.0. Experiments and measurements are archived in `docs/archive/VOICE_*.md`.

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
