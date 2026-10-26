# Ranking leads and the Chinese-first prior (rule 14)

The detail behind rule 14 in [rules.md](rules.md). It concerns candidates of equal native coverage (rule 1). The Rust ranker ([ranking.rs](../../../../Core/Portable/src/ranking.rs)) orders them from the page metadata that `inkflow_input_coverage.lua` reports. Missing, stale or malformed metadata returns the page to native order, and ranking is skipped after a selected prefix.

## Order at equal coverage

1. Exact custom phrases, which keep their explicit priority.
2. The three leads that share one place, directly behind custom phrases: the [technical lead](#technical-lead), [learned English over a sentence](#learned-english-over-a-sentence) and [personal English in a technical context](#personal-english-in-a-technical-context).
3. A [learned mixed sentence](#learned-mixed-sentences).
4. The single best contextual Han candidate, which keeps the neutral Chinese-first prior.
5. Admitted exact English, then other native candidates in stable order. Exact candidates precede English completions.

## Metadata marks

The `exact` field of a metadata row also carries three marks. `parse_metadata` rejects a mark on any other row, and a rejected row returns the page to native order.

| `exact` | Mark | Judged from | Accepted only on |
| --- | --- | --- | --- |
| 2 | [Technical lead](#technical-lead) | Context property `inkflow_technical_input`, published by the native mixed translator | A whole-input exact English row |
| 3 | A Chinese candidate of Rime type `sentence` | `inkflow_input_coverage.lua` | A native, whole-input, non-ASCII row starting at 0; the ranker reads it on the page's first row only |
| 4 | [Complete-Pinyin personal English](#complete-pinyin) | Context property `inkflow_pinyin_input`, published by the native mixed translator | A personal whole-input exact English row; the ranker leaves it out of the technical-context tier |

## Personal English in a technical context

An exact standalone personal English record may lead only when one of these holds:

- the current session's bounded preceding text (the last 16 graphemes) contains a technical signal: a contiguous two-character ASCII alphanumeric run, or an immediately preceding marker among `代码`, `编程`, `开发`, `命令`, `终端`, `接口` and `版本`;
- the page's first candidate is a composed sentence ([learned English over a sentence](#learned-english-over-a-sentence)).

### Complete Pinyin

The technical signal does not lift that record when the input is all lowercase and complete normal Pinyin syllables, judged with the same native spelling evidence as rule 9. Abbreviation, typo-correction and fuzzy spellings never make an input Pinyin. The record then takes the place of exact English behind the best Han candidate and keeps its personal bucket among the English rows, so 呢, 哦 and 背景 lead for `ne`, `o` and `beijing`, with `ne`, `o` and `Beijing` still on the first page.

- One letter uses the same test: `a`, `e` and `o` are syllables; `i`, `u` and `v` are not and keep the lead.
- Input with any uppercase letter is explicit English intent and keeps the lead.
- Inputs that are not complete Pinyin keep the lead: `claude`, `skill`, `memory`, and `agent`, which is Pinyin only up to an unfinished final syllable.

## Technical lead

When the input is 4 or more ASCII letters, an admitted exact standalone English candidate covers all of it, and native spelling evidence (rule 9) finds that the input is not complete normal Pinyin syllables optionally followed by one unfinished final syllable, the first exact English candidate in the English order leads the page.

- Abbreviation, typo-correction and fuzzy spellings never make an input Pinyin. An unfinished final syllable is the start of a key with a normal spelling, found with the prism's expand search, so there is no syllable table.
- `macos`, `deepseek` and `python` are not Pinyin-shaped. `email` (e mai l), `chin` (chi n), `shanghai` and `banana` are, and keep their order.
- The English candidate must share the first candidate's coverage.
- Inputs of 3 or fewer letters, completions and mixed sentences are unchanged.

## Learned English over a sentence

When the page's first candidate is a Chinese candidate of Rime type `sentence` at full coverage and an exact standalone English candidate of the same coverage has personal evidence (bucket 1-3), the first such candidate in the English order, which is the strongest bucket, leads without a technical signal. Other personal variants keep their place behind the Chinese reading. Nothing else changes.

A `sentence` is the poet's assembly of separate words, such as `热了阿瑟` for `release`. The script translator makes one only when no reliable whole-input phrase exists, and the input may be complete Pinyin (`re le a se`), which the technical lead excludes.

A first candidate of type `phrase`, `user_phrase` or `user_table`, or any other Chinese candidate, keeps its place. So a dictionary word (`shanghai` 伤害, `a` 啊) and a phrase the user learned (choosing a sentence makes Rime store it as a `user_phrase`) keep their priority, and an English word that is not learned stays behind the sentence.

## Learned mixed sentences

A mixed sentence whose every ASCII run has personal evidence (personal bucket 1-3, rule 8) is placed directly before the best Chinese candidate of equal native coverage, after custom phrases and technical-context personal English and ahead of exact English; a stronger bucket first. A sentence with any unconfirmed run keeps its place among exact English and mixed candidates. Rule 9 still decides which lowercase codes can be personal tokens, so complete Pinyin sequences such as `women` never promote a sentence.

## Limits

- Personal strength is capped at three commits.
- Context is memory-only and per session. Neither candidate nor context text enters ranking metadata or persistent state.
- Existing exact Han phrase matching remains bounded by the pinned dictionary; this is not contextual English prediction.
