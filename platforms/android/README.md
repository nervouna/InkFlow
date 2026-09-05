# Android input method

This single-module Gradle project builds the native InkFlow Android IME for
`arm64-v8a`. AGP uses its built-in Kotlin support; the app packages one JNI
library that statically contains the complete InkFlow, librime, and recursive
native dependency closure.

`schemas/source` remains the only editable product schema. A Gradle generated
assets task stages those three canonical files under `inkflow-schema` during
the build. There is intentionally no `app/src/main/assets` mirror.

Run the host-build acceptance gate from the repository root:

```sh
./tools/verify/android.sh
```

The app requests no network permission, uses no telemetry, retains the legacy
backup opt-out, and explicitly excludes every cloud-backup and device-transfer
domain on Android 12 and newer. Rime data also stays below
`noBackupFilesDir`. Password fields and editors that set
`IME_FLAG_NO_PERSONALIZED_LEARNING` send keys directly through the current
`InputConnection`; their text, key, and selection paths do not initialize or
process input with the native engine and do not read extracted editor text. An
already-open nonsensitive session is closed when the editor switches.

All service instances share one process-lifetime engine queue. Native opens
return an owner token, and every later operation validates that token so a
stale service teardown cannot close a replacement session. Host selection
callbacks are matched through an exact old/new transition journal that permits
ordered or collapsed self callbacks. A single strict composing-bounds matcher
can establish an unknown initial anchor; all other unknown state fails closed,
and the service never reads an extracted-text snapshot.

Return is offered to Rime first. When unhandled, the service uses the current
editor's custom or standard action when allowed, otherwise sends a raw Enter
pair and journals its expected selection transition. A rejected editor action
does not silently become a newline.

See `docs/android-acceptance.md` for the exact evidence boundary and optional
arm64 device or emulator checks.
