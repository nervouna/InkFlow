#!/usr/bin/env python3
"""Regenerate the offline snapshot; ordinary builds do not run this script.

Inventory: every spelling in the ESDB en_US-large and en_GB-large hunspell dictionaries, affixes expanded.
The two pinned zips are downloaded into the ignored build/esdb on first use.

UV_CACHE_DIR=<cache> uv run --no-project --python <python> \
    --with wordfreq==3.1.1 python macOS/scripts/snapshot-english-frequency.py
"""

import hashlib
import importlib.metadata
import io
import math
import re
import subprocess
import zipfile
from pathlib import Path

import wordfreq
from wordfreq.preprocess import preprocess_text

VERSION = "3.1.1"
DATA_SHA256 = "dffae8066b78dce0a6667cf5f58e567054f902674667090a7ac8a8a44628b05c"
ESDB_RELEASE = "2026.02.25"
ESDB_URL = f"https://github.com/en-wl/wordlist/releases/download/rel-{ESDB_RELEASE}"
ESDB_SHA256 = {
    "en_US": "06ab5a2a12c29033f100988d3b0a5e53dcad40bf2473ccb78270619d1da99321",
    "en_GB": "704a49438a3a9d4f11cd76db433a6b230b9ce8770ee13fa28700052c4517ddc1",
}
ROOT = Path(__file__).resolve().parents[2]
ESDB_DIRECTORY = ROOT / "build/esdb"
OUTPUT = ROOT / "Core/Data/english-wordfreq.tsv"
SPELLING = re.compile(r"(?=.*[A-Za-z])[A-Za-z'.-]+")


def fetch_esdb(locale: str) -> bytes:
    name = f"hunspell-{locale}-large-{ESDB_RELEASE}.zip"
    path = ESDB_DIRECTORY / name
    if not path.exists():
        ESDB_DIRECTORY.mkdir(parents=True, exist_ok=True)
        part = path.with_name(name + ".part")
        subprocess.run(["curl", "--fail", "--location", "--proto", "=https", "--connect-timeout", "20",
                        "--max-time", "180", "--retry", "2", f"{ESDB_URL}/{name}", "-o", str(part)], check=True)
        part.rename(path)
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != ESDB_SHA256[locale]:
        raise SystemExit(f"{name} checksum changed; review snapshot inputs first")
    return data


def parse_affixes(aff: str) -> tuple[dict, str]:
    """Return {flag: (kind, cross product, [(strip, add, condition)])} and the ONLYINCOMPOUND flag."""
    rules = {}
    only_in_compound = ""
    lines = aff.splitlines()
    index = 0
    while index < len(lines):
        fields = lines[index].split()
        index += 1
        if fields[:1] == ["ONLYINCOMPOUND"]:
            only_in_compound = fields[1]
        elif len(fields) == 4 and fields[0] in ("PFX", "SFX"):
            kind, flag, cross, count = fields
            entries = []
            for line in lines[index:index + int(count)]:
                _, _, strip, add, condition = line.split()[:5]
                pattern = f"^{condition}" if kind == "PFX" else f"{condition}$"
                entries.append((
                    "" if strip == "0" else strip,
                    "" if add.partition("/")[0] == "0" else add.partition("/")[0],
                    re.compile(pattern),
                ))
            index += int(count)
            rules[flag] = (kind, cross == "Y", entries)
    return rules, only_in_compound


def apply_rule(rule: tuple, word: str) -> list[str]:
    kind, _, entries = rule
    forms = []
    for strip, add, condition in entries:
        if not condition.search(word):
            continue
        if kind == "SFX" and word.endswith(strip):
            forms.append(word[:len(word) - len(strip)] + add)
        elif kind == "PFX" and word.startswith(strip):
            forms.append(add + word[len(strip):])
    return forms


def expand(dic: str, aff: str) -> set[str]:
    """All spellings of a hunspell dictionary: stems, prefixed, suffixed, and prefixed-and-suffixed forms."""
    rules, only_in_compound = parse_affixes(aff)
    forms: set[str] = set()
    for line in dic.splitlines()[1:]:
        stem, _, flags = line.partition("/")
        if only_in_compound in flags:
            continue
        forms.add(stem)
        suffixed: list[str] = []
        prefixes = []
        for flag in flags:
            rule = rules.get(flag)
            if rule is None:
                continue
            derived = apply_rule(rule, stem)
            forms.update(derived)
            if rule[1]:
                if rule[0] == "SFX":
                    suffixed += derived
                else:
                    prefixes.append(rule)
        for prefix in prefixes:
            for word in suffixed:
                forms.update(apply_rule(prefix, word))
    return forms


def main() -> None:
    if importlib.metadata.version("wordfreq") != VERSION:
        raise SystemExit(f"Snapshot requires wordfreq=={VERSION}")
    data = Path(wordfreq.__file__).parent / "data/large_en.msgpack.gz"
    if hashlib.sha256(data.read_bytes()).hexdigest() != DATA_SHA256:
        raise SystemExit("wordfreq data checksum changed; review snapshot inputs first")
    frequencies = wordfreq.get_frequency_dict("en", wordlist="large")
    texts: set[str] = set()
    for locale in ESDB_SHA256:
        with zipfile.ZipFile(io.BytesIO(fetch_esdb(locale))) as archive:
            dic = archive.read(f"{locale}-large.dic").decode("utf-8")
            aff = archive.read(f"{locale}-large.aff").decode("utf-8")
        texts |= {form for form in expand(dic, aff) if SPELLING.fullmatch(form)}
    rows = []
    for text in sorted(texts):
        # Direct key lookup avoids word_frequency/zipf_frequency estimates for
        # multi-token phrases, punctuation and digit patterns absent from data.
        probability = frequencies.get(preprocess_text(text, "en"))
        if probability is not None:
            rows.append(f"{text}\t{math.log10(probability) + 9:.2f}\n")
    header = (
        f"# wordfreq {VERSION}, en/large; CC BY-SA 4.0; see macOS/Licenses/wordfreq.txt.\n"
        f"# Spellings: ESDB {ESDB_RELEASE} en_US-large zip SHA256: {ESDB_SHA256['en_US']}\n"
        f"# Spellings: ESDB {ESDB_RELEASE} en_GB-large zip SHA256: {ESDB_SHA256['en_GB']}\n"
        f"# wordfreq large_en.msgpack.gz SHA256: {hashlib.sha256(data.read_bytes()).hexdigest()}\n"
        "# Exact ESDB display text<TAB>observed Zipf. Missing keys are omitted, not zero.\n"
        "# Regenerate with macOS/scripts/snapshot-english-frequency.py.\n"
    )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(header + "".join(rows), encoding="utf-8")
    print(f"Snapshot: {len(rows)} observed / {len(texts)} unique source texts; {len(texts) - len(rows)} missing")
    print(f"SHA256 {hashlib.sha256(OUTPUT.read_bytes()).hexdigest()}  {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
