# Local quality recording

[`QualityRecorder`](../Sources/InkFlowRime/QualityRecorder.swift) captures bounded memory on the event thread. The store's
worker owns JSON, disk and SQLite. The process owns the recorder's store across runtime recovery
and dictionary replacement. Effectiveness counters from outside a composition, including explicit
learning management, use the same utility worker with a separate bounded buffer. Measurement
failures do not affect typing. The persisted fields and privacy controls are defined in the
[query contract](../../.agents/skills/inkflow-quality-analysis/references/query-contract.md).

## Capture and evidence

- Record outermost engine operations only. A nested digit or selection operation remains part of
  its outer operation. The controller can record intercepted physical keys such as held Tab
  without passing them to Rime. Negative semantic codes record unsupported input without entering
  Rime. The reserved codes are -1 for other chords, -2 for an unsupported character, -3 for Cmd+Z,
  and -4 for Cmd+V.
- A capture generation change or pause invalidates the active composition and all pending
  post-commit windows. Resuming requires observing a clean input boundary. A composition that
  exceeds the memory budget remains suppressed through its commit drain. A mode request keeps
  the composition open. Its later selection or flush supplies the outcome.
- The recorder snapshots applied settings and candidate order before mutations. Candidate and
  page indices are zero-based, while ranks are one-based. Engine observation does not establish
  presentation in a client. Only use actual candidate-panel observations for visibility. Unknown
  ranks stay unknown, regardless of a later page's first candidate. Compacted historical
  pages can refer to revisions distinct from the final page.
- The captures before and after a mutation separate edits, movements, paging and selection.
  An arrow crossing a page contributes to both movement and page-turn counts. An apostrophe can
  delimit Pinyin and brackets can page without proving a selection. A final empty input is not
  another Pinyin edit. Backspace can clear the last raw character without an engine commit.
  A partial selection starts a remaining-input phase and leaves composition-wide measurements
  intact. Timing is the phase snapshot, so folding evidence back after a tentative punctuation
  selection cannot add its elapsed time twice.
- The decision is tentative until the original `takeCommit` drain proves it. Idle
  finish callbacks can reenter a native insertion before that drain is linked. An empty finish
  or highlight must leave the pending origin alone. AI insertion ends the composition without
  an ordinary candidate decision. Its separate record owns that insertion. An issued
  `insertText` records the call and does not read back the document.
- All keyboard, edit, visibility and endpoint observations use one injectable monotonic clock
  with origin at the composition start. Do not mix in native event timestamps, which fixtures
  can set to zero. Visibility follows observed panel refresh/key boundaries and bounded polling.
  It cannot establish the exact display onset or the user's attention. Retain the first N−1 timed
  keys and the latest key, even when intermediate keys are dropped. This preserves the
  terminating operation's actual adjacent interval.
- Post-commit windows outlive the composition and ride on the next submitted composition record.
  There is no window timer. The next event closes a window after its deadline and clamps the
  recorded distance to the configured maximum. Count idle keys until the deadline, the next
  composition, a client change or deactivation. Keep all-window edit, direct text and paste
  counts separate from deletions and undo before the first direct text or paste key.
  A missing window is unobserved, including on legacy rows. It does not report zero.
- Typo evidence can retain the raw input just before the first Backspace, Delete or Escape that
  removes it. Redaction drops it. Selected text length counts Unicode scalars before redaction.
  Unicode's Emoji property includes digits, so text-kind classification requires actual emoji
  presentation or an emoji sequence. Text kind describes output, independent of Rime provenance.
  A candidate's provenance and spelling-correction flag come from the exact ranking evidence row.
  Without a valid span, the only fallback is a selected custom phrase, whose span is the
  whole input. Otherwise leave consumed code unknown. This keeps partial-segment recurrences comparable.

## Storage and privacy

The worker enforces encoded byte limits independently of the recorder's conservative retained
byte budget. The memory estimate accounts for string UTF-16 storage and object/collection overhead.
It stops early on oversized observations. The same active cap covers transient page caches,
prioritizing decision and first-page evidence. The producer lock guards bounded memory and queues
at most one outstanding batch wakeup. Queue and timer creation use only memory. Keep connection
opening and manifest reads on the serial worker.

Text capture defaults off. Redaction removes every string typed, shown or chosen and keeps ranking,
positions, classifications and timing. Explicit phrases keep their stable IDs without their codes
or text. The redacted configuration has a different stored revision ID. Configuration
fingerprints are computed by the worker, which stores a revision once and reuses that identity
only when applied values match. Conflicting or missing page-revision evidence is invalid.
Build metadata fingerprints the unsigned app payload, excluding the metadata file itself and
later signing or notarization envelopes. Persisted timestamps use UTC ISO 8601 with milliseconds.

Only decisions can receive pair hashes, one over the selected candidate's consumed normalized code
and one over its text. Compute both or neither before text redaction, using HMAC-SHA256 truncated
to 128 bits (32 lowercase hexadecimal characters). The 32-byte device key lives beside the database
in the worker-managed `quality-pair-key` file. Exports, backups, records and logs never carry it.
Create the file owner-only. If it cannot be read or written, omit hashes. Clearing records rotates
the key and advances the producer generation, invalidating envelopes hashed under the old key.
Turning text capture off removes stored text-bearing records, including those predating text-free mode.

SQLite application ID `0x49465131` identifies IFQ1. Validate exact schema ownership before migration.
If another writer may have initialized an empty file, recheck after taking the writer lock.
Insert commit parents before decision children. The composite foreign key rejects links across
compositions. Delete children before parents because the schema intentionally has no cascade.
Logical removal is atomic and secure deletion cannot erase filesystem snapshots. Compaction
returns unused pages to the filesystem, with a one-time rebuild for databases lacking incremental
auto-vacuum. An occupied database can be retried on a later maintenance pass.

Pause changes the in-memory gate before the worker barrier. Flushing drains the accepted prefix
at invocation, so later submissions need not be processed yet. Only lifecycle, tools and tests
await it. Close stops acceptance immediately. A timeout ends the caller's wait, leaving SQLite
owned by the worker. Incomplete persistence cannot veto application termination. A failed final
update still closes the connection, and explicit close reports the failure.

## Diagnostic events

Diagnostic storage is platform-injected. Importing the engine creates no persistent diagnostics.
Automatic events accept source-defined finite labels, UUIDs and numbers. Run ID and PID separate
client switches from process startups. Do not conform user-text wrappers as labels or include
arbitrary error descriptions, URL or app identifiers, paths, SQL, configuration or document text.
Dictionary source and worker errors cross process boundaries with string codes. Only the allowlisted
codes reach diagnostics. Omit uncontrolled `userInfo`, file names and stderr. Diagnostic fields
stay separate from the dictionary journal and manifest.
