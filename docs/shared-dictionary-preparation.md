# Shared dictionary preparation

Dictionary source data and build-time policy live under `Core/`. The recipe has one implementation; the `macOS/scripts/` entry points delegate to it.

| Input or step | Owner |
| --- | --- |
| Static English frequency snapshot and technical spellings | `Core/Data/` |
| English admission/scaling and exact corrections; Chinese corrections | `Core/config/` |
| Chinese source catalog | `Core/config/chinese-sources.json`, embedded in the Rust library and read by Swift through its C ABI |
| Merge/calibration rules and spelling profiles | `Core/Portable/dictionary/src/`; Swift preparation/update callers delegate through `DictionaryGenerator.swift` |
| Downloaded, verified dictionary sources | Ignored `build/deps/` and `build/dictionary-sources/` |
| English admission, mixed dictionary derivation, and resource assembly | `Core/scripts/prepare-rime.sh` |
| Chinese source verification and generation | `Core/scripts/prepare-chinese.sh` |
| Spelling profile generation | `Core/scripts/prepare-spelling.sh` |
| Schemas, Lua, and OpenCC text resources | `schemas/` |

The optional wordfreq snapshot tool stays under `macOS/scripts/` and writes to `Core/Data/`.

## Commands

On Linux or macOS:

```sh
bash Core/scripts/resource-dependencies.sh
bash Core/scripts/prepare-chinese.sh --sources-only
bash Core/scripts/prepare-rime.sh build/shared-rime
```

The result contains source dictionaries and configuration. `bash macOS/scripts/dictionary-source-bundle.sh OUT.tar.gz` packs the verified pinned inputs, this recipe at `HEAD` and the license texts; releases attach it as the corresponding source. Compiled tables and prisms must be prepared by each target's runtime; never copy a macOS compiled cache to Linux.

The preparation cache hashes the shared package, generator sources/tools/scripts, data, configuration, schemas, and downloaded inputs; macOS frontend changes don't invalidate it. The destination is replaced only after generation succeeds.

```sh
bash Core/scripts/test-prepare-rime.sh
python3 scripts/mac-remote.py test preparation dictionary-generator quality-baseline quality-metadata
```

The shell fixtures use small stand-in generators to isolate admission and delivery; the Mac units exercise the real generators.

## Migration boundary

`Core/scripts/build-dictionary-generator.sh` builds the Rust CLI and static library. The Swift dictionary preparation/update worker calls that library in-process. The former Swift implementation exists only in the dictionary test target for [compatibility comparisons](../Core/Portable/dictionary/README.md). SwiftPM tracks a generated archive-identity header so changes in Rust relink native callers.

`bash Core/Portable/prepare-resources.sh` prepares source resources, compiles them with the source-built target runtime, and runs the existing worker smoke cases in separate temporary user directories. It retains source/cache hashes in `resources.json`. The cache is not a portable personal-data backup.
