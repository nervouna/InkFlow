# macOS application contracts

See the [debugging index](../DEBUGGING.md) for symptoms and reproduction commands and the
[test harness notes](TestHarnessContracts.md) for fixture design.

## InputMethodKit and presentation

`InputController` implements synchronous legacy callbacks on the main thread. The superclass prevents
inferred Sendable conformance. Keep non-Sendable arguments within synchronous `MainActor.assumeIsolated`
scopes. The menu is returned synchronously to IMK through a local slot because the actor callback
requires a Sendable result. Menu actions receive IMK action dictionaries. The server may retain the last
panel after controller teardown, so teardown hides it and clears its data. The process owns one
immutable selection-key layout because the panel borrows it. The lifetime owner retains the most
recent panel and reaches the owner through a weak association because the panel retains the server.

Swift always sets the public panel attributes. The guarded Objective-C binding
uses the protected SDK reference to adjust vertical width after direction and font changes, which
rebuild native traits. See [native candidate layout](../DEBUGGING.md#vertical-candidate-panel-minimum-width).

`InputControllerCore` lets AI consume only plain Tab. Presentation follows the offline state
transition. Mirror the engine's applied settings, which can lag the requested settings until the
composition boundary. Reserve or end the old composition before delivering text to an IMK client,
because a client callback can synchronously start another composition. Cmd+Z and Cmd+V pass through
Rime like unsupported chords. Their distinct recorder event codes retain the edit classification.

`Context` takes a bounded UTF-16 prefix of committed text. The client can widen a request to include
a full surrogate pair. Only text strictly before the anchor qualifies, outside an existing mark or
selection. `InputRankingContext` captures it at composition start only. Later keys, selections and
flushes retain displayed order. The engine clears the prefix when composition ends. This glue is
kept separate from AI so the build can audit offline ranking inputs by file.

The active composition's visibility tick reads the native panel state even when AI is disabled.
IMK can show the panel asynchronously. The tick reads no document text. Status feedback is passive
and anchored by the public caret API. Panel geometry uses bottom-left screen coordinates and
falls back to the same horizontal anchor below the caret. The thunder effect reuses a click-through
overlay with a few animation layers per action, after delivery, and honors Reduce Motion.

## AI suggestions

`AISuggestionCoordinator` owns one attempt per unchanged composition, including failures. Document
and UI callbacks remain synchronous on the main actor, with only the service operation asynchronous.
Range reads can reenter the controller. The validation hook runs before controller-authored edits
and on the visibility tracker without reading document text or starting inference. After a validated
mark edit, rebind only the presentation ranges and keep the original request and deadline. Wait for a
native panel with the same deadline and a weak session reference so an abandoned session can deallocate.
Capture surrounding text once per request. Missing text is valid and reported only as availability.
An inconsistent document length can clip the suffix only when consistent with the controller's mark.

The companion AI panel takes neither focus nor pointer input. Place it where the entire panel fits
without covering candidates or skip presentation. Include the text field inset in the width calculation.

`AIChatCompletions` shares a process-lifetime ephemeral session across controllers, with each task
independently cancellable. HTTPS is required away from the loopback host and redirects are refused.
The settings validator rejects insecure HTTP before saving and defers missing or unparseable URLs to
request validation. On the local Ollama endpoint, Qwen 3 and 3.5 use the
[thinking override](../DEBUGGING.md#ai-local-ollama-qwen-reports-an-incomplete-suggestion-github-4).
`AISettings` suppresses Keychain UI at startup and publishes updated settings only after the
credential write succeeds. Diagnostics emit allowlisted names and scalar metadata, never document
text, provider bodies, configuration or arbitrary errors. Notice-level events remain available
for investigation. Tests receive the same allowlisted events as the system log.

## Diagnostics and lifecycle

`StartupDiagnostics` reports only fixed labels, timing and Boolean delivery facts. First-key timing
sections emit after the synchronous operation returns. Logs contain no key metadata, text, candidates,
document values, client identifiers, paths or error descriptions. Tests read the same safe records.
AppKit exits after termination notifications, so `ApplicationLifecycle` owns cleanup. Interrupt
recorders and destroy sessions before closing the store. Startup-failure cleanup bounds the synchronous
bridge in addition to its individual store budgets. Diagnostics flushing is best-effort at termination.

`LocalDiagnostics` serializes disk work off the caller and never holds the submission lock during
I/O. A directory lock coordinates distinct process runs. Export lock contention keeps the bounded
queue for a later retry. Walk directory components with `O_NOFOLLOW`. Leave ancestor modes and
contents alone. Failed bookkeeping must preserve data already read. Compare timestamps in
the archive's integer Unix-millisecond time base to avoid fractional boundary errors. Decoding on-disk
records excludes unknown fields and corrupt records. Version/build metadata is restricted to release tokens.
Leftover `incident_*` files from builds that saved incidents stay in the rolling log's age and
capacity budget so cleanup still deletes them; they are never read. A leftover `incident.next`
temporary file is deleted under the directory lock.

`DiagnosticArchive` cleans old staging directories at activation and export. A process lease keeps
an active export alive. A lease-free stage is abandoned if found while holding the root lock, which
serializes stage and lease creation. Project bounded regular `.ips` files into a finite summary at
read time, without following symlinks in the report path. Classify `EXC_RESOURCE` and `EXC_GUARD` as
unsupported because their fatality varies. Accept string, Boolean and numeric forms of crash flags.
Settings dependencies perform side effects only on explicit actions, with fixtures supplying the
store, filesystem and reporting boundaries.

## Dictionary and personal data

`DictionaryCoordinator` owns requests across Settings window closure. Restrict its unified logs to
source, protocol and worker diagnostics and split payloads at scalar boundaries to stay within the
OS's roughly 1 KiB log entry size. Document context and learning data are excluded. `DictionaryWorkerRunner` launches its
configured local executable with a controlled environment that excludes inherited credentials, user
paths and dynamic-loader overrides. `sandbox-exec` launch failure is fatal to the request. Startup's
synchronous bootstrap reads inert data only, never executable code from an old bundle.

The personal-data backup uses an explicit missing value for an absent dictionary, distinct from an
empty dictionary. Validate nested round-trips because Codable silently ignores unknown fields.
The sandboxed worker closes staged copies before the core snapshots them. It stages inside the
candidate root because replacing a file through the normal atomic writer uses a directory outside
that root. Preserve ambiguous or unreadable artifacts for recovery, without following links. Native
diagnostics can carry dictionary text and stay out of macOS log and feedback records. The backup's
UserDefaults wrapper transfers access to the existing thread-safe owner.

The rollback-first journal covers exactly three native dictionaries and the allowlisted preferences.
Write the original-presence record before moving staged files. Recovery can see an interrupted
forward move before its rename and a restoring phase after its rename. Atomic writes and file
synchronization handle process interruption. If finalization fails, hold the reservation and block
further input and personal-data writes until the next startup resolves the authoritative journal.

## Settings and updates

The process-local argument domain alone can select the isolated credential store used by the
production initializer harness. Canonicalize old independent input preferences before publishing
a composition snapshot. Persist the user's quality-recording preference even if the writer has failed
for the current process. See [quality export](../QUALITY-EXPORT.md) for retention and scheduling.

AppKit owns the window constraints across SwiftUI pages. Shortcut capture uses the native button
under the accessibility proxy and receives events only while the button is first responder. The
[debugging index](../DEBUGGING.md) covers menu routing and regular activation for permission prompts.
The About view uses the version and build to locate the corresponding source archive attached
to the release.

An input method rarely quits during normal use. `UpdateIdleInstaller` checks Sparkle's immediate-install
handler on a timer outside input processing. It waits for the quiet period since the last login-session
keyboard, mouse or trackpad action. The CoreGraphics any-event selector uses the raw value `~0`.
Installation requires no composition, pending delivery, voice session, personal-data
transaction or open InkFlow window. The newest handler replaces the old one. Sparkle terminates, installs
and relaunches. If termination cleanup fails, a new attempt waits for the quiet period again.

## Diagnostic events

Diagnostic storage is platform-injected. Importing the engine creates no persistent diagnostics.
Automatic events accept source-defined finite labels, UUIDs and numbers. Run ID and PID separate
client switches from process startups. Do not conform user-text wrappers as labels or include
arbitrary error descriptions, URL or app identifiers, paths, SQL, configuration or document text.
Dictionary source and worker errors cross process boundaries with string codes. Only the allowlisted
codes reach diagnostics. Omit uncontrolled `userInfo`, file names and stderr. Diagnostic fields
stay separate from the dictionary journal and manifest.
