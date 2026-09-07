# Technical vocabulary data

The app enables technology, software and Internet vocabulary by default. Chinese
source generation and update behavior are documented in [DICTIONARIES.md](../DICTIONARIES.md).

`english-technology.tsv` supplies 120 exact display spellings and lowercase ASCII
lookup codes. It is an additional spelling source, separate from measured
`english-wordfreq.tsv`. It contains 104 selections from Rime Ice `en_ext` at
`569ff3bc65dd4aec0a26b33c49c8bbdfa8b5fd57` and 16 explicitly maintained InkFlow
spellings. [Upstream file](https://github.com/iDvel/rime-ice/blob/569ff3bc65dd4aec0a26b33c49c8bbdfa8b5fd57/en_dicts/en_ext.dict.yaml)
SHA-256: `d0c11afd09443a8a13ddc79c630ae22c6b9a0403031bf0adaa2c301a127f20ea`, 52,217 bytes.
`english-technology-provenance.tsv` records the exact source lines/codes and
existing measured observations for review. It is provenance, not generator input.

Each active source record has three literal-tab-separated columns: display text,
lowercase ASCII-letter code, and `rime-ice-en-ext` or `inkflow-maintained`. Display
text is printable ASCII with no outer whitespace. Spaces and punctuation remain
in the output; the code must be explicitly usable by the existing translator.
Examples: `SwiftUI / swiftui`, `Claude Code / claudecode`, `C++ / cpp`, `.NET / dotnet`.
Duplicate source pairs and malformed rows fail generation before replacing either
generated dictionary. Equal pairs shared with easy-en collapse; its other aliases
remain available. Empty supplemental data is valid; a missing file is an error.

All records still pass the shared exact-display admission gate. The 109 explicitly
selected spellings with missing/below-4 observations use 4.0 policy replacements
in `config/english-overrides.tsv`. These are not observed measurements. Eleven
existing observations at/above the gate retain their original values. An override
still applies to every source code for the exact displayed spelling and may
exclude it with zero. Case variants are independent. No generic threshold or
runtime translator changed.

The mixed dictionary retains its existing extra conditions: display text is
ASCII letters, at least four characters, and exactly equals the source code.
Cased lowercase-code aliases and punctuated/spaced forms therefore remain
standalone candidates; existing literal aliases can still qualify. There is no
new English-learning dictionary or automatic English sentence splitting.

The supplemental spellings and policy ship with application updates. The Chinese
check/download action does not update this file. Review changes against the
provenance, then run the existing prepare-rime fixtures and native engine tests,
which select all 120 display spellings and verify representative prefix, case,
backspace, short-code and mixed/custom-phrase boundaries. Runtime/UI acceptance
in actual typing clients remains separate from these isolated tests.

See [technology-english-NOTICE.txt](../Licenses/technology-english-NOTICE.txt) for
selection/alias attribution and the existing GPL/LGPL/wordfreq license notices.
