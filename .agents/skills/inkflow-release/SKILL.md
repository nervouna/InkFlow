---
name: inkflow-release
description: Release InkFlow for macOS from main — version bump, one verification run, Developer ID signing, notarization, Installer DMG, Sparkle appcast and GitHub Release. A request naming a version or major/minor/patch authorizes the whole workflow; `--draft` stops before tagging and publishing. Not for routine local installs.
---

# InkFlow release

Ships a notarized Installer DMG, `SHA256SUMS`, a Sparkle app-only ZIP, `appcast.xml` and the dictionary corresponding-source bundle (`InkFlow-X.Y.Z-BUILD-dictionary-source.tar.gz`, built by `macOS/scripts/dictionary-source-bundle.sh`; the About page and README link to it) as a GitHub Release tagged `vX.Y.Z` on `main`. Scripts live in `.agents/skills/inkflow-release/scripts/`.

A release request with a version or bump type authorizes every step below, including both Apple notarization submissions, the tag/main push and publication. Don't ask for confirmation between steps. Never force-push, overwrite a published Release or tag, create Apple credentials, or install the app for the user. Run signing, notarization and network steps outside the sandbox.

Input, Settings and installation behavior are the user's responsibility before they ask for a release; don't gate on them.

## Steps

1. **Preflight.** On a clean, up-to-date `main` (`git fetch origin --tags`; fast-forward only). Check `gh auth status` and `bash scripts/check-credentials.sh` (credentials: [configuration.md](references/configuration.md)). Confirm the tag doesn't exist yet.
2. **Bump.** `bash scripts/bump-version.sh major|minor|patch`, then commit only `macOS/Info.plist` as `chore(release): vX.Y.Z (build N)`.
3. **Verify once.** `bash macOS/scripts/release-verification.sh` — build, `test.sh all`, deep bundle check, installer receipt. If a unit fails: fix it and commit, or rerun that unit if it was flaky, then rerun verification. No extra rounds.
4. **Prepare.** `bash scripts/package.sh prepare` signs a copy of the app and its notarization ZIP under `build/releases/InkFlow-X.Y.Z-BUILD/`.
5. **Notes.** Write Chinese user-facing notes to `build/public-release-notes.md` ([public-notes.md](references/public-notes.md)).
6. **Release.** `bash scripts/release.sh` notarizes and staples the app, builds and notarizes the DMG, checks the mounted installer and embedded app, generates the appcast and the dictionary source bundle, tags and pushes `main` + tag, uploads assets, verifies the downloaded bytes, and publishes.

   `bash scripts/release.sh --draft` does everything except the tag, push and publish, leaving a GitHub draft for inspection. Running `release.sh` afterwards reuses that draft.

## If something fails

Every step in `release.sh` is skipped when its output already exists, so fix the cause and rerun the same command. Don't bump the version again to retry. If `package.sh prepare` refuses an existing output directory from a broken attempt, move it aside and rerun prepare. A notarization interrupted mid-upload is simply resubmitted on rerun; a duplicate submission is harmless.

Report the release URL, version/build and what was verified when done.
