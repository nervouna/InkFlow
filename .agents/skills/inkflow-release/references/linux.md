# Linux release

Read before publishing a Linux release. It builds and drafts `linux-vX.Y.Z` independently of the macOS version.
Publishing is a user-authorized maintainer step like the macOS one in [SKILL.md](../SKILL.md).

1. **Draft.** Run **Linux Release** in GitHub Actions on `main` and enter an independent `X.Y.Z` version. The native
   ARM64 runner builds against the Omarchy ARM stable mirror, checks both archives, loads the extracted addon on a
   private D-Bus, and exercises install, upgrade, rollback and uninstall. A successful run links its GitHub Release
   draft in the run summary, with the publish command. The CI container uses Arch4Edu's import of the upstream generic
   Arch Linux ARM rootfs. On upload failure, rerun the failed job to resume with the same verified artifact. The job
   keeps completed uploads and clears an empty GitHub starter asset before retrying it.
2. **Check.** For input-path changes, compare the previous published package and the draft on the same target using
   the [frontend latency probe](../../../../Linux/fcitx5/README.md#frontend-latency). While signed in, open the draft
   and follow its install instructions on an ARM64 Omarchy/Hyprland machine. Check that selecting InkFlow Pinyin and
   committing a candidate work.
3. **Publish without Latest.** After confirming the install, run
   `gh release edit linux-vX.Y.Z --draft=false --latest=false`, the command the run summary prints. In the web editor,
   leave **Set as the latest release** unchecked. The Linux updater discovers the published Linux tag.
4. **Check Latest.** `gh api repos/nervouna/InkFlow/releases/latest --jq .tag_name` must start with `v`.

A Linux release that becomes Latest breaks the macOS Sparkle feed, `releases/latest/download/appcast.xml`, which
resolves through Latest. It did from 2026-11-20 to 11-28. Restore it with `gh release edit v<stable> --latest`, using the
newest stable macOS tag. A macOS release published with `--prerelease` does not restore Latest.
`release.sh` checks Latest before tagging and after publishing and prints this command when it fails.
