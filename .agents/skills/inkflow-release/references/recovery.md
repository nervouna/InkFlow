# Release recovery

`release.sh` is resumable: each step checks for its output (stapled app, package, stapled package, appcast, draft assets) and skips it if present. Fix the cause and rerun the same command. Don't bump the version again to retry.

- **Interrupted attempt:** `package.sh prepare` refuses an existing `build/releases/InkFlow-X.Y.Z-BUILD/` left by a broken attempt. Move it aside and rerun prepare.
- **Notarization interrupted mid-upload:** rerun `release.sh`, which resubmits it. A duplicate submission is harmless.
- **Notarization rejected:** read `build/releases/…/payload-notary.plist.details` or `pkg-notary.plist.details`, fix signing/entitlements, then remove the release directory and rerun `package.sh prepare` and `release.sh`.
- **Broken package/ZIP:** delete the `.pkg`, ZIP and appcast from the release directory and rerun `release.sh`; it rebuilds and re-signs the package from the stapled app.
- **Package signer or embedded tool rejected:** `release.sh` stops before notarizing the package. Check that `INKFLOW_INSTALLER_IDENTITY` names the Developer ID Installer certificate and `INKFLOW_SIGN_IDENTITY` the Application one ([configuration.md](configuration.md)), delete the `.pkg` and rerun.
- **Existing draft with stale assets:** `release.sh` re-uploads with `--clobber` and byte-compares the downloads.
- **Tag exists on another commit / origin/main diverged:** stop and ask the user. Never force-push or move a published tag.
- **GitHub Actions run failed before the push:** nothing carries over and `main` is unchanged; fix the cause and run the workflow again. It replaces the draft's assets and keeps its notes.
- **GitHub Actions run failed after the push:** `main` ends on the tagged release commit. Running the workflow again rebuilds that commit and finishes the release without a bump (the `bump` input is ignored).
- **Local release after a CI draft:** the draft's assets carry another build, so `release.sh` stops at its asset check. Delete those assets (`gh release delete-asset`) and rerun.
