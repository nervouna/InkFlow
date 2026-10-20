#!/usr/bin/env python3
"""Collect the notices that macOS/Licenses lacks for the portable core: the native libraries
built from the pinned sources, and the Rust crates linked into libinkflow_rime.

Without arguments it rewrites the files in macOS/Licenses; --check compares them instead.
Needs build/portable/sources (Core/Portable/build-native.py) and the locked crates in the
Cargo registry (any cargo build of Core/Portable)."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
destination = root / 'macOS/Licenses'
sources = root / 'build/portable/sources'
# marisa offers BSD-2-Clause or LGPL-2.1-or-later; COPYING.md carries both texts.
native = {'glog.txt': 'glog/COPYING', 'leveldb.txt': 'leveldb/LICENSE',
          'librime-octagram.txt': 'rime-octagram/LICENSE',
          'marisa.txt': 'marisa/COPYING.md', 'yaml-cpp.txt': 'yaml/LICENSE'}

manifest = str(root / 'Core/Portable/Cargo.toml')
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--locked', '--offline', '--format-version', '1', '--manifest-path', manifest,
], cwd=root))
# The lock file also lists packages that no build of this crate uses; take the real graph.
tree = subprocess.check_output([
    'cargo', 'tree', '--locked', '--offline', '-e', 'normal,build', '--prefix', 'none', '--format',
    '{p}', '--manifest-path', manifest,
], cwd=root, text=True)
linked = {tuple(line.split()[:2]) for line in tree.splitlines()}
sections = ['Rust crates linked into libinkflow_rime\n\nIncludes the normal and build dependencies of the locked Cargo graph.\n']
for package in sorted(metadata['packages'], key=lambda p: p['name']):
    if package['name'] == 'inkflow-rime' or (package['name'], 'v' + package['version']) not in linked:
        continue
    directory = Path(package['manifest_path']).parent
    notices = sorted(p for p in directory.iterdir() if p.is_file() and
                     p.name.lower().startswith(('license', 'copying', 'copyright', 'notice')))
    if not notices:
        raise SystemExit(f"Missing license files: {package['name']}")
    sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\n"
                    f"License expression: {package['license']}\n"
                    f"Source: {package.get('repository') or package['source']}\n")
    for notice in notices:
        sections.append(f'\n--- {notice.name} ---\n{notice.read_text()}\n')
generated = {'inkflow-rime-crates.txt': ''.join(sections)}
for name, source in native.items():
    generated[name] = (sources / source).read_text()

if '--check' in sys.argv[1:]:
    stale = [name for name, text in generated.items()
             if not (destination / name).is_file() or (destination / name).read_text() != text]
    if stale:
        raise SystemExit(f"Out of date, rerun Core/scripts/portable-notices.py: {', '.join(stale)}")
    print('PASS portable notices match the pinned sources and Cargo.lock')
else:
    for name, text in generated.items():
        (destination / name).write_text(text)
    print(f'Wrote {", ".join(generated)} to {destination}')
