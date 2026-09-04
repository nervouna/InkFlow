# InkFlow

InkFlow is a local-first, cross-platform Chinese input method experiment. The
repository is organized around one shared [librime](https://github.com/rime/librime)
engine boundary and native shells for macOS, iOS, and Android.

> **Current status:** repository foundation only. There is no installable input
> method yet, and no target silently substitutes a fake engine for librime.

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

The verification is intentionally offline after the submodules have been
initialized. See `docs/foundation-acceptance.md` for the evidence each check
produces.

## Licensing

InkFlow-authored source is currently reserved for private use; no redistribution
license is granted. Third-party work, including librime and its recursive
dependencies, retains its own license. See `LICENSE` and `NOTICE.md` before any
future publication or redistribution.
