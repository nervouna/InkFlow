# Native AI panel feasibility probe

Run `bash macOS/scripts/probe-ai-native-panel.sh` from a logged-in GUI session, outside the sandbox.
The harness creates its own temporary IMK server and two candidate panels, independent of
Rime and production sources. It installs nothing and sends no input events. Output stays under `build/`.

It exits 0 only if both panels are visible at the same time, their `NSWindow.frame`s don't
overlap, and each hides independently. `candidateFrame()` reports local origins, so it is
not used for the overlap check.

## Result (2026-09-09)

Failed (exit 1). Both panels showed, but `setCandidateFrameTopLeft:` was ignored: both
windows stayed at origin (5, 6) and overlapped. Hiding the AI panel left the ordinary
panel visible. Window capture failed, so rendering was not inspected.

Decision: don't reach into private frameworks for a second panel; use the passive AppKit
styling fallback.
