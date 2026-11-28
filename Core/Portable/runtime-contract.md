# Portable runtime contract

The [runtime guide](README.md) covers the build and test commands. Frontends use
[the C declarations](include/inkflow_rime.h) or Rust's `Engine` and `InputSession` types.

## Frontend ABI

`ifr_abi_version()` returns the ABI version; the current value is `ABI_VERSION` in [abi.rs](src/abi.rs).
Each opaque handle has a matching release function, which accepts null.
`ifr_session_take_commit` returns an owned string when there is text and null when the buffer is empty.
Call `ifr_string_free` on owned strings. Strings read from a snapshot, backup, learning listing, export or reply
are borrowed for the life of that owner. A caller keeps a handle alive throughout each call. Null handles
and out-of-range indices in read-only accessors return neutral values. Invalid pointers are programmer errors.
Strings crossing the ABI are NUL-terminated UTF-8. Export calls with a status use `ifr_last_error` to report
failure on the calling thread. Its pointer remains valid until another failure on that thread.

`IFR_NATIVE`, `IFR_POISONED` and `IFR_PANIC` can leave a runtime unusable. Stop using its handles after one of
these errors and recreate the engine. A failed native teardown keeps the process from starting another
runtime. `IFR_ALREADY_RUNNING` can mean that a session still holds the last reference after its parent
handle was released. `IFR_RESOURCE` covers missing or invalid prepared resources and context data.
`IFR_CONFIGURATION` identifies an engine or session configuration failure. `IFR_ENGINE_ACTIVE` requires
dropping all sessions and engines before personal-data maintenance. `IFR_INCOMPATIBLE` covers a mismatched
backup format, Rime version or dictionary set. A snapshot that breaks the TSV contract returns `IFR_SNAPSHOT`.
An interrupted import requires `ifr_personal_recover` before starting another.
Learning management reports `IFR_TOO_LARGE` when the number of entries or a learning count exceeds its bounds.

| Status | Meaning |
| --- | --- |
| `IFR_SESSIONS_ACTIVE` | Preparation needs the runtime exclusively, but a session still holds it. |
| `IFR_IO` | A file or directory operation failed. |
| `IFR_STALE_SNAPSHOT` | The snapshot passed to select or highlight is not the session's latest. |
| `IFR_INVALID_CANDIDATE` | The candidate index is outside the snapshot's page. |
| `IFR_UNKNOWN_FIELDS` | A backup document carries fields the format does not define. |
| `IFR_SETTINGS` | A backup's settings are missing, mistyped or inconsistent. |
| `IFR_PHRASES` | A custom phrase failed validation; `ifr_last_error` holds the stable code (`invalid-code`, `control-character`, `empty-text`, `invalid-data` or `duplicate`). |
| `IFR_RECOVERY_REQUIRED` | An interrupted import left a transaction that `ifr_personal_recover` must resolve first. |

`ifr_compiled_file_count` and `ifr_compiled_file_name` list the files a compiled cache must contain. The name
pointer lives for the process and is null when the index is out of range. `ifr_phrase_normalize` returns the
trimmed, lowercased code and the trimmed text as caller-owned strings, which `ifr_string_free` releases; on
failure it writes neither output. `ifr_phrases_validate` accepts a list with `IFR_OK` only when every entry is
already normalized, identities are unique and no code and text pair repeats; otherwise it returns `IFR_PHRASES`.
`ifr_input_options_default` returns the option mask of a new configuration. `ifr_engine_context_ranking_ready`
returns 1 when the engine loaded a context index, and 0 when it orders by Rime alone or the handle is null.

`IFREngineConfig` names prepared shared resources, an isolated writable user directory, a compiled cache and
a context index. The user directory is created if it is absent. A null cache compiles into `user/build`
during setup. A null context index keeps Rime's order. `ifr_rime_version` reads the linked library's version
without an engine. It returns a process-lifetime pointer, or null if the engine lock was poisoned.

`ifr_session_snapshot_if_changed` returns a fresh owned snapshot unless its predecessor has the same content
and selection identity, in which case success writes null. A null predecessor always requests a copy.
The highlighted index is in display order. Selection and highlight require the latest snapshot from the same
session. Native operations may invalidate a selection identity even when they leave its visible content
unchanged. Offsets in the preedit are UTF-8 bytes on character boundaries. The raw caret is an offset into
the raw input, whose text omits the spaces inserted into the preedit. An AI request identifies its input by
the raw text, raw caret and preedit prefix before the selection start. A stray raw caret is clamped to
the nearest preceding character boundary so an invalid optional caret does not fail a key event.

## Native bridge

One process-wide Rust mutex serializes all Rime calls, including initialization, deployment, reads,
destruction and finalization. An engine's policy lock serializes its `InputSession`s and nests outside that
mutex. Sessions can move between threads, and no GUI event loop, actor or thread affinity is required. Another
engine must not call librime outside the lock in the same process, so old and new comparisons need separate
processes. There is at most one runtime: a second initialization returns `IFR_ALREADY_RUNNING`. Sessions hold
the runtime, so the last owner finalizes Rime, and a poisoned lock fails later normal operations while
destructors still clean up. The wrapper does no resource preparation, download, SQLite access or telemetry from
`process_key`.

`native/bridge.h` is used within the runtime under the Rust process-wide Rime lock. Its calls return 0 for
success, -1 for a native failure, -2 for an invalid session or schema and -3 for a caught C++ exception. A key
Rime leaves unhandled is not an error. Every throwing entry point catches exceptions before returning to Rust,
and the bridge has no callbacks into Rust. A native exception can leave engine state partly changed, so stop
using the runtime and restart it. Allocator aborts and native crashes are not status codes. Callers pass valid
borrowed pointers and zero-initialized outputs, and release native snapshots and commit buffers with their
matching functions, never Rust's allocator. The mixed translator enumerates normal lexical spans through the
native prism before the syllabifier prunes paths, and it keeps its read-only language object valid because the
Lua `Phrase.lang_name` binding dereferences it. Rime borrows the paths
from the runtime through finalization. Initialization that fails after installing modules attempts to
finalize. Native output structs start zeroed and use their own free functions. The snapshot owner holds every
returned string even if conversion stops partway through, and freeing the snapshot zeros the struct.
The native lookahead snapshot owns text for up to nine materialized candidates without moving the cursor or
changing the page. Its other fields are unused.

To apply a schema configuration, the native bridge saves whole nodes, installs the patch and reseats the
schema in one idle session before restoring the originals. The returned bitmask reports patch, selection
and restoration separately (bits 0, 1 and 2). Setup errors from opening the schema or initializing or loading
the patch leave the original nodes untouched. The operation leaves other sessions' existing components
attached to their own configuration snapshots.

## Session configuration and navigation

Configuration accepts candidate counts 3–9 and falls back to 5. A null options pointer retains the
requested preferences. The option mask follows the bit positions declared in the header in
`InputOption::ALL` order. Option names in quality records are the same names the Swift frontend uses.
The live options accessor writes the applied preferences after a composition boundary has accepted them.
The requested ASCII accessor reflects a frontend request or toggle before the composition boundary.
The live ASCII accessor reflects the Rime switch, with the requested value as its fallback if the session
is unavailable.

Custom phrases use an opaque frontend identity unique within a configuration. Their code is lowercase
ASCII and their text cannot contain control characters. Identical code and text pairs are duplicates.
Earlier entries have greater weight. The `# no comment` TSV directive lets users save phrases beginning
with `#`. Stable validation and application errors such as `invalid-code`, `duplicate`,
`phrase-write` and `missing-prism` are returned by the configuration error accessor for localization.
Restart the engine if restoring its temporary schema configuration fails.

The settings path writes Rime's native `custom_phrase.txt` in the user directory before requesting a reload. Every live session must be
idle and have no undrained commit before the process releases its shared custom-phrase table.
The next sessions read the current file and reapply their individual settings. A session that failed
to reload retries alone on its next use. Other deferred preference changes can apply at the individual
session's idle boundary. Schema reselection also resets Rime's commit buffer, so the engine drains
finished text into its own buffer before applying the change. Frontends drain commits after each key,
selection, configuration change or explicit commit before processing the next action.

Digits select visible candidates and Up/Down move the displayed highlight. A handled result of 1 means
the engine consumed the key. Callers can omit the handled output pointer. A step beyond the page uses
the corresponding native page edge, so Rime decides whether another page exists. Paging keys are Rime
Page_Up and Page_Down. The Rime/X11 modifier masks for Shift, Control, Alt, Super and Release are bits
0, 2, 3, 26 and 30. A highlighted partial choice can change the preedit and cursor. The engine preserves
that explicit navigation and saves the new page content. Home and End first put Rime's highlight on the
native first candidate so the navigator handles the caret motion. At the start of the input Rime
rebuilds the page and pins its first candidate, so the engine keeps native order there. Shift+Backspace
forgets a highlighted candidate when candidates exist. See the [forgetting rules][forgetting] for
assembled sentences.
## Candidate evidence and ordering

The ranker keeps at most 16 graphemes of preceding text. When the user selects a segment, the immediate
prefix lives in the mark. The remaining page defers to Rime rather than using older document context.
An applied custom phrase puts the user's explicit choices ahead of ordinary candidates for that code.
The position and rank accessors use Rime's native ordering before InkFlow's display order. Position is a
zero-based current-page index and rank is one-based across pages (`page * page size + native index + 1`).
Both accessors return zero for an out-of-range index.

The quality evidence row is `start,end,class,exact,personal,source,type,corrected`. The first two fields
are UTF-8 byte offsets of the input the candidate consumes. They are available through the consumed-input
accessor only for an exact record the user confirmed. Personal commits are capped at three. For a mixed
sentence this is the weakest ASCII run, including zero for an unconfirmed run. The evidence omits
displayed text, annotations and raw input. It can be absent after a selected prefix, for a custom-phrase
code, or when the native page cannot be read. Legacy six-field evidence has an empty Rime candidate type
and an unset corrected flag. Current types are lowercase ASCII letters, digits and underscores with a
maximum of 32 bytes and no leading digit. The corrected flag includes abbreviations and fuzzy or algebra
rules that reach a different spelling.

Fcitx5 supplies the preceding document text through `ifr_session_start_document_context` while idle. For a
Han continuation on a short first page, the ranker examines up to nine native Rime candidates. When the
preferred Han candidate lies beyond the displayed page, a Rime filter moves its existing handle to the last
visible slot before ordinary page ordering, and the native menu keeps the remaining candidates, selection and
learning. `ifr_session_set_preceding_text` keeps its current-page behavior.

The [ranking leads](../../.agents/skills/inkflow-mixed-input-maintenance/references/ranking-leads.md)
define the full order, `exact` evidence marks and deferral rules. A phrase boundary match may extend a
whole indexed word at the end of the preceding text, as in 行为, but cannot begin inside it, as in 为时.
Long native leaders that cannot fit an indexed phrase stay on the original page. When the wider
document-context ranking is safe to clip, it preserves relative priorities. If partial spans appear,
rank the visible window separately to preserve visible native slots and English deferral. For the
context index format see the [dictionary generator](dictionary/README.md). In-memory dictionary
loading preserves the Swift fixture's character-level line splitting, in which CRLF is one grapheme
and does not act as a bare LF separator.

## Personal data

Learning management (`ifr_personal_learning_entries`, `_delete`, `_undo`, `_invalidate`) runs only when every
session is idle and Rime's native undo window, 4 s after the last commit, has passed; otherwise it returns
`IFR_BUSY`. Never call it from a key callback. Entries and undo tokens carry a learning revision that any
commit, Backspace or Delete, new session or invalidation supersedes, and a stale one returns `IFR_CONFLICT`.
A successful `voice_learning`, `ai_learning` or `clear_english_learning` call advances the revision too, and a
clear also drops every session's cached learning view. A failed native write may be partial, so it invalidates
the revision. The active native Rime memories own the namespaces and there is no separate index. Listings sort
by source, code and text and borrow their strings until the listing is freed. If management gives no usable
answer, refresh and retry. [Rule 18](../../.agents/skills/inkflow-mixed-input-maintenance/references/rules.md)
owns the policy.

`src/personal.rs` reads and writes the macOS backup format 1, a document with `format`, `rime`, `settings` and
`dictionaries`. It carries the three Rime user dictionaries (`pinyin_simp`, `inkflow_shared_english`,
`inkflow_voice_alias`), custom phrases, the candidate count and the input options. macOS-only preferences
(shortcuts, font size, layout, thunder mode, voice rules) are skipped and listed in `Backup::unsupported`, and
unknown fields are rejected as on macOS. Written documents carry neutral values for the skipped fields; macOS
additionally requires the three fuzzy options to agree and exactly one paging pair. `None` for a dictionary is
explicit absence and removes the local one. Export snapshots closed copies of the databases under
`user/PersonalData/staging` and removes that directory afterwards; the TSV text is byte-identical to the macOS
worker's export and stays borrowed until the export is released. Unknown names and absent dictionaries return
null. Import restores snapshots into a staging directory, moves the originals aside, installs the new databases
and restores the originals on any failure; `ifr_personal_recover` finishes an interrupted import. None of this
runs while an engine is initialized in the process (`IFR_ENGINE_ACTIVE`). Frontends stop the engine, apply the
returned settings through `set_configuration` after recreating it, and keep backup phrase strings only while the
backup handle is live. A backup never implies that live databases can be shared between engines.

## Lua channel

The native bridge performs one synchronous property round trip and retains neither the request nor the
reply. The schema modules observe the request and respond before the property update returns.

```text
request 1\t<op>\t<field>\t<field>...
result  1\t<op>\t<status>\n<body>
```

Operations use lowercase letters and underscores. At most 64 fields may be sent (`abi.rs`) and none may
include tabs, CR or LF. The caller bounds the reply to at most 4 MiB (`abi.rs`). Personal-learning listings
request 3 MiB (`engine.rs`). A buffer filled to its limit can indicate truncation, so the native bridge discards
that answer. A wrong version, mismatched operation or malformed header is ignored. A module responds only to
operations it owns, and a caught Lua error returns `failed`. A module can answer with `ok`,
`failed`, `unknown` or `conflict`; these all travel as `IFR_OK`. `IFR_NO_REPLY` leaves the caller's output
untouched when the session is unavailable, no module answers, a reply is too large or a request cannot be
framed. Invalid arguments and exceeded ABI bounds return `IFR_INVALID_ARGUMENT`. Reply accessors borrow
their strings until the reply is freed, and a valid body may be empty.

Keep channel calls out of key callbacks, apart from the engine's own candidate evidence and editing
operations. Frontends gate optional feature calls on every session being idle and postpone reads past
Rime's native undo window. [Personal data](#personal-data) explains how successful writes and clearing learning
invalidate captured listings. The [schemas guide](../../schemas/README.md#property-channel-and-ranking-evidence)
lists which Lua module owns each operation and who calls it, and the rule for opening a short-lived `Memory`.

[forgetting]: ../../.agents/skills/inkflow-mixed-input-maintenance/references/forgetting.md
