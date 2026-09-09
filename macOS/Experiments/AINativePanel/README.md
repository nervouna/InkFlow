# Native AI panel feasibility probe

Run `bash macOS/scripts/probe-ai-native-panel.sh` from a logged-in GUI session.
The harness compiles independently of Rime and production sources. It only creates
its own temporary IMK server and two candidate panels. It does not register an
input source, install InkFlow, or send keyboard/mouse events. Compiler caches,
executable and logs stay under ignored `build/`.

The exit status checks simultaneous visibility, non-overlapping actual public
`NSWindow.frame` rectangles, and independent hide. `candidateFrame()` reports
local origins on the observed runtime, so it is not used to check overlap.
A zero exit would establish only these properties, not safe input routing.

## Observed result

2026-09-09, current local macOS runtime:

- Both panels reported visible; the application had two visible windows with
  widths 176 and 336 points, respectively. Neither was key.
- `setCandidateFrameTopLeft:` requested distinct positions (200, 500) and
  (200, 430), both before and after showing. Both actual windows remained at
  origin (5, 6), so they overlapped. The probe exited 1.
- Hiding the AI panel left the ordinary panel visible.
- A sandboxed invocation aborted before output; the same scoped invocation
  outside the GUI sandbox ran and produced the recorded observations.
- An attempted capture limited to the two owned window IDs failed with
  `could not create image from window`. No screenshot or visual-content proof
  was obtained. This may be a desktop/capture limitation.

This bounded public-API path does not pass the integration gate. This is evidence
about this standalone harness, not proof that a live input-method session can
never position a second panel. Keyboard/click routing, actual rendered text,
font variants, and real-editor interaction remain unverified. Avoid expanding
into private framework internals just to achieve the visual change; use the
accepted passive AppKit styling fallback.
