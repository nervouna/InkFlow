# Shared Swift core

The two SwiftPM manifests share the domain, Rime facade and tests. The standalone manifest builds
them without resolving the macOS application or its external packages. The boundary check compares
SwiftPM's declaration dumps, which need no external-package resolution. See the
[portable runtime](Portable/README.md) for the native build and the
[shared dictionary recipe](../docs/shared-dictionary-preparation.md) for resource preparation.

## Native linkage

The macOS build links the Rust runtime archive at its explicit path because a conventional
`-linkflow_rime` search would select the crate's dynamic library. The archive includes the
`InkFlowRimeNative` sources compiled by the portable bridge. It links against the source-built
`librime.1.dylib`. SwiftPM exposes that API through the `InkFlowPortable` C module. The dictionary
generator is a separate Rust archive. Both archives contain Rust standard library members, so
the linker must extract members on demand. Forcing either archive to load in full can produce
duplicate symbols. The [Swift ABI smoke test](Tests/PortableABITests/main.swift) links both archives
and librime in the same process, as the app does.

`scripts/build-portable.sh` compiles under `build/portable` and takes the minimum macOS deployment
target from the app manifest, like the native dependency builder. CMake, Boost.Build and Cargo
reuse their outputs. SwiftPM tracks a generated C include that records the identities of the
runtime archive and librime so changes relink their callers. The dictionary build supplies its own
archive-identity include. The standalone build helper expects the repository root as its working
directory. Top-level build and test drivers set `INKFLOW_PORTABLE_BUILT` when they have already built
the runtime for their Swift targets.

License packaging uses the actual target's locked Cargo dependency graph, including build
dependencies. The lockfile can include crates outside that graph. For marisa, the notice source
is `COPYING.md`, which contains the BSD-2-Clause and LGPL-2.1-or-later texts.

## Contracts and tests

- [Swift engine facade and learning](Sources/InkFlowRime/README.md)
- [Dictionary preparation and activation](Sources/InkFlowRime/dictionary-lifecycle.md)
- [Local quality recording](Sources/InkFlowRime/quality-recording.md)
- [Shared regression fixtures](Tests/README.md)

## Prepared resources

Source extraction can restore changed or absent files from verified archives. Verify the raw
inputs even when a generated Chinese dictionary is cached. Its cache key includes the generator
executable, exact legacy bytes and local corrections. Rebuild the spelling profiles and context
index after the generated dictionary changes. The profiles use that dictionary's syllable
inventory and the same generator as the update worker.
