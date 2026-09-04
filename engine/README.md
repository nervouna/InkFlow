# Shared engine boundary

`include/inkflow/engine.h` is the only engine interface exposed to platform
targets. Its implementation builds the pinned recursive librime source and its
pinned dependencies behind one CMake target. Platform targets must not include
librime headers directly. Platform packaging combines that target's static
link closure into the generated native artifact.

## Contract

- Runtime, session, and snapshot handles are opaque to C callers.
- A process owns one runtime generation. Creation only sets up and initializes
  librime. Raw schema deployment is a separate synchronous `runtime_prepare`
  operation that returns `INKFLOW_STATUS_RUNTIME_IN_USE` while sessions are
  active; clients with compatible prebuilt data skip it during cold start.
  Finalization is explicit.
- Sessions have independent composition state. A process-wide lifecycle lock
  serializes calls into librime.
- Snapshots own deep copies of all returned text and outlive later session
  operations.
- Text is UTF-8 and preedit cursor and selection ranges are byte offsets.
- Portable key codes are translated in one engine-owned mapping.
- `session_commit` synchronously commits the current composition and returns an
  owned snapshot; an empty composition is a successful unhandled operation.
- Session creation rejects a syntactically valid schema ID when its deployed
  config is missing, unreadable, or reports a different `schema/schema_id`.
- Every fallible ABI call returns an explicit status and catches C++
  exceptions.

Callers supply distinct read-only shared/prebuilt data paths and writable
user/staging paths. The application name must use librime's `rime.` prefix.
A fake production backend is rejected during configuration.

Bundled librime and dependency objects compile with hidden visibility. A final
`SHARED` or `MODULE` platform target that statically embeds `InkFlow::Engine`
must call `inkflow_apply_engine_export_boundary(target [extra_symbol ...])`.
The checked-in manifest is the single allowlist for the 27 engine C symbols;
optional extra names are reserved for required platform entry points such as
`JNI_OnLoad`. The `inkflow_engine_link_closure` target is a non-shipping audit
artifact containing the complete native closure.

Boost's hash-pinned archive and extracted source are shared under the ignored
dependency cache. A cache lock gives the first configuration sole ownership of
population and publishes a ready marker only after validation. FetchContent's
small population sub-build is keyed by the dependency digest, CMake generator,
CMake version, and build-program path; later configurations only read the
validated source. Unix Makefiles, Xcode, and Android Ninja therefore cannot
reuse incompatible state or re-extract over a concurrent build.

## Host verification

```sh
./tools/verify/engine.sh
cmake --preset engine-sanitize
cmake --build --preset engine-sanitize
ctest --preset engine-sanitize
```

The tests explicitly prepare only `schemas/test/`, prove creation itself does
not deploy, and execute the checked-in transcript, including the real `nihao`
to `你好` candidate and both candidate-selection and forced-composition commit
paths.
