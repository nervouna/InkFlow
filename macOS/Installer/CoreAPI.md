# Native installer

The installer extracts its embedded `Payload/InkFlow.zip`, prepares a complete app
beside `~/Library/Input Methods/InkFlow.app`, normally terminates running InkFlow
applications by bundle ID, and publishes the staged app with an atomic rename.
Replacement swaps the old app into the staging slot; cleanup removes that slot.
Copy failure leaves the installed app unchanged. No permanent backup, journal,
lock, runtime receipt, signature validator or version/path policy is used.
File and system API errors remain visible in the window's diagnostics.

`IFInstallerFiles` owns filesystem work on an actor. `IFSystemLifecycle` uses
`NSRunningApplication.terminate()` and waits up to ten seconds for exit. It never
force-kills the input method. When updating an active InkFlow source, switching
to an available ASCII source is best effort. First installation needs no fallback.

`IFSystemInputSources` uses public LS/TIS APIs on the main actor. The coordinator
registers missing sources, enables parent and mode, selects the mode and reads
back enabled/selected state. API failures permit activation retry without copying
again. Delayed approval is shown with a System Settings action. System selection
is not proof of engine startup or real typing acceptance.

The native window retains its owning task during preparation, replacement and
activation. Duplicate clicks are disabled; close and quit wait until the owned
operation and extraction cleanup settle. Preparation can be cancelled before
stopping the old application.

`--check-payload` extracts the actual embedded ZIP, requires `InkFlow.app` and
readable Info.plist, prints payload version/build and removes temporary files.
It is an assembly check only, not signature, notarization or trust validation.
Release tooling independently signs, verifies and notarizes the payload and outer
installer; release launch and real input acceptance remain separate QA.

The input method retains AppKit's graceful shutdown: drain dictionary work, stop
engine sessions, close the statistics store, then approve termination. Cleanup
failure denies quit and can be retried. No runtime status files are written.

Checks: `check-installer-core.sh`, `test-installer-core.sh`,
`test-installer-window.sh`, and `test-termination.sh`. Core tests use temporary
files and fake TIS/lifecycle backends. Native window tests use real AppKit controls
with fake backends, including duplicate clicks and busy close/quit behavior.
None install or mutate the user's daily input method.
