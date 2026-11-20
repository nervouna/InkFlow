# Swift engine facade and learning

[`IFEngine`](Engine.swift) owns the Swift side of the [portable Rime runtime](../../Portable/README.md).
The main actor accesses the process-global engine. Editing, paging, ranking, selection, commits and
Rime configuration belong to the Rust core. Swift owns platform delivery leases, deferred idle
notifications, voice lexicon refresh, quality capture and Settings-facing errors.

## Sessions and delivery

A Swift session can remain attached to a runtime generation after losing its native Rime session.
The core tries to recover an underlying session lost during phrase reload on the next use.
During shutdown all Swift objects are invalidated before the core goes away. A late deinitializer
must not destroy a session or handle belonging to a new generation. The last engine/session reference
finalizes the native runtime.

Idle requires releases of all delivery leases, including those spanning nested native client calls.
The idle check drains already-completed text into each session's buffer. Undelivered text keeps the
session busy. Rime may also undo learning while reporting Backspace as unhandled for the client.
Starting or finishing a capture sequence does not change how commits are delivered.

User-requested preferences, ASCII mode and candidate count take effect at composition boundaries.
A composition uses its captured preference values until it ends. Replacing whole schema
configuration nodes lets existing Rime components retain their old snapshots. Requested custom
phrases outlive a runtime restart. The core writes `custom_phrase.txt` and reloads it at shared idle.
A failed phrase-file write keeps the configuration waiting. The fresh runtime's probe establishes
the requested phrase file before sessions are restored, so restoration only reads it. A learned
user's first candidate can differ from the clean preparation worker's first candidate.
The preceding context set for ranking belongs to the active composition and clears with its content.
With no prepared context index, Rime's native order remains available.

Read-only quality snapshots do not consume pending commits or update ranking and highlight.
Selection passes the current displayed snapshot into the core. Highlighting a partial candidate can
change Rime's preedit and cursor, so the recorder observes the new content while respecting the
explicit navigation.

## Foreign interfaces and personal data

Swift C string arguments are borrowed, NUL-terminated and valid only for the call. Callers reject
embedded NULs. The option mask follows the order of `InputOption.allCases`. An owned display
snapshot keeps its strings and ranking evidence available until release. Rime probe errors preserve
the first failing case's diagnostic number, using 1 for session setup and 2 plus the zero-based
case index for a failing case.

The personal-data worker snapshots the three user dictionaries through `ifr_personal_export`.
The core first copies their databases under the user's `PersonalData/staging` directory. An absent
dictionary has no returned snapshot text. Restore uses `IFPersonalDataSnapshot` in the Rust archive's
bundled native sources. Call it only from the isolated worker with closed staged databases. It is
separate from the portable session ABI. Validation compares all data and metadata rows. Native
`TsvReader` trims the trailing delimiter for a metadata key with an empty value, so restore explicitly
writes those keys from the independently validated map before comparison.

Lifecycle learning-management calls use the active Rime memories without filesystem enumeration or
a second database. They refer to entries by an index in a particular learning revision. External
changes invalidate cached listings and undo tokens. After a failed native write the dictionaries
may have applied part of the operation, so the frontend drops its old listing and undo eligibility.
An explicit reset of the two English learning memories leaves the public dictionaries and ordinary
`pinyin_simp` user dictionary open.

## AI adoption and voice correction

Request identity tracks raw input, caret and selected prefix. Presentation-only paging,
highlighting and preedit changes do not invalidate it. Record a learning adoption only after the
controller consumes the recommendation and while its delivery lease is held. Learning failure may
neither block insertion nor teach the original typo. The applied dictionary's reverse-table path
follows activation and rollback. Reading resolution uses only phrase and character codes for the
current recommendation, without a corpus scan or persistent index. It allows isolated edits under
the typo-tolerance preference. Equal-cost distinct paths remain ambiguous, so two paths suffice per
state. An exact user-provided reading takes precedence over a corrected phrase reading. Only
learning uses this edit-distance acceptance gate. Recommendation display can reject a clear
expansion when a proper output prefix consumes the full spelling and the complete output has
no valid alignment.

The [VoiceLearning coordinator](../InkFlowDomain/VoiceLearningCoordinator.swift) owns correction
policy, deadlines and generation-bound tickets. A stale or early callback cannot touch the client.
The adapter supplies immutable document evidence before a bounded native read, and qualification is
rechecked on submission. An automatic polish is excluded from user correction evidence. The
coordinator revokes old reads before invoking any storage or adapter effect. It consumes the
learning action before storage, including when that write fails.

The voice lexicon is a disposable view of Rime learning. Explicit custom phrases from Settings have
priority. Refresh is triggered by deferred engine idle independently of dictionary activation.
A check for idle can drain a new commit, so test the undo guard after checking idle. The guard measures
wall and monotonic time before reading, accounting for Rime's whole-second native clock and backward
system-clock adjustments. A learning revision invalidates management listings and undo tokens.
Explicit management invalidation advances the lexicon epoch without shortening the normal undo grace
period.

Voice reranking keeps the ASR primary alternative first on a tie and can choose only offered
alternatives with the same normalized Latin reading. The explicit character-description heuristic
leaves the primary untouched. It does not infer intended spelling from arbitrary language.
The bounded beam filters entries using the set of characters appearing in eligible alternatives and
the fixed prefix, so unrelated personal entries cannot affect scoring.

## Rime channel and mixed translator

Swift and Lua exchange one versioned request/reply pair through the core's
[`InputSession::call`](../../Portable/README.md#interface-contract). Lua replies synchronously
through a context property with a status and body. Unavailable sessions, unanswered operations,
oversized replies and invalid framing yield no result. Use the channel outside key callbacks.

The [mixed-input rules](../../../.agents/skills/inkflow-mixed-input-maintenance/references/rules.md)
describe admission, boundaries and ranking. The C++ extension registers after Rime initialization
and before sessions are created. It enumerates normal lexical spans through the native prism before
the Syllabifier prunes paths. This keeps viable syllable boundaries that a winning homophone could
otherwise hide. A normal span excludes abbreviation, fuzzy, completion and corrected spellings.
One span graph supports both technical-input and complete-lowercase-Pinyin verdicts and the
personal lookup. Each Lua-visible verdict stores the exact input it describes or the empty string.
This keeps old context properties from applying to a different composition.

A read-only mixed sentence still carries its lexical provenance and original cursor spans.
Its distinct language has no Memory and supplies no shared native syllable-code namespace. Keep
its language object valid because the Lua `Phrase.lang_name` binding dereferences it. The entry's
custom code passes each ASCII run as display and lowercase code to the learner. Its weakest usable
personal run supplies the confirmation bucket, so one unconfirmed run removes the sentence's
personal evidence. A public run counts only when it comprises whole public entries and shares
its exact display/span with an admissible confirmed edge. Validate runs across adjacent native
entries. The translator retains its reader for its lifetime, letting queries reuse it without
destructing a native UserDictionary or closing the shared transaction during a query.
