# Apple acceptance contract

`tools/verify/apple.sh` is the executable acceptance gate for the native Apple
frontends. It starts from ignored generated output and performs the checks
below without selecting a Team ID or signing identity.

## Core packaging

- Verify the pinned librime commit and its recursive dependency lock before
  compiling any slice.
- Build distinct arm64 archives for macOS, iOS device, and iOS Simulator.
- Merge the InkFlow wrapper, librime, yaml-cpp, LevelDB, OpenCC, and marisa into
  each archive before creating the XCFramework.
- Require exactly the 27 symbols in `engine/exports/inkflow_engine.symbols` to
  remain public and require librime's `rime_get_api` to remain private external.
- Inspect each archive's architecture and `LC_BUILD_VERSION` platform.
- Require each XCFramework slice to expose only `engine.h` and its Clang
  `module.modulemap`.
- Compile and link standalone C and Swift consumers against each final
  XCFramework slice with no project static library other than that slice.
- Run both standalone consumers for the native macOS slice.

## Schema and adapter behavior

- Deploy product resources from the sole editable `schemas/source` directory.
- Reject missing prebuilt schema artifacts or leaked writable Rime state.
- Exercise the production engine through Swift with the deterministic
  `nihao -> 你好` transcript.
- Test UTF-8 byte offsets at Unicode-scalar boundaries, including a boundary
  inside a multi-scalar grapheme, and convert them to UTF-16 ranges.
- Test the iOS action pipeline for FIFO execution and delivery, stale candidate
  rejection, exactly-once commit, synchronous own-proxy callback suppression,
  delayed text/selection invalidation, reset barriers, and lifecycle-scoped
  finish completion.
- Wrap every `UITextDocumentProxy` insertion and deletion in a main-actor,
  synchronous mutation scope. Ignore a text or selection callback only when it
  re-enters during that exact proxy call stack, because its origin is then
  provably local. After the proxy call returns UIKit provides neither an origin
  token nor an acknowledgement, so later callbacks remain ambiguous and are
  conservatively treated as external: they invalidate queued work and enqueue a
  coalesced engine reset. This can cancel queued input if UIKit reports a local
  write only asynchronously; without an origin token that case cannot be safely
  distinguished from an actual host edit.

## Native products

- Regenerate the Xcode project twice and require identical output.
- Run the Swift unit suite on macOS arm64.
- Build the macOS InputMethodKit application in Debug with signing disabled.
- Build the iOS host and embedded keyboard extension for iOS Simulator arm64
  with signing disabled.
- Require the schema resource and production core symbol in each IME binary.
- Require the iOS host binary not to contain the production core symbol.
- Require no internal Swift adapter framework or archive to be embedded.

## Metadata and privacy

- Validate the macOS controller class, input-source identifiers, intended
  language, character repertoire, and agent-only application metadata.
- Validate the keyboard extension point, `zh-Hans` primary language, and
  `RequestsOpenAccess=false`.
- Reject App Group configuration, network APIs or frameworks, fake-backend
  selection, machine-local dynamic dependencies, and machine-local paths.

## Evidence boundary

A passing gate proves source generation, unit behavior, unsigned compilation,
static linkage, resource embedding, and metadata structure. It does not prove
code signing, installation, Input Sources registration, launch, interaction in
a host application, a running iOS Simulator session, or physical-device use.
Those layers require an explicitly selected local signing configuration and
separate manual acceptance.
