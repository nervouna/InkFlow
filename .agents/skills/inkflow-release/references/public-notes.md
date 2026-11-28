# Public release notes

Read before writing or freezing public notes.

Write the Chinese user-facing notes to `build/public-release-notes.md` after local preparation or before
dispatching a publishing run in GitHub Actions. Never include internal paths, credentials or
notarization logs.
Use [the template](../assets/release-notes-template.md), the release diff, and the
[release-note candidate script](../scripts/release-note-candidates.sh) as evidence. Run from the repository root.

```sh
bash .agents/skills/inkflow-release/scripts/release-note-candidates.sh "$previous_tag" "$release_ref"
```

Set `previous_tag` to the previous release tag and `release_ref` to the local release commit or
`origin/main` for GitHub Actions. Review both suggested and excluded commits for user-visible changes. Consolidate related commits
and rewrite them in user-facing Chinese rather than copying subjects. Use three to
five bullets when the scope supports them, include only observable changes, omit
empty sections, and exclude release, test, documentation, dependency, skill and
repository-maintenance work unless it changes the shipped product.

The `### 更新内容` bullets are required: `package.sh finish` fails without them. They fill the installer's welcome
page under `X.Y.Z 更新内容`, and links there show as plain text, so each bullet must read on its own. Packaging
freezes the notes into the `.pkg` (see [recovery](recovery.md)).

The GitHub title supplies the version. Keep stable installation and update steps
in the README and link to them instead of repeating them. Add `运行要求` or
`升级提示` only when platform requirements, installation, compatibility, migration
or user-data behavior changed. Do not routinely mention signing, notarization or
checksum commands. End with the README link and the comparison URL from
`previous_tag` through `tag`.
