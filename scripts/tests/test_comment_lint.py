from pathlib import Path
import runpy
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

LINTER = Path(__file__).resolve().parents[1] / "comment-lint.py"
MODULE = runpy.run_path(str(LINTER))
COMMENTS = MODULE["comments"]
COMMENT_ONLY_LINES = MODULE["comment_only_lines"]


class SyntaxTests(unittest.TestCase):
    def test_language_comments_and_literals(self):
        cases = [
            ("Sources/View.swift", b'let s = #"// literal"#\n/* outer /* nested */ end */\n', 2),
            ("src/main.rs", b'let s = r#"/* literal */"#;\n/// doc string\n', 2),
            ("src/main.cpp", b'#include <x>\nconst auto s = R"(// text)"; // trailing\n', 2),
            ("src/main.m", b'#import <x>\nid s = @"// literal"; // trailing\n', 2),
            ("src/tool.py", b'#!/usr/bin/python3\nx = "# literal" # trailing\n', 2),
            ("src/tool.sh", b"#!/bin/bash\ncat <<'EOF'\n# payload\nEOF\necho ${a#b} # trailing\n", 5),
            ("src/filter.lua", b'local s = [[-- literal]]\n--[=[ block ]=]\n', 2),
            ("src/schema.yaml", b'value: "# literal"\n# comment\n', 2),
            ("src/settings.toml", b'value = "# literal"\n# comment\n', 2),
            ("src/Info.plist", b'<?xml version="1.0"?>\n<!-- comment -->\n<plist/>\n', 2),
            ("src/index.html", b'<div title="<!-- literal -->"></div>\n<!-- comment -->\n', 2),
            ("CMakeLists.txt", b'message("# literal")\n#[=[block]=]\n', 2),
        ]
        for path, source, line in cases:
            with self.subTest(path=path):
                self.assertEqual([comment.line for comment in COMMENTS(Path(path), source)], [line])

    def test_directives(self):
        cases = [
            ("Package.swift", b"// swift-tools-version: 6.2\n"),
            ("main.py", b"#!/usr/bin/python3\n# coding: utf-8\npass  # noqa: F401\n"),
            ("macOS/Package/postinstall", b"#!/bin/bash\n# shellcheck disable=SC2086\necho hi\n"),
            ("example.dict.yaml", b"---\nname: test\n...\n# no comment\n# entry\tentry\n"),
        ]
        for path, source in cases:
            with self.subTest(path=path):
                self.assertEqual(COMMENTS(Path(path), source), [])

    def test_workflow_literal_shell(self):
        source = (
            b"run: |\n"
            b"  cat <<'EOF'\n"
            b"  # literal\n"
            b"  EOF\n"
            b"  \n"
            b"  # comment\n"
            b"  echo hello # trailing\n"
            b"env:\n"
            b"  VALUE: |\n"
            b"    # literal\n"
        )
        found = COMMENTS(Path(".github/workflows/ci.yml"), source)
        self.assertEqual([comment.line for comment in found], [6, 7])
        for comment in found:
            self.assertEqual(source[comment.start:comment.end], comment.text)
        self.assertEqual(COMMENT_ONLY_LINES(source, found), 1)

    def test_rime_dictionary_and_line_counts(self):
        source = b'---\nname: "a # b" # tail\n...\n# comment\nentry\tcode\n'
        found = COMMENTS(Path("example.dict.yaml"), source)
        self.assertEqual([comment.line for comment in found], [2, 4])
        self.assertEqual(COMMENT_ONLY_LINES(source, found), 1)
        source = b"/* first\n   second */ int x;\n/* another */ /* comment */\n"
        self.assertEqual(COMMENT_ONLY_LINES(source, COMMENTS(Path("main.c"), source)), 2)


class IncrementalTests(unittest.TestCase):
    def test_baseline_rejects_new_comments_and_allows_cleanup(self):
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)

            def git(*args):
                subprocess.run(["git", *args], cwd=directory, check=True, capture_output=True)

            def lint(*args):
                return subprocess.run(
                    [sys.executable, "-B", str(LINTER), *args], cwd=directory, capture_output=True, text=True,
                )

            git("init", "-q")
            previous = directory / "original.py"
            previous.write_text("x = 1\ny = 2\n# grandfathered\n")
            git("add", "original.py")
            git("-c", "user.name=Lint Test", "-c", "user.email=lint@example.invalid", "commit", "-qm", "baseline")

            self.assertEqual(lint("--base", "HEAD").returncode, 0)
            self.assertEqual(lint().returncode, 1)
            git("mv", "original.py", "renamed.py")
            renamed = directory / "renamed.py"
            renamed.write_text("x = 4\ny = 2\n# grandfathered\n")
            self.assertEqual(lint("--base", "HEAD").returncode, 0)
            renamed.write_text("x = 4\ny = 2\n# grandfathered\n# grandfathered\n")
            (directory / "new.py").write_text("# extra\n")
            result = lint("--base", "HEAD")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("renamed.py:4:", result.stdout)
            self.assertIn("new.py:1:", result.stdout)
            self.assertEqual(len(result.stdout.splitlines()), 2)

            renamed.write_text('x = 4\ny = "# literal"\n')
            (directory / "new.py").write_text("x = 3\n")
            self.assertEqual(lint("--base", "HEAD").returncode, 0)


if __name__ == "__main__":
    unittest.main()
