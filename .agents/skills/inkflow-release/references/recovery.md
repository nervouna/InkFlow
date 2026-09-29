# Release recovery

`release.sh` is resumable: each step checks for its output (stapled app, DMG, stapled DMG, appcast, draft assets) and skips it if present. Fix the cause and rerun.

- **Notarization rejected:** read `build/releases/…/payload-notary.plist.details` or `dmg-notary.plist.details`, fix signing/entitlements, then remove the release directory and rerun `package.sh prepare` and `release.sh`.
- **Broken DMG/ZIP:** delete the DMG, ZIP and appcast from the release directory and rerun `release.sh`.
- **Existing draft with stale assets:** `release.sh` re-uploads with `--clobber` and byte-compares the downloads.
- **Tag exists on another commit / origin/main diverged:** stop and ask the user. Never force-push or move a published tag.
