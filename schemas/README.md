# Rime schemas and Lua contracts

`inkflow_pinyin.schema.yaml` is adapted from rime/rime-pinyin-simp (Apache-2.0).
InkFlow removes reverse lookup and external presets and defines its basic key bindings explicitly.
The bindings use the PinyinKeyboard mappings observed with ABC key labels on macOS 26.6.2.
Rime alternates punctuation pairs for the lifetime of the engine component. The matcher keeps
URLs and email addresses in one literal ASCII segment. See the [mixed-input rules](../.agents/skills/inkflow-mixed-input-maintenance/references/rules.md)
for composition keys, admission, learning and ordering.

The English dependency compiles literal spellings independently of Pinyin algebra. Its mixed
counterpart supplies the supplemental sentence translator. The input-source menu exposes one Pinyin
mode. Rime reads `custom_phrase.txt` from the user directory. Saving custom phrases rewrites that
file, then reloads idle sessions. AI adoption uses a separate custom patch for a property observer
with no candidate output.

## Property channel and ranking evidence

The host and Lua exchange properties synchronously on the same thread. A request in `inkflow_request`
is `1\t<op>\t<field>...` with tab-separated fields containing no tab, CR or LF. A module responds
only to operations it owns. `inkflow_result` contains `1\t<op>\t<status>\n<body>` with an optional
body and a status of `ok`, `failed`, `unknown` or `conflict`. A caught Lua error returns `failed`.

`inkflow_input_coverage.lua` inspects at most nine already materialized candidates, since calling
`get_candidate_at` on an unmaterialized row expands the translation. The reply carries bounds, class,
source, personal strength and spelling facts without candidate or context text. The schema's
`inkflow_input_coverage` Memory opens the Pinyin dictionary with `enable_user_dict: false` and is
kept for decoding. The runtime patch leaves that node in place. Its commit, delete and key callbacks
have no user dictionary to update. Disconnecting it would drop the decode dictionary.

Use the original candidate of a simplified item or the first genuine of a deduplicated item for
type and code facts. Inspect at most 256 retained genuines to recover mixed or custom-phrase evidence
only when display and span both match. The genuine type field accepts a lowercase letter or underscore
followed by lowercase letters, digits or underscores, up to 32 bytes. A Pinyin phrase's spelling is
marked corrected when its decoded syllables differ from its typed span after removing spaces and
apostrophes. Completions, entries from other dictionaries and unavailable decode evidence produce zero.

The native translator publishes which input it found technical or complete lowercase Pinyin. Use
that evidence only for the same current input. For whole-input candidates, the exact field uses
`2` for exact English on technical input, `3` for a native assembled sentence, and `4` for a
personal exact English word on complete lowercase Pinyin. The [ranking contract](../.agents/skills/inkflow-mixed-input-maintenance/references/rules.md)
describes how these tags and corrected spelling affect ordering.

`inkflow_english.lua` reports exact English availability before its first yield or early return so
an older paused iterator cannot overwrite a newer menu's response. A confirmed absence bypasses
lookahead. Older resources without a marker take the bounded search. The filter continues from the
same lazy iterator after the buffered prefix, preserving native pagination.

## Learning callbacks

The Pinyin writer borrows a short-lived Memory and disconnects it after each operation, including on
error. Its native commit/key callbacks and user-dictionary lifetime can affect ordinary undoable
learning. The reading probe uses the existing translator menu with a 128-row bound. A second script
translator would also attach ordinary learning callbacks.

The voice lexicon uses an empty predictive prefix in native key order, bounded to 8,192 rows and
512 KiB of result data. The host invokes it after the ordinary native undo window. Releasing the
temporary dictionary can commit a pending native transaction [#236](https://github.com/nervouna/InkFlow/issues/236).
The Lua writer closes an explicit transaction even if its write fails.

Standalone English learning filters Memory's cross-translator commit callbacks through the text it
emitted. The selected Phrase's native language identifies the underlying dictionary. Keep its
compiled code for Phrase construction and set the canonical lowercase custom code for persistence.
The mixed translator supplies personal ASCII runs as `display<TAB>code` pairs. Public mixed runs
are admitted ASCII letters and use their lowercase spelling. A matching custom phrase suppresses
learning. The commit notifier runs inside the English Memory transaction, so native Backspace can
undo these confirmations. Raw Return and cancellation bypass mixed learning.

The supplemental script translator reads longer spans first and emits complete, genuinely mixed
sentences. Its input dictionary contains Chinese and ASCII-letter English, letting it detect both
through the text's ASCII and non-ASCII bytes. Native Chinese has priority at equal coverage.
The mixed stream can lead a shorter translation through native span ordering.

Explicit learning management waits until idle after native undo expires. The bounded transport
distinguishes failure from an empty valid list. Single-record deletion marks a native record
deleted. Revival adds a confirmation. The two-namespace compensation limitation is tracked in
[#234](https://github.com/nervouna/InkFlow/issues/234). The [forgetting trace](../.agents/skills/inkflow-mixed-input-maintenance/references/forgetting.md)
documents why speculative sentence deletion touches the sentence's learned words and rebuilds
composition. The Pinyin Memory is created and disconnected per attempt to avoid adding commit
callbacks across keys. Recovery failure is tracked in [#238](https://github.com/nervouna/InkFlow/issues/238).
