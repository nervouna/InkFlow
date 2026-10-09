#!/usr/bin/env python3
"""Complete a Linux staging tree with notices, corresponding source and hashes."""
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'build/portable'


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def copy(source, destination, expected=None):
    if expected and digest(source) != expected:
        raise SystemExit(f'Checksum mismatch: {source}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def hashes(directory):
    return {p.relative_to(directory).as_posix(): digest(p)
            for p in sorted(directory.rglob('*')) if p.is_file()}


def check_resources(resources, reused):
    if not (resources / 'prepared/complete').is_file():
        raise SystemExit('Missing target-native resource completion marker')
    native = json.loads((BUILD / 'native-build.json').read_text())
    shared = hashes(resources / 'shared')
    cache = hashes(resources / 'prepared/cache')
    manifest = json.loads((resources / 'shared/dictionary-manifest.json').read_text())
    if reused:
        report_path = resources / 'resources.json'
        if not report_path.is_file():
            raise SystemExit('Reused resources require resources.json; run package.sh without arguments to rebuild')
        report = json.loads(report_path.read_text())
        expected = hashes(ROOT / 'build/linux/package-shared')
        old_native = report.get('nativeBuild', {})
        if (report.get('platform') != 'Linux' or
                report.get('architecture') != platform.machine() or
                any(old_native.get(key) != native.get(key)
                    for key in ('platform', 'machine', 'sources', 'revision')) or
                report.get('sourceSHA256') != shared or
                report.get('cacheSHA256') != cache or
                report.get('manifest') != manifest or shared != expected):
            raise SystemExit('Reused resources do not match this Linux target/revision/recipe; rebuild without arguments')
    else:
        report = {'platform': 'Linux', 'architecture': platform.machine(),
                  'nativeBuild': native, 'sourceSHA256': shared,
                  'cacheSHA256': cache, 'manifest': manifest}
        (resources / 'resources.json').write_text(json.dumps(report, indent=2) + '\n')


def main():
    package = Path(sys.argv[1]).resolve()
    if command('git', 'status', '--porcelain', '--untracked-files=no'):
        raise SystemExit('Commit tracked changes before packaging')
    revision = command('git', 'rev-parse', 'HEAD')
    for name in ('lib/fcitx5/libinkflow.so', 'lib/inkflow/librime.so',
                 'lib/inkflow/librime.so.1',
                 'share/inkflow/rime/prepared/complete',
                 'share/inkflow/rime/shared/pinyin_simp.context.bin',
                 'share/fcitx5/addon/inkflow.conf',
                 'share/fcitx5/inputmethod/inkflow-pinyin.conf',
                 'share/inkflow/rime/shared/dictionary-manifest.json'):
        if not (package / name).is_file():
            raise SystemExit(f'Missing staged payload: {name}')
    copy(ROOT / 'Linux/scripts/install.py', package / 'install.py')
    notices = package / 'share/inkflow/Licenses'
    source = package / 'share/inkflow/SOURCE'
    source.mkdir(parents=True)
    notices.mkdir(parents=True)
    # Full committed project: recipe, modifications, data snapshots and licenses.
    subprocess.run(['git', 'archive', '--format=tar', '-o', str(source / 'inkflow.tar'),
                    revision], cwd=ROOT, check=True)
    for name in ('LICENSE', 'NOTICE'):
        copy(ROOT / name, notices / ('InkFlow-' + name))
    for name in ('chinese-dictionaries-NOTICE.txt', 'easy-en-GPL-3.0.txt',
                 'easy-en-LGPL-3.0.txt', 'pinyin-simp.txt', 'rime-frost.txt',
                 'rime-ice.txt', 'technology-english-NOTICE.txt', 'wordfreq.txt', 'opencc.txt'):
        copy(ROOT / 'macOS/Licenses' / name, notices / 'dictionary' / name)

    lock = json.loads((ROOT / 'Core/Portable/native-sources.lock.json').read_text())
    for name, item in lock.items():
        archive = name + ('.tar.bz2' if name == 'boost' else '.tar.gz')
        copy(BUILD / archive, source / 'native' / archive, item['sha256'])
    native = BUILD / 'sources'
    required = ['rime/LICENSE', 'rime/include/COPYING.darts-clone', 'rime/include/utf8.h',
                'rime-lua/LICENSE', 'rime-lua/src/lib/lauxlib-compat.c',
                'lua/lua5.4/lua.h', 'boost/LICENSE_1_0.txt', 'glog/COPYING',
                'leveldb/LICENSE', 'marisa/COPYING.md', 'yaml/LICENSE', 'opencc/LICENSE']
    utf8 = 'rime-lua/src/lib/lutf8lib-compat.c'
    if not (native / utf8).is_file():
        utf8 = 'rime-lua/src/lib/lutf8lib.c'
    required.append(utf8)
    for name in required:
        copy(native / name, notices / 'native' / name)
    # Preserve embedded header notices too (RapidJSON, UTF8-CPP, Darts-clone).
    for directory in ('rime/include', 'opencc/deps'):
        for path in sorted((native / directory).rglob('*')):
            if path.is_file() and (path.suffix in ('.h', '.hpp') or
                                  path.name.lower().startswith(('license', 'copying', 'notice'))):
                copy(path, notices / 'native' / path.relative_to(native))

    recipe = (ROOT / 'Core/scripts/resource-dependencies.sh').read_text()
    inputs = re.findall(r'^fetch (\S+) ([0-9a-f]{64}) (https:\S+)$', recipe, re.M)
    if len(inputs) != 3:
        raise SystemExit('Review changed dictionary download recipe')
    for name, sha, _ in inputs:
        copy(ROOT / 'build/deps' / name, source / 'deps' / name, sha)
    catalog = json.loads((ROOT / 'Core/config/chinese-sources.json').read_text())
    for item in catalog:
        name = item['id'] + '.yaml'
        copy(ROOT / 'build/dictionary-sources' / name,
             source / 'dictionary-sources' / name, item['pinnedSHA256'])

    # Both locked Rust graphs are used: engine and dictionary generator.
    for crate in ('Core/Portable', 'Core/Portable/dictionary'):
        metadata = json.loads(command('cargo', 'metadata', '--locked', '--offline',
                                      '--format-version', '1', '--manifest-path',
                                      str(ROOT / crate / 'Cargo.toml')))
        for entry in metadata['packages']:
            if entry['source'] is None:
                continue  # Local source and its license are in inkflow.tar.
            directory = Path(entry['manifest_path']).parent
            key = entry['name'] + '-' + entry['version']
            destination = source / 'rust' / key
            if not destination.exists():
                shutil.copytree(directory, destination, ignore=shutil.ignore_patterns('.git'))
            files = [p for p in directory.rglob('*') if p.is_file() and
                     p.name.lower().startswith(('license', 'copying', 'copyright', 'notice'))]
            if not files:
                raise SystemExit(f'Missing Rust notices: {key}')
            for path in files:
                copy(path, notices / 'Rust' / key / path.relative_to(directory))
    standard = Path(command('rustc', '--print', 'sysroot')) / 'share/doc/rust'
    copy(standard / 'COPYRIGHT-library.html', notices / 'Rust/COPYRIGHT-library.html')
    shutil.copytree(standard / 'licenses', notices / 'Rust/standard-library-licenses')
    (notices / 'Rust/toolchain.txt').write_text(command('rustc', '--version', '--verbose') + '\n')
    copy(BUILD / 'native-build.json', source / 'native-build.json')
    (source / 'REBUILD.txt').write_text(f'''InkFlow revision {revision}
Build scripts require Git metadata. Start with a clean checkout at this revision:
  git clone https://github.com/nervouna/InkFlow.git inkflow-rebuild
  cd inkflow-rebuild
  git checkout --detach {revision}
Alternatively, to use only the bundled project source, extract inkflow.tar into
an empty directory, enter it, and create a local provenance commit:
  git init
  git add .
  git -c user.name='Source rebuild' -c user.email='rebuild@localhost' commit -m 'Rebuild bundled InkFlow source from {revision}'
This local commit has a different revision from the original above; rebuilt
metadata identifies that local commit, not the original release revision.
From either checkout, restore the bundled inputs (replace /path/to/SOURCE):
  mkdir -p build/portable build/deps build/dictionary-sources
  cp /path/to/SOURCE/native/* build/portable/
  cp /path/to/SOURCE/deps/* build/deps/
  cp /path/to/SOURCE/dictionary-sources/* build/dictionary-sources/
  python3 Core/Portable/build-native.py
  bash Core/scripts/resource-dependencies.sh
  bash Core/scripts/prepare-chinese.sh --sources-only
  bash Core/scripts/prepare-rime.sh build/linux/resources/shared
  CARGO_TARGET_DIR="$PWD/build/portable/cargo" cargo run --locked --release --manifest-path Core/Portable/Cargo.toml --bin prepare-resources -- build/linux/resources/shared build/linux/resources/prepared
To build the full package instead, after restoring the inputs above run:
  bash Linux/scripts/package.sh
The packaging recipe requires clean tracked Git source and records its HEAD.
The source archive itself has no .git directory, hence the initialization step
when rebuilding from the archive rather than the original checkout.
Native archives are checksum pinned. OpenCC's C++17/cstdint adjustments are in
build-native.py. Rust dependency sources are in rust/; Cargo.lock records origins
and checksums. Cargo/toolchain and system build prerequisites may require network
access; this is source delivery, not an offline build environment.
Externally supplied prepared resources require a resources.json report matching
this Linux architecture, native pins and revision. Shared resource bytes must match
the current recipe; cache hashes must match the report. The report is a build
provenance record, not independent proof of how compiled cache bytes were produced.
''')
    dependencies = ('Requires compatible host Linux libc, libstdc++, libgcc and Fcitx5 '
                    '(including their transitive system dependencies). These are not bundled. '
                    'Architecture alone does not imply ABI compatibility; build on the oldest '
                    'supported target and check ELF dependencies on each target.')
    (package / 'share/inkflow/SYSTEM-DEPENDENCIES.txt').write_text(dependencies + '\n')
    # Dereference installed library aliases so every delivered byte is hashed.
    for path in sorted(package.rglob('*')):
        if path.is_symlink():
            if not path.is_file():
                raise SystemExit(f'Unsupported directory or broken symlink: {path}')
            content = path.read_bytes()
            path.unlink()
            path.write_bytes(content)
    manifest = {'format': 1, 'architecture': platform.machine(), 'revision': revision,
                'dirty': False, 'systemDependencies': dependencies,
                'files': {p.relative_to(package).as_posix(): digest(p)
                          for p in sorted(package.rglob('*'))
                          if p.is_file() and p != package / 'package.json'}}
    (package / 'package.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--check-resources':
        check_resources(Path(sys.argv[2]).resolve(), sys.argv[3] == 'reused')
    else:
        main()
