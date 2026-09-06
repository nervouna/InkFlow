#!/usr/bin/env python3
"""Regenerate the offline snapshot; ordinary builds do not run this script.

UV_CACHE_DIR=<cache> uv run --no-project --python <python> \
    --with wordfreq==3.1.1 python macOS/scripts/snapshot-english-frequency.py
"""

import hashlib
import importlib.metadata
import math
from pathlib import Path

import wordfreq
from wordfreq.preprocess import preprocess_text

VERSION = "3.1.1"
SOURCE_SHA256 = "4f039026b2746fa9b0d4d7a248cdf866b64609dca2317708f04e9e68ac7d868a"
DATA_SHA256 = "dffae8066b78dce0a6667cf5f58e567054f902674667090a7ac8a8a44628b05c"
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "build/deps/rime-easy-en-54a4a07289412efc54134092c0d945f895a71ed3/easy_en.dict.yaml"
OUTPUT = ROOT / "macOS/Data/english-wordfreq.tsv"


def main() -> None:
    if importlib.metadata.version("wordfreq") != VERSION:
        raise SystemExit(f"Snapshot requires wordfreq=={VERSION}")
    source = SOURCE.read_bytes()
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Dictionary source checksum changed; review snapshot inputs first")
    data = Path(wordfreq.__file__).parent / "data/large_en.msgpack.gz"
    if hashlib.sha256(data.read_bytes()).hexdigest() != DATA_SHA256:
        raise SystemExit("wordfreq data checksum changed; review snapshot inputs first")
    frequencies = wordfreq.get_frequency_dict("en", wordlist="large")
    texts: set[str] = set()
    entries = False
    for line in source.decode("utf-8").splitlines():
        if line == "...":
            entries = True
        elif entries and line.strip() and not line.lstrip().startswith("#"):
            fields = line.split("\t")
            if len(fields) >= 2:
                texts.add(fields[0])
    rows = []
    for text in sorted(texts):
        # Direct key lookup avoids word_frequency/zipf_frequency estimates for
        # multi-token phrases, punctuation and digit patterns absent from data.
        probability = frequencies.get(preprocess_text(text, "en"))
        if probability is not None:
            rows.append(f"{text}\t{math.log10(probability) + 9:.2f}\n")
    header = (
        f"# wordfreq {VERSION}, en/large; CC BY-SA 4.0; see macOS/Licenses/wordfreq.txt.\n"
        f"# Source dictionary SHA256: {SOURCE_SHA256}\n"
        f"# wordfreq large_en.msgpack.gz SHA256: {hashlib.sha256(data.read_bytes()).hexdigest()}\n"
        "# Exact existing display text<TAB>observed Zipf. Missing keys are omitted, not zero.\n"
        "# Regenerate with macOS/scripts/snapshot-english-frequency.py.\n"
    )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(header + "".join(rows), encoding="utf-8")
    print(f"Snapshot: {len(rows)} observed / {len(texts)} unique source texts; {len(texts) - len(rows)} missing")
    print(f"SHA256 {hashlib.sha256(OUTPUT.read_bytes()).hexdigest()}  {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
