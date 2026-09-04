# Shared engine acceptance contract

The shared engine is complete only when a fresh host build provides all of the
following evidence:

1. A strictly C11 consumer compiles against only `engine.h` and uses opaque
   runtime, session, and snapshot handles.
2. The process accepts one runtime generation, rejects duplicate or recreated
   runtimes, and reports invalid, closed, and finalized handles explicitly.
   Runtime creation only initializes librime. Explicit preparation deploys raw
   schemas, returns `INKFLOW_STATUS_RUNTIME_IN_USE` while a session is active,
   and can be skipped by platform clients that bundle compatible prebuilt data.
3. Every snapshot owns a deep copy of its commit, preedit, and candidate text;
   a later session operation cannot mutate an older snapshot.
4. Public text is UTF-8, all preedit ranges are documented byte offsets, and no
   librime type or C++ exception crosses the C boundary.
5. One portable key mapping accepts Unicode scalar values and named editing or
   navigation keys while rejecting invalid scalar values and modifier bits.
6. Concurrent calls on independent sessions keep their composition state
   isolated while the runtime lifecycle remains serialized.
7. The checked-in transcript explicitly prepares only the isolated
   `inkflow_test` schema, types `nihao`, exposes `你好`, and commits it. Separate
   lifecycle checks cover reset, a nonexistent schema, invalid candidates,
   unavailable pages, closed handles, and forced commits with both empty and
   active compositions.
8. Configuring a fake production backend fails instead of silently substituting
   test behavior.
9. ASan and UBSan tests pass. Both the thin engine archive and an actual shared
   library containing the complete native link closure expose exactly the 27
   names in `engine/exports/inkflow_engine.symbols`; the closure contains
   librime while keeping every librime and dependency symbol local. Host test
   executables and the shared closure do not load a package-manager librime,
   Boost, or OpenCC library. AppleClang's macOS ASan runtime does not provide
   LeakSanitizer, so this preset disables only leak detection while retaining
   address and undefined-behavior checks. The instrumentation is scoped to
   InkFlow-owned engine and test code rather than recursively instrumenting
   pinned third-party sources; the RapidJSON 1.1 transcript parser is excluded
   from UBSan while the engine it drives remains instrumented.
10. FetchContent keeps dependency-, generator-, CMake-version-, and build-tool-
    specific population state while a lock gives one owner to the shared,
    hash-verified Boost archive and source. A ready marker is published only
    after source validation; later configurations never re-extract it.
    Configuring with pinned Android CMake and Ninja after a Unix Makefiles build
    must succeed without deleting either build.

Run the normal host contract with:

```sh
./tools/verify/engine.sh
```

Run the instrumented contract with:

```sh
cmake --preset engine-sanitize
cmake --build --preset engine-sanitize
ctest --preset engine-sanitize
```
