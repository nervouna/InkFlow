from pathlib import Path
import runpy
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

LINTER = Path(__file__).resolve().parents[1] / "style-lint.py"
MODULE = runpy.run_path(str(LINTER))
VIOLATIONS = MODULE["violations"]


def rows(path, source):
    return [number for number, _ in VIOLATIONS(Path(path), source)]


class StatementTests(unittest.TestCase):
    def test_multiple_statements_are_flagged(self):
        cases = [
            ("a.swift", b"let a = 1; let b = 2\nlet c = 3\n", [1]),
            ("a.swift", b"func f() { a(); b() }\nfunc g() { a() }\n", [1]),
            ("a.rs", b"fn f() { let a = 1; let b = 2; }\n", [1]),
            ("a.c", b"int f(void) { a(); b(); }\n", [1]),
            ("a.cpp", b"struct S { int a; int b; };\n", [1]),
            ("a.m", b"int a = 1; int b = 2;\n", [1]),
            ("a.py", b"a = 1; b = 2\n", [1]),
            ("a.lua", b"local a = 1; local b = 2\n", [1]),
            ("a.sh", b"a; b\nif x; then y; fi\n{ a; b; }\n", [1, 2, 3]),
        ]
        for path, source, expected in cases:
            with self.subTest(path=path, source=source):
                self.assertEqual(rows(path, source), expected)

    def test_allowed_forms(self):
        cases = [
            ("a.swift", b'let s = "a; b"\nlet t = #"c; d"#\nlet u = 1 // x; y\n'),
            ("a.swift", b"for i in 0..<3 {\n  a()\n}\nswitch x {\ncase 1: a()\ndefault: break\n}\n"),
            ("a.rs", b'let a = [0u8; 4];\nlet b = vec![0; 4];\nlet s = "a; b";\nfn f() { return; }\n'),
            ("a.c", b'for (;;) {\n}\nfor (int i = 0; i < 3; i++) {}\nconst char *s = "a; b";\n'),
            ("a.cpp", b"for (auto &x : xs) {}\nint a = 1; // x; y\n"),
            ("a.py", b"a = 1\nb = 'x; y'  # a; b\nc = 2;\n"),
            ("a.lua", b"local a = 'x; y'\n"),
            ("a.sh", b'if x; then\n  y\nfi\nwhile read l; do\n  :\ndone\ncase $x in\na) b ;;\nesac\n'),
            ("a.sh", b'find . -exec rm {} \\;\nfor ((i = 0; i < 3; i++)); do\n  x\ndone\necho "a; b"\n'),
            ("a.sh", b"cat <<EOF\na; b\nEOF\n"),
        ]
        for path, source in cases:
            with self.subTest(path=path, source=source):
                self.assertEqual(rows(path, source), [])

    def test_shell_one_line_groups_are_flagged(self):
        self.assertEqual(rows("a.sh", b"f() { a; }\n"), [1])


class WidthTests(unittest.TestCase):
    def test_columns(self):
        exact = b"x = '" + b"a" * 114 + b"'\n"
        self.assertEqual(len(exact) - 1, 120)
        self.assertEqual(rows("a.py", exact), [])
        self.assertEqual(rows("a.py", b"x = '" + b"a" * 115 + b"'\n"), [1])
        self.assertEqual(rows("a.swift", ("let s = \"" + "字" * 115 + "\"\n").encode()), [1])

    def test_other_languages_are_ignored(self):
        self.assertEqual(rows("a.md", b"x; y " + b"a" * 200 + b"\n"), [])
        self.assertEqual(rows("a.yaml", b"key: " + b"a" * 200 + b"\n"), [])


class AssertionTests(unittest.TestCase):
    def test_bare_assertions_are_flagged(self):
        source = (
            b"set -e\n"
            b"[[ -f a ]]\n"
            b"! grep x a\n"
            b"[[ -f a ]] && echo ok\n"
            b"[[ -f a ]] || fail\n"
            b"! grep x a || fail\n"
            b"[[ -f a && -f b ]] ||\n"
            b"  fail\n"
            b"if [[ -f a ]]; then\n"
            b"  [[ -f b ]]\n"
            b"fi\n"
        )
        self.assertEqual(rows("macOS/scripts/test-x.sh", source), [2, 3, 4, 10])

    def test_allowed_assertions(self):
        source = (
            b"[[ -f a ]] || fail\n"
            b"! grep x a || fail\n"
            b"if [[ -f a ]]; then\n"
            b"  :\n"
            b"fi\n"
            b"if ! grep x a; then\n"
            b"  :\n"
            b"fi\n"
            b"while [[ -f a ]] && [[ -f b ]]; do\n"
            b"  :\n"
            b"done\n"
            b"[[ -f a ]] ||\\\n"
            b"  fail\n"
        )
        found = rows("Core/scripts/test-x.sh", source)
        self.assertEqual(found, [])

    def test_only_test_scripts_are_checked(self):
        for path in ("macOS/scripts/build.sh", "Linux/fcitx5/test.sh", "scripts/test-x.py"):
            with self.subTest(path=path):
                self.assertEqual(rows(path, b"[[ -f a ]]\n"), [])


class IncrementalTests(unittest.TestCase):
    def test_only_changed_lines_are_checked(self):
        with TemporaryDirectory() as tmp:
            directory = Path(tmp)

            def git(*args):
                subprocess.run(["git", *args], cwd=directory, check=True, capture_output=True)

            def lint(*args):
                return subprocess.run(
                    [sys.executable, "-B", str(LINTER), *args], cwd=directory, capture_output=True, text=True,
                )

            git("init", "-q")
            old = "a = 1; b = 2\nlong = '" + "x" * 130 + "'\nkeep = 3\n"
            (directory / "old.py").write_text(old)
            git("add", "old.py")
            git("-c", "user.name=Lint Test", "-c", "user.email=lint@example.invalid", "commit", "-qm", "baseline")

            self.assertEqual(lint("--base", "HEAD").returncode, 0)
            self.assertEqual(lint().returncode, 1)

            (directory / "old.py").write_text(old.replace("keep = 3", "keep = 4"))
            self.assertEqual(lint("--base", "HEAD").returncode, 0)

            (directory / "old.py").write_text(old.replace("keep = 3", "keep = 4; more = 5"))
            result = lint("--base", "HEAD")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ["old.py:3: more than one statement on a line."])

            (directory / "old.py").write_text(old)
            git("mv", "old.py", "new.py")
            self.assertEqual(lint("--base", "HEAD").returncode, 0)

            (directory / "added.py").write_text("x = 1; y = 2\n")
            result = lint("--base", "HEAD")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout.splitlines(), ["added.py:1: more than one statement on a line."])


if __name__ == "__main__":
    unittest.main()
