---
name: inkflow-release
description: Publish an InkFlow macOS release from a clean main candidate with conditional verification, Developer ID signing, notarization, and a downloadable GitHub Release DMG. Also use to resume an interrupted release; not for routine local installation.
---

# InkFlow release

Deliver a public GitHub Release containing a signed, notarized DMG and SHA-256 checksum. Use `main` and an annotated `vX.Y.Z` tag; do not maintain a `release` branch.

A request to execute this release workflow with a confirmed semantic version or bump type is durable authorization for that release's normal end-to-end operations: update and commit the version, create and push the annotated tag with `main`, upload the generated input-method submission ZIP and final DMG to Apple's notarization service, create and populate the GitHub Release in the verified repository, download its assets for verification, and publish it after every gate passes. Exact generated artifact names and submission IDs are covered by this authorization even when they do not exist at request time. Do not ask for renewed authorization at each stage. Merely discussing, inspecting or editing this skill does not authorize a release. Honor narrower user instructions. Do not install or register the input method on the publisher's machine.

Run commands from the repository root. Read `macOS/DEVELOPMENT.md` for the current verification list and use `$apple-signing-workflow` for certificate selection and artifact verification. Helpers live beside this file in `scripts/`.

## Execution ownership and authorization

The current task executes an authorized release or recovery directly and retains its state through completion or a genuine blocker. Do not delegate release execution to a subagent or split mutating release steps across agents. Run state-dependent operations sequentially.

Treat required sandbox, Keychain, signing and network elevation as an execution mechanism within the authorization above, not as a new product decision. When the environment requires approval, submit the narrow tool escalation directly with the specific command, artifact and destination; do not first ask the same question in chat. Reuse an already approved narrow command prefix when available, and group only operations whose scope and failure state remain clear. An unavoidable host or macOS permission prompt may still require user action.

Pause only when the version decision is missing; the repository, account or destination cannot be verified; `main` diverges; credentials are missing or invalid; a required verification or notarization gate fails; source or artifact provenance is uncertain; an existing tag, Release or asset conflicts; or continuation would require a force update, history rewrite, remote overwrite, repository visibility change, credential creation, installation or another action outside the authorization above. A narrower user instruction or denied elevation also blocks the affected action. Do not convert ordinary stage transitions, recovery of a retained submission, or already authorized uploads into additional confirmation gates.

## Local configuration

The helpers read `.release.local.plist` at the current checkout's repository root, independent of the caller's working directory. The legacy profile configuration uses `INKFLOW_SIGN_IDENTITY` (verified certificate SHA-1) and `INKFLOW_NOTARY_PROFILE` (existing notarytool Keychain profile name). For first-time setup, verify the local path is ignored and untracked, use the [profile template](assets/release.example.plist) or [API-key template](assets/release-api-key.example.plist), and replace placeholders with verified references; preserve unrelated existing configuration. Do not commit the local file or create new Apple credentials automatically. Each worktree needs its own ignored file, or an explicit `INKFLOW_RELEASE_CONFIG` path to an existing local configuration.

For unattended notarization, set `INKFLOW_NOTARY_AUTH` to `api-key`, `INKFLOW_NOTARY_KEY_FILE` to an existing owner-readable-only `.p8` file, and `INKFLOW_NOTARY_KEY_ID` to its Key ID. `INKFLOW_NOTARY_KEY_TYPE` defaults to `team`, which requires `INKFLOW_NOTARY_ISSUER`; set it to `individual` and omit the issuer for an Individual Key. Relative key paths resolve beside the configuration file. Store only the path and identifiers in the plist, never the private key bytes. Before storing any key inside a repository, require it to be ignored and untracked. Do not export a key from the existing Keychain or create credentials automatically.

The default `INKFLOW_NOTARY_AUTH=keychain` retains the existing profile behavior; only `api-key` removes the notarization dependency on Keychain access. API-key mode never falls back to the profile. Environment variables override file values. Explicitly empty required fields fail validation; empty optional mode/type selects its documented default. `INKFLOW_RELEASE_CONFIG` optionally selects another plist for testing. The loader parses data with `plutil`; it never sources the configuration as shell code.

`notary.sh` closes stdin and rejects authentication flags in its arguments; configure authentication through the plist/environment. It can run without a signing identity for standalone notarization checks. `check-credentials.sh` uses the same wrapper for its authentication request. Validate API-key authentication with `notary.sh history` and a known submission's `info` before submitting. For unattended acceptance, run these after the user locks the screen, then submit a test artifact, retain its Submission ID, and verify acceptance/stapling without unlocking. An unlocked test alone is not locked-session acceptance. Developer ID signing remains a separate Keychain concern.

Use the elevation policy above for Keychain/signing/network checks if the agent sandbox blocks access; an empty sandbox identity list is not proof that the host lacks certificates. Never dump credentials to diagnose authentication. Configuration loading is local; `check-credentials.sh` performs a read-only Apple authentication request. The `notary.sh` wrapper loads the same configuration for every submit/info/log/history call.

## 1. Preflight and version confirmation

- Inspect worktrees and require a clean `main` with no merge/rebase in progress. Create an isolated linked worktree at that commit using detached HEAD; do not switch another worktree's branch, stash changes, reset history, or maintain a release branch. Run build, verification, packaging, and tagging in this isolated worktree.
- Verify `origin` identifies the intended GitHub repository using `git remote get-url origin` and `gh repo view`. Set `repo` to that verified `OWNER/REPO` and use `--repo "$repo"` on all release commands. Check `gh auth status`, then `git fetch origin --tags`. Stop on divergent history or conflicting tags. Fast-forward a behind-only `main`; local commits ahead of origin are part of the release and must be reviewed.
- Run `bash .agents/skills/inkflow-release/scripts/check-credentials.sh` before the version bump/build. It validates the configured Developer ID Application identity, the exact certificate's subject OU `T7976FL2LP`, and Apple authentication through the configured Keychain profile. Packaging repeats this check before creating output. Missing/invalid credentials block packaging, not inspection.
- Read `CFBundleShortVersionString` and `CFBundleVersion` from `macOS/Info.plist`. Show the current values and proposed major/minor/patch results; ask the user to choose 大版本升级 / 新增功能 / Bugfix. Reuse an explicit choice in this release request. Major resets minor and patch; minor resets patch; patch increments alone. Build increments once, independently. Do not infer a 1.0 graduation from a 0.x version.
- Identify and record the previous published stable release tag for release-note generation. Verify it is an ancestor of the proposed release commit.
- Check the proposed tag and Release do not already exist locally or remotely before changing files. Existing release state routes to recovery below, not another version bump.
- Run `bash .agents/skills/inkflow-release/scripts/bump-version.sh TYPE`, where TYPE is the confirmed `major`, `minor` or `patch`. Review the diff. Set `version`, `build`, and `tag="v$version"` from the updated plist, and record the starting commit in `build/release-notes.md` with the selected version/build and subsequent verification results. Stage only `macOS/Info.plist`, commit it as `chore(release): $tag (build $build)`, and record that detached clean commit as `release_commit`. This ignored local record is for recovery, not a second version source. Verification and package receipts bind this commit; do not amend it after verification.

## 2. Verify the release contents

```sh
bash macOS/scripts/release-verification.sh --from "$previous_tag"
```

This is the single release-verification entry. It requires the isolated worktree and clean `release_commit`, builds the application, runs the complete non-GUI core profile once, and runs one deep bundle check. From the previous stable tag to `HEAD`, it conditionally selects Settings/candidate/controller GUI, Installer core/window, and release-helper/package fixtures. Triggered GUI checks require a logged-in, unlocked desktop; do not replace missing evidence with an unrelated prior log. It then freezes the verified Installer executable and icon with a commit/input/artifact receipt for packaging.

Confirm version/build match the selected bump. Do not separately repeat the core profile, deep bundle check, or package fixtures: packaging performs repeatable fast structural checks against the exact candidate. Signing, notarization, Gatekeeper, and downloaded-asset checks still run on the release bytes below. Automated checks do not establish real installed-IME typing acceptance; report that separately as user-owned.

## 3. Sign, package and notarize

```sh
bash .agents/skills/inkflow-release/scripts/package.sh prepare
```

Prepare checks the existing input-method bundle, preserves nested signing order,
and signs a copy at `build/releases/InkFlow-X.Y.Z-BUILD/payload/InkFlow.app`.
It retains `inputmethod-submission.zip` for the first notarization. It refuses an
existing release directory. Set `release_dir` to this directory, `payload_app` to
`"$release_dir/payload/InkFlow.app"`, and `dmg` to
`"$release_dir/InkFlow-$version-$build-arm64.dmg"`.
Neither packaging phase submits notarization, installs, registers or publishes.
Both retain the existing credential/public certificate OU validation, including
the read-only Apple authentication request. All submissions are explicit below.

```sh
(set -C; bash .agents/skills/inkflow-release/scripts/notary.sh submit "$release_dir/inputmethod-submission.zip" --no-wait --output-format plist > "$release_dir/payload-submission.plist")
```

Read and retain the submission `id`. Poll
`bash .agents/skills/inkflow-release/scripts/notary.sh info "$submission_id" --output-format plist`
at reasonable intervals. Only `Accepted` permits continuation; on `Invalid`, use
the wrapper's `log` command and stop for diagnosis. After a network failure or
interruption, inspect the retained response and query the existing ID before
resubmitting; use wrapper `history` if the submission response was lost. Never
blindly overwrite a response or create a duplicate submission.

```sh
xcrun stapler staple "$payload_app"
xcrun stapler validate "$payload_app"
bash .agents/skills/inkflow-release/scripts/package.sh finish
```

Finish requires the stapled input method, matching source plist, Developer ID team
`T7976FL2LP`, strict signature, and the existing inner bundle checks. It creates a
fresh ZIP containing the stapled app as a signed data resource, then assembles and
signs `assembly.XXXXXX/stage/InkFlow Installer.app` from the verified executable and icon. It checks installer arm64 and
system-only dynamic dependencies, outer identity/version/signature and executes
the installer's actual `--check-payload` extraction/structure probe before creating
the final DMG. The probe reports payload version/build; it does not validate trust.
Signature and notarization checks above remain required.
The DMG contains only `InkFlow Installer.app` and `安装说明.txt`. Assembly directories
remain inspectable. Version/build come from `macOS/Info.plist`; finish never bumps
or re-signs the inner payload. This DMG still needs its own notarization:

```sh
(set -C; bash .agents/skills/inkflow-release/scripts/notary.sh submit "$dmg" --no-wait --output-format plist > "$release_dir/submission.plist")
```

Retain this separate submission ID and poll it to `Accepted` as above, then:

```sh
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
hdiutil verify "$dmg"
```

Mount the final DMG read-only with `hdiutil attach -readonly -nobrowse`, retaining
the returned mount point. Check its `InkFlow Installer.app` using
`codesign --verify --deep --strict`, verify Developer ID authority/team, bundle ID
`io.damao.inkflow.installer` and version/build against the source plist, and run
`spctl --assess --type execute --verbose=2` on the mounted installer. Run its
`Contents/MacOS/InkFlowInstaller --check-payload` again. Confirm only the installer
and `安装说明.txt` appear at the volume root. Detach even if a check fails.

For independent inner ticket verification, use `ditto -x -k` to extract the mounted
installer's `Contents/Resources/Payload/InkFlow.zip` into a fresh temporary directory.
Check that extracted `InkFlow.app` with `codesign --verify --deep --strict`,
`xcrun stapler validate` and `spctl --assess --type execute --verbose=2`; verify its
input-method bundle ID, team and version/build as well. Remove only this owned
extraction after checking. These commands do not install or establish typing
acceptance. Record downloaded/quarantined launch and isolated clean-user/upgrade
acceptance separately, as required in `macOS/DEVELOPMENT.md`.

After stapling and verification, generate `SHA256SUMS` inside `release_dir` with `shasum -a 256` using the DMG basename. Freeze these bytes for upload; do not rebuild/re-sign after this point.

## 4. Tag the verified commit

Review `git diff`, `git diff --cached` and `git status`; the isolated worktree and index must still be clean at `release_commit`. Recheck the built plist and package receipt match it. Do not amend the verified commit or sweep unrelated changes into the release.

```sh
git tag -a "$tag" -m "InkFlow $version (build $build)"
```

Before tagging, require the clean worktree and recorded commit match. Fetch origin again; require `origin/main` to be an ancestor of `release_commit`, and the tag to point to that commit. If main advanced incompatibly, stop; do not force push, rebase or retag to hide it.

## 5. Publish the checked bytes

Create short Chinese user-facing release notes from [the template](assets/release-notes-template.md). Generate an internal candidate list from the release's first-parent history:

```sh
bash .agents/skills/inkflow-release/scripts/release-note-candidates.sh "$previous_tag" "$tag"
```

Treat this output as evidence to review, not text to publish. Inspect both sections and the release diff so a mislabeled commit cannot hide a user-visible change. Consolidate duplicate or related commits and rewrite them in user-facing Chinese; never copy raw commit subjects mechanically. Publish three to five bullets when the scope supports them, include only observable changes, and omit empty sections. Exclude internal release, test, documentation, dependency, skill and repository-maintenance work unless it materially changes the shipped product.

The GitHub title already supplies the version. Keep stable installation and update steps in the README and link to them instead of repeating them. Add `运行要求` or an `升级提示` section only when platform requirements, installation, compatibility, migration or user-data behavior changed. Do not routinely mention signing, notarization or checksum commands in the notes; the verified assets and `SHA256SUMS` carry that evidence. End with the README link and `https://github.com/$repo/compare/$previous_tag...$tag`. Keep the internal recovery record separate. Do not expose local paths, credentials or notarization logs in the notes.

```sh
git push --atomic origin "$release_commit:refs/heads/main" "refs/tags/$tag"
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

- Before the release commit: preserve the plist change and reuse the same version; do not package uncommitted bytes.
- After the release commit: verify it matches the recorded source and package before resuming. Rerun only invalidated checks. `package.sh prepare` refuses an existing output directory. If prepare failed before a usable submission ZIP, inspect and move that failed directory to a unique backup before retrying the same version. After payload submission, retain the ZIP/app and resume its existing ID, then staple the app and run `finish`. A failed finish leaves a unique `assembly.XXXXXX`; rerun finish after resolving the failure, without deleting earlier assemblies. A process crash may leave `finishing/`: establish that no packager is running before removing this empty lock. Finish refuses any existing final DMG, including unknown output. If only final notarization or stapling failed, reuse the same DMG and submission ID instead of packaging again. Do not create duplicate commits or move tags.
- After an uncertain push/create/upload/publish response: inspect remote state first. Reuse a matching draft and upload only missing assets. A mismatching existing asset or tag is a blocker; do not use `--clobber` or overwrite a published version. If already published and identical, report success.
- If source/artifact provenance cannot be recovered, stop and explain the gap instead of certifying old bytes. Never silently omit required release verification or notarization.

## Primary command references

- [SemVer](https://semver.org/)
- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow); installed `xcrun notarytool --help`, `xcrun stapler --help`, `hdiutil create -help`.
- GitHub CLI [create](https://cli.github.com/manual/gh_release_create), [upload](https://cli.github.com/manual/gh_release_upload), [edit](https://cli.github.com/manual/gh_release_edit).
