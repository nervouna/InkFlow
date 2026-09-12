---
name: inkflow-release
description: Execute or resume an InkFlow macOS release end to end from a clean main candidate through verification, Developer ID signing, notarization, upload, and public GitHub Release. A release request naming a semantic version or bump type authorizes the whole workflow without repeated stage confirmation; not for routine local installation.
---

# InkFlow release

Deliver a public GitHub Release containing a signed, notarized DMG and SHA-256 checksum. Use `main` and an annotated `vX.Y.Z` tag; do not maintain a `release` branch.

## Release command contract

A direct request such as “发布 v0.4.0”, “发布 patch 版本” or “把 v0.4.0 发出去” is one durable authorization to complete that release end to end. It covers updating and committing the version, running verification, signing and packaging, submitting both generated artifacts to Apple, polling their existing submission IDs until a terminal result, stapling and verifying them, creating and pushing the annotated tag with `main`, creating and populating the GitHub Release in the verified repository, downloading its assets for verification, and publishing it after every gate passes. Exact generated paths, artifact names and submission IDs are covered even though they do not exist when the request is made.

Once this contract is active, continue directly from each successful stage to the next. Do not stop after a preflight report, version commit, automated verification, package preparation, notarization submission or acceptance, stapling, DMG creation, tag creation, push, draft creation, asset upload, or downloaded-asset verification to ask whether to continue. A pending notarization status is waiting, not a blocker: keep polling at reasonable intervals in the same task. Do not substitute a plan or handoff for execution and do not ask the user to repeat permission already granted by the release command.

This authorization is limited to the named release and the verified `origin`. Merely discussing, inspecting or editing this skill does not authorize a release. Honor narrower user instructions. Do not install or register the input method on the publisher's machine.

Run commands from the repository root. Read `macOS/DEVELOPMENT.md` for the current verification list and use `$apple-signing-workflow` for certificate selection and artifact verification. Helpers live beside this file in `scripts/`.

## Execution ownership and authorization

The current task executes an authorized release or recovery directly and retains its state through completion or a genuine blocker. Do not delegate release execution to a subagent or split mutating release steps across agents. Run state-dependent operations sequentially.

Treat required sandbox, Keychain, signing and network elevation as an execution mechanism within the authorization above, not as a new product decision. Before packaging, submit any required narrow escalation for the exact command being run. After `package.sh prepare`, `bash .agents/skills/inkflow-release/scripts/release-runner.sh continue` is the one stable outer command and the narrow reusable execution/approval boundary for every remaining release stage. Do not request separate tool approvals for its internal notarization, stapling, tag, push, upload or publication operations, and do not first ask the same question in chat. After approval, resume the runner without seeking another conversational confirmation. Host, macOS or Keychain approval prompts may still be unavoidable and cannot be suppressed by this procedure; when one appears, let the user satisfy that system prompt and continue the same runner invocation or rerun its stable command.

Pause only when the version decision is missing; the repository, account or destination cannot be verified; `main` diverges; credentials are missing or invalid; a required verification or notarization gate fails; source or artifact provenance is uncertain; required change-based installation results are missing at publication; an existing tag, Release or asset conflicts; or continuation would require a force update, history rewrite, remote overwrite, repository visibility change, credential creation, installation or another action outside the authorization above. A narrower user instruction or denied elevation also blocks the affected action. Do not convert ordinary stage transitions, recovery of a retained submission, or already authorized uploads into additional confirmation gates.

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
- Read `CFBundleShortVersionString` and `CFBundleVersion` from `macOS/Info.plist` and compute the proposed major/minor/patch results. An explicit target such as `v0.4.0` is already the version decision: match it to the computed bump and proceed without asking the user to choose again. An explicit `major`, `minor` or `patch` request is likewise final. Ask the user to choose 大版本升级 / 新增功能 / Bugfix only when the release request contains neither a semantic target nor a bump type. If an explicit target is not one of the valid next bump results and retained state does not establish a recoverable attempt for that target, stop and explain the mismatch rather than silently choosing another version. Major resets minor and patch; minor resets patch; patch increments alone. Build increments once, independently. Do not infer a 1.0 graduation from a 0.x version.
- Identify and record the previous published stable release tag for release-note generation. Verify it is an ancestor of the proposed release commit.
- Check the proposed tag and Release do not already exist locally or remotely before changing files. Existing release state routes to recovery below, not another version bump.
- Run `bash .agents/skills/inkflow-release/scripts/bump-version.sh TYPE`, where TYPE is the confirmed `major`, `minor` or `patch`. Review the diff. Set `version`, `build`, and `tag="v$version"` from the updated plist, and record the starting commit in `build/release-notes.md` with the selected version/build and subsequent verification results. Stage only `macOS/Info.plist`, commit it as `chore(release): $tag (build $build)`, and record that detached clean commit as `release_commit`. This ignored local record is for recovery, not a second version source. Verification and package receipts bind this commit; do not amend it after verification.

## 2. Verify the release contents

```sh
bash macOS/scripts/release-verification.sh --from "$previous_tag"
```

This is the single release-verification entry. It requires the isolated worktree and clean `release_commit`, builds the application, runs `test.sh all` once (including Installer core and workflow fixtures), and runs one deep bundle check. It conditionally selects release-helper fixtures and prints only the shared impact mapping's change-based installation checklist. GUI, Keychain adapter and paid live suites are never launched automatically; existing GUI scripts remain explicit diagnostic tools. It then freezes the verified Installer executable and icon with a commit/input/artifact receipt for packaging.

Entering this release flow assumes the user has already accepted affected input and Settings interaction. Do not request, record as pending, or block publication on those GUI results. Daily development may still use the shared mapping to hand off input and Settings checks. When installation or delivery changes are affected, hand off the installation/upgrade operations and expected outcomes, and record explicit user confirmation in the existing `build/release-notes.md`, including version/build, tested scope, result and corresponding commit. Missing installation results are pending, not success. Build, automated verification, notarization and draft preparation may continue while they are pending.

Confirm version/build match the selected bump. Do not separately repeat the core profile, deep bundle check, or package fixtures: packaging performs repeatable fast structural checks against the exact candidate. Signing, notarization, Gatekeeper, and downloaded-asset checks still run on the release bytes below. Automated checks do not establish installation or upgrade acceptance when that check is required.

## 3. Prepare the signed package and public notes

```sh
bash .agents/skills/inkflow-release/scripts/package.sh prepare
```

Prepare checks the existing input-method bundle, preserves nested signing order,
and signs a copy at `build/releases/InkFlow-X.Y.Z-BUILD/payload/InkFlow.app`.
It retains `inputmethod-submission.zip` for notarization and refuses an existing
release directory. Prepare does not submit notarization, install, register or
publish. It repeats the credential and public-certificate OU checks, including the
read-only Apple authentication request.

After prepare succeeds, create the final Chinese user-facing notes at
`build/public-release-notes.md`. This file is separate from the internal recovery
and acceptance record at `build/release-notes.md`; never copy internal paths,
credentials, acceptance bookkeeping or notarization logs into the public file.
Use [the template](assets/release-notes-template.md), the release diff, and the
candidate helper's first-parent output from `previous_tag` through
`release_commit` as evidence. Review both its suggested and excluded sections so
a mislabeled commit cannot hide a user-visible change. Consolidate related commits
and rewrite them in user-facing Chinese rather than copying subjects. Use three to
five bullets when the scope supports them, include only observable changes, omit
empty sections, and exclude release, test, documentation, dependency, skill and
repository-maintenance work unless it changes the shipped product.

The GitHub title supplies the version. Keep stable installation and update steps
in the README and link to them instead of repeating them. Add `运行要求` or
`升级提示` only when platform requirements, installation, compatibility, migration
or user-data behavior changed. Do not routinely mention signing, notarization or
checksum commands. End with the README link and the comparison URL from
`previous_tag` through `tag`. Review and freeze `build/public-release-notes.md`
before starting the runner; its digest becomes part of retained release state and
must not change during recovery.

## 4. Continue the release through the runner

After package preparation and immutable public-note review, invoke exactly this
one post-prepare command:

```sh
bash .agents/skills/inkflow-release/scripts/release-runner.sh continue
```

This is the only operative outer command for notarizing and stapling the payload,
finishing and verifying the DMG, notarizing and stapling the DMG, generating its
checksum, tagging and atomically pushing the verified commit, creating or reusing
the draft GitHub Release, uploading and downloading its assets for byte comparison,
and publishing it. Do not invoke those upload or publication operations separately.
The runner retains submission intents, responses, receipts, hashes and release
state, and is resumable and idempotent: after interruption or a recoverable
failure, inspect the retained diagnostic, resolve the cause, and run the same
stable command again. It reuses matching completed stages and refuses ambiguous,
drifted or conflicting state instead of overwriting it or duplicating submissions.

If release verification selected a change-based installation/upgrade check, the
runner may prepare the draft and verified assets but stops before publication until
the user's exact manual result is present as one line in internal
`build/release-notes.md`:

```text
Release-Installation-Acceptance: version=... build=... releaseCommit=... dmgSHA256=... scope=installation-upgrade result=pass
```

Use the exact version, build, release commit and DMG SHA-256 printed by the runner.
Missing evidence is pending, not success. Reuse it only while delivery behavior and
artifact bytes remain unchanged; otherwise require renewed manual acceptance and
rerun the same `continue` command. Input and Settings interaction remain preaccepted
at release entry and are not publication gates. Automated checks do not establish
installation acceptance, and the workflow must never install or register InkFlow
on the publisher's behalf.

On success, report the Release URL, version/build, artifact name and concise
verification status, then stop.

## Recovery

Stop on the first failed gate and report the last successful step, version/build, commit/tag, output path and submission ID where available. Keep the failed attempt's files and logs; do not bump again just to retry.

- Before the release commit: preserve the plist change and reuse the same version; do not package uncommitted bytes.
- After the release commit but before a successful prepare: verify it matches the recorded source and package inputs before retrying. `package.sh prepare` refuses an existing output directory. If prepare failed before a usable submission ZIP, inspect and move that failed directory to a unique backup before retrying the same version.
- After prepare: do not manually replay internal stages. Retain the ZIP, app, submission state, assemblies, DMG, tag and draft, then rerun only the stable `release-runner.sh continue` command. A process crash may leave an ownership lock; establish that no runner or packager is active before removing only the proven stale lock. The runner recovers a uniquely identifiable lost submission, reuses matching remote state and missing assets, and blocks ambiguous submissions, mismatching assets/tags or drifted notes instead of resubmitting, clobbering or overwriting a published version.
- If source/artifact provenance cannot be recovered, stop and explain the gap instead of certifying old bytes. Never silently omit required release verification or notarization.

## Primary command references

- [SemVer](https://semver.org/)
- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow); installed `xcrun notarytool --help`, `xcrun stapler --help`, `hdiutil create -help`.
- GitHub CLI [create](https://cli.github.com/manual/gh_release_create), [upload](https://cli.github.com/manual/gh_release_upload), [edit](https://cli.github.com/manual/gh_release_edit).
