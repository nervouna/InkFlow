# Public release notes

Read before writing or freezing public notes.

After prepare succeeds, create the final Chinese user-facing notes at
`build/public-release-notes.md`. This file is separate from the internal recovery
and acceptance record at `build/release-notes.md`; never copy internal paths,
credentials, acceptance bookkeeping or notarization logs into the public file.
Use [the template](../assets/release-notes-template.md), the release diff, and the
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
