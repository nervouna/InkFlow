# Shared dictionary preparation

Dictionary source data and build-time policy live under `Core/`. The recipe has one implementation; the `macOS/scripts/` entry points delegate to it.

| Input or step | Owner |
| --- | --- |
| Static English frequency snapshot and technical spellings | `Core/Data/` |
| English admission/scaling and exact corrections; Chinese corrections | `Core/config/` |
| Chinese source catalog, merge/calibration rules, and spelling profiles | `Core/Sources/InkFlowDomain/DictionaryModels.swift` and `DictionaryGenerator.swift` |
| Downloaded, verified dictionary sources | Ignored `build/deps/` and `build/dictionary-sources/` |
| English admission, mixed dictionary derivation, and resource assembly | `Core/scripts/prepare-rime.sh` |
| Chinese source verification and generation | `Core/scripts/prepare-chinese.sh` |
| Spelling profile generation | `Core/scripts/prepare-spelling.sh` |
| Schemas, Lua, and OpenCC text resources | `schemas/` |

The optional wordfreq snapshot tool stays under `macOS/scripts/` and writes to `Core/Data/`.

## Commands

On the Mac, after preparing the pinned dependencies:

```sh
bash Core/scripts/prepare-rime.sh build/shared-rime
```

The result contains source dictionaries and configuration. Compiled tables and prisms must be prepared by each target's runtime; never copy a macOS compiled cache to Linux.

The preparation cache hashes the shared package, generator sources/tools/scripts, data, configuration, schemas, and downloaded inputs; macOS frontend changes don't invalidate it. The destination is replaced only after generation succeeds.

```sh
bash Core/scripts/test-prepare-rime.sh
python3 scripts/mac-remote.py test preparation dictionary-generator quality-baseline quality-metadata
```

The shell fixtures use small stand-in generators to isolate admission and delivery; the Mac units exercise the real generators.

## Migration boundary

Production still builds the Swift generator through the Mac toolchain (`Core/scripts/build-dictionary-generator.sh`). The [Rust generator comparison](../Core/Portable/dictionary/README.md) matches it on Linux and macOS but has not replaced it; target-native preparation is part of [#35](https://github.com/nervouna/InkFlow/issues/35).
