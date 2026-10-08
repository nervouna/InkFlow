#!/usr/bin/env python3
"""Compare the Rust generator with explicit Swift reference outputs and pinned inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
BUILD = ROOT / 'build/dictionary-parity'
FIXTURES = Path(__file__).resolve().parent / 'fixtures'


def equivalent(actual, expected, path='root'):
    if isinstance(actual, dict) and isinstance(expected, dict):
        assert actual.keys() == expected.keys(), f'{path}: field mismatch'
        for key in actual:
            equivalent(actual[key], expected[key], f'{path}.{key}')
    elif isinstance(actual, list) and isinstance(expected, list):
        assert len(actual) == len(expected), f'{path}: length mismatch'
        for index, (a, b) in enumerate(zip(actual, expected)):
            equivalent(a, b, f'{path}[{index}]')
    elif path.endswith(('.multiplier', '.overallMultiplier')):
        assert abs(actual - expected) <= max(1.0, abs(expected)) * 1e-12, f'{path}: {actual} != {expected}'
    else:
        assert actual == expected, f'{path}: {actual!r} != {expected!r}'


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def inputs(catalog):
    destination = BUILD / 'inputs'
    destination.mkdir(parents=True, exist_ok=True)
    for spec in catalog:
        target = destination / (spec['id'] + '.yaml')
        cached = ROOT / 'build/dictionary-sources' / target.name
        if spec['group'] == 'legacy':
            cached = next((ROOT / 'build/deps').glob('rime-pinyin-simp-*/pinyin_simp.dict.yaml'), cached)
        if not target.exists() and cached.exists() and digest(cached) == spec['pinnedSHA256']:
            shutil.copyfile(cached, target)
        if not target.exists():
            url = f"https://raw.githubusercontent.com/{spec['repository']}/{spec['pinnedCommit']}/{spec['path']}"
            part = target.with_suffix('.part')
            subprocess.run(['curl', '--fail', '--location', '--proto', '=https', '--retry', '2',
                            '--connect-timeout', '20', '--max-time', '180', '--max-filesize',
                            str(spec['pinnedByteCount']), url, '-o', str(part)], check=True)
            assert part.stat().st_size == spec['pinnedByteCount'] and digest(part) == spec['pinnedSHA256'], target
            part.rename(target)
        assert target.stat().st_size == spec['pinnedByteCount'] and digest(target) == spec['pinnedSHA256'], target
    return destination


def snapshot(dictionary, schemas):
    manifest = json.loads((dictionary / 'dictionary-manifest.json').read_text())
    assert manifest['dictionarySHA256'] == digest(dictionary / 'pinyin_simp.dict.yaml')
    return dict(manifest=manifest, spellingSHA256={p.name: digest(p) for p in sorted(schemas.iterdir())
                                                if p.name.endswith('.schema.yaml') or p.name == 'pinyin_simp.context.bin'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--catalog', type=Path, required=True)
    parser.add_argument('--swift', type=Path)
    parser.add_argument('--bridge', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text())
    source = inputs(catalog)
    with tempfile.TemporaryDirectory(prefix='generate-', dir=BUILD) as temporary:
        root = Path(temporary)
        generated, schemas = root / 'dictionary', root / 'spelling'
        subprocess.run([str(args.binary), 'generate', str(args.catalog), str(source), str(source / 'legacy.yaml'),
                        str(ROOT / 'Core/config/chinese-overrides.tsv'), str(generated)], check=True)
        subprocess.run([str(args.binary), 'spelling', str(generated / 'pinyin_simp.dict.yaml'), str(schemas)], check=True)
        actual = snapshot(generated, schemas)
        assert len(actual['spellingSHA256']) == 33
        if args.swift:
            assert (generated / 'pinyin_simp.dict.yaml').read_bytes() == (args.swift / 'pinyin_simp.dict.yaml').read_bytes(), 'Dictionary bytes differ from Swift'
            expected = snapshot(args.swift, args.swift)
            equivalent(actual, expected)
        else:
            expected = json.loads((FIXTURES / 'corpus.json').read_text())
            equivalent(actual, expected)
        args.report.mkdir(parents=True, exist_ok=True)
        (args.report / 'corpus.json').write_text(json.dumps(expected, ensure_ascii=False, indent=2) + '\n')
        (args.report / 'rust-corpus.json').write_text(json.dumps(actual, ensure_ascii=False, indent=2) + '\n')
        print(f"PASS pinned corpus: {actual['manifest']['entryCount']} rows, dictionary, all 32 profiles and the context index match Swift")
        if args.bridge:
            native_dictionary, native_schemas = root / 'native-dictionary', root / 'native-spelling'
            subprocess.run([str(args.bridge), 'generate', str(args.catalog), str(source), str(source / 'legacy.yaml'),
                            str(ROOT / 'Core/config/chinese-overrides.tsv'), str(native_dictionary)], check=True)
            subprocess.run([str(args.bridge), 'spelling', str(native_dictionary / 'pinyin_simp.dict.yaml'),
                            str(native_schemas)], check=True)
            native = snapshot(native_dictionary, native_schemas)
            assert native == actual, 'Swift FFI and Rust CLI summaries differ'
            assert (native_dictionary / 'pinyin_simp.dict.yaml').read_bytes() == (generated / 'pinyin_simp.dict.yaml').read_bytes()
            for file in schemas.glob('*.schema.yaml'):
                assert (native_schemas / file.name).read_bytes() == file.read_bytes(), file.name
            assert (native_schemas / 'pinyin_simp.context.bin').read_bytes() == (schemas / 'pinyin_simp.context.bin').read_bytes()
            (args.report / 'swift-ffi-corpus.json').write_text(json.dumps(native, ensure_ascii=False, indent=2) + '\n')
            print('PASS Swift in-process Rust ABI: complete dictionary, manifest, 32 spelling profiles and context index')
    if args.swift:
        for name in ('catalog.json', 'reference.json', 'corpus.json'):
            equivalent(json.loads((args.report / name).read_text()), json.loads((FIXTURES / name).read_text()), name)
        print('PASS recorded fixtures match the current Swift reference')


if __name__ == '__main__':
    main()
