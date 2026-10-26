# Regression anchors and accepted limits

Fixtures behind the rules in [rules.md](rules.md). They describe the current defaults; future intentional data/config changes should update their expectations, not hard-code special cases in Lua.

| Case | Current expectation / reason |
| --- | --- |
| `d`, `niyebuxiangnid`, `womenshenzh` | Chinese leads through forward typing and backspaces; no promoted `D`, `nid` or `zh` mixed tail |
| `women` | 我们 leads; measured `women` (5.57) remains selectable |
| `WOMENS`, `womenfolk`, `tameness`, `Nimes`, `nimetti`, `nimetz`, `Haiti`, `Haitian`, `Haitienne`, `haitians` | Rejected at the default gate, including exact/prefix/case/alias paths, later pages and mixed boundaries; `WOMENS` is 3.40 |
| `email`, `emails`, `online`, `bug` | Measured 4.68, 4.24, 5.19, 4.20 respectively; no zero-weight exception needed; admitted does not mean first-page/first-place |
| `email`, `wofaleemail` | 额买了 / 我发了额买了 lead at equal coverage; `email` / 我发了email remain selectable and commit exactly. Once 我发了email has been selected, it leads `wofaleemail`; Return, cancellation and an immediate undo do not count |
| `compute`, `actual` | `computer` can complete excluded `compute`; admitted exact-code `actual` precedes frequency-ordered completions such as `actually` |
| `a`, `i`, `D` | Admitted exact short codes remain reachable; `i` can select `I`; intentional uppercase `D` remains available |
| `niruguoxiangyaozhefenoffer`, `niruguoxiangyaozhefenofferkeyihuifuwo`, `offerhenhao`, `wofaleemails`, `wofaleEmail`, `womenquoffice` | Preserve complete mixed results at initial/internal/final boundaries and exact selection; also exercise edits within `zhefenoffer` |
| `woyongAPIkeyihuifuwo`, `woyongSwiftUIhenhao`, `banbenDkeyi` | Preserve admitted acronym, source-case and single-letter uppercase words followed by Pinyin; exercise real Shift key events and backspaces across complete Pinyin boundaries |
| `api`, `Api`, `swiftui`, `claudecode`, `cpp`, `ebpf`, `typec` | Select exact `API`, `API`, `SwiftUI`, `Claude Code`, `C++`, `eBPF`, `Type-C`; technical spellings still use the shared gate and existing mixed restrictions |
| Shift-typed `API`, `SwiftUI` (standalone) | The exact word is the first candidate; the lowercase code is queried in addition to the typed one |
| `iphone`, `ipad`, `youtube`, `ebay`, `phd`, `app`, `core`, `demo`, `ceo`, `john`, `android`, `go`, `swift` | The first English candidate is iPhone, iPad, YouTube, eBay, PhD, app, core, demo, CEO, John, Android, go, swift: ESDB's canonical spelling, lowercase first on ties, so `john` and `android` rely on a `0` override of the lowercase form |
| `china`, `english`, `pc`, `whos`, `polish` | The first English candidate is China, English, PC and who's (case-tie overrides demote the lowercase or capitalized form that wins the tie); Polish and polish are both on the first page, polish only moved down |
| Shift-typed `Hello`, Caps Lock `HELLO`, `woyongiphone` | `Hello` and `HELLO` lead as typed (generated case forms); 我用iPhone is on the first page (rule 6) |
| `macos`, `deepseek`, `ios` | `macOS`, `DeepSeek` and `iOS` lead the page, before and after learning (rule 14); the abbreviation-built Chinese readings stay selectable behind them. ESDB has no lowercase `ios` to compete with `iOS` |
| `tin`, `chin`, `email`, `banana`, `shanghai` | Complete Pinyin, or Pinyin up to an unfinished final syllable: Chinese stays first and exact English follows; the technical lead does not apply |
| `python`, `google`, `offer`, `world` | Not Pinyin-shaped: the exact English word leads (rule 14). Their Chinese readings stay on the page |
| `ne`, `o`, `beijing` with a learned `ne`, `o`, `Beijing` and a technical context | Complete Pinyin: 呢, 哦 and 背景 lead and the learned word is behind them. Shift-typed `O`, `google` and the letters `i`, `u`, `v` keep the lead (rule 14) |
| `can`, `you`, `she`, `he`, `man`, `bug` | Chinese stays first; exact English is second and commits exactly. `canpin`, `youxi`, `sheji`, and `hezuo` keep their Chinese first candidates |
| `offline`, `plugin` | Default exclusion is an accepted baseline limit, not a runtime-gate defect |

Frequency cannot choose between case variants (wordfreq folds case), infer spellings ESDB lacks, or add missing public words such as `haha`, `lmao`, `wtf`, `idk` and `tbh`.
