#!/usr/bin/env python3
"""Collect notices for the locked dictionary library and its Rust standard library."""
import json
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1]).resolve()
metadata = json.loads(subprocess.check_output([
    'cargo', 'metadata', '--locked', '--offline', '--format-version', '1',
    '--manifest-path', str(root / 'Core/Portable/dictionary/Cargo.toml'),
], cwd=root))
sections = ['Rust dictionary dependencies\n\nIncludes build-time dependencies from the locked Cargo graph.\n']
for package in sorted(metadata['packages'], key=lambda p: p['name']):
    if package['name'] == 'inkflow-dictionary':
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
sysroot = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], cwd=root, text=True).strip())
standard = sysroot / 'share/doc/rust'
if not (standard / 'COPYRIGHT-library.html').is_file() or not (standard / 'licenses').is_dir():
    raise SystemExit('Rust standard-library copyright and license files are required for packaging')
output.mkdir(parents=True, exist_ok=False)
(output / 'dictionary-crates.txt').write_text(''.join(sections))
(output / 'toolchain.txt').write_text(subprocess.check_output(['rustc', '--version'], cwd=root, text=True))
shutil.copyfile(standard / 'COPYRIGHT-library.html', output / 'COPYRIGHT-library.html')
shutil.copytree(standard / 'licenses', output / 'licenses')
print(f'Collected dictionary and Rust standard-library notices in {output}')
