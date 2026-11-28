# Input-source installation lifecycle

`InputSourceManager` keeps TIS references on the login session's main actor and exposes value
snapshots. `TrialInstallationLifecycle` saves the registered, enabled and selected state and checks
the expected target and build. When no InkFlow source is registered and no process is running, finish
treats the install as new. It enables the parent and mode and selects the mode. A registered upgrade
restores what was enabled and selected before. Unconfirmed enablement or selection is reported after
the new process is verified. The user can finish in Keyboard Settings.

AppKit's process state can lag. Query existence with signal zero and accept only `ESRCH` as
fallback proof that it exited. Recheck after a declined quit because the process can exit between
observation and the request. Use the SDK's `4 * MAXPATHLEN` buffer size for `proc_pidpath`,
since its macro is unavailable in Swift. A prior installer may already have removed the old image.
Launch Services can then identify the original installed URL for a graceful quit.

Atomically swap the incoming app with the old one so the installed path remains present. The old
bundle remains at the candidate path. A first install uses an exclusive rename to prevent overwrite.
Installer scripts run as the logged-in user with that user's home directory. Preinstall requests a
graceful application shutdown through the lifecycle tool so the incumbent app can run its termination
handler. Postinstall can remove the staging directory after either swap outcome. It contains the old
app after success or the staged app after a failure. The swap keeps the registered path continuously
present, which macOS 27's input menu requires, and the update never restarts the menu agent, because
restarting it can make the input menu disappear. `refresh-menu.sh` is a separate current-user diagnostic
for that agent.

Local update checks process and input-source observations in the real login session. It checks for
an installed-app replacement even when the helper exits before confirming success.

See [the packaging workflow](../DEVELOPMENT.md#building-the-installer-package) for the shell entry points.
