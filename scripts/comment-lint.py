import argparse
from collections import Counter
from dataclasses import dataclass
from functools import cache
import json
from pathlib import Path
import re
import subprocess
import sys
from textwrap import dedent

from tree_sitter import Query, QueryCursor
from tree_sitter_language_pack import get_parser

SUFFIXES = {
    ".c": "c", ".h": "cpp", ".cpp": "cpp", ".m": "objc", ".swift": "swift", ".rs": "rust",
    ".lua": "lua", ".py": "python", ".sh": "bash", ".yaml": "yaml", ".yml": "yaml",
    ".toml": "toml", ".html": "html", ".xml": "xml", ".plist": "xml", ".entitlements": "xml",
    ".conf": "ini", ".strings": "c", ".modulemap": "cpp",
}
FILENAMES = {
    "CMakeLists.txt": "cmake", ".editorconfig": "ini", ".gitignore": "gitignore",
    "macOS/Package/preinstall": "bash", "macOS/Package/postinstall": "bash",
    "Linux/fcitx5/inkflow.conf.in": "ini",
}
COMMENT_NODES = {
    "cmake": ("line_comment", "bracket_comment"),
    "rust": ("line_comment", "block_comment"),
    "swift": ("comment", "multiline_comment"),
    "xml": ("Comment",),
}
DIRECTIVES = {
    "bash": re.compile(rb"#\s*shellcheck\s+(?:disable|enable|source|source-path|shell|external-sources)="),
    "python": re.compile(rb"#\s*(?:type:\s*ignore\b|noqa\b|fmt:\s*(?:on|off|skip)\b)"),
}


@dataclass(frozen=True)
class Comment:
    start: int
    end: int
    line: int
    end_line: int
    text: bytes


def git(*args):
    return subprocess.check_output(["git", *args])


def files():
    paths = git("ls-files", "-z", "-co", "--exclude-standard").decode().split("\0")
    return sorted({Path(path) for path in paths if path})


def language(path):
    return FILENAMES.get(path.as_posix()) or FILENAMES.get(path.name) or SUFFIXES.get(path.suffix)


@cache
def syntax(lang):
    parser = get_parser(lang)
    nodes = COMMENT_NODES.get(lang, ("comment",))
    query = Query(parser.language, f"[{' '.join(f'({node})' for node in nodes)}] @comment")
    return parser, query


def syntax_comments(lang, source):
    parser, query = syntax(lang)
    nodes = QueryCursor(query).captures(parser.parse(source).root_node).get("comment", [])
    for node in nodes:
        if lang == "html" and node.parent.type in {"attribute", "quoted_attribute_value"}:
            continue
        text = node.text.rstrip(b"\r\n")
        if text.strip():
            yield Comment(node.start_byte, node.start_byte + len(text), node.start_point.row + 1,
                          node.start_point.row + text.count(b"\n") + 1, text)


@cache
def workflow_query():
    parser, _ = syntax("yaml")
    return Query(parser.language, """
        (block_mapping_pair
          key: (flow_node) @key
          value: (block_node (block_scalar) @script)
          (#eq? @key "run"))
    """)


def workflow_comments(path, source):
    parser, _ = syntax("yaml")
    tree = parser.parse(source)
    for node in QueryCursor(workflow_query()).captures(tree.root_node).get("script", []):
        if not node.text.startswith(b"|") or b"\n" not in node.text:
            continue
        content = node.text.split(b"\n", 1)[1]
        script = dedent(content.decode()).encode()
        offsets = []
        source_offset = source.index(b"\n", node.start_byte) + 1
        script_offset = 0
        for original, parsed in zip(content.split(b"\n"), script.split(b"\n"), strict=True):
            offsets.append(source_offset + len(original) - len(parsed) - script_offset)
            source_offset += len(original) + 1
            script_offset += len(parsed) + 1
        for comment in syntax_comments("bash", script):
            if is_directive(path, "bash", comment):
                continue
            start = offsets[comment.line - 1] + comment.start
            line = node.start_point.row + 1 + comment.line
            yield Comment(start, start + len(comment.text), line, line, comment.text)


def line_comments(source, prefix, offset=0, first_line=1, stop=None):
    for line, data in enumerate(source.splitlines(keepends=True), first_line):
        text = data.rstrip(b"\r\n")
        if text == stop:
            break
        if text.startswith(prefix):
            yield Comment(offset, offset + len(text), line, line, text)
        offset += len(data)


def is_directive(path, lang, comment):
    if comment.start == 0 and lang in {"bash", "python", "swift", "lua"} and comment.text.startswith(b"#!"):
        return True
    if comment.line == 1 and path.name == "Package.swift":
        return bool(re.match(rb"//\s*swift-tools-version\s*:", comment.text))
    if comment.line <= 2 and lang == "python":
        if re.match(rb"#.*?coding[:=][ \t]*[-\w.]+", comment.text):
            return True
    pattern = DIRECTIVES.get(lang)
    return bool(pattern and pattern.match(comment.text))


def comments(path, source):
    lang = language(path)
    if lang is None:
        return []
    if lang == "gitignore":
        return list(line_comments(source, b"#"))
    header = source
    tail = ()
    if path.name.endswith(".dict.yaml"):
        boundary = re.search(rb"(?m)^\.\.\.[ \t]*\r?\n", source)
        if boundary:
            end = boundary.end()
            header = source[:end]
            tail = line_comments(source[end:], b"#", end, header.count(b"\n") + 1, stop=b"# no comment")
    found = [comment for comment in syntax_comments(lang, header) if not is_directive(path, lang, comment)]
    if lang == "yaml" and path.parent == Path(".github/workflows"):
        found.extend(workflow_comments(path, source))
    return sorted([*found, *tail], key=lambda comment: comment.start)


def comment_only_lines(source, found):
    code = bytearray(source)
    affected = set()
    for comment in found:
        code[comment.start:comment.end] = re.sub(rb"[^\r\n]", b" ", comment.text)
        affected.update(range(comment.line, comment.end_line + 1))
    return sum(not row.strip() for number, row in enumerate(code.split(b"\n"), 1) if number in affected)


def inventory(paths):
    totals = Counter()
    entries = []
    for path in paths:
        source = path.read_bytes()
        found = comments(path, source)
        lines = source.count(b"\n") + bool(source and not source.endswith(b"\n"))
        totals.update(files=1, files_with_comments=bool(found), lines=lines, comments=len(found),
                      comment_only_lines=comment_only_lines(source, found))
        entries.extend({"path": path.as_posix(), "line": comment.line, "end_line": comment.end_line,
                        "text": comment.text.decode()} for comment in found)
    return {"totals": dict(totals), "comments": entries}


def changes(base):
    fields = iter(git("diff", "--name-status", "-z", "--find-renames", base, "--").decode().split("\0")[:-1])
    result = {}
    for status in fields:
        path = Path(next(fields))
        if status.startswith("R"):
            result[Path(next(fields))] = path
        elif status != "D":
            result[path] = None if status == "A" else path
    result.update({Path(path): None for path in git("ls-files", "-zo", "--exclude-standard").decode().split("\0")
                   if path})
    return result


def lint(base, paths):
    old_paths = changes(base) if base else dict.fromkeys(paths)
    errors = 0
    for path in paths:
        if path not in old_paths:
            continue
        old = old_paths[path]
        previous = Counter()
        if old and language(old):
            previous.update(comment.text for comment in comments(old, git("show", f"{base}:{old}")))
        for comment in comments(path, path.read_bytes()):
            if previous[comment.text]:
                previous[comment.text] -= 1
            else:
                print(f"{path}:{comment.line}: new code comment. Move decisions to project docs.")
                errors += 1
    return bool(errors)


def main():
    parser = argparse.ArgumentParser(description="Reject code comments, with optional allowance for existing ones.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--base", help="Allow the comments already present in this Git revision.")
    mode.add_argument("--inventory", action="store_true", help="Print the current comment inventory and LOC as JSON.")
    options = parser.parse_args()
    paths = [path for path in files() if language(path) and not path.is_symlink() and path.is_file()]
    if options.inventory:
        json.dump(inventory(paths), sys.stdout, ensure_ascii=False, indent=2)
        print()
        return 0
    return lint(options.base, paths)


if __name__ == "__main__":
    sys.exit(main())
