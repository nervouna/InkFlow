# Shared Rust dictionary generator

This crate ports the Chinese dictionary generator, all 32 spelling profiles and the context-ranking index for #35. It is an isolated library and command-line tool, with no Rime, Swift, GUI, or network dependency in generation itself. The preparation scripts run its CLI; the Swift dictionary update worker calls the same library through its C ABI.

## Verify

From the repository root:

```sh
bash Core/Portable/dictionary/test.sh
python3 scripts/mac-remote.py dictionary
```

On Linux, the script tests Rust against the recorded Swift contract and pinned corpus. On macOS, it first runs the existing Swift dictionary-generator tests, exports a fresh contract, then compares Rust against those live results and the recorded fixtures. Both use the repository's Rust toolchain and this crate's `Cargo.lock`.

Preparation may download the pinned public dictionary sources. Downloads go under ignored `build/dictionary-parity/inputs/`; byte counts and SHA-256 are checked before use, then Rust verifies the Git blob hash and SHA-256 again. Existing verified Mac source caches can be reused. There are no downloads from the library or CLI. Comparison outputs stay under `build/dictionary-parity/`; the shared Cargo artifacts live under `build/dictionary/cargo/`. The remote runner returns the catalog, reference results, Swift corpus summary (`corpus.json`), actual Rust corpus summary (`rust-corpus.json`), logs, and its usual exact-revision receipt.

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

## In-process preparation boundary

`include/inkflow_dictionary.h` and its Clang module map expose an experimental C ABI from `libinkflow_dictionary.a`. It calls the same Rust generation, receipt validation, and spelling functions as the CLI. It does not launch a process, touch the filesystem, or initialize Rime. Call it from preparation/update workers, never from key handling. `Core/Sources/InkFlowDomain/DictionaryGenerator.swift` is the Swift production wrapper. The old Swift algorithm is retained only in the dictionary test target.

Inputs are borrowed pointer/length buffers. Catalog and receipt buffers contain UTF-8 JSON; dictionary and correction inputs remain raw bytes so validation can reject malformed text. The boundary accepts at most 64 inputs, 1 MiB of catalog/corrections, 16 KiB per receipt, and the existing 128 MiB per source. Malformed transport inputs return `bridge-input` or `bridge-json`; domain failures retain their code, source, and line. Recoverable Rust panics return `bridge-panic`. Invalid foreign pointers, allocator aborts, and process crashes are outside that guarantee.

Every operation returns an owned opaque result. Successful generation supplies the dictionary and manifest; spelling supplies 32 named schema files plus `pinyin_simp.context.bin`; receipt validation supplies no files. Failure supplies error JSON and no files. Output pointers and names are length-delimited, not NUL-terminated, and remain valid until the caller frees the result. Result accessors require a live non-null handle. Independent calls share no mutable generator state.

The test script compiles and links a C consumer on both desktops. On macOS it also builds a standalone Swift consumer, releases input storage before reading results, and compares the complete corpus and all spelling bytes through the ABI against the Rust CLI and original Swift implementation. `swift-ffi-corpus.json` retains that consumer's actual summary. This proves the preparation boundary, not shipping worker sandbox, packaging, or resource activation behavior.

## Reference and compatibility contract

`Core/config/chinese-sources.json` is the authoritative production catalog. Rust embeds it; `IFDictionaryCatalog` reads it through the ABI without filesystem access. Rust also owns the recipe version and maximum source size. `fixtures/cases.json` supplies 43 inputs to both implementations. The test-only Swift reference exports `catalog.json` and `reference.json`; the copied catalog is a pinned fixture, and checks reject drift from the production catalog.

`reference.json` records parser errors, complete provenance manifests, dictionary hashes, and the hashes of all 32 spelling profiles and the context index for successful cases. `corpus.json` records the Swift output for the complete pinned source set and current Chinese corrections. Both fixture generation and actual output comparison use isolated build directories.

The checks cover normalized readings, canonical Unicode key equality with the first display spelling retained, source/group precedence, specialty gap filling, zero weights, log-median calibration, the 100-pair bucket boundary, rounding/saturation, corrections, line/text/reading limits, and malformed input. Separate Rust tests cover receipts, invalid UTF-8, CLI replacement refusal, and output ownership. Source headers remain uninterpreted text; only the tab-separated body is read.

Dictionary, spelling-profile and context-index bytes must match exactly. Manifest fields must match after JSON decoding, except calibration multipliers allow relative/absolute error up to `1e-12` for platform math libraries. This tolerance does not apply to weights, hashes, counts, or content versions. JSON spacing and floating-point number spelling are not compatibility requirements.

Two details are deliberately preserved:

- Swift String keys use canonical equivalence, but generated output keeps the first spelling of a key. The Rust map stores a normalized lookup key separately from its emitted text.
- The existing Swift parser splits on the LF Character. CRLF is one grapheme and is not that separator, so CRLF source dictionaries currently fail validation. The port keeps that behavior; changing it would be a separate parser fix.

Generated schema headers retain the existing `IFSpellingGenerator` wording for byte compatibility. This port does not change the Pinyin algebra, English admission, ranking, or dictionary identities.

## Scope and dependencies

Production callers share one generator; deployment, session policy, and personal-data migration still require their own verification.

The Rust dependency versions and checksums are in `Cargo.lock`. Hashing uses RustCrypto SHA-1/SHA-256; SHA-1 is used only for the existing Git blob identity, alongside SHA-256 verification. Serde handles the explicit catalog/manifest format. Unicode normalization, segmentation, and general-category tables implement the Swift text contract.

The dependency metadata lists MIT/Apache-2.0 alternatives for most crates, Apache-2.0 for `unicode-general-category`, MIT for `generic-array` and `zmij`, and an additional Unicode-3.0 requirement for the build-time `unicode-ident` crate. The app and worker statically link the library. `Core/scripts/dictionary-notices.py` collects the locked crate license files and the toolchain's standard-library notices for app packaging. The [dictionary distribution review](../licenses.md) still applies to the data.
