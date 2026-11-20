# macOS test harness contracts

See [macOS testing](../TESTING.md) for commands and the
[application contracts](ApplicationContracts.md) for runtime behavior.

## Native controller and Settings fixtures

- The exact-initializer fixture uses only the process-local argument domain to select isolated
  credentials. Put defaults suite names under a temporary directory as in `temporarySuiteName`.
  For a plain name, cfprefsd can recreate the emptied plist in the user's Preferences directory
  after it has been removed.
- InputMethodKit normally expects its cross-process client proxy during initialization. The
  Objective-C shim intercepts framework initialization, teardown and test client lookup and
  still runs the actual Swift subclass initializer, so every stored property is initialized.
  Preserve the real controller and native panels. Check teardown without allocating a window
  or starting an AI request. Private menu and panel inspections are diagnostic-only and fail
  explicitly when the relevant selectors disappear. Catch Objective-C exceptions in the shim.
- Drain the autorelease pool containing native panel inspection, deactivation and replacement
  before asserting deallocation. Native getters may autorelease their returns. Only the newest
  panel should own the server reference. Reuse the process's one IMK server connection across
  isolated startup cases. Clear compositions left by earlier fixtures before collective
  phrase reloads because reload waits for every session to be idle.
- Controller tests simulate client callbacks that can pump a nested event loop. Restore
  temporary permissions before asserting a failed phrase write. A later key must keep its
  error and avoid rewriting the file. Use synthetic secure-input observations for ordinary
  controller/capture tests. Exercise secure input separately. The controller rows of the
  [composition key table](../../.agents/skills/inkflow-mixed-input-maintenance/references/keys.md)
  pair with the shared engine rows. Include physical device-dependent Shift bits, Caps Lock and
  the DEL value of Backspace in the forget-candidate test; those flags must resolve to Shift.
- Grouped SwiftUI Forms may expose control labels as adjacent static text. Their AX proxies
  can offer public selectors without declaring NSAccessibility protocol conformance. A child
  process performs the system checkbox action because the in-process checkbox proxy lacks a press
  selector. Use a bounded public child process read to initialize the lazy AX tree. The sidebar
  layout fixture starts in the requested section because its proxies are not selectable rows.
  Check sidebar navigation in the app. Allow for asynchronous activation while keeping a bounded
  focus assertion. Keep clipboard checks nonterminating until the original contents are restored.
- Use the physical POSIX temporary path for filesystem safety fixtures. Foundation may abbreviate
  `/private/var` as `/var` even after resolving symlinks, but diagnostics intentionally reject a
  symlink ancestor. Keep personal backup size coverage for cases where native inputs each fit but
  the encoded document exceeds the limit after quoted phrase text is escaped.

## AI and voice fixtures

- Headless AI keeps real per-key Rime processing and simulates only window readiness. Use physical
  ANSI key codes, modifiers and event timestamps via `handle(_:client:)`. A late-show fixture
  remains hidden until explicitly completed. Functional tests wait for the presentation event and
  use an infrastructure timeout longer than the debounce. Drive visibility both before and after
  the original deadline. Paging preserves that deadline and hidden panels trigger no context read.
  Test reentrancy and focus separately from visibility. The fixture can exercise a late window close
  without real desktop focus changes or global secure-input mutation.
- The AI runtime clock advances only when tests ask it to. Scheduler delays affect when a sleeper
  wakes, while elapsed deadline comparisons use the injected time. An intentionally
  cancellation-insensitive service tests that the coordinator rejects late results. Keep the case
  where Rime changes the displayed mark without changing raw input. `URLSession` can complete before
  `URLProtocol.stopLoading`, so wait for the latter independently.
- Paid live AI runs observe the real service and use synthetic text. Parse the optional configuration
  as data and redact credentials even from unexpected output. Credential tests use a random
  Keychain service and synthetic keys.
- The voice feed test invokes the exact production tap on a detached executor without opening a
  microphone. The hosted runner can use the known zh_CN format (16 kHz mono interleaved Int16)
  only under `INKFLOW_SPEECH_ASSETS_OPTIONAL=1` when the production locale is unavailable.
  Early release or cancel cannot open the microphone or prepare language assets.
- Wait for the controller deadline transition rather than assuming a fixed scheduling delay.
  Exercise the ASR tail during replacement controller activation and preparation finishing between
  target capture and queued startup. Isolate the captured rule closure when testing it because the
  general settings notification cancels active sessions. Synthetic correction can defer indefinitely
  or ignore cancellation. A missing or failed correction falls back to the complete finalized
  transcript. A tail timeout drops unfinished recognition.

## Quality capture, export and shutdown

- The recorder loads the device key on the first worker start. Envelopes submitted earlier have
  no pair hashes. Candidate evidence describes Rime's translator type and whether a fuzzy or
  algebra rule reached the spelling. Match the evidence row to the candidate without needing
  text. The English module's own candidates lack a Rime dictionary spelling. The `zongguo`
  fixture reaches 中国 only through the option that groups z/zh, c/ch and s/sh. The forget fixture
  uses unique learned entries. Shift+Backspace records one act for the highlighted candidate and
  returns it to native order without committing. Idle Shift+Backspace and regular Backspace
  record none.
- A post-commit window records against the commit it observes but is stored on the next composition
  the recorder submits. The fixture submits a second composition on the same controller. It tests
  leading Backspaces, undo before and after paste, direct digits, arrow keys, following punctuation,
  a target switch and deactivation. No client insertion means no window. Secure input suppresses
  the window. Assert that elapsed time is within the injected window rather than equal to a host
  timestamp. Processing the key or delivering text is not the user's wait.
- The exporter test fixture takes `DATABASE DESTINATION` for manual export or
  `auto DATABASE FOLDER LAST NOW` for a weekly check. `LAST` is Unix seconds or `none`.
  A check that is not due prints `skipped`. These tests use synthetic settings and an injected
  clock to avoid scheduling a real timer.
- To observe timer-driven store work, advance its injected clock and await its worker barrier.
  Frequent same-process read-only SQLite probes can race the macOS VFS locks with `IOERR_LOCK`.
  Exercise an older store without auto-vacuum, a text-bearing abandoned composition whose only
  retained text is its deleted input, and both topologies the worker can observe around a submit.
  The key is separate from the SQLite bytes. Migration appends count columns and leaves
  previously unobserved lengths null.
- A shutdown timeout releases the caller while the serial worker still owns the SQLite attempt.
  A second close queued behind it exposes final failure accounting. Let deliberately stalled
  workers resume before asserting, so an unbounded implementation produces a failure without
  hanging the test. The pressure fixture needs the longer close timeout described in the
  [debugging index](../DEBUGGING.md#quality-store-failed-under-load).
  The termination test starts a real detached resource factory and submits a real pending
  composition with complete synthetic build identity. A subprocess watchdog bounds failure.
- Test packaged startup with an inert resource set and an unusable cache to force recovery.
  Confirm that the first key already uses the context index. If the index is unreadable, serving
  must fail. An older recipe without raw sources can recover through the shipped dictionary.
  A self-consistent receipt still fails if the manifest dictionary digest is false. After engine
  loss, retry must still take the packaged serving path. Deployment fixtures make YAML older
  while preserving `user.yaml`'s last build time.

See [Python query fixtures](QualityQueryFixtures.md) for scorecard and replay expectations.
