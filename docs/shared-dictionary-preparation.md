# Shared dictionary preparation

Dictionary source data and build-time policy live under `Core/`. The preparation recipe has one implementation; the commands under `macOS/scripts/` delegate to it.

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

The move preserves source bytes, admission rules, dictionary identities, and output filenames. Existing macOS entry points remain available so app builds, workers, and developer commands keep using the same recipe. The optional wordfreq snapshot regeneration tool remains under `macOS/scripts/`; it writes to `Core/Data/` and is never invoked by an ordinary build.

## Commands

On the Mac, after preparing the pinned dependencies:

```sh
bash Core/scripts/prepare-rime.sh build/shared-rime
```

The result contains source dictionaries and configuration. Native compiled tables and prisms must still be prepared with the runtime for each target. Do not copy a macOS compiled cache to Linux.

The source preparation cache hashes the shared package, generator sources/tools/scripts, data, configuration, schemas, and downloaded inputs. macOS frontend source changes do not invalidate this cache. Delivery preserves file times and replaces the destination only after generation succeeds. Invalid input must leave the previous destination intact.

The admission/resource-assembly fixtures run on Linux and macOS:

```sh
bash Core/scripts/test-prepare-rime.sh
python3 scripts/mac-remote.py test preparation dictionary-generator quality-baseline quality-metadata
```

The shell fixtures substitute small Chinese/spelling generators to isolate admission and delivery. They also verify that the old macOS wrapper produces identical resources, cache delivery preserves timestamps, and shared generator changes invalidate the cache. The Mac tests separately exercise the real Chinese/spelling generator, the retained behavioral baseline, and build provenance for shared resource inputs.

## Migration boundary

The production path still uses `Core/scripts/build-dictionary-generator.sh` to build the Swift implementation through the Mac toolchain. An isolated [Rust generator comparison](../Core/Portable/dictionary/README.md) now checks the same Chinese dictionary and spelling profiles on Linux and macOS. It has not replaced the shipping generator or update worker. Target-native production resource preparation and the remaining offline behavior are still part of [#35](https://github.com/nervouna/InkFlow/issues/35).

Historical baseline reports and corpus source descriptions retain their original paths as provenance. Current readers and build identity use `Core/Data/` and `Core/config/`. No ranking, learning, personal-data format, or installed input-method behavior changes in this step. The [distribution review](../Core/Portable/licenses.md) still applies to the resource set.
