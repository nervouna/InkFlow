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

## CI decisions

On Linux, the shared-core boundary check dumps the root Swift manifest and checks it against the standalone Core
manifest. Manifest evaluation avoids resolving Sparkle. The root products need the macOS SDK, CryptoKit, AppKit,
InputMethodKit, the Sparkle framework and macOS librime. The dictionary job pairs the Rust checks with frozen Swift
fixtures. The [Fcitx5 job](../Linux/fcitx5/README.md#continuous-integration) reuses the ABI test's debug archive.

The PR workflow always decides whether to run the two required macOS jobs. It skips them for docs-only changes,
which lets GitHub satisfy the required checks without allocating a Mac. The quick group builds and exercises the root
products. The parallel portable group checks the source-built native runtime, production-resource parity and the
Swift link. The full suite is a release step. The jobs use the same pinned CMake and Ninja versions as Linux.
GitHub-hosted macOS runners need the pipx bin directory added to the Actions path.

The native cache retains dependencies, librime and the Cargo target directory. Prepared-resource directories are
per-run. The resource cache keys follow the pinned dependencies and the preparation recipe. Resource inputs are
verified by SHA-256, so stale caches can require a download or rebuild.
