# Input quality metrics

One metric system for two questions: how well InkFlow ranks candidates, and how intelligently it learns. It scores
field decisions (what the user actually did), offline replays (what a change would have done on those decisions) and
fixed benchmarks (what any input method does on a public corpus), with the same definitions in all three.

Design rules:

- **Definitions name only user-visible events.** A metric's numerator and denominator refer to the event model in
  section 2: code typed, list shown, action taken, text committed, text kept. Engine facts (Rime candidate type, the
  corrected flag, the ranking evidence row, user-dictionary state) are breakdown dimensions, never terms of a formula.
  That is what lets the same metric be computed for another input method, where no engine fact is visible.
- **Every rate is a fraction with a stated denominator, an exclusion list, a unit of analysis and a 95% Wilson
  interval.** A zero denominator is "unavailable", never 0%.
- **Judgement is per bucket, never a composite score.** The scorecard under the first-choice target lists the headline metrics; none is
  a weighted sum of the others.
- **Content-free by default.** Every signal this document uses is a count, a flag or a keyed hash whose key never
  leaves the device ([pair hashes](../macOS/QUALITY-EXPORT.md#pair-hashes)). Literal text appears only in records
  written while 「同时保存输入文本」 is on.

## The first-choice target

- **Metric.** R1, R3 and R-paged (section 5) over Chinese decisions, `top1_selected`, `top3_selected` and `paged_selected` over `known_rank`, read from the `chinese` series of `trend --days 28`. Every rate is reported with its 95% Wilson score interval over the 28-day rolling window. A wrong first choice accepted with Space is invisible to them; replay leaves out or relabels such a choice when the user reverted it at once (`replay-cases` in the [query contract](../.agents/skills/inkflow-quality-analysis/references/query-contract.md)).
- **Target band (adopted 2026-10-20).** 28-day rolling Chinese top-1 at least 95.5% with the Wilson lower bound at least 95.0%; top-3 at least 99.0%; paged selections at most 0.4% of known-rank decisions; by selected length, 1-char at least 93%, 2-char at least 96.5%, 3+ chars at least 99%. The target and PR acceptance are judged per bucket, not on the aggregate: a change that lifts the aggregate while a bucket stays below its line does not meet the target. Reference point when adopted: 94.37% [93.89, 94.82] aggregate, 1-char 90.61%, 2-char 95.02%, 3-char 97.92%.
- **Stable** means two non-overlapping 28-day windows whose Wilson 95% lower bound is at or above the target line, for the aggregate and for every bucket. That needs 56 days of records written by schema v4 or later, in either text mode. Local retention is 28 days and
  weekly export files are deleted after 35 days, each covering at most 14 days, so keep an earlier export and read it
  with `--exports-only` to assemble the second 28-day window.
- **Raising the bar.** The aggregate target moves to 96.5% only after two non-overlapping 28-day windows with the lower bound at least 96.0% and the 1-char bucket at least 94%. 97% is the long-term goal, not a near-term acceptance line. It is adopted only after a paired replay arm (list or engine mode) holds at least 97% across two such windows.
- **Ship rule.** Any ranking change ships when paired `fixed - broken > 0` and the McNemar `p < 0.05` on distinct `(raw_input, selected_text)` pairs, in list or engine [replay](../Core/Portable/replay.md#replay). Report it with the distinct count and the per-class and per-bucket breakdown, never as a comparison of two unpaired windows.
- **Sample size.** About 2.4k, 6.3k and 13k decisions are needed to see +1, +0.5 and +0.3 percentage points at disagreement rates of 3%, 2% and 1.5%. This is `n = d * (2.8 / delta)^2` for 80% power at two-sided 0.05, with `d` the share of decisions on which the two arms differ in outcome and `delta` the net gain.

### Scorecard

Per bucket, each with its interval; targets exist today only for the R family.

| Headline | Reads | Target |
| --- | --- | --- |
| R1 by selected length | ranking accuracy | the target band above |
| R-paged | first-page sufficiency | the target band above |
| C-rev | wrong choices the user had to undo | proposal pending data |
| E-kspc (Chinese) | effort per character | proposal pending data |
| L-avoid (interim: learned-provenance miss share) | learning recall | proposal pending data |
| L-over | learning precision | proposal pending data |

## 1. Sources of the numbers

- Field records: `quality.py` and its [query contract](../.agents/skills/inkflow-quality-analysis/references/query-contract.md). Replay: [Replay](../Core/Portable/replay.md#replay).
- Fixed benchmark: [Core/Fixtures/QualityBaseline](../Core/Fixtures/QualityBaseline/README.md). Latency and memory limits are not quality metrics: `Core/Portable/performance.sh`.

## 2. Event model

All metrics are defined over these entities. Names in parentheses are the fields that carry them today.

| Entity | Definition | Today |
| --- | --- | --- |
| **Composition** | From the first key that starts a code to the key that empties it: commit, cancel or interruption. | `compositions` (outcome, operation totals, timing) |
| **Code** | The letters typed for a span, as typed (abbreviations and fuzzy spellings included), without the already-selected prefix. | `snapshot.rawInput`, `selectedPrefix`, `caret` |
| **Shown list** | The ordered candidates the user could see when acting: page, page size, highlighted index. The *shown-first* is index 0 of page 0 of the same code and context. | `snapshot_json`, `first_page_json`, `visitedPages` |
| **Decision** | One act that resolves a span of the code into text from a shown list. Action: accept highlighted (Space), pick by digit, pick by pointer, after optional paging and highlight moves. A decision is *whole* when its span ends at the end of the code, *segment* otherwise. | `candidate_decisions` (trigger, outcome, `selected_display_index`, operations) |
| **Commit** | Text delivered to the application, with its kind: candidate, punctuation, raw letters, ASCII, forced flush, mode toggle. | `commits` (kind, `insertion_issued`) |
| **Post-commit window** | Keys arriving after a commit until the next code starts, the client or application changes, InkFlow is deactivated, or `W` seconds pass: deletions, forward deletions, Cmd+Z, direct text, paste. Fields and `W`: [interpretation](../.agents/skills/inkflow-quality-analysis/references/interpretation.md#deletions-and-post-commit-windows). | `operations_json.postCommitWindows` of the next composition |
| **Pair** | The identity `(normalized code, chosen text)`; **word** is the chosen text alone. Hashed in both modes; literals additionally in text mode, so one window that spans a mode switch is one identity space. | `codeHash` and the selected candidate's `textHash` ([pair hashes](../macOS/QUALITY-EXPORT.md#pair-hashes)); literals in text mode |
| **Learning act** | A user act about learning: forget the highlighted candidate (Shift+Backspace), delete or restore an entry in Settings. | `effectiveness_events` `candidate_learning` as counts; no pair hash |

Dimensions, usable on any metric, never inside a formula:

| Dimension | Values | Source |
| --- | --- | --- |
| Text kind | chinese, english, mixed, emoji, symbol, number, other | `text_kind` |
| Selected length | 1, 2, 3+ characters | `selected_character_count` |
| Code kind | full spelling, abbreviation, corrected spelling, mixed Latin | `corrected`, evidence span, code letters |
| Candidate provenance | dictionary (`phrase`, `user_table`), learned (`user_phrase`, personal English and mixed types), assembled (`sentence`), completion, custom phrase, English module | `type`, `matches_custom_phrase`, `source` |
| Position | first segment of the composition, later segment, whole | `sequence`, selected prefix |
| Context | preceding text present or empty | `precedingContext` non-empty |
| Learned state | cold (fresh user directory) or trained | benchmark and replay |
| Application | bundle identifier | `app_bundle_id` |

## 3. Truth hierarchy

What counts as "right" depends on which truth a metric uses. Each metric names its truth.

| Level | Truth | Catches | Misses |
| --- | --- | --- | --- |
| T0 | **Shown-first**: index 0 of the first page for the code and context | what the engine would commit with one Space | everything |
| T1 | **Selected**: the candidate the user picked from the list they saw | a wrong first choice the user noticed and corrected by digit, pointer or paging | a wrong first choice accepted with Space; a user who gives up and takes the first candidate |
| T2 | **Committed**: the text delivered to the application, across all decisions of the composition | segment-by-segment choices as one whole | the same as T1 |
| T3 | **Kept**: committed text not deleted in the post-commit window | a wrong first choice accepted with Space and then deleted | a wrong choice the user left in the document |
| T4 | **Intended**: the corpus target | everything, in a benchmark | nothing is known about the user |

Rules:

- Ranking metrics (R family) use **T1**. The adopted target band is defined on T1 and stays comparable.
- Correction metrics (C family) compare **T2 against T3**. The adjusted first-choice rate `R-adj` is reported beside
  `R1`, never in its place.
- Benchmarks use **T4**; a benchmark run of InkFlow reports both T0-against-T4 (one Space) and the scripted search
  that the baseline fixture performs.
- A paged choice is a T1 miss for the first page: the user saw the first page and rejected it.
- A cancelled composition has no T1; it counts in the C family only.

## 4. Scenario coverage

Every scenario the records can tell apart, the signal that identifies it, and the metrics it feeds. "Regular" is the adopted cohort (trigger Space, digit or panel; outcome committed; insertion issued;
list shown).

| # | Scenario | Signal | Metrics |
| --- | --- | --- | --- |
| 1 | Space accepts the first candidate | regular, display rank 1 | R1 hit, E-onekey |
| 2 | Digit or pointer picks rank 2–9 on the first page | regular, rank 2–9, page 0 | R1 miss, R3, R-mrr |
| 3 | Page turn, then pick | regular, page > 0 | R-paged, E-page; replay class `off_page` |
| 4 | Arrow or Tab moves the highlight, then Space | `candidateMoves` > 0 | rank by highlighted index; E-sel |
| 5 | Segment choice, then more typing | span ends before the code ends; `sequence` > 1 | R-sent miss; replay class `segmentation`; position dimension |
| 6 | Whole input in one choice | one regular decision covering the whole code | R-sent, R-char (text mode for R-char) |
| 7 | Backspace or Delete before commit | `preeditEdits` > 0, `inputBeforeDeletion` | C-pre; retyped-code dimension in text mode |
| 8 | Escape abandons the code | composition outcome cancelled | C-cancel |
| 9 | Return commits the raw letters | commit kind `raw_return` | C-raw |
| 10 | Punctuation commits the highlighted candidate | trigger punctuation | implicit acceptance; outside the regular cohort |
| 11 | Shift-typed or ASCII text committed directly | commit kind `ascii`, text kind english/mixed | text-kind dimension; C-raw excludes it |
| 12 | Undo of a selected prefix inside the composition | decision outcome `reverted` | excluded from regular; counted in C-pre |
| 13 | Deletion right after commit covering the committed text | post-commit window: deletions ≥ committed length before other typing | C-rev, R-adj |
| 14 | Deletion of part of the committed text, then typing | deletions 1 … length − 1, then direct text | C-partial |
| 15 | Cmd+Z right after commit | post-commit window: undo | C-rev |
| 16 | Same code typed again right after a revert | next composition's pair identity equals the reverted one | C-retype (confirms an engine miss, not a change of mind) |
| 17 | Chosen candidate was a learned entry | provenance learned | L-over, provenance dimension of every R metric |
| 18 | The same pair chosen again | pair identity recurs in the window | L-ttl, L-futile, L-util, L-avoid, L-reuse |
| 19 | Shift+Backspace forgets the highlighted candidate | learning act `forgotten` (counts only, no pair hash) | L-forget |
| 20 | Entry deleted or restored in Settings | learning act `deleted`, `restored` (English entries; counts only, no pair hash) | L-forget |
| 21 | Custom phrase chosen | `matches_custom_phrase` | provenance dimension |
| 22 | Fuzzy or abbreviated spelling reached the candidate | `corrected`, code kind | code-kind dimension |
| 23 | Homophone that depends on context (的/地/得, 他/她/它) | selected text in the function-word set, context present | R-ctx; replay class `function_word` |
| 24 | Secure input, list not shown, engine-only observation | presentation `not_shown`, timing suppressed | excluded from every denominator |
| 25 | AI suggestion accepted, voice text committed | own telemetry (`effectiveness_events` sources) | out of scope here |

## 5. Metric catalog: ranking, effort, correction

Columns: numerator / denominator, unit, truth, source (F = field records, P = replay, B = benchmark; the design
sources, not what is implemented), the command that computes it today, the industry counterpart it maps to, and the bias
to state when reporting. Dimensions from section 2 apply to all.

### R: ranking accuracy

| ID | Name | Numerator / denominator | Unit | Truth | Source | Computed by | Counterpart | Bias |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| R1 | First-choice rate | regular decisions at display rank 1 / regular known-rank decisions | decision | T1 | F P B | `trend`, `summary` | 首选率; top-1 MIU accuracy | blind to Space-accepted errors; see R-adj |
| R3 | Top-3 rate | rank 1–3 / same denominator | decision | T1 | F P B | `trend`, `summary` | 三选率; P@3 | same |
| R-mrr | Mean reciprocal rank | Σ 1/rank / known-rank decisions; a paged choice uses its global rank | decision | T1 | F P B | not computed | MRR | dominated by rank-1 share; report with the rank histogram |
| R-paged | Paged rate | decisions chosen on page > 0 / known-rank decisions | decision | T1 | F P B | `trend`, `summary` | 翻页率 | depends on page size (9 here) |
| R-sent | Whole-input first-choice rate | compositions resolved by one regular decision at rank 1 covering the whole code / regular committed compositions | composition | T1 | F P B | not computed | 整句首选率; sentence accuracy | penalizes segment typers; report E-dec beside it |
| R-char | Character accuracy of the first candidate | 1 − edit distance(shown-first for the whole code, committed text) / committed length, averaged over compositions | composition | T2 | F(text) P B | not computed | 字准确率; 1 − CER (Gao, Suzuki & Yuan 2006) | needs the shown-first for the whole code; segment choices make it a lower bound |
| R-ctx | Context-conditional first-choice rate | R1 over decisions whose selected text is in the function-word set and whose context is non-empty | decision | T1 | F P B | not computed | none standard | small n; report the interval only below 200 decisions |
| R-adj | Kept first-choice rate | rank-1 decisions whose commit was kept / known-rank decisions with a post-commit window observed | decision | T3 | F | not computed | none standard | window `W` and deletion threshold are instrument constants |

### E: effort

| ID | Name | Numerator / denominator | Unit | Truth | Source | Computed by | Counterpart | Bias |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| E-kspc | Keystrokes per committed character | all keys of the composition (letters, edits, paging, moves, selection) / Unicode scalars of its candidate commits' text | composition | T2 | F B | `trend`, `summary` | KSPC; 键均; KySS (Jia & Zhao 2013) | abbreviations lower it; English and mixed compositions are a separate series |
| E-onekey | One-key commit rate | regular decisions with no paging, no move and trigger Space / regular decisions | decision | T1 | F B | `trend`, `summary` | none standard | the user-effort view of R1 |
| E-sel | Selection overhead | paging + highlight moves + digit keys / regular decisions | decision | — | F B | not computed | none standard | arrow across a page counts as a page turn and a move; never summed into a distinct count |
| E-page | Page turns per 100 decisions | `pageTurns` × 100 / regular decisions | decision | — | F B | not computed | none standard | |
| E-dec | Decisions per composition | regular decisions / regular committed compositions | composition | — | F B | `trend`, `summary` | none standard | user habit as much as engine quality; context for R-sent |
| E-wait | Post-edit wait | p50 and p95 of `postEditWait` on ended compositions | composition | — | F | `timing` | time-to-select | hesitation and reading time, not engine time; never pooled with key latency |

### C: correction

| ID | Name | Numerator / denominator | Unit | Truth | Source | Computed by | Counterpart | Bias |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C-pre | Pre-commit edit rate | compositions with `preeditEdits` > 0 / compositions | composition | — | F B | `trend`, `summary` | 回删率; corrected error rate (Soukoreff & MacKenzie 2003) | mixes typing slips with engine misses; the retyped-code dimension (text mode) separates them |
| C-cancel | Cancel rate | cancelled compositions / compositions | composition | — | F | `trend`, `summary` | none standard | includes interrupted focus changes only when the outcome says so |
| C-raw | Raw-commit rate | `raw_return` commits / `candidate` and `raw_return` commits (the commits of pinyin compositions; a Return on raw pinyin records no Chinese-kind decision) | commit | T2 | F | `trend`, `summary` | none standard | dictionary gaps and deliberate pinyin output look alike |
| C-rev | Revert rate | candidate commits whose post-commit window shows deletions ≥ committed length, or Cmd+Z, before other typing / candidate commits with a window observed | commit | T2 vs T3 | F | `trend`, `summary` | 上屏后修改率; Words Modified Ratio (Gboard) | counts a change of mind as a revert; C-retype separates it |
| C-partial | Partial edit rate | commits whose window shows 1 … length − 1 deletions followed by direct text / same denominator | commit | T2 vs T3 | F | not computed | WMR | typing slips in the next word are excluded by "before other typing" |
| C-retype | Confirmed-miss rate | reverts followed by a composition with the same code identity / reverts | commit | T3 | F | not computed | none standard | depends on the post-commit window only; the code identity is the keyed [pair hash](../macOS/QUALITY-EXPORT.md#pair-hashes) |
| C-total | Effective first-choice error | 1 − R-adj | decision | T3 | F | not computed | 回删率; total error rate (Soukoreff & MacKenzie 2003) | lower bound: errors left in the document are invisible |

## 6. Learning intelligence

Learning quality has three observable faces: how fast a correction takes effect, how long it holds, and what it
breaks. The adaptive-IME literature names them. Jiang et al. (2011) define Futile Effort (a chunk the user keeps
correcting that the IM never adapts to), Beneficial Effort (corrections needed before it adapts) and Utility (uses
before the adapted chunk is forgotten); Suzuki & Gao (2005) define the error ratio `ER = |E_A| / |E_B|`, newly
introduced errors per error fixed by an adapted model. The L family is those quantities over pair identities.

A **miss** is a regular decision at rank > 1 or on page > 0. **Window** is the 28-day retention. Pairs first seen
inside the window may have been learned before it (left-censoring): L-ttl and L-avoid report the share of pairs
whose first observation is within 7 days of the window start, and exclude nothing.

| ID | Name | Numerator / denominator | Unit | Source | Computed by | Counterpart | Bias |
| --- | --- | --- | --- | --- | --- | --- | --- |
| L-ttl | Time to learn | for pairs whose first observed decision was a miss: the number of selections until the first rank-1 decision of the same pair; report the distribution and the share learned after exactly one selection | pair | F B | `learning` | Beneficial Effort (Jiang 2011) | a pair that alternates with a homophone by context never "learns"; report R-ctx beside it |
| L-futile | Futile effort rate | pairs with ≥ 3 selections, all misses / pairs with ≥ 3 selections | pair | F B | `learning` | Futile Effort (Jiang 2011) | the engine's rule may be right (a longer sentence wins); inspect before calling it a defect |
| L-util | Retention | for pairs that reached rank 1: selections at rank 1 until the next miss of the same pair; report the median and the regression rate (pairs that fell back / pairs that reached rank 1) | pair | F B | `learning` | Utility (Jiang 2011) | context switches look like forgetting; the context dimension splits them |
| L-avoid | Avoidable-miss rate | misses whose pair was already selected earlier in the window / misses | decision | F | `learning`; the proxy also in `trend`, `summary` | none standard | **headline**: the engine had the evidence and missed anyway. Interim proxy without pair identity: misses whose selected candidate has learned provenance / misses, a dimension already recorded ("the engine had learned it and still did not lead"); it undercounts, because a learned word can also be a first-time dictionary miss |
| L-over | Learned-leader miss rate | decisions whose shown-first has learned provenance and the user chose another candidate / decisions whose shown-first has learned provenance; reported beside the same rate for dictionary-led lists | decision | F P | `trend`, `summary` | 误学率; error ratio (Suzuki & Gao 2005) | a learned leader displacing a right dictionary choice is 误学; replay computes ER directly from cold and trained arms |
| L-reuse | Learned-word reuse rate | words first chosen in days 1–14 that recur in days 15–28 / words first chosen in days 1–14 | word | F | `learning` | reused-word rate (Tanaka-Ishii 2003) | low values mean the user dictionary fills with one-off words |
| L-forget | Forget correctness | after a `forgotten` act: pairs that reappear at rank 1 within the window (forget failed) and pairs the user selects again (forget regretted), each / forgotten pairs | pair | F B | unavailable | none standard | unavailable: needs a pair hash per learning act, which is not recorded |
| L-cold | Learning curve | B only: rank of the target cold, after 1, 2 and 5 selections, and after `M` unrelated commits; Eb and U per sample | sample | B | not computed by `quality.py` | Jiang 2011 | the baseline fixture records cold, after 1-4 selections, learned (after 5 and a restart) and retained |

The learning headline is L-avoid, read with L-over: a low avoidable-miss rate with a low learned-leader miss rate
means the engine learns what it should and nothing else. A low L-avoid with a high L-over means it over-learns.

## 7. Benchmark layer and industry comparison

The field metrics measure this user on this machine. The benchmark layer measures the engine on a fixed corpus so
that a number is comparable across versions and across input methods.

Protocol:

- **Corpus.** A versioned, hashed test set with per-sample code, target and category: the project's own
  `Core/Fixtures/QualityBaseline/corpus.json` (sanitized incident boundaries and controls).
- **State.** Cold: a fresh user directory, no custom phrases, default options, nine candidates. Trained: the cold
  state after the fixture's selection schedule. Every result records which.
- **Typing policy.** Fixed and scripted: type the full code; one Space commits the first candidate (T0 against T4
  gives R1, R-sent, R-char); the search variant pages up to 20 pages and picks by digit (gives R-mrr, E-kspc,
  E-page as `baseline.json` records them). No arrow keys, no cursor edits.
- **Learning schedule.** Per sample: observe cold, select the target `k` times for `k` in 1, 2, 5, observe after
  each, type `M` unrelated samples, observe again. This yields L-cold, and over the whole corpus ER between the cold
  and trained arms.
- **Other input methods.** The same corpus and policy driven black-box through the application (type into a plain
  text view, Space, read back): only R1 on T0, R-sent, R-char and E-kspc are observable without reading their
  candidate panel; R3 and R-paged only where the panel can be read. Fresh profile, cloud features off, version and
  date recorded. Published third-party comparisons of this shape exist (sentence accuracy and edit-distance
  character accuracy over Rime schemas and commercial IMEs on news, novel and essay text); their numbers are not
  comparable with ours unless corpus, policy and state match.
- **Provenance.** Every report carries the corpus hash, engine and resource digests, state and policy, as the
  baseline report does. A result without provenance is not a benchmark.

## 8. Statistics and maintenance

- **Intervals and windows.** Daily, 7-day and 28-day rolling, ratios of summed counts, 95% Wilson interval, as
  `trend` does. A bucket under 200 units reports its interval and no verdict.
- **Changes are paired.** A ranking change is judged by the ship rule of
  [the first-choice target](#the-first-choice-target). A learning change is judged the same way on per-pair outcomes
  between a cold and a trained arm, or between two trained arms with different learning rules.
- **Field, replay and benchmark are never pooled.** Scripted operation counts and live counts have different units.
- **Metric identity.** IDs in this document are stable. A change to any numerator, denominator or cohort is a new
  metric-rule version: the measurement fingerprint changes, the trend selects the newest cohort and reports the
  excluded counts, and [nothing is pooled across fingerprints](../.agents/skills/inkflow-quality-analysis/references/interpretation.md#measurement-fingerprints-and-pooled-rates). Adding a dimension or a new metric needs no version bump.
- **Instrument constants** (`W`, the deletion threshold, the function-word set, 200-unit minimum, page limit 20,
  `M`) are listed with their metric and versioned with the rule. `W`
  ([10 s](../.agents/skills/inkflow-quality-analysis/references/interpretation.md#deletions-and-post-commit-windows))
  belongs to R-adj and C-rev.
- **Recording-source changes** (for example moving recording into the Rust core) must reproduce the
  same counts on the same scripted input; a parity test is the acceptance.
- **Review cadence.** The 28-day report lists every headline per bucket with its interval; target changes follow the
  raise rule in [the first-choice target](#the-first-choice-target). Benchmarks run per release and per ranking or
  learning PR.

## Sources

- Soukoreff & MacKenzie, *Metrics for text entry research: an evaluation of MSD and KSPC, and a new unified error metric*, CHI 2003 — <https://www.yorku.ca/mack/chi03.html>
- Jiang et al., *Robustness Analysis of Adaptive Chinese Input Methods* (MAC, generalized backward compatibility, Futile/Beneficial Effort, Utility), 2011 — <https://aclanthology.org/W11-3509.pdf>
- Gao, Suzuki & Yuan, *An Empirical Study on Language Model Adaptation* (CER; the error ratio of Suzuki & Gao 2005), TALIP 2006 — <https://www.microsoft.com/en-us/research/uploads/prod/2017/01/gao_suzuki_yuan.2006.talip_.pdf>
- Huang et al., *Chinese Pinyin Aided IME, Input What You Have Not Keystroked Yet* (MIU top-K, KySS), 2018 — <https://arxiv.org/pdf/1809.00329>
- Zhang et al., *Open Vocabulary Learning for Neural Chinese Pinyin IME* (MIU, PD dataset), 2019 — <https://arxiv.org/pdf/1811.04352>
- Tan et al., *Exploring and Adapting Chinese GPT to Pinyin Input Method* (PD and WD datasets), 2022 — <https://arxiv.org/pdf/2203.00249>
- *An Automated Evaluation Metric for Chinese Text Entry* (correction penalty, AAC), 2007 — <https://arxiv.org/pdf/0704.3662>
- Google, *Spatial model personalization in Gboard* (Words Modified Ratio), 2022 — <https://arxiv.org/pdf/2209.11311>
- Google Research, *Improving Gboard language models via private federated analytics* (post-commit modification rate, OOV coverage), 2024 — <https://www.research.google/blog/improving-gboard-language-models-via-private-federated-analytics/>
- Hard et al., *Federated learning for mobile keyboard prediction* (top-1 recall, prediction CTR), 2018 — <https://arxiv.org/abs/1811.03604>
- 百度输入法多项测试排名第一 (first-candidate hit definition used in a vendor test) — <https://t.cj.sina.com.cn/articles/view/6506167855/v183cc3e2f00100iqxl?from=tech>
- 评测了下 rime 各个方案的整句准确度 (black-box sentence accuracy and edit-distance character accuracy over Rime schemas and commercial IMEs) — <https://emacs-china.org/t/rime/31306>
