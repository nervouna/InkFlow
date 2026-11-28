# Replay

Replay scores a ranking change on real decisions before it ships ([#130](https://github.com/nervouna/InkFlow/issues/130)). The target a change is judged against and the ship rule are in [the first-choice target](../../docs/input-quality-metrics.md#the-first-choice-target).

`quality.py replay-cases` exports the regular committed decisions of a window as JSON Lines replay cases. [The query contract](../../.agents/skills/inkflow-quality-analysis/references/query-contract.md) defines the file, what it leaves out and how a decision the user reverted at once is relabelled or excluded. A case's candidates are the commit-time list on page 0 and the first page when the user paged, so a paged choice is normally a miss for every arm. Records from before the candidate facts (#129) have no `evidence`: the `ranked` arm skips them, and the classes that need a type leave them out.

`replay list` (`src/bin/replay.rs`) scores each case against `selected_text` in three arms: `native` (the candidate with `native_rank` 1), `displayed` (display index 0) and `ranked` (`ContextRanker::order` run again on the case's texts in Rime's order, its `preceding_context` and the `parse_metadata` of its `evidence` rows; a case with a missing or unreadable row is skipped and counted). Each arm is reported against `native`: hits, `fixed` (the arm is right where native is wrong) and `broken` (the reverse), on every case and on distinct `(raw_input, selected_text)` pairs (the first case of a pair stands for it), with the exact two-sided McNemar p-value of the distinct pairs. The breakdown covers `all`, six classes decided from the case alone (`dictionary_leader`: Rime's first candidate is a `phrase`, `user_phrase` or `user_table`; `decoder_leader`: it is a `sentence`; `segmentation`: the selected candidate's evidence ends before the input does; `single_char`: the selected text is one Han character; `off_page`: the user paged; `function_word`: the selected text is one of 的 地 得 在 再 吧 把 他 她 它, an instrument constant, not a product rule) and the three selected-text length buckets the target is judged on. A case can belong to several scopes. `--json` prints the same counts as JSON. `fixtures/replay-cases.json` holds 54 synthetic cases with the expected counts, which `tests/replay.rs` compares.

```sh
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
python3 "$query" replay-cases --since 2026-10-15 --until 2026-10-21 --output "$TMPDIR/cases.jsonl"
cargo run --locked --release --manifest-path Core/Portable/Cargo.toml --bin replay -- \
  list "$TMPDIR/cases.jsonl" --context-index PATH/TO/pinyin_simp.context.bin
rm "$TMPDIR/cases.jsonl"
```

Without `--context-index` the `ranked` arm is not run. The checked-in fixture ranks with its own small dictionary.
Unlike exported JSON Lines, the synthetic fixture is one JSON document without an export timestamp.
The timestamp parser and formatter share the exporter's UTC form, `YYYY-MM-DDTHH:MM:SS[.fff]Z`,
and use Howard Hinnant's civil-calendar algorithm. The Wilson calculation mirrors
`NormalDist().inv_cdf(0.975)` in the Python reporter. McNemar doubles the lower binomial tail of the
discordant pairs. Both calculations are instrument definitions used to compare replays.

Delayed correction chains are collapsed by the exporter and explicitly marked as inferred context returns.
Report direct and inferred chain counts separately; the inference is not document readback.

## Replay files

Case files hold typed text. They stay outside the repository (`replay-cases` refuses a path inside it, writes the file owner-only and never over an existing file), are deleted after the run, never outlive the 28-day retention of their source records (`replay` refuses a file whose header `generated_at` is older than 28 days and says to delete it), and are deleted when text recording is turned off. The record files of engine mode follow the same rules. The replay record writer refuses
a path inside any Git work tree, found from the output path when it runs, and inside the checkout that built it.

## Engine-mode replay

`replay engine CASES --arm NAME=RESOURCES|NAME=@FILE ... [--train NAME ...] [--record NAME=FILE ...] [--json]` runs the real engine on the same case files as list mode and compares **arms with each other**. A live arm (`NAME=RESOURCES`, a `prepare-resources.sh` output) starts one `Engine` on those resources with an absent user directory and `set_configuration(9, &[], Some(&InputPreferences::default()))`. It walks the compositions of the file (see "Learning arms"): per decision it sets `preceding_context`, types `raw_input` and snapshots the first page. Unless `--train` names it, an arm never makes a composition's last selection, so it never commits and nothing is learned. The user directory is a scratch directory under the temporary directory, removed when the arm ends, and one arm finishes before the next engine starts (Rime is process-global).

Each arm is scored on the first candidate against `selected_text` (a hit), and, for `segmentation` cases, on the longest candidate whose evidence covers the whole input against `committed_text`, keeping the earlier
candidate on ties. The report gives, per arm, its first-candidate hits, how often its first candidate equals the recorded `displayed` leader (below 100%: the records came from a trained user dictionary, which a fresh engine does not have), the whole-input hits and the hits per class, the walk and training counts and the misses of the first candidate by provenance; then, for every pair of arms in the order given (the earlier one is the base), fixed, broken, distinct counts and the McNemar p-value in list mode's table, plus a `whole_input` row on the segmentation cases and the ER and `repeat` table. Counts of two arms are only comparable with each other.

`--record NAME=FILE` writes a live arm's outcomes as JSON Lines (a header with `generated_at`, `trained` and the `walk` and, for a trained arm, `training` counts, then `id` (the `decision_id`), `first`, `first_provenance`, `longest`, `first_hit` and `longest_hit` per case), and `--arm NAME=@FILE` loads such a file as an arm. That is how an arm from another binary joins the comparison. A record without `first_provenance` loads with `none` and is counted `without_provenance`; its L-over is unavailable. Record files hold typed text and follow the [replay file rules](#replay-files); their header carries the case file's `generated_at`.

```sh
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
python3 "$query" replay-cases --since 2026-10-15 --until 2026-10-21 --output "$TMPDIR/cases.jsonl"
bash Core/Portable/prepare-resources.sh   # prints "PASS production resources: build/portable/resources.XXXXXX"
cargo run --locked --release --manifest-path Core/Portable/Cargo.toml --bin replay -- \
  engine "$TMPDIR/cases.jsonl" --arm base=build/portable/resources.XXXXXX --arm candidate=PATH/TO/OTHER/RESOURCES \
  --record base="$TMPDIR/base.jsonl"
rm "$TMPDIR/cases.jsonl" "$TMPDIR/base.jsonl"
```

`tests/replay.rs` replays `fixtures/replay-cases.json` this way: recorded arms reproduce list mode's pairwise counts without Rime, and with `INKFLOW_PORTABLE_RESOURCES` set two live arms on the prepared resources must agree, record, and reload as the same arm; a cold and two trained arms walk the fixture and its multi-decision and unfound variants, and leave no scratch user directory. `performance.sh` on an arm's resources measures it against the approved limits.

### Learning arms

`--train NAME` makes a live arm learn: its user dictionary is built from the recorded decisions, in file order. NAME must be a live `--arm`, and several arms may train (two trained arms with different resources are the "two learning rules" comparison of the design's section 8); a recorded arm is trained or not according to its header.

The cases are grouped by `composition_id` in file order, and a composition whose cases are not adjacent is refused. A composition is *walkable* when each later case's `raw_input` starts with the previous one's and the `selected_text`s in order make the `committed_text`. Every live arm walks a walkable composition once. Per case it snapshots the first page and scores it in the state the user was in, after the selections of the earlier cases: the first candidate against `selected_text`, the longest whole-input candidate against `committed_text`. It then finds `selected_text` on that page or by Page_Down within 20 pages (instrument constant), selects it and types the next case's extra letters. The cold arm clears instead of making the last selection, so it never commits. A trained arm makes it and drains the commit: `trained` (the commit is `committed_text`), `incomplete` (letters remain, as `huix` → 辉; the session is cleared and nothing is learned) or `commit_mismatch` (another text; reported, not undone). A text not found within 20 pages ends the walk: that composition is `unfound`, trains nothing, and its later cases are scored on a fresh composition. A composition that is not walkable is `unwalkable`: each case is scored by typing the whole `raw_input` on a fresh composition, and nothing is trained. A single-decision composition is the plain protocol plus, for a trained arm, one selection.

Leakage rule: every case of a composition is scored before that composition's final selection, and nothing from a later composition precedes an earlier one's score. A trained arm's state at a case is the commits of the walkable compositions before it in the file, visible at the next query (Rime commits the pending transaction when the next query starts). Its scratch user directory is that dictionary, built from typed text: it lives under the temporary directory only and is removed when the arm ends, like the case and record files.

- **L-over** (design section 6) is the `learned` row of `leaders`: of the cases whose first candidate has learned provenance (`user_phrase`, or an English or mixed candidate with a personal source), the share whose first candidate is not `selected_text` (unit decision, truth T1). The `dictionary` (`phrase`, `user_table`) and `assembled` (`sentence`) rows are the same rate for those leaders; `other` folds `completion` and the English and mixed types without a personal source, and `none` is a page without evidence (after a selected prefix, or a custom-phrase code). Each row has its rate with a Wilson interval on every case and on the distinct pairs. A zero denominator is unavailable, never 0%, which is what a cold arm gets; under 200 cases the interval is printed and no verdict.
- **ER** (design section 6) is `broken / fixed` of an arm against its base: the errors the learning introduced per error it fixed (truth T1), unavailable when nothing is fixed. Give the cold arm first so the trained arm is the one measured. The regression share `broken / (fixed + broken)` carries its Wilson interval; ER is its odds. Every block reports both.
- **`repeat`** sits beside `cases` and `distinct` in every scope row and in `whole_input`: one unit per `(raw_input, selected_text)` pair that occurs more than once (`(raw_input, committed_text)` for `whole_input`), its last case, with its own McNemar p. `distinct` keeps the first case of a pair, so it scores the pair before the trained arm has committed it (the word may already have been learned from an earlier composition, since Rime memorizes the parts of every commit); `repeat` is the view after all of the user's selections of the pair. Which block decides a learning change is left to the first measurement.

The trained arm starts cold while the recorded dictionary did not, so only compare it with the cold arm, never with the recorded `displayed` leader.

```sh
query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
python3 "$query" replay-cases --since 2026-10-15 --until 2026-10-21 --output "$TMPDIR/cases.jsonl"
cargo run --locked --release --manifest-path Core/Portable/Cargo.toml --bin replay -- \
  engine "$TMPDIR/cases.jsonl" --arm cold=build/portable/resources.XXXXXX \
  --arm trained=build/portable/resources.XXXXXX --train trained
rm "$TMPDIR/cases.jsonl"
```
