# Shared Rust dictionary generator

This crate ports the Chinese dictionary generator, all 32 spelling profiles and the context-ranking index for #35. It is an isolated library and command-line tool, with no Rime, Swift, GUI, or network dependency in generation itself. The preparation scripts run its CLI; the Swift dictionary update worker calls the same library through its C ABI.

Context index version 2 keeps separate frequencies for a phrase's terminal readings. Each fixed-width record contains
the NFC phrase key (three bytes per scalar), six bytes of zero-padded lowercase terminal Pinyin and the eight-byte
little-endian frequency. The 40-byte header and phrase-length tables keep their layout. The ranker also accepts
version 1; preparing resources upgrades the index.
An unsplit or unsupported code has an all-zero syllable, retaining its text evidence without claiming a terminal reading.
The index accepts 2–8 Han graphemes, each a single scalar. The sorted fixed-width tables let the ranker
load the index directly.

## Verify

From the repository root:

```sh
bash Core/Portable/dictionary/test.sh
```

The script tests Rust against the recorded fixtures and pinned corpus on every platform, then checks the Swift bridge on macOS. It uses the repository's Rust toolchain and this crate's `Cargo.lock`.

## Re-record the fixtures

The fixtures are the reference. Rust output is the only generator, so a rule change in `src/` or an edit to `Core/config/chinese-overrides.tsv` moves the hashes in `fixtures/reference.json` and `fixtures/corpus.json`. After an intended change, re-record both from the Rust generator:

```sh
bash Core/Portable/dictionary/test.sh --record
```

Re-record only for an intended rule or data change, and explain every moved case in the PR. Change a case in `fixtures/cases.json` only for a reasoned behaviour change. `catalog.json` is the pinned copy of `Core/config/chinese-sources.json`; update it by hand when the catalog changes.

Preparation may download the pinned public dictionary sources. Downloads go under ignored
`build/dictionary-parity/inputs/`. Preparation checks byte counts and SHA-256 before use, and Rust checks
the Git blob hash and SHA-256 again. The library and CLI use those local inputs. Comparison outputs stay
under `build/dictionary-parity/`. The shared Cargo artifacts live under `build/dictionary/cargo/`.

The CLI uses the compiled production catalog and creates a new output directory. Tests may supply an explicit catalog before the source-directory argument:

```sh
build/dictionary/cargo/release/inkflow-dictionary generate \
  build/dictionary-parity/inputs build/dictionary-parity/inputs/legacy.yaml \
  Core/config/chinese-overrides.tsv build/dictionary-parity/new-dictionary

build/dictionary/cargo/release/inkflow-dictionary spelling \
  build/dictionary-parity/new-dictionary/pinyin_simp.dict.yaml \
  build/dictionary-parity/new-spelling
```

It refuses an existing output directory. Validation completes before creating output; a write failure removes only the new directory it created.
Callers stage this new directory before publishing prepared resources.

## In-process preparation boundary

`include/inkflow_dictionary.h` and its Clang module map expose an experimental C ABI from `libinkflow_dictionary.a`. It calls the same Rust generation, receipt validation, and spelling functions as the CLI. It does not launch a process, touch the filesystem, or initialize Rime. Call it from preparation/update workers, never from key handling. `Core/Sources/InkFlowDomain/DictionaryGenerator.swift` is the Swift production wrapper.

Inputs are borrowed pointer/length buffers. The C caller supplies valid, aligned, readable storage for
nonempty buffers and arrays. Null input pointers are accepted for empty buffers and arrays. Catalog and receipt buffers contain UTF-8 JSON; dictionary and correction inputs remain raw bytes so validation can reject malformed text. The boundary accepts at most 64 inputs, 1 MiB of catalog/corrections, 16 KiB per receipt, and the existing 128 MiB per source. Malformed transport inputs return `bridge-input` or `bridge-json`; domain failures retain their code, source, and line. Recoverable Rust panics return `bridge-panic`. Invalid foreign pointers, allocator aborts, and process crashes are outside that guarantee.

Every operation returns an owned opaque result. Successful generation supplies the dictionary and manifest; spelling supplies 32 named schema files plus `pinyin_simp.context.bin`; receipt validation supplies no files. Failure supplies error JSON and no files. Output pointers and names are length-delimited, not NUL-terminated, and remain valid until the caller frees the result. Result accessors require a live non-null handle. Retain the result while reading its buffers and release it
once. Freeing a null result has no effect. Out-of-range file indices produce empty buffers. File names
are UTF-8 basenames. The error buffer is empty on success and contains JSON with `code`, `source` and
`line` on failure. The immutable buffer returned by `ifd_catalog` lives for the process lifetime.
Independent calls and results may be used on different threads because they share no mutable generator state.

The test script compiles and links a C consumer on both desktops. On macOS it also builds a standalone Swift consumer, releases input storage before reading results, and compares the complete corpus and all spelling bytes through the ABI against the Rust CLI. `swift-ffi-corpus.json` retains that consumer's actual summary. This proves the preparation boundary, not shipping worker sandbox, packaging, or resource activation behavior.

## Reference and compatibility contract

`Core/config/chinese-sources.json` is the authoritative production catalog. Rust embeds it; `IFDictionaryCatalog` reads it through the ABI without filesystem access. Rust also owns the recipe version and maximum source size. `fixtures/cases.json` supplies 43 inputs. The recorded `catalog.json` is a pinned copy of the production catalog, and checks reject drift from it.

`reference.json` records parser errors, complete provenance manifests, dictionary hashes, and the hashes of all 32 spelling profiles and the context index for successful cases. `corpus.json` records the output for the complete pinned source set and current Chinese corrections. Comparison uses isolated build directories.

The checks cover normalized readings, canonical Unicode key equality with the first display spelling retained, source/group precedence, specialty gap filling, zero weights, log-median calibration, the 100-pair bucket boundary, rounding/saturation, corrections, line/text/reading limits, and malformed input. Separate Rust tests cover receipts, invalid UTF-8, CLI replacement refusal, and output ownership. Source headers remain uninterpreted text; only the tab-separated body is read.

Dictionary, spelling-profile and context-index bytes must match exactly. Manifest fields must match after JSON decoding, except calibration multipliers allow relative/absolute error up to `1e-12` for platform math libraries. This tolerance does not apply to weights, hashes, counts, or content versions. JSON spacing and floating-point number spelling are not compatibility requirements.

The parser preserves Foundation's whitespace character sets. Spelling profiles omit the legacy source's
consonant-only syllables so syllable coverage leaves abbreviations available.

Two details are deliberately preserved:

- Keys use canonical Unicode equivalence, but generated output keeps the first spelling of a key. The Rust map stores a normalized lookup key separately from its emitted text.
- The parser splits on the LF character, treating CRLF as one grapheme, so CRLF source dictionaries fail validation. Changing it would be a separate parser fix.

Generated schema headers retain the existing `IFSpellingGenerator` wording for byte compatibility. This port does not change the Pinyin algebra, English admission, ranking, or dictionary identities.

## Scope and dependencies

Production callers share one generator; deployment, session policy, and personal-data migration still require their own verification.

The Rust dependency versions and checksums are in `Cargo.lock`. Hashing uses RustCrypto SHA-1/SHA-256; SHA-1 is used only for the existing Git blob identity, alongside SHA-256 verification. Serde handles the explicit catalog/manifest format. Unicode normalization, segmentation, and general-category tables implement the Swift text contract.

The dependency metadata lists MIT/Apache-2.0 alternatives for most crates, Apache-2.0 for `unicode-general-category`, MIT for `generic-array` and `zmij`, and an additional Unicode-3.0 requirement for the build-time `unicode-ident` crate. The app and worker statically link the library. `Core/scripts/dictionary-notices.py` collects the locked crate license files and the toolchain's standard-library notices for app packaging. The [dictionary distribution review](../licenses.md) still applies to the data.
