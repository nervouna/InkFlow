# Foundation acceptance contract

Task 1 is complete only when a fresh checkout can produce all of the following
evidence without product code or a fake production backend:

1. `dependencies.lock.json`, `.gitmodules`, and the checked-out recursive
   `third_party/librime` submodule agree on one repository and commit.
2. Every schema header parses as YAML, every dictionary header and row is valid,
   and the deterministic transcript refers to an isolated test schema.
3. Product schema files exist only in `schemas/source/`; test-only schema files
   exist only in `schemas/test/`; generated platform mirrors are absent.
4. `cmake --preset foundation` configures the real pinned engine and rejects a
   fake production backend; installed toolchains satisfy the locked minimum,
   exact, or major-version requirements.
5. XcodeGen can generate the non-product aggregate project from
   `platforms/apple/project.yml` in a temporary directory.
6. The Android settings project and version catalog agree with
   `toolchains.lock.json`. The Gradle version gate rejects a synthetic 8.13
   result and accepts the exactly locked 9.3.1 result. Discovery runs offline
   only when a wrapper or system Gradle reports that exact version; otherwise a
   missing Gradle is explicitly reported as skipped and a mismatched Gradle
   fails the gate.
7. Expected generated and local-only paths are ignored, canonical inputs are
   not ignored, and the source tree contains no obvious secret or personal
   absolute-path material.

Run the complete contract with:

```sh
./tools/verify/foundation.sh
```

During initial authoring only, `--metadata-only` may validate all repository
content before the parent repository adds the real submodule. It is not valid
completion evidence and must not be used for the Task 1 commit gate.
