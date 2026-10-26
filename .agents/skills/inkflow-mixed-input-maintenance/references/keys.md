# Keys during composition

How each key behaves in Chinese mode. ASCII mode is native passthrough (rule 13 in [rules.md](rules.md)). "Idle" means no composition. "Recognizer match" means the input already matches a pattern of the schema's `recognizer`:

- `email`: `^[A-Za-z][-_.0-9A-Za-z]*@.*$`
- `url`: `^(www[.]|https?:|ftp[.:]|mailto:|file:).*$`

Patterns are case-sensitive and anchored at the start of the unconfirmed input (`WWW.` is not a URL). The `recognizer` processor follows `ascii_composer`, so it takes every printable ASCII key (not Space) before `key_binder`, `speller`, `punctuator` and `selector` see it. The `matcher` segmentor, ahead of `abc_segmentor`, makes the whole input one segment that no translator serves, so a match has no candidates and its preedit is the raw text. When Backspace leaves input that no longer matches, it composes as usual. Input that never matches is unchanged by this section.

| Key (row id) | Idle | Composing (Chinese mode) | Recognizer match |
| --- | --- | --- | --- |
| a–z (`letter-lower`) | Starts a composition | Appended to the input | Appended raw |
| A–Z (`letter-upper`) | Starts a composition, case kept | Appended, case kept | Appended raw |
| 1–9 within the displayed page (`digit-page`) | Passes through | Selects that displayed candidate; a partial candidate leaves the rest composing | Appended raw |
| 0 (`digit-zero`) | Passes through | Swallowed by Rime's selector, no effect. Kept as a no-op | Appended raw |
| A digit beyond the page, 6–9 at the default page of 5 (`digit-beyond-page`) | Passes through | Swallowed by Rime's selector, no effect. Kept as a no-op | Appended raw |
| Space (`space`) | Passes through | Commits the highlighted candidate | Commits the raw text |
| Return (`return`) | Passes through | Commits the raw input | Commits the raw text |
| Backspace (`backspace`) | Passes through | Reverts the last partial selection, else deletes the last input character | Deletes the last character |
| Escape (`escape`) | Passes through | Cancels; nothing is committed | Cancels; nothing is committed |
| `` , . ; : ! ? ( ) { } < > \| ~ $ ^ _ ` \ `` and `"` (`punctuation-chinese`) | Commits the Chinese punctuation; `"` alternates “ ” | Commits the highlighted candidate and the punctuation | Appended raw |
| `'` (`punctuation-chinese`) | Commits ‘ or ’, alternating | The syllable delimiter: appended to the input | Appended raw |
| The same keys with ASCII punctuation on (`punctuation-ascii`) | Pass through | Commit the highlighted candidate, then the key passes through. `'` stays the delimiter | Appended raw |
| @ (`at`) | Passes through | Commits the highlighted candidate and passes through, unless the input is only `[A-Za-z][-_.0-9A-Za-z]*`, which starts an email | Appended raw |
| . (`dot`) | Commits 。 | Commits the highlighted candidate and 。, unless the input is `www` or `ftp`, which starts a URL | Appended raw |
| : (`colon`) | Commits ： | Commits the highlighted candidate and ：, unless the input is `http`, `https`, `ftp`, `mailto` or `file`, which starts a URL | Appended raw |
| / (`slash`) | Passes through | Commits the highlighted candidate and passes through | Appended raw |
| Page Up, Page Down (`paging-keys`) | Pass through | Page the candidates | Swallowed, no effect |
| `[` `]` `-` `=` (`paging-bound-keys`) | `[` `]` commit 【 】; `-` `=` pass through | Page up and down (both pairs are on by default) | Appended raw |
| Up, Down (`arrows-vertical`) | Pass through | Move the highlight, across pages | Swallowed, no effect |
| Left, Right (`arrows-horizontal`) | Pass through | Move the caret in the preedit | Move the caret in the raw text |
| Home (`home`) | Passes through | Moves the caret to the start of the input in one press, whatever the highlight or the page order, and highlights the page's first candidate. Rime rebuilds the composition at the start and cannot keep a later candidate highlighted there, so that page keeps Rime's order, also when Left reaches the start | Moves the caret to the start of the raw text |
| End (`end`) | Passes through | Moves the caret to the end of the input, ranks the page again and highlights its first displayed candidate. At the end that highlight is all it changes | Moves the caret to the end of the raw text |
| Left Shift tap (`shift-tap`) | Toggles the mode at once | Waits; the mode switches after the composition is committed or cancelled | Waits the same way; the raw text commits first |
| Command, Control or Option with a key (`chords`) | Pass through | The composition is committed, then the chord passes to the application | Same, committing the raw text |
| Shift+Backspace (`forget`) | Passes through | Forgets the highlighted candidate's learning ([forgetting.md](forgetting.md)); nothing is committed, and the input, page and highlight index stay | Deletes the last character, as Backspace does |

Consequences of the patterns:

- A pattern matches only when its last key arrives, so earlier keys follow the composing column. In `john.doe@example.com` the `.` commits 解耦很难。 first, in `user1@example.com` the `1` selects a candidate, and in `john-doe@example.com` the `-` pages and is not typed; only the part after that key matches. A local part of letters (`name@example.com`) comes out literally.
- Letters followed by `@` are an email, so `nihao@` does not commit 你好 first. After a partial selection the unconfirmed rest is matched: 你 then `haowo@x.com`.

Each row has one regression block, labelled with its row id; every failure message starts with that id. Engine rows: `EngineRegression.compositionKeys(event:)`. `shift-tap`, `chords` and an end-to-end URL/email through the controller: `ControllerTests.compositionKeys()`.
