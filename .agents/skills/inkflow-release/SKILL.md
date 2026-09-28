---
name: inkflow-release
description: Execute or resume an InkFlow macOS release end to end from a clean main candidate through verification, Developer ID signing, notarization, upload, and public GitHub Release. A release request naming a semantic version or bump type authorizes the whole workflow without repeated stage confirmation; not for routine local installation.
---

# InkFlow release

Deliver a public GitHub Release with a signed/notarized Installer DMG, legacy SHA-256 checksum, Sparkle-signed app-only ZIP and `appcast.xml`, from `main` with an annotated `vX.Y.Z` tag. Do not maintain a release branch.

## Authorization and hard boundaries

A direct release request naming a semantic version or `major`/`minor`/`patch` durably authorizes that release end to end in the verified `origin`: version update/commit, verification, signing, packaging, both Apple submissions, polling, stapling, tag and atomic main/tag push, draft/assets, downloaded-byte verification and publication. Generated paths, names and submission IDs are included. Skill inspection/editing alone authorizes no release; honor narrower instructions.

Proceed through successful stages without repeated conversational confirmation or separate approvals for runner internals. Pending notarization means wait and poll at reasonable intervals in this task, not hand off. Execute sequentially in the current task; never delegate release execution or split mutations across agents.

Request required narrow sandbox/signing/Keychain/network elevation for the command being run. After prepare, the `continue` command below is the single stable outer execution/approval boundary. Do not first ask the same question in chat. After approval, continue directly; unavoidable host/Keychain prompts still require the user to satisfy them.

- Never install or register the input method on the publisher's behalf, create credentials automatically, expose secrets, force-update history, overwrite remote state or change repository visibility.
- Never overwrite an existing tag, Release or asset. Only matching retained state may be reused through the runner; conflicts stop execution.
- Unknown remote submission state is fail-closed. A lost response with zero history matches is **unknown**, not failure; multiple matches are ambiguous. Never automatically resubmit, delete an intent to unlock retry, or use elapsed time as retry permission. `retry-notary` is a scoped exception requiring the recovery reference and authorization covering that uncertainty.
- Preserve failed attempts, receipts and logs until explicitly authorized cleanup. Do not bump again just to retry or rebuild after prepare.

## Read only when needed

| Trigger | Required reading before acting |
| --- | --- |
| Setup, authentication-mode change, missing/invalid credentials, sandbox/Keychain diagnosis, unattended acceptance | [configuration.md](references/configuration.md) |
| Failure/interruption, existing tag/Release/output, uncertain submission, stale lock, any retry-notary decision | [recovery.md](references/recovery.md) |
| Writing/freezing public release notes | [public-notes.md](references/public-notes.md) |
| External command/API compatibility question | [command-references.md](references/command-references.md) |

Run from the release worktree root. Read `macOS/DEVELOPMENT.md` for verification requirements and use `$apple-signing-workflow` for certificate selection/artifact verification. Helpers below are under `.agents/skills/inkflow-release/scripts/`.

## 1. Preflight and version commit

1. Verify clean `main`, no merge/rebase, worktree state, intended `origin` (`git remote get-url origin`, `gh repo view`) and account (`gh auth status`). Set `repo` to verified `OWNER/REPO`; use `--repo "$repo"` for release commands. Fetch with `git fetch origin --tags`; stop on divergence/conflicting tags, fast-forward behind-only main, review ahead commits.
2. Create an isolated detached linked worktree at that main commit under the main checkout's ignored `.worktrees/`. Build, verify, package and tag there. Do not switch another worktree's branch, stash or reset. Supply its existing ignored `.release.local.plist` or explicit `INKFLOW_RELEASE_CONFIG`; read configuration guidance before setup/change.
3. Run `bash .agents/skills/inkflow-release/scripts/check-credentials.sh` before bump/build. Require Developer ID Application, exact certificate subject OU `T7976FL2LP` and configured Apple authentication. Missing/invalid credentials block packaging, not inspection; prepare repeats the checks.
4. Read version/build from `macOS/Info.plist`. An explicit version or bump is final; ask 大版本升级 / 新增功能 / Bugfix only if neither was supplied. Match a target to the next major/minor/patch result; otherwise route a retained attempt to recovery or stop on mismatch. Major resets minor/patch, minor resets patch, patch increments alone; never infer 1.0 graduation. The source build increments independently once.
5. Record the previous published stable tag as `previous_tag`, verify its ancestry, and check the proposed tag/Release locally and remotely **before editing**. Existing state requires recovery, not a new bump.
6. Run `bash .agents/skills/inkflow-release/scripts/bump-version.sh TYPE`; review the diff. Derive `version`, provisional `build`, and `tag="v$version"` from the plist. Record starting commit/version/build and subsequent results in ignored `build/release-notes.md`. Commit only `macOS/Info.plist` as `chore(release): $tag (build $build)`; retain the clean detached `release_commit`. Never amend it after verification; notes are not a second version source.

## 2. Verify once and retain evidence

```sh
bash macOS/scripts/release-verification.sh --from "$previous_tag"
```

The sole verification entry builds the clean isolated candidate, runs `test.sh all` once (including Installer fixtures), one deep bundle check and change-selected release-helper fixtures, and freezes Installer executable/icon receipts. Do not separately repeat core/deep/package fixtures. GUI, Keychain-adapter and paid-live suites are never automatic; GUI scripts are explicit diagnostics only.

Input/Settings interaction is preaccepted at release entry: do not ask again, mark it pending or gate publication on it. Hand off only selected installation/upgrade checks with operations and expected outcomes; missing manual results are pending. Build, notarization and draft preparation may proceed meanwhile.

Confirm the semantic version. Each `build.sh` allocates a fresh build above the source floor without changing tracked source. Replace provisional `build` with `appBuild` from `build/release-verification/installer.plist`; record it and include the full `bash macOS/scripts/build-summary.sh APP` table after each successful build. Retain the root verification receipt through packaging/recovery. Build success proves neither installation, launch nor notarization.

## 3. Prepare and freeze public notes

```sh
bash .agents/skills/inkflow-release/scripts/package.sh prepare
```

Prepare checks the bundle, signs a copy in nested order at `build/releases/InkFlow-X.Y.Z-BUILD/payload/InkFlow.app`, retains `inputmethod-submission.zip` and refuses an existing output directory. It does not submit, install, register or publish. Packaging uses the verified artifact build and repeatable fast structural checks.

Read [public-notes.md](references/public-notes.md), write/review Chinese `build/public-release-notes.md`, and freeze it before continuing. Keep internal recovery/acceptance data in `build/release-notes.md`; never publish it. The public-note digest is immutable during recovery.

## 4. Continue through publication

```sh
bash .agents/skills/inkflow-release/scripts/release-runner.sh continue
```

This is the only normal post-prepare outer command. It notarizes/staples payload and DMG, assembles/verifies Installer DMG and app-only ZIP, generates/validates EdDSA appcast and checksum, tags/atomically pushes, creates/reuses the draft, uploads all assets, downloads for byte comparison and publishes. It uses locked Sparkle `generate_appcast` and its configured local Keychain account, without deltas. Signing, notarization, Gatekeeper and downloaded checks apply to the release bytes. Never replay internal stages or separately upload/publish. After interruption, read recovery, resolve the cause, then rerun this command to reuse matching completed stages.

If change-based installation/upgrade acceptance is required, the runner stops before publication until the user's explicit pass is recorded as one line in internal notes:

```text
Release-Installation-Acceptance: version=... build=... releaseCommit=... dmgSHA256=... scope=installation-upgrade result=pass
```

Use the runner's exact identity/hash and the user's actual result. Reuse only while delivery behavior and artifact bytes are unchanged; otherwise renew manual acceptance. Automation never proves this result or authorizes installation.

## Stop conditions and completion

Stop at the first failed gate: missing version decision; unverified repo/account/destination; divergent main; invalid credentials; verification/notarization failure; uncertain provenance or remote state; tag/Release/asset conflict; missing required installation result **at publication**; denied elevation, narrower instruction or any action beyond authorization. Report the last successful stage, version/build, commit/tag, output path and submission ID when available; read recovery before retrying. Never omit required verification or notarization. Ordinary stage transitions and recoverable retained submissions add no confirmation gates.

On success, report Release URL, artifact version/build/name and concise verification status, then stop.
