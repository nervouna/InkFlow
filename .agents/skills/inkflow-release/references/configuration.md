# Local release configuration

Read before configuring credentials, changing authentication mode, or diagnosing credential/access failures. The authorization and elevation rules in [SKILL.md](../SKILL.md) still apply.


The helpers read `.release.local.plist` at the current checkout's repository root, independent of the caller's working directory. The legacy profile configuration uses `INKFLOW_SIGN_IDENTITY` (SHA-1 of the Developer ID Application certificate), `INKFLOW_INSTALLER_IDENTITY` (SHA-1 of the Developer ID Installer certificate, which signs the `.pkg`) and `INKFLOW_NOTARY_PROFILE` (existing notarytool Keychain profile name). Both certificates need their private keys in the login keychain; `check-credentials.sh` verifies each with `verify-developer-id.sh`. Find the Installer hash with `security find-identity -v` (the `-p codesigning` list omits Installer certificates). `build-pkg.sh` looks up the certificate's common name from this hash because `productbuild --sign` does not accept hashes. For first-time setup, verify the local path is ignored and untracked, use the [profile template](../assets/release.example.plist) or [API-key template](../assets/release-api-key.example.plist), and replace placeholders with verified references; preserve unrelated existing configuration. Do not commit the local file or create new Apple credentials automatically. Each worktree needs its own ignored file, or an explicit `INKFLOW_RELEASE_CONFIG` path to an existing local configuration.

For unattended notarization, set `INKFLOW_NOTARY_AUTH` to `api-key`, `INKFLOW_NOTARY_KEY_FILE` to an existing owner-readable-only `.p8` file, and `INKFLOW_NOTARY_KEY_ID` to its Key ID. `INKFLOW_NOTARY_KEY_TYPE` defaults to `team`, which requires `INKFLOW_NOTARY_ISSUER`; set it to `individual` and omit the issuer for an Individual Key. Relative key paths resolve beside the configuration file. Store only the path and identifiers in the plist, never the private key bytes. Before storing any key inside a repository, require it to be ignored and untracked. Do not export a key from the existing Keychain or create credentials automatically.

The default `INKFLOW_NOTARY_AUTH=keychain` retains the existing profile behavior; only `api-key` removes the notarization dependency on Keychain access. API-key mode never falls back to the profile. Environment variables override file values. Explicitly empty required fields fail validation; empty optional mode/type selects its documented default. `INKFLOW_RELEASE_CONFIG` optionally selects another plist for testing. The loader parses data with `plutil`; it never sources the configuration as shell code.

`notary.sh` closes stdin and rejects authentication flags in its arguments; configure authentication through the plist/environment. It can run without a signing identity for standalone notarization checks. `check-credentials.sh` uses the same wrapper for its authentication request. Validate API-key authentication with `notary.sh history` and a known submission's `info` before submitting. For unattended acceptance, run these after the user locks the screen, then submit a test artifact, retain its Submission ID, and verify acceptance/stapling without unlocking. An unlocked test alone is not locked-session acceptance. Developer ID signing remains a separate Keychain concern.

Use the entrypoint elevation policy for Keychain/signing/network checks if the agent sandbox blocks access; an empty sandbox identity list is not proof that the host lacks certificates. Never dump credentials to diagnose authentication. Configuration loading is local; `check-credentials.sh` performs a read-only Apple authentication request. The `notary.sh` wrapper loads the same configuration for every submit/info/log/history call.

## GitHub Actions release

`.github/workflows/release.yml` sets the same variables from secrets, so it needs no `.release.local.plist`. It imports both `.p12` files into a keychain created for the job (unlocked, first in the search list, partition list set for codesign and productbuild), derives `INKFLOW_SIGN_IDENTITY` and `INKFLOW_INSTALLER_IDENTITY` from it, writes the `.p8` and the Sparkle key to `chmod 600` files in `$RUNNER_TEMP`, uses `INKFLOW_NOTARY_AUTH=api-key`, and deletes the keychain and files in an `always()` step. Derived values are masked; no step prints a secret.

`release-appcast.sh` reads the Sparkle EdDSA private key from the Keychain account `io.damao.inputmethod.inkflow` unless `INKFLOW_SPARKLE_KEY_FILE` names an absolute, owner-only key file (environment only; the plist does not carry it). A key that does not match `SUPublicEDKey` produces no signature, which the appcast check rejects.

Store these secrets in the `release` environment (Settings → Environments; restrict its deployment branches to `main`) or as repository secrets. The user creates and adds them; never create Apple credentials or add secrets automatically. Export from the Mac that holds the credentials.

| Secret | Content |
|---|---|
| `DEVELOPER_ID_APPLICATION_P12` | Base64 of the Developer ID Application certificate and private key exported as `.p12` (`base64 -i application.p12`) |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | That `.p12`'s export password |
| `DEVELOPER_ID_INSTALLER_P12` | Base64 of the Developer ID Installer `.p12` |
| `DEVELOPER_ID_INSTALLER_PASSWORD` | That `.p12`'s export password |
| `NOTARY_API_KEY_P8` | Contents of the App Store Connect API key `.p8` (Developer role or higher) |
| `NOTARY_API_KEY_ID` | Its Key ID |
| `NOTARY_API_ISSUER_ID` | Issuer ID of a team key; leave unset for an individual key |
| `SPARKLE_ED_PRIVATE_KEY` | Contents of the file written by Sparkle's `generate_keys --account io.damao.inputmethod.inkflow -x FILE` |
| `RELEASE_DEPLOY_KEY` | Private half of the write deploy key below |

Create the environment once with `gh api -X PUT repos/nervouna/InkFlow/environments/release`, then set each secret with `gh secret set NAME --env release < FILE` (or `--body` for the IDs) and delete the exported files.

**Pushing to `main`.** The `Main Required Checks` ruleset requires six checks and only admins bypass it, so `GITHUB_TOKEN` cannot push the bump commit. The workflow checks out with a write deploy key, and the ruleset lets deploy keys bypass it. A deploy key is scoped to this repository, does not expire and is not a personal token; a fine-grained admin token would also work but expires and acts as the owner, and a bump PR would wait about an hour for checks and still need a token to trigger them. Tags are not covered by a ruleset; releases use `GITHUB_TOKEN` (`contents: write`). One-time setup:

```bash
ssh-keygen -t ed25519 -N '' -C 'InkFlow release workflow' -f inkflow-release-deploy
gh repo deploy-key add inkflow-release-deploy.pub --allow-write --title 'Release workflow'
gh secret set RELEASE_DEPLOY_KEY --env release < inkflow-release-deploy
rm inkflow-release-deploy inkflow-release-deploy.pub
gh api -X PUT repos/nervouna/InkFlow/rulesets/26946523 --input - <<'JSON'
{"bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"},
  {"actor_id": null, "actor_type": "DeployKey", "bypass_mode": "always"}]}
JSON
```

Check the result with `gh api repos/nervouna/InkFlow/rulesets/26946523 --jq .bypass_actors`. The bypass covers every write deploy key, so keep this the only one. A missing bypass fails the publishing run at the push (`GH013`), before anything is published.

**Build numbers.** A runner has no build counter and `macOS/Info.plist` holds only the floor, so the workflow seeds `build/build-number/last` with the highest build in any release's asset names, drafts included. Sparkle then sees the build increase.

**Dry run.** After adding the secrets, run `gh workflow run release.yml --ref main -f bump=patch -f draft=true` (or Actions → Release → Run workflow). It checks the credentials within minutes, then bumps without pushing, verifies (`test.sh all`), signs, notarizes both artifacts and leaves draft `vX.Y.Z` with placeholder notes; no tag, push or publication. Inspect the draft, then delete it or replace its notes for the publishing run. A failed run uploads the verification log and notarization results as the `release-logs` artifact.
