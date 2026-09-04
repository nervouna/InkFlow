# Transcript format

Transcripts are versioned JSON fixtures consumed by shared and platform adapter
tests. Each action represents one synchronous engine operation and its complete
expected snapshot delta.

`formatVersion` changes only for incompatible fixture-shape changes. `schemaId`
must name a schema in `schemas/test/`, and deterministic fixtures must not use a
user dictionary.
