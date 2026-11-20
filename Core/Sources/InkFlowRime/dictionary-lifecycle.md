# Dictionary preparation and activation

The [shared recipe](../../../docs/shared-dictionary-preparation.md) builds the immutable source tree.
The [Rust generator](../../Portable/dictionary/README.md) owns the production Chinese dictionary,
spelling profiles and context index. Swift's `IFContextRanker.buildIndex` remains a byte-level
reference used by tests. It builds sorted keys from three bytes per canonically normalized scalar.
Live ranking belongs to the Rust core. A descriptor identifies the prepared index, which the engine
loads on initialization. The packaged cache receipt binds data bytes, independent of binary signing
and notarization.

## Preparation boundary

Swift retains its foreign input buffers across each synchronous dictionary-generator call. The
embedded catalog is read from the verified Rust library. The CLI and update worker share this
generator. Resource preparation accepts the isolated native operations provided by the host
without launching a process itself. Put replacement staging under the sandbox's candidate
directory. The host uses disposable runtime resources, candidate directories and user data when
constructing a packaged cache for tests. Compiling in a separate process keeps initialization
and finalization away from any serving Rime runtime.

Each source fetch uses an ephemeral delegate. Apply the byte bound while receiving the response
and preserve the source policy through redirects. Public endpoints may use system TLS trust and
receive no credentials. Resolve every destination from locally generated paths. To compare
filesystem paths, use the canonical identity obtained from `realpath`; Foundation can collapse
`/private` aliases differently before and after creation. Hashing reuses one read buffer because
`FileHandle` chunks could accumulate as autoreleased objects during a large read.

## Startup and active dictionary replacement

The process owns the coordinator and its single operation. Settings observes its progress.
Construction without an injected backend or factory performs no default filesystem, preference,
network or engine work. A new error from a running operation can appear in the current
presentation, while a reopened view starts free of old failures. An explicit user action after a
successful availability check starts download and preparation.

Production `bootstrapForServing` starts from the packaged compiled cache before constructing the
input server. Deferred recovery validates artifacts on a background executor while the packaged
engine keeps serving. The synchronous bootstrap entry is used by the focused harnesses.
The standalone engine initializer can compile into the user's `build` directory when no prepared
cache is supplied. This cache path is retained for compile-free rollback. Its missing-resource
error retains the standalone `NSError` contract. Production supplied caches skip deployment.

Adoption and immutable-artifact validation hash files off the input actor. Single-flight remains
occupied while prepared activation waits for shared idle. Activation runs on the deferred idle
signal once every session and delivery lease settles. Journal updates at the switch are compact.
Abandoning an activation and cleaning up artifacts run off the main actor. Native startup, probing
and every restored session must succeed before confirming the artifact. Test seams can fail each
of those steps without replacing normal hashing or filesystem validation.

Personal-data operations require a settled configuration, no pending dictionary operation, and
an idle engine past its ordinary undo grace. The reservation stops the engine and suspends input
until the transaction completes. The worker operates on closed staged databases. Shutdown
cancels optional preparation and awaits its producers before abandoning their files. Entered
synchronous journal or native activation operations finish. Cleanup and final journal writes
use separate uncancelled tasks.

## Store and recovery

A state write's rename is its commit boundary. A later directory-sync hint cannot turn success
into an uncommitted transaction. Begin and confirm specializations take a descriptor resolved
in the same serialized operation. Confirmation follows successful engine and session startup,
and does not hash the cache again on the serving path. A content-equivalent source update saves
new provenance only after generation proves the same active content. It keeps the activation date.

Keep historical journal identities readable so recovery can reject incompatible manifests and
select the bundled artifact normally. An interrupted pending version is abandoned. Confirmed and
fallback pointers supply recovery candidates. Startup can regenerate an older recipe only where
it retained raw data for the current source catalog. Rebuilds use the current app schemas, Lua and
corrections. An artifact that cannot rebuild is superseded by the packaged fallback rather than
retried indefinitely.

While only the transient packaged engine is usable, preserve saved versions and journal pointers
for retry. Confirm a recovery after its engine starts. Repair an unreadable journal only after
the packaged fallback actually starts. Confirming the bundled fallback after exhausting
recoverable alternatives prevents the next launch from replaying those failed artifacts.

Version directories have locally generated identities `rN-contentSHA-runtimeSHA-UUID`.
Housekeeping is bounded, protects journal references and does not traverse outside the owned
store into personal learning or custom-phrase data. Treat unknown file types and regular files
as outside recursive cleanup even if their names resemble version directories.
