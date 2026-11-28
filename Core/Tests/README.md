# Shared regression fixtures

The standalone Swift package compiles its test products without the macOS app. The embedded
full suite delegates duplicated expensive runs to the canonical macOS units and keeps the
Core-only voice coordination tests. The macOS engine host supplies native event metadata, while
the standalone engine host uses the same Rime key. Fixture modifier bits are Shift 1, Command 2,
Control 4 and Option 8.

## Engine input and learning

[`EngineRegression.swift`](InkFlowEngineTestSupport/EngineRegression.swift) uses failure messages
keyed to the [composition key table](../../.agents/skills/inkflow-mixed-input-maintenance/references/keys.md).
The key-matrix cases cover idle, composing and recognizer-match input. A recognizer match retains
raw text without a menu. Home/End cases cover Rime order, contextual reordering and a learned
mixed sentence. At the start of the input, Rime rebuilds the composition and cannot keep a later
candidate highlighted, so the page follows native order. End from the start ranks the page
again. An email recognizer case uses an apostrophe to break the email pattern. Keep page-based
checks independent of implicit candidates such as Emoji.

The [mixed input policy](../../.agents/skills/inkflow-mixed-input-maintenance/references/rules.md)
owns English admission and ranking. Keep the first case and mixed-decoding checks ahead of
selections that teach the shared dictionary. Words selected in a mixed sentence can later lead
as standalone English. Keep mixed examples that admit a competing full-coverage Chinese
abbreviation focused on reachability and exact selection. The Caps Lock fixtures send uppercase
characters without the Shift modifier. They ensure previously learned lowercase input does not
override explicit typed case. Measured Frost counts put 背景 first for `beijing` and its tested
transposition while leaving 北京 selectable.

The mixed-learning fixtures isolate words from other tests. They observe personal provenance
when a word such as `google` leads regardless of learning. Tab closes the undo window without
teaching another word, while immediate Backspace reverses the selection. A native lookup cached
for one input can hide a changed record until another input invalidates it. The complete-Pinyin
cases verify that uppercase, technical non-Pinyin and individual nonsyllable letters lead as
specified, while learned complete lowercase Pinyin stays behind Han. In the technical guard
fixtures, the old `tin` and `chin` leaders 题嗯 and 吃嗯 depended on a consonant-only syllable
that profiles now discard. The evidence row's `exact` field marks exact English, technical input
and complete Pinyin with bits 1, 2 and 4 respectively.

The forget-learning cases isolate native user data, verify that a previous composing session
does not prevent phrase-file reload, and cover Rime's poet composing a sentence from words.
Deleting the sentence's own record may leave the same sentence assembled from separately learned
words. The cases cover one whole selection, partial selections, independent words and learning
through both routes. The fallback tries the strongest contributing learned word and restores
records whose deletion leaves the leader unchanged. The `cs` fixture checks restoration when
a learned word contributes to a sentence that already led without it. The poet-only English lead
guard checks that the pre-rule leaders for `shanghai`, `a` and `release` remain at their documented
boundaries when learning or explicit intent changes.

## AI and voice

The [AI adoption fixtures](AIAdoptionLearningTests/AIAdoptionLearningTests.swift) use real shared
user dictionaries, including across restart. Lookup and display must leave native undo and
learning untouched. A rejected management read may not close an ordinary undo window. Explicit
English deletion and restoration count as learning effectiveness acts, while voice aliases and
failed undo do not. Effectiveness checks use a separate quality store outside the Rime user
directory. The export command reads one named database in a closed fixture, producing empty output
when it is absent. A test-only Lua module owns the `learning_contract` command ([fixture rules](../../macOS/Docs/TestHarnessContracts.md#test-fixture-constraints)). Native end-to-end
cases verify versioned property transport in addition to the portable channel tests.

The carrier fixtures keep a real Chinese prefix. They use keypad movement when a source-character
step is required, since Rime's Rewind can jump whole syllables. Native syllable spaces and
apostrophes preserve the user's letters and cannot justify fabricated Latin carriers. Cover
single-letter `i`/`a` inside normally spelled syllables and alternate syllable boundaries.

## Dictionary fixtures

The tests compile and probe real resources in an isolated host. The fixture host and macOS host
share preparation and activation assertions, while assembling subprocesses and resources
separately. A test fault can reject startup, probing or restoration of an already allocated
session. Use valid synthetic identity for lifecycle tests; malformed metadata is covered by the
store tests. A new syllable must rebuild the spelling guard in both downloaded and dictionary-only
preparation even when the bundle still uses its old inventory.

The retained Swift generator is a compatibility reference for the [Rust generator](../Portable/dictionary/README.md).
It consumes only the tab-separated body, treating remote headers and imports as inert.
Specialty dictionaries fill weights only where the calibrated base union has a gap and cannot feed
back into overlap calibration. Saturation is applied at the signed Rime weight boundary to mapped
source weights. A single spelling inventory supplies normal equivalents, enabled fuzzy pairs and
the full-spelling collision set. Only typo copies carry transformations. Validate final combined
aliases and remove the marker before compiling, preserving original and fuzzy paths.

[`test-prepare-rime.sh`](../scripts/test-prepare-rime.sh) compares CJK data by bytes under
`LC_ALL=C` because macOS AWK locale collation can compare distinct strings as equal. It builds
stand-in generators in a discarded fixture repository so the English policy tests are isolated
from the Chinese/spelling generator tests. It verifies that spelling generation sees the replaced
Chinese dictionary and that empty admission data cannot fall back to historical weights.
Repeated shaping uses distinct text/code pairs and Rime file order for equal-weight case variants.
