import argparse
import posixpath
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

TOP_DIRS = ("Core", "macOS", "Linux", "schemas", "docs", "scripts", ".agents", ".github")
EXCLUDED = ("Core/Fixtures/", "macOS/Licenses/")
TEST_RUNNER = "macOS/scripts/test.sh"
SKILL = re.compile(r"^\.agents/skills/([^/]+)/SKILL\.md$")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
HEADING = re.compile(r"^ {0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$")
CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")
LINK = re.compile(r"\]\(\s*<?([^)>\s]+)>?(?:\s+[\"'][^)]*)?\s*\)")
LINK_DEFINITION = re.compile(r"^ {0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s|$)")
SCHEME = re.compile(r"^(?:[A-Za-z][A-Za-z0-9+.-]*:|//)")
HTML_ID = re.compile(r"""<[A-Za-z][^>]*?\b(?:id|name)=["']([^"']+)["']""")
COMMAND = re.compile(r"""\b(bash|python3)\s+((?:-[A-Za-z]+\s+)*)([^\s`'"]+\.(?:sh|py))(?![\w.])(.*)""")
TEST_COMMAND = re.compile(r"""((?:[\w.$-]*/)*test\.sh)(?![\w.])(.*)""")
FLAG = re.compile(r"(?<![\w-])(--[A-Za-z][\w-]*)")
UNIT_TOKEN = re.compile(r"^(?:--[\w-]+|[a-z][a-z0-9-]*)$")
SEPARATORS = re.compile(r"[|;&<>#]")
PATH_SKIP = ("*", "<", "{", "$", "...", "X.Y.Z")
PATH_TRAILING = ".,;:)"


def git_files(root):
    output = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"])
    return sorted(path for path in output.decode().split("\0") if path)


def is_linted_markdown(path):
    return path.endswith(".md") and not path.startswith(EXCLUDED)


def github_slug(text):
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"<[^>]+>", "", text)
    text = text.replace("`", "").replace("*", "")
    text = re.sub(r"(?<!\w)_(.+?)_(?!\w)", r"\1", text)
    text = re.sub(r"[^\w\- ]", "", text.strip().lower())
    return text.replace(" ", "-")


def scan(text):
    in_fence = None
    for number, line in enumerate(text.splitlines(), 1):
        match = FENCE.match(line)
        if in_fence:
            if match and match.group(1)[0] == in_fence[0] and len(match.group(1)) >= len(in_fence):
                in_fence = None
                continue
            yield number, line, True
            continue
        if match:
            in_fence = match.group(1)
            continue
        yield number, line, False


def anchors(text):
    found = set()
    counts = {}
    for number, line, fenced in scan(text):
        if fenced:
            continue
        found.update(HTML_ID.findall(line))
        match = HEADING.match(line)
        if not match:
            continue
        slug = github_slug(match.group(1))
        seen = counts.get(slug, 0)
        counts[slug] = seen + 1
        found.add(slug if seen == 0 else f"{slug}-{seen}")
    return found


def code_segments(text):
    pending = None
    for number, line, fenced in scan(text):
        if fenced:
            if pending:
                number, line = pending[0], pending[1] + " " + line.strip()
                pending = None
            if line.rstrip().endswith("\\"):
                pending = (number, line.rstrip()[:-1])
                continue
            yield number, line
            continue
        for match in CODE_SPAN.finditer(line):
            yield number, match.group(2).strip()
    if pending:
        yield pending


def prose_lines(text):
    for number, line, fenced in scan(text):
        if not fenced:
            yield number, CODE_SPAN.sub(lambda match: " " * len(match.group(0)), line)


class Repo:
    def __init__(self, root, paths):
        self.root = Path(root)
        self.files = set(paths)
        self.directories = {parent for path in paths for parent in self.parents(path)}
        self.cache = {}
        self.problems = []

    @staticmethod
    def parents(path):
        parts = path.split("/")[:-1]
        return {"/".join(parts[:index]) for index in range(1, len(parts) + 1)}

    def read(self, path):
        if path not in self.cache:
            self.cache[path] = (self.root / path).read_text(encoding="utf-8", errors="replace")
        return self.cache[path]

    def exists(self, path):
        path = path.rstrip("/")
        return path in self.files or path in self.directories

    def resolve_from(self, document, path):
        directory = posixpath.dirname(document)
        while True:
            candidate = posixpath.normpath(posixpath.join(directory, path))
            if self.exists(candidate):
                return candidate
            if not directory:
                return None
            directory = posixpath.dirname(directory)

    def report(self, path, line, check, message):
        self.problems.append(f"{path}:{line}: [{check}] {message}")

    def test_units(self):
        if TEST_RUNNER not in self.files:
            return None
        source = self.read(TEST_RUNNER)
        units = re.search(r"all_units=\(([^)]*)\)", source)
        names = set(units.group(1).split()) if units else set()
        labels = re.findall(r"^\s+([a-z][a-z0-9|-]*)\)", source, re.M)
        for label in labels:
            names.update(label.split("|"))
        return names


def check_links(repo, path, text):
    directory = posixpath.dirname(path)
    targets = []
    for number, line in prose_lines(text):
        targets += [(number, target) for target in LINK.findall(line)]
        definition = LINK_DEFINITION.match(line)
        if definition:
            targets.append((number, definition.group(1)))
    for number, target in targets:
        if SCHEME.match(target) or "{{" in target:
            continue
        base, _, fragment = target.partition("#")
        base = unquote(base)
        if not base:
            resolved = path
        elif base.startswith("/"):
            resolved = posixpath.normpath(base.lstrip("/"))
        else:
            resolved = posixpath.normpath(posixpath.join(directory, base))
        if resolved.startswith("../") or resolved == "..":
            repo.report(path, number, "links", f"link leaves the repository: {target}")
            continue
        if not repo.exists(resolved):
            repo.report(path, number, "links", f"link target does not exist: {target}")
            continue
        if fragment and resolved in repo.files and resolved.endswith(".md"):
            if unquote(fragment).lower() not in anchors(repo.read(resolved)):
                repo.report(path, number, "links", f"anchor does not exist: {target}")


def check_paths(repo, path, text):
    for number, content in code_segments(text):
        if content != content.strip() or re.search(r"\s", content):
            continue
        if not content.startswith(tuple(f"{top}/" for top in TOP_DIRS)):
            continue
        if any(marker in content for marker in PATH_SKIP):
            continue
        candidate = content.split("#", 1)[0]
        candidate = re.sub(r":\d+(?:-\d+)?$", "", candidate).rstrip(PATH_TRAILING)
        if not repo.resolve_from(path, candidate):
            repo.report(path, number, "paths", f"path does not exist: {content}")


def check_commands(repo, path, text):
    units = repo.test_units()
    for number, content in code_segments(text):
        for match in COMMAND.finditer(content):
            script = match.group(3)
            if script.startswith(("/", "~")) or any(marker in script for marker in PATH_SKIP):
                continue
            script = repo.resolve_from(path, posixpath.normpath(script))
            if script not in repo.files:
                repo.report(path, number, "commands", f"script does not exist: {match.group(3)}")
                continue
            arguments = SEPARATORS.split(match.group(4), 1)[0]
            source = repo.read(script)
            if '"$@"' in source:
                continue
            for flag in FLAG.findall(arguments):
                if flag not in source:
                    repo.report(path, number, "commands", f"{script} has no {flag}")
        if units is None:
            continue
        for match in TEST_COMMAND.finditer(content):
            runner = posixpath.normpath(match.group(1))
            if runner != TEST_RUNNER and not (runner == "test.sh" and path.startswith("macOS/")):
                continue
            arguments = SEPARATORS.split(match.group(2), 1)[0].split()
            for token in arguments:
                if not UNIT_TOKEN.match(token):
                    break
                if token.startswith("--"):
                    if token not in repo.read(TEST_RUNNER):
                        repo.report(path, number, "units", f"{TEST_RUNNER} has no {token}")
                elif token not in units:
                    repo.report(path, number, "units", f"unknown test unit: {token}")


def single_line_value(frontmatter, key):
    lines = frontmatter.split("\n")
    for index, line in enumerate(lines):
        match = re.match(rf"^{key}:[ \t]*(.*?)[ \t]*$", line)
        if not match:
            continue
        value = match.group(1)
        continuation = index + 1 < len(lines) and re.match(r"^[ \t]+\S", lines[index + 1])
        if value in {">", "|", ">-", "|-", ">+", "|+"} or (continuation and not value.startswith(("'", '"'))):
            return None, "is not on a single line"
        if len(value) > 1 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        return value, None
    return "", "is missing"


def check_skill(repo, path, text):
    directory = SKILL.match(path).group(1)
    match = re.match(r"^---\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|$)", text, re.S)
    if not match:
        repo.report(path, 1, "skills", "frontmatter is missing")
        return
    frontmatter = match.group(1).replace("\r", "")
    name, problem = single_line_value(frontmatter, "name")
    if problem or name != directory:
        repo.report(path, 1, "skills", f"name must equal the directory name {directory}")
    description, problem = single_line_value(frontmatter, "description")
    if problem:
        repo.report(path, 1, "skills", f"description {problem}")
    elif not description:
        repo.report(path, 1, "skills", "description is empty")
    elif len(description) > 1024:
        repo.report(path, 1, "skills", f"description has {len(description)} characters, over 1024")


def lint(root, paths):
    repo = Repo(root, paths)
    for path in sorted(repo.files):
        if is_linted_markdown(path):
            text = repo.read(path)
            check_links(repo, path, text)
            check_paths(repo, path, text)
            check_commands(repo, path, text)
        if SKILL.match(path):
            check_skill(repo, path, repo.read(path))
    return repo.problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[1]))
    arguments = parser.parse_args()
    problems = lint(arguments.root, git_files(arguments.root))
    for problem in problems:
        print(problem)
    if problems:
        print(f"{len(problems)} documentation problem(s)", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
