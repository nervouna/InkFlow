# Build metadata tools

`QualityBuildMetadata` stamps actual working-tree source bytes and the resources copied into the
bundle. Include the portable Rust engine, ranking implementation, native bridge, C ABI header and
pinned dependencies. Record a missing tracked input as a distinct entry. Hash files in stable path
order with their kind, length-framed path and length-framed contents, without file timestamps.

The ranking source digest uses exact bytes of the audited sources from
[`ranking-sources.txt`](../Quality/ranking-sources.txt). An edit to an audited comment changes the
recorded ranking fingerprint even when it leaves the executable policy unchanged. Do not interpret
a fingerprint change from those edits as a change in ranking accuracy.

Ordinary metadata verification compares the complete bundle digest after removing embedded
signatures and excluding signature artifacts. Re-signing can also change Mach-O layout beyond the
removed blobs. Signed metadata verification keeps the source, resource, ranking, version and build
checks. The release caller runs separate signature verification. Verifying the signed executable
payload against the build output is tracked separately. [Issue #233](https://github.com/nervouna/InkFlow/issues/233)
