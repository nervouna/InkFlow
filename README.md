# InkFlow

InkFlow is a local-first, cross-platform Chinese input method experiment. The
repository is organized around one shared [librime](https://github.com/rime/librime)
engine boundary and native shells for macOS, iOS, and Android.

> **Current status:** the shared librime-backed engine and native Apple source
> shells are implemented. Signing-disabled macOS and iOS Simulator products are
> buildable; installation, launch, device use, and distribution are separate
> acceptance layers. No production target substitutes a fake engine for
> librime. The native Android frontend remains a later implementation task.

## Architecture

```text
schemas/source  ->  InkFlow C ABI + librime  ->  native platform adapters
       |                    |
       +-> deterministic test data           +-> macOS / iOS / Android
```

- `schemas/source/` is the only editable product schema and dictionary source.
- `schemas/test/` contains deliberately isolated deterministic fixtures. It is
  not shipped as product data.
- `engine/` owns the stable C boundary; platform code must not bind directly to
  librime.
- `platforms/` contains native platform projects. Generated projects and copied
  resources are build outputs, not editing surfaces.
- `third_party/librime` is an exact recursive Git submodule. Its expected
  repository and commit are recorded in `dependencies.lock.json`.

InkFlow is offline by design. The foundation adds no account, telemetry,
network permission, synchronization, or secret-bearing configuration.

## Getting started

The required and validated toolchain versions are recorded in
`toolchains.lock.json`. Initialize dependencies and run all foundation checks:

```sh
./tools/bootstrap/bootstrap.sh
```

Run the checks again without changing dependency state:

```sh
./tools/verify/foundation.sh
```

The first engine configuration downloads the exact Boost archive pinned by
librime and `dependencies.lock.json`; later configurations share that ignored,
hash-verified source cache while keeping generator-specific CMake state
separate. Verify the shared engine, including its real isolated Chinese schema,
C consumer, full native link-closure symbol surface, and dynamic linkage, with:

```sh
./tools/verify/engine.sh
```

See `docs/foundation-acceptance.md` and `docs/engine-acceptance.md` for the
evidence each check produces.

Build and verify the native Apple adapter, macOS input method, and iOS keyboard
extension with:

```sh
./tools/verify/apple.sh
```

See `docs/apple-acceptance.md` for the exact artifact, lifecycle, privacy, and
signing-disabled evidence contract.

## Licensing

InkFlow-authored source is currently reserved for private use; no redistribution
license is granted. Third-party work, including librime and its recursive
dependencies, retains its own license. See `LICENSE` and `NOTICE.md` before any
future publication or redistribution.
