# Portable runtime contract

The [runtime guide](README.md) covers resource preparation, session policy and the test commands. Frontends use
[the C declarations](include/inkflow_rime.h) or Rust's `Engine` and `InputSession` types.

## Frontend ABI

The ABI version is 1. Each opaque handle has a matching release function, which accepts null.
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

The observer runs synchronously on the mutating thread after the policy lock is released. Its callback and
user pointer must be usable on any mutating thread. Snapshot pointers in a mutation are borrowed for that
callback. Its key and modifier fields apply to key actions, and the index to select and highlight actions.
Keep observer work bounded and enqueue I/O elsewhere. The callback must avoid reentry into the same session.
A null callback removes the observer.

## Native bridge

`native/bridge.h` is used within the runtime under the Rust process-wide Rime lock. Rime borrows the paths
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

The settings path writes the new phrase file before requesting a reload. Every live session must be
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
assembled sentences. An unobserved clear ends a composition consumed by a feature such as AI adoption
without telling the quality observer that the user cancelled.

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

The [ranking leads](../../.agents/skills/inkflow-mixed-input-maintenance/references/ranking-leads.md)
define the full order, `exact` evidence marks and deferral rules. A phrase boundary match may extend a
whole indexed word at the end of the preceding text, as in 行为, but cannot begin inside it, as in 为时.
Long native leaders that cannot fit an indexed phrase stay on the original page. When the wider
document-context ranking is safe to clip, it preserves relative priorities. If partial spans appear,
rank the visible window separately to preserve visible native slots and English deferral. For the
context index format see the [dictionary generator](dictionary/README.md). In-memory dictionary
loading preserves the Swift fixture's character-level line splitting, in which CRLF is one grapheme
and does not act as a bare LF separator.

## Lua channel

The native bridge performs one synchronous property round trip and retains neither the request nor the
reply. The schema modules observe the request and respond before the property update returns.

```text
request 1\t<op>\t<field>\t<field>...
result  1\t<op>\t<status>\n<body>
```

Operations use lowercase letters and underscores. At most 64 fields may be sent and none may include
tabs, CR or LF. The caller bounds the reply to at most 4 MiB. Personal-learning listings request 3 MiB.
A buffer filled to its limit can indicate truncation, so the native bridge discards that answer.
A wrong version, mismatched operation or malformed header is ignored. A module can answer with `ok`,
`failed`, `unknown` or `conflict`; these all travel as `IFR_OK`. `IFR_NO_REPLY` leaves the caller's output
untouched when the session is unavailable, no module answers, a reply is too large or a request cannot be
framed. Invalid arguments and exceeded ABI bounds return `IFR_INVALID_ARGUMENT`. Reply accessors borrow
their strings until the reply is freed, and a valid body may be empty.

Keep channel calls out of key callbacks, apart from the engine's own candidate evidence and editing
operations. Frontends gate optional feature calls on every session being idle and postpone reads past
Rime's native undo window. The [learning contract](README.md#personal-learning-and-portable-personal-data)
explains how successful writes and clearing learning invalidate captured listings.

[forgetting]: ../../.agents/skills/inkflow-mixed-input-maintenance/references/forgetting.md
