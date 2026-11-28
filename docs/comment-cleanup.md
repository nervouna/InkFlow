# Code comment cleanup

Put code decisions and cross-language contracts in the closest maintained project documentation.
Use GitHub issues to track shortcuts that leave a defect. Delete comments that repeat the code or describe
superseded behavior.

## Lint and inventory

From the repository root, install the pinned parsers in a Python virtual environment.

```sh
python3 -m venv build/comment-lint
build/comment-lint/bin/python -m pip install -r scripts/comment-lint-requirements.txt
build/comment-lint/bin/python -B scripts/comment-lint.py --base origin/main
build/comment-lint/bin/python -B scripts/comment-lint.py --inventory
build/comment-lint/bin/python -B scripts/tests/test_comment_lint.py
```

The existing **Script and frontend helper tests** check runs the lint. It compares the checked-out result
with the PR's base commit, or with the previous revision for a push. Existing comments are matched by text
and occurrence count within a file, including renames Git detects. A new comment, edited comment or new copy
fails with its path and line. Removing a comment needs no allowlist edit. Running without either flag rejects
all comments in covered files and is suitable when the backlog is gone.

The inventory lists the comment text, source path and line span. The parser covers C, C++, Objective-C,
Swift, Rust, Bash, Python, Lua, CMake, YAML, TOML, HTML, XML and the repository's related configuration formats.
It also reads Bash in literal GitHub Actions `run` blocks and the comment-delimited portion of Rime dictionary
tables. Quoted values, shell heredoc data and markup payloads retain their contents. Keep interpreter
shebangs, SwiftPM tools versions, recognized tool directives, and Rime's `# no comment` switch.
Generated lockfiles, dictionary data, standalone license material, documentation and ignored build output
are outside this inventory.
