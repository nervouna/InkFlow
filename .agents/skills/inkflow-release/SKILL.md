---
name: inkflow-release
description: Publish an InkFlow macOS release from main with a confirmed semantic version, full verification, Developer ID signing, notarization, and a downloadable GitHub Release DMG. Also use to resume an interrupted release; not for routine local installation.
---

# InkFlow release

Deliver a public GitHub Release containing a signed, notarized DMG and SHA-256 checksum. Use `main` and an annotated `vX.Y.Z` tag; do not maintain a `release` branch.

A request to execute this release workflow authorizes its version commit, tag, push and publication after version confirmation. Merely discussing, inspecting or editing this skill does not authorize a release. Honor narrower user instructions. Do not install or register the input method on the publisher's machine.

Run commands from the repository root. Read `macOS/DEVELOPMENT.md` for the current verification list and use `$apple-signing-workflow` for certificate selection and artifact verification. Helpers live beside this file in `scripts/`.

## Local configuration

The helpers read `.release.local.plist` at the current checkout's repository root, independent of the caller's working directory. Store only the two string keys `INKFLOW_SIGN_IDENTITY` (verified certificate SHA-1) and `INKFLOW_NOTARY_PROFILE` (existing notarytool Keychain profile name). Raw credentials remain in Keychain. For first-time setup, verify the local path is ignored and untracked, copy [the template](assets/release.example.plist) there and replace both placeholders with verified references; preserve an existing configuration. Do not commit the local file or create new Apple credentials automatically. Each worktree needs its own ignored file, or an explicit `INKFLOW_RELEASE_CONFIG` path to an existing local configuration.

Environment variables override file values, including explicitly empty values (which fail validation). `INKFLOW_RELEASE_CONFIG` optionally selects another plist for testing. The loader parses data with `plutil`; it never sources the configuration as shell code. Missing or invalid configuration produces an actionable error without printing its contents.

Use elevated execution for Keychain/signing/network checks if the agent sandbox blocks access; an empty sandbox identity list is not proof that the host lacks certificates. Never dump credentials to diagnose authentication. Configuration loading is local; `check-credentials.sh` performs a read-only Apple authentication request. The `notary.sh` wrapper loads the same configuration for every submit/info/log/history call.

## 1. Preflight and version confirmation

- Inspect worktrees and use the existing `main` checkout. Require a clean worktree and index, with no merge/rebase in progress. Do not switch another worktree's branch, stash changes or reset history automatically.
- Verify `origin` identifies the intended GitHub repository using `git remote get-url origin` and `gh repo view`. Set `repo` to that verified `OWNER/REPO` and use `--repo "$repo"` on all release commands. Check `gh auth status`, then `git fetch origin --tags`. Stop on divergent history or conflicting tags. Fast-forward a behind-only `main`; local commits ahead of origin are part of the release and must be reviewed.
- Run `bash .agents/skills/inkflow-release/scripts/check-credentials.sh` before the version bump/build. It validates the configured Developer ID Application identity, the exact certificate's subject OU `T7976FL2LP`, and Apple authentication through the configured Keychain profile. Packaging repeats this check before creating output. Missing/invalid credentials block packaging, not inspection.
- Read `CFBundleShortVersionString` and `CFBundleVersion` from `macOS/Info.plist`. Show the current values and proposed major/minor/patch results; ask the user to choose 大版本升级 / 新增功能 / Bugfix. Reuse an explicit choice in this release request. Major resets minor and patch; minor resets patch; patch increments alone. Build increments once, independently. Do not infer a 1.0 graduation from a 0.x version.
- Check the proposed tag and Release do not already exist locally or remotely before changing files. Existing release state routes to recovery below, not another version bump.
- Run `bash .agents/skills/inkflow-release/scripts/bump-version.sh TYPE`, where TYPE is the confirmed `major`, `minor` or `patch`. Review the diff. Set `version`, `build`, and `tag="v$version"` from the updated plist, and record the starting commit in `build/release-notes.md` with the selected version/build and subsequent verification results. This ignored local record is for recovery, not a second version source.

## 2. Verify the release contents

Move any existing `build/InkFlow.app` to a unique backup under `build/` before building to prevent stale bundle contents. Preserve dependency caches. Run these sequentially, retaining exit status and logs under `build/`:

Before testing, stage only `macOS/Info.plist`, record `git write-tree` in the local recovery record, and require `git diff --exit-code` to pass. This fixes the source snapshot the package must represent.

```sh
bash macOS/scripts/build.sh
bash macOS/scripts/test.sh
bash macOS/scripts/check-bundle.sh
bash macOS/scripts/test-controller-initialization.sh
bash macOS/scripts/test-settings-ui.sh
bash .agents/skills/inkflow-release/scripts/test.sh
```

Also run any checks subsequently added to `macOS/DEVELOPMENT.md`. GUI tests require a logged-in desktop; an unavailable GUI check is blocked, not passed. Do not proceed to publication with skipped/failed required checks. Any source change invalidates the affected evidence and requires a new build/package. Automated checks do not establish real installed-IME typing acceptance; that remains user-owned and is reported separately.

## 3. Sign, package and notarize

```sh
bash .agents/skills/inkflow-release/scripts/package.sh
```

This signs a staged copy and creates `build/releases/InkFlow-X.Y.Z-BUILD/InkFlow-X.Y.Z-BUILD-arm64.dmg`. It does not rebuild, install, register, notarize or publish. Set `release_dir` to that output directory and `dmg` to the full DMG path. Verify the helper's signing metadata against the expected team and Developer ID identity. Submit the exact DMG:

```sh
bash .agents/skills/inkflow-release/scripts/notary.sh submit "$dmg" --no-wait --output-format plist > "$release_dir/submission.plist"
```

Read and retain the submission `id`. Poll `bash .agents/skills/inkflow-release/scripts/notary.sh info "$submission_id" --output-format plist` at reasonable intervals. Only `Accepted` permits continuation; on `Invalid`, use the wrapper's `log` command and stop for diagnosis. On network failure or interruption, query the existing ID before resubmitting.

```sh
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
hdiutil verify "$dmg"
```

Mount the final DMG read-only with `hdiutil attach -readonly -nobrowse`, retaining the returned mount point. Check its `InkFlow.app` with `codesign --verify --deep --strict`, verify Developer ID authority/team, bundle ID, version/build against the source plist, and run `spctl --assess --type execute --verbose=2` on the mounted app. Confirm `安装说明.txt` exists. Detach the mount even if a check fails. Do not claim installed acceptance from these checks.

After stapling and verification, generate `SHA256SUMS` inside `release_dir` with `shasum -a 256` using the DMG basename. Freeze these bytes for upload; do not rebuild/re-sign after this point.

## 4. Commit and tag

Review `git diff`, `git diff --cached` and `git status`; only the intended staged plist version change should remain. Recheck the built plist matches it, `git diff --exit-code` passes and `git write-tree` still equals the pre-test tree. Require the release commit's tree to equal that recorded tree. Do not sweep unrelated changes into the release.

```sh
git add macOS/Info.plist
git diff --cached --check
# Inspect the staged diff and compare git write-tree to the pre-test record.
git commit -m "chore(release): $tag (build $build)"
git tag -a "$tag" -m "InkFlow $version (build $build)"
```

Before tagging, require a clean worktree and the recorded tree match. Record the release commit SHA. Fetch origin again; require `origin/main` to be an ancestor of this commit, and `main` and the tag to point to this commit. If main advanced incompatibly, stop; do not force push, rebase or retag to hide it.

## 5. Publish the checked bytes

Write short Chinese user-facing release notes to a local file, covering actual changes, version/build, Apple Silicon/macOS 26 requirements and DMG installation instructions. Keep the internal recovery record separate. Do not expose local paths, credentials or notarization logs in the notes.

```sh
git push --atomic origin main "refs/tags/$tag"
gh release create "$tag" --repo "$repo" --verify-tag --draft --title "InkFlow $version" --notes-file "$notes_file"
gh release upload "$tag" "$dmg" "$release_dir/SHA256SUMS" --repo "$repo"
```

Download both draft assets to a fresh temporary directory using `gh release download`. Compare them byte-for-byte with the local files and run `shasum -a 256 -c SHA256SUMS` there. Only then publish:

```sh
gh release edit "$tag" --repo "$repo" --draft=false --latest
gh release view "$tag" --repo "$repo" --json url,isDraft,tagName,assets
```

Verify `isDraft` is false, both assets exist, and `git ls-remote origin` resolves the remote annotated tag's peeled commit to the recorded release SHA. A private repository still requires GitHub access; do not change repository visibility. Return the Release URL, version/build, artifact name and concise verification status, then stop.

## Recovery

Stop on the first failed gate and report the last successful step, version/build, commit/tag, output path and submission ID where available. Keep the failed attempt's files and logs; do not bump again just to retry.

- Before commit: preserve the plist change and reuse the same version. Rerun only invalidated checks. `package.sh` refuses an existing output directory; move a failed package directory to a unique backup only after identifying its state. If only notarization or stapling failed, reuse the same DMG instead of packaging again.
- After commit/tag: verify they match the recorded source and package before resuming. Do not create duplicate commits or move tags.
- After an uncertain push/create/upload/publish response: inspect remote state first. Reuse a matching draft and upload only missing assets. A mismatching existing asset or tag is a blocker; do not use `--clobber` or overwrite a published version. If already published and identical, report success.
- If source/artifact provenance cannot be recovered, stop and explain the gap instead of certifying old bytes. Never silently omit full verification or notarization.

## Primary command references

- [SemVer](https://semver.org/)
- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow); installed `xcrun notarytool --help`, `xcrun stapler --help`, `hdiutil create -help`.
- GitHub CLI [create](https://cli.github.com/manual/gh_release_create), [upload](https://cli.github.com/manual/gh_release_upload), [edit](https://cli.github.com/manual/gh_release_edit).
