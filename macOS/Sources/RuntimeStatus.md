# Installer runtime receipt and termination contract

Production writes `~/Library/Application Support/InkFlow/Runtime/<pid>.json`.
The directory is owned by the current user and mode 0700; each replacement file is
created mode 0600 in that directory and renamed over the destination. Readers
see a complete old or new JSON document. This is an observation receipt, not IPC,
a daemon, a flush request, a durability guarantee, or proof of text-client input.
Tests supply temporary directories explicitly.

Schema 1 fields:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer 1; reject unsupported schemas. |
| `pid` | Process PID (Int32). |
| `startSeconds`, `startMicroseconds` | Exact `proc_bsdinfo.pbi_start_tvsec` / `pbi_start_tvusec`, not a Swift launch timestamp. |
| `executablePath` | `proc_pidpath` captured at startup, before dictionary bootstrap. |
| `version`, `build` | Startup bundle `CFBundleShortVersionString` / `CFBundleVersion`; missing values are `unknown`. Never reread replaced app metadata as the running version. |
| `engineReady` | Current engine readiness, updated using the existing engine availability notification. |
| `serverCreated` | IMKServer was successfully constructed; does not prove a client connection. |
| `terminating` | A quit was requested. Remains true after denied cleanup; this process must not be presented as normal ready service. |

The installer must independently check live process UID, PID, exact start-time
pair and executable path, plus the expected installed application identity/version.
Reject missing/dead/reused PIDs, mismatched paths or times, unknown versions,
`terminating: true`, and malformed receipts. A PID filename or `kill(pid, 0)` alone
is insufficient. Old receipts may remain after exit/crash and must be rejected by
these checks; presence or disappearance is not a cleanup acknowledgment. Do not
infer graceful termination of old releases that do not implement this contract.
No live installed-version inference was used to implement this feature.

`applicationShouldTerminate` returns `terminateLater`, stops admitting dictionary
operations and drains the coordinator's owned task (including awaited detached
filesystem/helper work). It prevents pending activation and abandons its journal
only after producers finish. Normal dictionary replacement keeps its existing
finalize/reinitialize sequence. Then the engine interrupts quality recorders,
destroys sessions and finalizes Rime, before the quality store drains/closes.
Only successful cleanup replies yes to AppKit. `applicationWillTerminate` is a
notification after this work, not the asynchronous cleanup entry point.

On cleanup failure AppKit receives no, the receipt stays terminating, and another
quit retries the failed stage. Completed dictionary/engine stages are not repeated.
This deliberately does not restore an already-stopped engine or resume dictionary
updates after rejected termination. A persistently failed drain stays denied;
installers must time out without replacing the app or force-killing it. A hung
worker is drained rather than unsafely cancelled midway through filesystem work.
There is no in-process timeout pretending that unfinished cleanup succeeded.

Quality recording is best effort during normal operation. `QualityStore.close()`
reports whether the work still pending on its serial queue was persisted; earlier
recording failures or a disabled/unavailable store with no pending data do not
make quitting impossible. Failure to write final metadata is logged; it only
denies close when there was pending work. A failed close result remains failed on
retry (the existing store has already closed); no data recovery is claimed.

## Checked upstream semantics

librime 1.17.0's [RimeFinalize implementation](https://github.com/rime/librime/blob/1.17.0/src/rime_api_impl.h#L53-L58)
joins maintenance, stops the service, clears the registry and unloads modules.
[Service shutdown](https://github.com/rime/librime/blob/1.17.0/src/rime/service.cc#L76-L79)
cleans up sessions. [RimeSyncUserData](https://github.com/rime/librime/blob/1.17.0/src/rime_api_impl.h#L127-L134)
cleans up sessions and starts installation/backup/user-dictionary maintenance;
it is not a generic flush. This change does not add sync_user_data or redundant
join calls. The dependency script pins the official 1.17.0 release archive.

## Focused validation

After building resources, run `bash macOS/scripts/test-termination.sh` in an
unsandboxed GUI session. It builds a separate LSUIElement .app with a test bundle
identity and invokes only that test executable. Each subprocess has a 15-second
watchdog and synthetic dictionary/SQLite/receipt roots. Timers initiate real
AppKit termination; initiating it inside a main-dispatch callback can stall that
callback's nested termination loop, so the probe does not use that driver.

The success case uses real librime, an active synthetic composition, an in-flight
detached coordinator factory, SQLite close verification, and ordered cleanup
trace. Other cases cover dictionary denial/retry, store denial/retry, repeated
quit, disabled storage, bundle version/PID/start identity, and receipt permissions.
These tests are not clean-user installation, old-release upgrade, external
client typing, user-dictionary learning durability, or downloaded DMG evidence.
Those remain separate acceptance requirements.
