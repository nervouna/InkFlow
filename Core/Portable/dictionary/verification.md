# Dictionary generator verification

Revision `4d1c939e5f80dc2f934e0be08632b41ec3b52dac` passed on Linux x86_64 and macOS 27.0.1 arm64 with Rust 1.98.1. The Mac used Xcode 27.0 to build the Swift reference. Rust ran in release mode; the existing Swift test recipe retained its normal build configurations.

- All 44 shared contract cases matched, including manifests, parser failures, and hashes for all 32 spelling profiles in successful cases.
- The complete pinned corpus produced 969,894 rows with identical dictionary bytes and spelling-profile bytes on the Mac. Linux matched the recorded Swift hashes and manifest values. The retained actual Rust summaries are identical across both targets; their decoded numeric values also equal the Swift summary without needing the allowed float tolerance.
- Dictionary SHA-256: `d6327de9da8fd4b9644baaaf35acc09dd490e111da69a2afe3b6b10292aa12c6`.
- Content version: `r2-0f6965ffc115ffb79fcf6f52cb5c79a4310c49e9981e325da904c15c31ff4ec4`.
- Rust receipt/input-boundary, ownership/determinism, and CLI preservation tests passed. Clippy with warnings denied, formatting, and all 18 remote-runner tests passed on Linux.

The final Mac run regenerated the Swift fixtures and checked them against the recorded files. An earlier comparison exposed the LF-versus-CRLF Character behavior; the Rust parser was corrected to preserve the Swift contract. A subsequent capture supplied the initial pinned-corpus reference before the final complete passing run.

No native production caches, installed input method, live personal data, or performance measurements were involved. This is generator evidence, not engine or full #35 acceptance.

## Retained evidence

Paths are relative to the worktree and remain under ignored `build/`.

| File | SHA-256 |
| --- | --- |
| `build/dictionary-parity/linux-final.log` | `efaa6319c85ff38451bbc7bbcb5b7e5866e46f3a6c050d364953c556215d91e2` |
| `build/dictionary-parity/report/rust-corpus.json` | `63bb2d4234e0470a0549e00303f21192065ee10683ce2ff603b5371f6375b16d` |
| `build/mac-remote/20261004T210919Z-97637ce3/run.json` | `23d13ff76c48546ca30c32ccee97c2cb0dc14bd0e4b7ed5051ab66b72b6bf25b` |
| `build/mac-remote/20261004T210919Z-97637ce3/00-dictionary.log` | `69c7e7bee9583460c2fb9fe6bf95aae028e488ffd6e9631b168a902b02deb95e` |
| `build/mac-remote/20261004T210919Z-97637ce3/rust-corpus.json` | `63bb2d4234e0470a0549e00303f21192065ee10683ce2ff603b5371f6375b16d` |
| `build/mac-remote/20261004T210919Z-97637ce3/reference.json` | `1bbb940ecbbbaff2764329524881c261c5e854c1e32750599aa3f023f979c75b` |
