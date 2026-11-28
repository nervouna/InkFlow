from pathlib import Path
import runpy
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

LINTER = Path(__file__).resolve().parents[1] / "docs-lint.py"
MODULE = runpy.run_path(str(LINTER))
LINT = MODULE["lint"]
SLUG = MODULE["github_slug"]

TEST_SH = """all_units=(alpha beta-one
  gamma)
case "$arg" in
  quick) requested+='alpha ' ;;
  all) requested+='x' ;;
esac
echo --help
"""
TOOL_SH = "while [[ $# -gt 0 ]]; do case $1 in --known) ;; esac; done\n"
FORWARDER_SH = 'exec ./real "$@"\n'
SKILL = "---\nname: demo\ndescription: Does a thing.\n---\n# Demo\n"


def lint(files):
    with TemporaryDirectory() as directory:
        for name, text in files.items():
            path = Path(directory, name)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return LINT(directory, sorted(files))


def checks(problems):
    return sorted({problem.split("[", 1)[1].split("]", 1)[0] for problem in problems})


class SlugTests(unittest.TestCase):
    def test_github_slugs(self):
        cases = [
            ("Build and verify", "build-and-verify"),
            ("`test.sh` units & groups", "testsh-units--groups"),
            ("安装与启用", "安装与启用"),
            ("A [link](x.md) here", "a-link-here"),
            ("snake_case *emphasis*", "snake_case-emphasis"),
        ]
        for heading, slug in cases:
            with self.subTest(heading=heading):
                self.assertEqual(SLUG(heading), slug)


class LinkTests(unittest.TestCase):
    def test_valid_links(self):
        files = {
            "README.md": "[a](docs/a.md#second-part) [d](docs/) [self](#top) [web](https://x.y/z) [m](mailto:a@b.c)\n"
            "[cjk](docs/a.md#安装与启用) [dup](docs/a.md#second-part-1) [enc](docs/a%20b.md)\n# Top\n",
            "docs/a.md": "# A\n## Second part\n## Second part\n## 安装与启用\n",
            "docs/a b.md": "x\n",
        }
        self.assertEqual(lint(files), [])

    def test_broken_links(self):
        files = {
            "README.md": "[gone](docs/gone.md)\n[anchor](docs/a.md#nope)\n[self](#missing)\n[up](../x.md)\n",
            "docs/a.md": "# A\n",
        }
        problems = lint(files)
        self.assertEqual(len(problems), 4)
        self.assertEqual(checks(problems), ["links"])

    def test_code_and_templates_are_not_links(self):
        files = {"README.md": "`[x](gone.md)`\n```\n[x](gone.md)\n```\n[t]({{placeholder}})\n"}
        self.assertEqual(lint(files), [])


class PathTests(unittest.TestCase):
    def test_existing_and_skipped_paths(self):
        files = {
            "docs/a.md": "`Core/x.rs` `Core/` `Core/x.rs:12` `Core/x.rs#frag` `Core/*.rs` `docs/<name>.md`\n"
            "`docs/X.Y.Z.md` `Core/...` `build/none.rs` `Core/$VAR` `Core/x.rs and more`\n",
            "Core/x.rs": "",
        }
        self.assertEqual(lint(files), [])

    def test_missing_paths(self):
        files = {"docs/a.md": "`Core/gone.rs` and `macOS/missing/` and `scripts/gone.py`\n", "Core/x.rs": ""}
        problems = lint(files)
        self.assertEqual(len(problems), 3)
        self.assertEqual(checks(problems), ["paths"])

    def test_paths_relative_to_the_document_are_allowed(self):
        files = {
            ".agents/skills/demo/SKILL.md": SKILL + "`scripts/tool.py`\n",
            ".agents/skills/demo/scripts/tool.py": "",
        }
        self.assertEqual(lint(files), [])


class CommandTests(unittest.TestCase):
    def test_valid_commands(self):
        files = {
            "docs/a.md": "`bash scripts/tool.sh --known` and `python3 -B scripts/tool.sh --known | head --nope`\n"
            "```sh\nbash scripts/tool.sh \\\n  --known # --nope\nbash scripts/forward.sh --anything\n"
            "python3 /opt/x/install.py --y\nbash ~/x.sh --z\n```\n",
            "scripts/tool.sh": TOOL_SH,
            "scripts/forward.sh": FORWARDER_SH,
        }
        self.assertEqual(lint(files), [])

    def test_missing_script_and_flag(self):
        files = {
            "docs/a.md": "`bash scripts/gone.sh`\n```sh\nbash scripts/tool.sh --unknown\n```\n"
            "```sh\nbash scripts/tool.sh \\\n  --other\n```\n",
            "scripts/tool.sh": TOOL_SH,
        }
        problems = lint(files)
        self.assertEqual(len(problems), 3)
        self.assertEqual(checks(problems), ["commands"])


class UnitTests(unittest.TestCase):
    def test_valid_units(self):
        files = {
            "macOS/scripts/test.sh": TEST_SH,
            "macOS/T.md": "`bash macOS/scripts/test.sh quick all alpha` and `test.sh beta-one gamma --help`\n"
            "```sh\nbash macOS/scripts/test.sh gamma # not-a-unit\n```\n",
            "docs/b.md": "`test.sh --record` and `bash Core/scripts/test.sh zeta`\n",
            "Core/scripts/test.sh": "echo zeta\n",
        }
        self.assertEqual(lint(files), [])

    def test_unknown_units(self):
        files = {
            "macOS/scripts/test.sh": TEST_SH,
            "macOS/T.md": "`bash macOS/scripts/test.sh alpha delta`\n`test.sh --gone`\n"
            "```sh\nbash macOS/scripts/test.sh epsilon\n```\n",
        }
        problems = lint(files)
        self.assertEqual(len(problems), 3)
        self.assertEqual(checks(problems), ["units"])


class SkillTests(unittest.TestCase):
    def test_valid_skill(self):
        self.assertEqual(lint({".agents/skills/demo/SKILL.md": SKILL}), [])
        quoted = '---\nname: demo\ndescription: "A: quoted one."\n---\n'
        self.assertEqual(lint({".agents/skills/demo/SKILL.md": quoted}), [])

    def test_malformed_skills(self):
        cases = {
            "no frontmatter": "# Demo\n",
            "wrong name": "---\nname: other\ndescription: x\n---\n",
            "missing description": "---\nname: demo\n---\n",
            "empty description": "---\nname: demo\ndescription:\n---\n",
            "folded description": "---\nname: demo\ndescription: >\n  folded\n---\n",
            "wrapped description": "---\nname: demo\ndescription: first\n  second\n---\n",
            "long description": "---\nname: demo\ndescription: " + "x" * 1025 + "\n---\n",
        }
        for label, text in cases.items():
            with self.subTest(label=label):
                self.assertEqual(checks(lint({".agents/skills/demo/SKILL.md": text})), ["skills"])

    def test_description_limit_is_inclusive(self):
        text = "---\nname: demo\ndescription: " + "x" * 1024 + "\n---\n"
        self.assertEqual(lint({".agents/skills/demo/SKILL.md": text}), [])


class ScopeTests(unittest.TestCase):
    def test_excluded_directories_are_not_linted(self):
        files = {"Core/Fixtures/a.md": "[x](gone.md)\n", "macOS/Licenses/b.md": "`Core/gone`\n"}
        self.assertEqual(lint(files), [])

    def test_command_line_exit_codes(self):
        with TemporaryDirectory() as directory:
            subprocess.run(["git", "init", "-q", directory], check=True)
            Path(directory, "a.md").write_text("# A\n", encoding="utf-8")
            subprocess.run(["git", "-C", directory, "add", "--", "a.md"], check=True)
            run = [sys.executable, "-B", str(LINTER), "--root", directory]
            self.assertEqual(subprocess.run(run, capture_output=True).returncode, 0)
            Path(directory, "a.md").write_text("[x](gone.md)\n", encoding="utf-8")
            result = subprocess.run(run, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("a.md:1: [links]", result.stdout)


if __name__ == "__main__":
    unittest.main()
