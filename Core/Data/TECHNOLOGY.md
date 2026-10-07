# Technical vocabulary data

`english-technology.tsv` supplies 122 exact display spellings with lowercase ASCII
lookup codes: 104 selections from Rime Ice `en_ext` at
`569ff3bc65dd4aec0a26b33c49c8bbdfa8b5fd57`
([upstream file](https://github.com/iDvel/rime-ice/blob/569ff3bc65dd4aec0a26b33c49c8bbdfa8b5fd57/en_dicts/en_ext.dict.yaml),
SHA-256 `d0c11afd09443a8a13ddc79c630ae22c6b9a0403031bf0adaa2c301a127f20ea`) and 18
InkFlow-maintained spellings. `english-technology-provenance.tsv` records the source
lines/codes for review; it is not generator input.

Each row has three tab-separated columns: display text (printable ASCII, no outer
whitespace), lowercase ASCII-letter code, and `rime-ice-en-ext` or
`inkflow-maintained`. Examples: `SwiftUI / swiftui`, `eBPF / ebpf`,
`Type-C / typec`, `C++ / cpp`. Duplicate or malformed rows fail generation; pairs
equal to an easy-en entry collapse. An empty file is valid; a missing one is an error.

Rows pass the same admission gate as easy-en. The 111 selections without a
sufficient measured frequency are admitted by 4.0 policy rows in
`Core/config/english-overrides.tsv`. Gate and mixed-dictionary rules are in
[the mixed-input rules](../../.agents/skills/inkflow-mixed-input-maintenance/references/rules.md).

The file ships with app updates, not Chinese dictionary updates. Attribution is in
[technology-english-NOTICE.txt](../../macOS/Licenses/technology-english-NOTICE.txt).
