# Installer core handoff (task B)

Compile the four `Installer*.swift` files together with
`Shared/InputSourceManager.swift` and `Sources/RuntimeStatus.swift`, using the
Swift 6 / macOS 26 arm64 flags in `scripts/check-installer-core.sh`.
No package dependencies or executable entrypoint are added by the core.

## Window integration

Create `IFInstallerCoordinator.production(candidate:)` on the main actor.
Assign `stateChanged`, render the current `state`, and dispatch a button with
`await coordinator.perform(action)`. `state.actions` is the allowed action set;
concurrent submissions are ignored. Keep the coordinator alive for the window.
Use `state.busy` to defer window closing. `cancel` is accepted during preparation;
copying finishes off the main actor, then the prepared transaction is discarded
before input-source disruption. The commit/termination phase is not cancellable
through a window action. Do not cancel the owning Task to close a busy window.

Actions: `installAndEnable`, `retryActivation`, `repairMissingRegistration`,
`resumeRecovery`, `cancel`. Activation retries validate the installed code and never prepare/copy
or reinstall. Explicit registration repair retries an API failure, skipping
an already-successful LS stage. A successful registration with delayed discovery
is only re-enumerated, not repeatedly registered.

Results distinguish `installedMissingRegistration`, `installedRegistrationFailed`,
`installedAwaitingApproval`, `installedEnabled(observation)`,
`installedRuntimeFailed(reason:fallbackRestored:)`, `installedRecoveryRequired`,
`legacyNeedsReview`, and `failed(installed:message:)`. API failures must not be
worded as user refusal. `installedEnabled` returns only `.ready` or
`.waitingForSystemLaunch`. The latter means selection and enablement were confirmed
but the system has deferred starting the process, and finishes observation early.

A live process gets up to 40 intervals of 250 ms (about 10 seconds, plus API work)
for cold bootstrap. Persistently `.initializing` or `.unverifiedReceipt`, a
`.terminating` process, a process that exits during observation, or an observation
error returns `installedRuntimeFailed`. Before selecting Hans, every activation
attempt, including first install and retries, retains an enabled ASCII source.
On runtime failure it attempts to restore that source once, then polls at most
8 intervals, freshly checking identity, enabled-roster uniqueness and selection.
The failure result reports whether restoration was confirmed; if false, show the
failure details and ask the user to select a working keyboard in the input menu.
Files remain installed. `retryActivation` takes a fresh fallback snapshot and
never reinstalls or registers. No state proves actual typing.

An archive/finalization failure after verified commit returns
`installedRecoveryRequired`, preserving the committed app and journal and releasing
the lock without cancelling the committed transaction. Its only action is
`resumeRecovery`, which reacquires the lock, validates the expected installed code,
and finishes journal recovery without copying or swapping. A failed attempt stays
in this resumable state. Successful recovery proceeds to activation; a normal
upgrade does not register. The message describes the original verified commit,
not a promise that external file changes since that commit are safe.

For `legacyNeedsReview(version)`, explain that the installation was preserved and
that this version's normal-exit behavior needs inspection before retrying. Do not
say that lack of a receipt requires logout. Inspected 0.1.0 and 0.2.0 versions
already permit signature/UID/path/start-verified normal termination plus bounded
exit observation without a receipt. This does not promise old buffered statistics
were saved. Refused or timed-out termination never swaps or kills the IME.

## Shipped candidate boundary for packaging

Task C owns the ZIP extraction step. Its caller must locate the signed installer's
own `Contents/Resources/Payload/InkFlow.zip`, verify the outer bundle before
unpacking, and unpack that shipped resource into an owned canonical temporary
root. Retain that directory until `perform(.installAndEnable)` finishes. Construct
`IFUnpackedShippedCandidate(installerBundle:unpackedApp:expectedVersion:)` from
that result. The core repeats outer signed-resource verification, confirms the
ZIP is present, and verifies inner identity, team, version/build and signature;
it verifies the copy again at staging and after atomic commit. This is a narrow
unpacked-candidate API, not an arbitrary ZIP extraction utility. Production has
no unsigned/ad-hoc or team-check bypass.

## Native application and packaging probe (task C)

`NativeWindow.swift` binds `IFInstallWindowController` directly to the coordinator,
with an injected async factory and cleanup closure. The owner task stays alive
through preparation, file commit, activation and payload cleanup. Both window
close and the application's Quit action return a deferred termination reply while
busy; preparation may request core cancellation, but the owner task is never
cancelled. `IFInstallAppDelegate` replies only after that task settles.

`ShippedPayload.swift` provides the actor-isolated `IFShippedPayload.load()` and
`clean()` pair. It verifies the outer bundle before extraction, accepts only its
own sealed `Payload/InkFlow.zip`, uses bounded system ditto extraction in an owned
private temporary directory, requires exactly `InkFlow.app`, and repeats the
core's candidate verification with version/build read from the outer plist.
Cleanup checks the owned directory identity. No unsigned-production mode exists.

Build with `bash macOS/scripts/build-installer.sh /path/to/InkFlow.zip [output.app]`.
The default is `build/InkFlow Installer.app`; an existing output is preserved and
rejected. The script copies version/build from `macOS/Info.plist` and reuses the
input method's icon. It compiles and assembles only; release packaging signs the
result. The separate `AppMain.swift` entrypoint is outside `Installer*.swift`.

After signing the outer bundle, run its actual executable with `--check-payload`.
This calls the same loader and cleanup, prints version/build on success and exits
nonzero on failure, before creating NSApplication. It performs no installation,
registration, enablement, selection, or IME launch. A successful local signed
probe is not notarization or trusted downloaded-release evidence.

`bash macOS/scripts/test-installer-window.sh` builds a separate test app using
fake file/TIS/lifecycle backends and injected settings/termination replies. Native
buttons, progress, bounded diagnostics, recovery and fallback states, duplicate
submissions, cancellation, and actual close/Quit actions are checked. It captures
only test-owned windows under `build/installer-task/ui/`; a 25-second watchdog
bounds the executable. AppKit tests may require execution outside the agent
sandbox. The production entrypoint is not linked into the test executable.

Only known `/tmp` and `/var` aliases are canonicalized. Links within candidate,
state or target paths are rejected. Payloads must use regular files/directories,
matching the existing dylib layout, rather than symlinked framework layouts.
Both Input Methods directories are scanned for bundle ID or connection-name
collisions; the destination and all operational identity constants are fixed.

## Transactions and boundaries

File/signature/archive work runs on the `IFInstallerFiles` actor. TIS and AppKit
calls stay on the main actor. Temporary candidates use a private same-volume
installer-state directory and a `.bundle` name. Old bundles are archived as ZIPs
outside Input Methods. This naming is not a claim that all OS scanners ignore
staging directories; real installation/relogin acceptance remains separate.

`flock` spans preparation through commit; small journals identify directory device
and inode before SWAP/EXCL. A synchronous prelaunch validation failure reverses
the swap or removes only the newly installed first-install bundle. Recovery does
not overwrite the target: it discards a never-committed candidate or verifies the
committed target and finishes archiving. Unknown targets or failed verification
retain evidence and require inspection. Archives use fresh exclusive names on
each recovery attempt, so interruption after publication does not block recovery
or overwrite an earlier backup. An interruption after journal removal can leave
an orphan private scratch directory; it is not automatically deleted as unknown
content. These are process-crash checks, not a power-loss durability guarantee.

Archive helper timeout is 30 seconds; old-process exit timeout is 8 seconds.
Activation phases use bounded read-only polling. No direct IME launch, force kill,
user-dictionary writes, cache resets, TIS preference edits or daily installation
occur in builds/tests. The core does not retry a file transaction automatically
after an unknown recovery outcome.

## Evidence

Run `bash macOS/scripts/check-installer-core.sh` and
`bash macOS/scripts/test-installer-core.sh`. The former only compiles the production
core and legacy CLI. The latter uses temporary real file transactions, a bounded
crash subprocess, value-only receipt checks, and fake TIS/lifecycle adapters.
Neither executes the real backend against the daily input method.

The parent's isolated legacy probe confirmed last selected-word learning survived
normal exit of real librime 1.17.0 without explicit finalize/destroy_session, with
independent export and restart checks (`build/installer-task/legacy-probe/README.md`).
This evidence does not establish actual old AppKit/IMK termination.

Pending outside B's completed checks: actual old-app deactivation/upgrade,
clean-user TIS/system confirmation, native window interaction, downloaded signed
ZIP/DMG and production signed-payload verification, and client typing acceptance.
The source investigation of librime 1.17.0's Service/UserDictionary/LevelDB normal
exit path is recorded by the parent in `build/installer-task/plan.md` section 10;
it is not a substitute for those remaining runtime checks.
