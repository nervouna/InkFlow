---
name: inkflow-release
description: Publish or draft an InkFlow macOS release from main, or publish a drafted Linux release. Use for release requests with a version or major/minor/patch. For a local trial build, use the macOS development guide.
---

# InkFlow release

A release request naming a version or bump authorizes the requested workflow. A publishing run submits both
the app and installer to Apple, pushes `main` and the tag, and publishes on GitHub. A `--draft` run also signs, notarizes
and uploads assets to a GitHub draft. It stops before tagging, pushing or publishing. Continue through the
authorized steps without intermediate confirmations. Never force-push, overwrite a published release or tag,
create Apple credentials or install the app. Run signing, notarization and network steps outside the sandbox.
Typing, Settings and installation checks belong to the user's pre-release testing.

Use the local path on a Mac with the signing identities, notarization credentials and Sparkle key.
Use [GitHub Actions](#release-from-github-actions) when requested or when local credentials or tools are unavailable.
For setup or credential errors, read [release configuration](references/configuration.md).

## Select the version

Base version selection on the fetched `origin/main`. For an explicit `X.Y.Z`, derive the next version for each of
`major`, `minor` and `patch` from [the app version](../../../macOS/Info.plist). Use the bump that
produces exactly the requested version. If none matches, stop before changing the version or dispatching CI
and confirm the intended bump. For a request naming a bump, use it directly.

## Local release

Run commands from the repository root in the release checkout. From a worktree, export
`INKFLOW_RELEASE_CONFIG=<main checkout>/.release.local.plist`. `release.sh` pushes `HEAD` to `main` and requires
`HEAD` to contain `origin/main`, so the `main` branch need not be checked out.

```sh
release_scripts=.agents/skills/inkflow-release/scripts
```

1. **Preflight.** On a clean checkout at `origin/main`, run `git fetch origin --tags` and fast-forward only. Confirm
   the proposed tag is free. Run `gh auth status` and `bash "$release_scripts/check-credentials.sh"`.
   `gh api repos/nervouna/InkFlow/releases/latest --jq .tag_name` must start with `v`; if not, restore it first
   ([Linux release](references/linux.md)).
2. **Bump.** Set `bump` to the selected component and run `bash "$release_scripts/bump-version.sh" "$bump"`.
   Verify the resulting version. Commit only `macOS/Info.plist` as `chore(release): vX.Y.Z (build N)`.
3. **Verify once.** Run `bash macOS/scripts/release-verification.sh` to build, run `test.sh all`, check the
   bundle deeply and record the commit and app build in the release receipt. If a unit fails, fix and commit
   the change or rerun a flaky unit, then rerun verification. One successful verification is enough.
4. **Prepare.** Run `bash "$release_scripts/package.sh" prepare` to sign a copy of the verified app and create
   its notarization ZIP under `build/releases/InkFlow-X.Y.Z-BUILD/`.
5. **Notes.** Write Chinese user-facing notes to `build/public-release-notes.md`. See [public notes](references/public-notes.md).
6. **Ship.** Run `bash "$release_scripts/release.sh"` for a stable release. Add `--draft` to leave the GitHub
   draft, or `--prerelease` to publish while keeping the previous stable release in Sparkle's feed. A later
   publishing run reuses the draft. To promote a pre-release without a rebuild, run
   `gh release edit vX.Y.Z --prerelease=false --latest`.

## Release from GitHub Actions

[The release workflow](../../../.github/workflows/release.yml) uses the same scripts on a hosted Mac.
Fetch `origin/main` and tags before selecting the version and preparing notes. The workflow selects a build
number above earlier release builds and uses [configured credentials](references/configuration.md#github-actions-release).

1. **Notes.** For publication, prepare the Chinese notes from the previous tag through `origin/main` using
   [public notes](references/public-notes.md). Store them in the target version's draft with
   `gh release create vX.Y.Z --draft --title "InkFlow X.Y.Z" --notes-file build/public-release-notes.md`.
   A dry run may use placeholder notes. Publishing requires the final notes.
2. **Run.** Set `bump` to the selected component. For a draft, run:

   ```sh
   gh workflow run release.yml --ref main -f "bump=$bump" -f draft=true
   ```

   For publication, set `draft=false`. For a pre-release, also add `-f prerelease=true`.
   Find the run with `gh run list --workflow release.yml --limit 1` and follow it with
   `gh run watch RUN_ID --exit-status`. CI replaces the draft's assets on rebuild and keeps its notes.

Read [release recovery](references/recovery.md) before retrying an interrupted run. Report the release or draft
URL, version/build and verification result.

## Linux release

Publish a drafted `linux-vX.Y.Z` as described in [Linux release](references/linux.md). Keep it off Latest.
