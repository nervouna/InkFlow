# Release recovery

Read before resuming any failed/interrupted attempt, reconciling existing release state, removing a stale lock, or considering `retry-notary`. Keep the entrypoint authorization and stop conditions in force.

## Retained runner state

The runner retains submission intents, upload output/diagnostics, responses, receipts, hashes and release
state, and is resumable and idempotent: after interruption or a recoverable
failure, inspect the retained diagnostic, resolve the cause, and run the same
stable command again. It reuses matching completed stages and refuses ambiguous,
drifted or conflicting state instead of overwriting it. Submissions skip
`notarytool`'s redundant local preflight only after the repository's artifact
checks pass, use Apple's standard S3 endpoint instead of Transfer Acceleration,
and bound the upload phase. If an upload response is lost, the runner adopts
exactly one later matching history entry. Zero or multiple matches remain
fail-closed and never trigger an automatic resubmission of unknown remote state.
The DMG build binding records the submitted, pre-stapling bytes; the final receipt
records both that hash and the post-stapling distribution hash. A rerun with a
valid final receipt verifies the final artifact and resumes at remote publication
without requiring the stapled DMG to retain its pre-stapling inode or hash.

## Recovery decisions

Stop on the first failed gate and report the last successful step, version/build, commit/tag, output path and submission ID where available. Keep the failed attempt's files and logs; do not bump again just to retry.

- Before the release commit: preserve the plist change and reuse the same version; do not package uncommitted bytes.
- After the release commit but before a successful prepare: verify it matches the recorded source and package inputs before retrying. `package.sh prepare` refuses an existing output directory. If prepare failed before a usable submission ZIP, inspect and move that failed directory to a unique backup before retrying the same version.
- After prepare: do not manually replay internal stages. Retain the notarization ZIP, app, submission state, assemblies, Installer DMG, Sparkle ZIP, appcast receipt, final receipt, tag and draft, then rerun only the stable `release-runner.sh continue` command. A process crash may leave an ownership lock; establish that no runner or packager is active before removing only the proven stale lock. The runner recovers a uniquely identifiable lost submission, reuses valid post-stapling receipts, matching remote state and missing assets, and blocks zero or ambiguous submission matches, mismatching assets/tags or drifted notes without resubmitting unknown remote state, clobbering or overwriting a published version.
- Lost upload response with no matching history: zero rows mean **unknown**, not confirmed remote failure. Apple assigns the submission UUID before upload and buffers plist output until the operation finishes; an interrupted upload can therefore leave no local UUID. Inspect the retained intent, `*-submit-output.plist`, `*-submit.log`, `*-submit-result.plist` and Apple history. Never delete the intent to unlock a retry. If the existing release/recovery authorization covers retrying the same bytes under that uncertainty, use the dedicated exception below with the exact current intent SHA-256 printed by the stopped runner and a specific reason. Otherwise obtain that scope decision before dispatch.
- If source/artifact provenance cannot be recovered, stop and explain the gap instead of certifying old bytes. Never silently omit required release verification or notarization.

```sh
bash .agents/skills/inkflow-release/scripts/release-runner.sh retry-notary \
  payload CURRENT_INTENT_SHA256 'Reason for retrying the retained upload' --acknowledge-unknown
```

Use `dmg` instead of `payload` for the Installer DMG. This command requires unchanged
artifact bytes and release state, rechecks history, and adopts a unique existing
submission instead of uploading again. Ambiguous history, observation failures,
known submissions (including Accepted or In Progress), Invalid/Rejected results,
and unknown statuses do not authorize another upload. Empty history still leaves
residual duplicate-submission risk; elapsed time is never an automatic retry rule.

Each explicit retry preserves its predecessor and publishes a new immutable intent
under `notary-attempts/KIND/PREVIOUS_INTENT_SHA256/` before dispatch. It records the
reason, unknown-state acknowledgment, reconciliation snapshot and artifact/state
identity, then retains upload output, diagnostics and exit status there. The old
token cannot dispatch again; after another failed or interrupted attempt, inspect
the new evidence and pin the newly printed current intent digest for a separately
decided retry. `continue` still never automatically resubmits an unknown attempt.
Reconciliation includes the original attempt's window so older delayed records
remain visible. Retain these records with the release state until its explicitly
authorized cleanup. The command stops after the selected recovery/upload and
status observation; resume other release stages with `continue`.

This exception follows [Apple's submission/upload contract](https://developer.apple.com/documentation/notaryapi/submit-software)
and [Apple DTS's failed-upload guidance](https://developer.apple.com/forums/thread/837038?answerId=896444022).
Neither supplies a guaranteed history visibility deadline or an idempotent retry key.
