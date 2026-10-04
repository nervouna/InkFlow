#!/usr/bin/env python3
"""Build the pinned desktop runtime in build/portable; never install system-wide."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BUILD = ROOT / 'build/portable'
PREFIX = BUILD / 'prefix'


def run(*args, cwd=None):
    subprocess.run([str(a) for a in args], cwd=cwd, check=True)


def main():
    if sys.platform not in ('linux', 'darwin'):
        raise SystemExit('Only Linux and macOS are supported by this probe')
    lock = json.loads((HERE / 'native-sources.lock.json').read_text())
    sources = BUILD / 'sources'
    sources.mkdir(parents=True, exist_ok=True)
    for name, item in lock.items():
        archive = BUILD / (name + ('.tar.bz2' if name == 'boost' else '.tar.gz'))
        if not archive.exists():
            part = archive.with_suffix('.part')
            run('curl', '--fail', '--location', '--retry', '2', item['url'], '-o', part)
            part.rename(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError(f'Checksum mismatch: {archive}')
        dest = sources / name
        stamp = dest / '.inkflow-source'
        if not stamp.exists() or stamp.read_text() != item['sha256']:
            if dest.exists():
                shutil.rmtree(dest)
            dest.mkdir()
            run('tar', '-xf', archive, '-C', dest, '--strip-components=1')
            stamp.write_text(item['sha256'])
    # The plugin's pinned thirdparty tree supplies Lua; no system Lua discovery.
    plugin = sources / 'rime/plugins/lua'
    if not plugin.exists():
        plugin.symlink_to(sources / 'rime-lua', target_is_directory=True)
    thirdparty = sources / 'rime-lua/thirdparty'
    if not thirdparty.exists():
        thirdparty.symlink_to(sources / 'lua', target_is_directory=True)

    def cmake(name, *options, source=None):
        binary = BUILD / ('cmake-' + name)
        run('cmake', '-S', source or sources / name, '-B', binary, '-G', 'Ninja',
            '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
            '-DCMAKE_INSTALL_LIBDIR=lib', f'-DCMAKE_INSTALL_PREFIX={PREFIX}',
            f'-DCMAKE_PREFIX_PATH={PREFIX}', '-DBUILD_SHARED_LIBS=OFF',
            '-DBUILD_TESTING=OFF', *options)
        run('cmake', '--build', binary, '--parallel', os.environ.get('CMAKE_BUILD_PARALLEL_LEVEL', '4'))
        run('cmake', '--install', binary)

    cmake('glog', '-DWITH_GFLAGS=OFF', '-DWITH_GTEST=OFF', '-DWITH_UNWIND=none')
    cmake('leveldb', '-DLEVELDB_BUILD_TESTS=OFF', '-DLEVELDB_BUILD_BENCHMARKS=OFF',
          '-DHAVE_SNAPPY=OFF', '-DHAVE_CRC32C=OFF', '-DHAVE_TCMALLOC=OFF')
    cmake('marisa', '-DENABLE_TOOLS=OFF')
    cmake('yaml', '-DYAML_CPP_BUILD_TESTS=OFF', '-DYAML_CPP_BUILD_TOOLS=OFF')
    # OpenCC's pinned source requests C++14; the matching Rime marisa needs C++17.
    opencc_cmake = sources / 'opencc/CMakeLists.txt'
    original = opencc_cmake.read_text()
    updated = original.replace('-std=c++14', '-std=c++17').replace(
        'set(CMAKE_CXX_STANDARD 14)', 'set(CMAKE_CXX_STANDARD 17)')
    if updated != original:
        opencc_cmake.write_text(updated)
    cmake('opencc', '-DUSE_SYSTEM_MARISA=ON', '-DENABLE_GTEST=OFF', '-DENABLE_BENCHMARK=OFF',
          f'-DCMAKE_CXX_FLAGS=-I{PREFIX}/include -include cstdint',
          f'-DCMAKE_EXE_LINKER_FLAGS=-L{PREFIX}/lib')
    boost = sources / 'boost'
    if not (boost / 'b2').exists():
        run('bash', 'bootstrap.sh', '--with-libraries=regex', cwd=boost)
    run('./b2', '--with-regex', 'variant=release', 'link=static', 'cxxflags=-fPIC',
        '--layout=system', f'--prefix={PREFIX}', 'install', cwd=boost)
    cmake('rime', '-DBUILD_SHARED_LIBS=ON', '-DBUILD_STATIC=ON', '-DBUILD_TEST=OFF',
          '-DBUILD_MERGED_PLUGINS=ON', '-DENABLE_EXTERNAL_PLUGINS=OFF',
          '-DINSTALL_PRIVATE_HEADERS=ON', '-DENABLE_TIMESTAMP=OFF',
          '-DCMAKE_DISABLE_FIND_PACKAGE_Gflags=ON',
          f'-DBOOST_ROOT={PREFIX}', f'-DBoost_INCLUDE_DIR={PREFIX}/include',
          f'-DCMAKE_INSTALL_RPATH={PREFIX}/lib')
    cmake('bridge', source=HERE / 'native')
    cache = (BUILD / 'cmake-bridge/CMakeCache.txt').read_text().splitlines()
    compiler = next(line.split('=', 1)[1] for line in cache
                    if line.startswith('CMAKE_CXX_COMPILER:FILEPATH='))
    (BUILD / 'native-build.json').write_text(json.dumps({
        'platform': sys.platform, 'machine': os.uname().machine, 'sources': lock,
        'cmake': subprocess.check_output(['cmake', '--version'], text=True).splitlines()[0],
        'compiler': subprocess.check_output([compiler, '--version'], text=True).strip(),
        'rust': subprocess.check_output(['rustc', '--version'], cwd=ROOT, text=True).strip(),
        'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'fixtures': {str(file.relative_to(HERE)): hashlib.sha256(file.read_bytes()).hexdigest()
                     for file in sorted((HERE / 'fixtures').rglob('*')) if file.is_file()},
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
