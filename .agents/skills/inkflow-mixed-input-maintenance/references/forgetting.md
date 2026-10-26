# Forgetting a candidate while composing (rule 18)

The detail behind the forgetting sentence of rule 18 in [rules.md](rules.md). While composing, Shift+Backspace (`forget` in [keys.md](keys.md)) forgets the highlighted candidate's learning through Rime's native `delete_candidate`. The core (`forget_highlighted` in [engine.rs](../../../../Core/Portable/src/engine.rs)) sends it as Control+Delete, so it acts on the candidate Rime has highlighted, which is the displayed highlight even when the display order differs from the native one.

Unlike management, it needs neither idle sessions nor an expired undo grace period. Every deletion invalidates the English lookup cache and rebuilds the composition.

## What one press updates

| Highlighted candidate | Effect |
| --- | --- |
| Chinese candidate | One native negative update in `pinyin_simp.userdb` |
| Standalone English `Phrase`/`ShadowCandidate` | One native negative update in `inkflow_shared_english.userdb` |
| Mixed sentence, which belongs to no Rime memory | `inkflow_english.lua` listens to the delete notifier and applies one negative update in `inkflow_shared_english.userdb` for each ASCII run of `mixed_runs` that has a positive record there |
| Custom phrase, or a candidate or run without learning | Nothing visible. A native update on an unlearned entry leaves only a deletion mark that no lookup shows |

## Chinese sentences

A Chinese sentence that Rime's poet made from learned words (candidate type `sentence`) has no record of its own. Deleting its text leaves the poet to make it again from the same words, so the lead would not change. While the highlighted text keeps its place after a deletion, the core therefore:

1. Sends `forget_sentence` through the property channel. `inkflow_english.lua` makes one more negative update in `pinyin_simp.userdb` for the learned component of that sentence (positive commit count) with the greatest weight, through a `Memory` that lives for the call and is disconnected at once, because a live one would end Rime's commit transaction early.
2. Repeats, heaviest first, for at most 8 components, and stops as soon as the text no longer keeps its place. Components without learning and the system dictionary are never touched.
3. If the text still keeps its place after every learned component is forgotten or the cap is reached, those words were not what led it (a sentence of unlearned words that holds a learned one). The core then sends `unforget_sentence`, and `inkflow_english.lua` revives each word it forgot in this press with one positive update. Rime revives a record forgotten at N commits as N + 1, so those words come back with one commit more, which is close enough. The sentence's own deletion mark on a text that was never learned stays.

The trade-off: when the forgetting does move the text, a word learned elsewhere is forgotten too. Forgetting `测试学习奥`, made of learned `测试学习` and `奥`, can cost `奥` its learning in other sentences.

## Regression

`EngineRegression.forgetCandidate(event:)` and `ControllerTests.forgetCandidate()`.
