---
name: inkflow-release
description: Release InkFlow for macOS from main — version bump, one verification run, Developer ID signing, notarization, signed installer package, Sparkle appcast and GitHub Release. A request naming a version or major/minor/patch authorizes the whole workflow; `--draft` stops before tagging and publishing. Not for routine local installs.
---

# InkFlow release

Ships a signed, notarized and stapled installer package (`InkFlow-X.Y.Z-BUILD-arm64.pkg`), `SHA256SUMS`, a Sparkle app-only ZIP, `appcast.xml` and the dictionary corresponding-source bundle (`InkFlow-X.Y.Z-BUILD-dictionary-source.tar.gz`, built by `macOS/scripts/dictionary-source-bundle.sh`; the About page and README link to it) as a GitHub Release tagged `vX.Y.Z` on `main`. Scripts live in `.agents/skills/inkflow-release/scripts/`.

A release request with a version or bump type authorizes every step below, including both Apple notarization submissions, the tag/main push and publication. Don't ask for confirmation between steps. Never force-push, overwrite a published Release or tag, create Apple credentials, or install the app for the user. Run signing, notarization and network steps outside the sandbox.

Input, Settings and installation behavior are the user's responsibility before they ask for a release; don't gate on them.

Two paths run the same scripts. The local path below needs the signing identities, notarization credentials and Sparkle key on this Mac. The [GitHub Actions path](#release-from-github-actions) needs none of them locally; use it when `check-credentials.sh` fails here or when asked.

## Steps

1. **Preflight.** On a clean, up-to-date `main` (`git fetch origin --tags`; fast-forward only). Check `gh auth status` and `bash scripts/check-credentials.sh` (credentials: [configuration.md](references/configuration.md)). Confirm the tag doesn't exist yet.
2. **Bump.** `bash scripts/bump-version.sh major|minor|patch`, then commit only `macOS/Info.plist` as `chore(release): vX.Y.Z (build N)`.
3. **Verify once.** `bash macOS/scripts/release-verification.sh` — build, `test.sh all`, deep bundle check, release receipt (commit and app build). If a unit fails: fix it and commit, or rerun that unit if it was flaky, then rerun verification. No extra rounds.
4. **Prepare.** `bash scripts/package.sh prepare` signs a copy of the app and its notarization ZIP under `build/releases/InkFlow-X.Y.Z-BUILD/`.
5. **Notes.** Write Chinese user-facing notes to `build/public-release-notes.md` ([public-notes.md](references/public-notes.md)).
6. **Release.** `bash scripts/release.sh` notarizes and staples the app, builds the package (`package.sh finish`: `build-pkg.sh --sign` with the Developer ID Installer identity, its embedded `register-input-source` signed with Developer ID Application, hardened runtime and a timestamp) plus the Sparkle ZIP, checks the package signer, the embedded tool and the app inside, notarizes and staples the package, generates the appcast and the dictionary source bundle, tags and pushes `main` + tag, uploads assets, verifies the downloaded bytes, and publishes.

   `bash scripts/release.sh --draft` does everything except the tag, push and publish, leaving a GitHub draft for inspection. Running `release.sh` afterwards reuses that draft.

   `bash scripts/release.sh --prerelease` publishes the release as a GitHub pre-release. The Sparkle feed (`releases/latest`) keeps serving the previous stable release, so existing installs are not offered it. To promote it later without a new build: `gh release edit vX.Y.Z --prerelease=false --latest`.

## Release from GitHub Actions

`.github/workflows/release.yml` runs steps 1-4 and 6 on a `macos-26` runner with credentials from repository secrets ([configuration.md](references/configuration.md#github-actions-release) lists them and the one-time setup). It bumps from the dispatched `main`, seeds the build counter above every build attached to a release, and pushes the bump commit and tag with a deploy key. The default `draft: true` is the dry run.

1. **Notes.** CI can't write them. Write the step 5 notes from `release-note-candidates.sh "$previous_tag" origin/main`, then store them in a draft for the bumped version: `gh release create vX.Y.Z --draft --title "InkFlow X.Y.Z" --notes-file build/public-release-notes.md`. A publishing run fails without them; a dry run without a draft uses marked placeholder notes, which a publishing run refuses.
2. **Run.** `gh workflow run release.yml --ref main -f bump=patch -f draft=false` (add `-f prerelease=true` for a pre-release). Find the run with `gh run list --workflow release.yml --limit 1` and follow it with `gh run watch RUN_ID --exit-status`.
3. **Report** the release URL from the run summary, as for a local release.

Every CI run builds afresh: it deletes an existing draft's assets for the tag and uploads its own build, keeping the draft's notes.

## If something fails

Every `release.sh` step is skipped when its output already exists, so fix the cause and rerun the same command. Specific failures and their fixes are in [recovery.md](references/recovery.md).

Report the release URL, version/build and what was verified when done.
