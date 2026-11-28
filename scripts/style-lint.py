import argparse
from pathlib import Path
import re
import runpy
import sys

COMMENT_LINT = runpy.run_path(str(Path(__file__).with_name("comment-lint.py")))
changes = COMMENT_LINT["changes"]
files = COMMENT_LINT["files"]
git = COMMENT_LINT["git"]
language = COMMENT_LINT["language"]
syntax = COMMENT_LINT["syntax"]
syntax_comments = COMMENT_LINT["syntax_comments"]

LANGUAGES = {"swift", "rust", "c", "cpp", "objc", "python", "bash", "lua"}
MAX_COLUMNS = 120
SEMICOLON_SKIPPED_PARENTS = {
    "rust": {"array_type", "array_expression", "token_tree"},
    "c": {"for_statement"},
    "cpp": {"for_statement", "for_range_loop"},
    "objc": {"for_statement"},
    "bash": {"c_style_for_statement"},
}
SWIFT_CONTAINERS = {"source_file", "statements"}
SHELL_TEST = re.compile(r"(?:.*/)?scripts/test-[^/]*\.sh")
SHELL_CONTINUATION = re.compile(rb"^(?:then|do)\b")
CONDITION_PARENTS = {"if_statement", "elif_clause", "while_statement"}


def walk(node):
    stack = [node]
    while stack:
        current = stack.pop()
        yield current
        stack.extend(reversed(current.children))


def long_lines(source):
    for number, line in enumerate(source.decode(errors="replace").split("\n"), 1):
        if len(line.rstrip("\r")) > MAX_COLUMNS:
            yield number, f"line is longer than {MAX_COLUMNS} columns."


def in_loop_header(node):
    ancestor = node.parent
    while ancestor is not None:
        if ancestor.type == "for_statement":
            body = ancestor.child_by_field_name("body")
            return body is not None and node.end_byte <= body.start_byte
        ancestor = ancestor.parent
    return False


def multiple_statements(lang, source):
    parser, _ = syntax(lang)
    root = parser.parse(source).root_node
    comment_starts = {comment.start for comment in syntax_comments(lang, source)}
    if lang == "swift":
        yield from swift_statements(root, comment_starts)
        return
    skipped = SEMICOLON_SKIPPED_PARENTS.get(lang, set())
    for node in walk(root):
        if node.type != ";" or node.parent.type in skipped or in_loop_header(node):
            continue
        line_end = source.find(b"\n", node.end_byte)
        line_end = len(source) if line_end < 0 else line_end
        rest = source[node.end_byte:line_end]
        stripped = rest.lstrip()
        start = node.end_byte + len(rest) - len(stripped)
        if not stripped.strip() or start in comment_starts:
            continue
        if lang == "bash" and SHELL_CONTINUATION.match(stripped):
            continue
        if lang != "bash" and stripped.startswith(b"}"):
            continue
        yield node.start_point.row + 1, "more than one statement on a line."


def swift_statements(root, comment_starts):
    for node in walk(root):
        if node.type not in SWIFT_CONTAINERS and not node.type.endswith("_body"):
            continue
        previous = None
        for child in node.named_children:
            if child.start_byte in comment_starts or child.type.endswith("comment"):
                continue
            if previous is not None and previous.end_point.row == child.start_point.row:
                yield child.start_point.row + 1, "more than one statement on a line."
            previous = child


def guarded(statement):
    if statement.type != "list" or statement.children[-2].type != "||":
        return False
    last = statement.children[-1]
    name = last.child_by_field_name("name")
    return last.type == "command" and name is not None and name.text == b"fail"


def assertions(path, source):
    if not SHELL_TEST.fullmatch(path.as_posix()):
        return
    parser, _ = syntax("bash")
    for node in walk(parser.parse(source).root_node):
        if node.type not in {"test_command", "negated_command"}:
            continue
        statement = node
        while statement.parent.type in {"list", "redirected_statement"}:
            statement = statement.parent
        if statement.start_byte != node.start_byte:
            continue
        parent = statement.parent
        if parent.type in CONDITION_PARENTS and statement in parent.children_by_field_name("condition"):
            continue
        if not guarded(statement):
            kind = "[[ … ]]" if node.type == "test_command" else "! cmd"
            yield statement.start_point.row + 1, f"bare {kind} assertion must end in `|| fail`."


def violations(path, source):
    lang = language(path)
    if lang not in LANGUAGES:
        return []
    found = list(long_lines(source))
    found.extend(multiple_statements(lang, source))
    if lang == "bash":
        found.extend(assertions(path, source))
    return sorted(set(found))


def changed_lines(base, path, old):
    if old is None:
        return None
    diff = git("diff", "-U0", "--no-color", "--find-renames", base, "--", old.as_posix(), path.as_posix())
    lines = set()
    for match in re.finditer(rb"(?m)^@@ -\S+ \+(\d+)(?:,(\d+))? @@", diff):
        start = int(match.group(1))
        count = 1 if match.group(2) is None else int(match.group(2))
        lines.update(range(start, start + count))
    return lines


def lint(base, paths):
    old_paths = changes(base) if base else dict.fromkeys(paths)
    errors = 0
    for path in paths:
        if path not in old_paths:
            continue
        lines = changed_lines(base, path, old_paths[path]) if base else None
        for number, message in violations(path, path.read_bytes()):
            if lines is None or number in lines:
                print(f"{path}:{number}: {message}")
                errors += 1
    return bool(errors)


def main():
    parser = argparse.ArgumentParser(description="Enforce the AGENTS.md code style on added and edited lines.")
    parser.add_argument("--base", help="Check only the lines changed since this Git revision.")
    options = parser.parse_args()
    paths = [path for path in files() if language(path) in LANGUAGES and not path.is_symlink() and path.is_file()]
    return lint(options.base, paths)


if __name__ == "__main__":
    sys.exit(main())
