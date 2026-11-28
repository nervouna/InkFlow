# Desktop Rust/Rime runtime

Rust runtime over librime for [#34](https://github.com/nervouna/InkFlow/issues/34) and the shared session policy for [#35](https://github.com/nervouna/InkFlow/issues/35). macOS runs on this core through the `IFEngine` facade; the Swift engine is deleted, and its recorded results stay here as frozen references (below).

## Build and test

Requirements: the repository's Rust 1.98.1 toolchain, a C/C++17 compiler, Python 3, CMake 3.31, Ninja,
curl, tar, and a POSIX shell. CMake 3.31.6 and Ninja 1.11.1.4 can be installed without root using
`uv tool install`. Make these tools available on `PATH`.

From the checkout root:

```sh
bash Core/Portable/test.sh
# Compile and smoke-test full production resources in isolated directories:
bash Core/Portable/prepare-resources.sh [OUTPUT_DIRECTORY]
# Compare the Rust engine with the recorded Swift behavior on those resources:
bash Core/Portable/parity.sh [build/portable/resources.XXXXXX]
# Capture key latency and memory with the recorded macOS headless protocol:
bash Core/Portable/performance.sh build/portable/resources.XXXXXX [OUTPUT_DIRECTORY]
# macOS only: the native build plus the release libinkflow_rime.a that SwiftPM links
# (target InkFlowPortable), then everything above and the Swift link smoke test in one unit:
bash Core/scripts/build-portable.sh
bash macOS/scripts/test.sh portable
```

`abi.sh` builds the C-facing dynamic and static libraries and exercises the C consumer. By default it runs
the isolated probe and argument checks. Pass a directory from `prepare-resources.sh` to `abi.sh` or
`parity.sh` to reuse prepared production resources. The parity runner makes that path absolute because
Cargo starts the tests from the crate directory.

The first build downloads checksum-verified source archives. Subsequent builds reuse them under `build/portable/`; native outputs and Cargo artifacts stay there too. Set `CMAKE_BUILD_PARALLEL_LEVEL` to change the native build parallelism (default 4). Do not run two builds in the same checkout. On macOS the native libraries and the release Rust archive target the app's minimum system version, read from `LSMinimumSystemVersion` in `macOS/Info.plist` (`deploymentTarget` in `native-build.json`), so they load wherever the app does. Remove `build/portable/` for a clean rebuild or after changing compiler/SDK/architecture or that version.

`native-sources.lock.json` pins source commits, URLs, and SHA-256 hashes. When a pin changes in a reused build directory, such as a restored CI cache, the build downloads the archive again and removes the install prefix and every CMake build directory: extracted headers keep their archive dates, so Ninja would not recompile the libraries that include them. librime is the shipping 1.17.0 revision. Its glog, LevelDB, marisa, and yaml-cpp pins follow that revision's submodules; Boost remains 1.89.0. OpenCC is pinned to 1.4.2, ahead of the 1.1.9 submodule, for the out-of-bounds read fixes of GHSA-7fqq-q52p-2jjg. The Lua plugin is pinned to its last upstream commit before the 1.17.0 release, with Lua 5.4.8 from its pinned thirdparty tree.

Both desktops build the same source graph. The build links static dependencies and the Lua plugin into a shared librime, then compiles both existing `InkFlowRimeNative` source files against that build's installed headers and generated configuration. External plugin discovery is disabled. The narrow C++ bridge registers `inkflow_mixed_personal` after every initialization and checks its presence. No host librime or Homebrew C++ headers are used for the native extension.

The build compiles OpenCC unmodified and explicitly includes `cstdint` for GCC 15. It hides Git from OpenCC's configuration, which would otherwise derive the OpenCC version from this repository's tags. OpenCC uses the same pinned marisa library as librime. Optional gflags, libunwind, Snappy, crc32c, and tcmalloc dependencies are disabled to avoid host-dependent linkage.
Boost.Regex builds without ICU because the embedded Rime does not use ICU regex and the Linux shared
library would otherwise acquire a system ICU dependency. Its Linux rpath resolves both a colocated library
and the library directory beside `bin/`. On macOS, the build supplies the deployment target through the
environment used by clang and b2 and through CMake's explicit setting. Rime sends ERROR and higher
diagnostics to stderr for the dictionary worker and keeps no log files.

The test copies the tiny checked-in source fixture into a fresh temporary directory, compiles it using the target runtime, and removes the directory after runtime teardown. It checks Chinese composition, one-shot commits, a non-ASCII Lua filter, snapshot ownership, serialized sessions across threads, runtime/session lifetime, and restart.

The setup-only resource operations use exclusive Rime access and an isolated writable user directory.
Compilation uses Rime maintenance to deploy the schema list and checks that its output includes each
required configuration, dictionary, prism and all 32 spelling profiles. The first missing or empty
dependency is reported relative to the cache. The smoke probe serves the prepared cache from a clean
user directory and selects known Chinese, English, mixed and Emoji candidates. Failure names the first
input that could not be selected. This proves candidate availability.

## Session policy and old/new comparison

`src/engine.rs` ports `IFEngine`: `Engine` owns one runtime, the prepared context index and the custom-phrase file; `InputSession` owns one input context. Rime keeps editing, segmentation, lookup, paging and its own learning. The engine adds equivalent-span ordering and selection by displayed index, digit and Up/Down policy, the preceding-text context, custom phrases through Rime's native `custom_phrase.txt` (written on settings changes, reloaded by every session at a shared idle), input preferences and candidate counts applied by replacing schema nodes at a composition boundary, ASCII mode, and commit text preserved across a settings reload. `src/preferences.rs`, `src/phrases.rs` and `src/channel.rs` port the matching Swift domain code.

`src/ranking.rs` ports the Swift equivalent-span ranker, including strict metadata parsing, Han phrase context, personal-strength limits, custom-source priority, and native-order fallback; it reads the prepared `pinyin_simp.context.bin` whole into memory and never touches storage from a key event. Its 312 synthetic cases compare against `fixtures/ranking-reference.json`, the Swift ranker's recorded results.

Fcitx5 supplies the preceding document text through `ifr_session_start_document_context` while idle.
For a Han continuation on a short first page, the ranker examines up to nine native Rime candidates. When
the preferred Han candidate lies beyond the displayed page, a Rime filter moves its existing handle to
the last visible slot before ordinary page ordering. The native menu keeps the remaining candidates,
selection and learning. The existing `ifr_session_set_preceding_text` keeps its current-page behavior.

The version-2 context index retains a phrase's terminal syllable and its frequency per reading.
Full-input single-character candidates with literal lowercase, uncorrected input require that syllable to start with
the typed spelling. A phrase's other reading cannot promote the character. Corrected spellings and inputs with
delimiters defer to Rime; longer candidates keep text-based matching. Version-1 indices retain their historical
text-only behavior until preparation rebuilds them. The index adds no key-event I/O.

`tests/parity.rs` compares the Rust engine with the recorded behavior of the Swift engine on prepared production resources and isolated user directories (`parity.sh`; the tests skip without `INKFLOW_PORTABLE_RESOURCES`):

- The 24 samples of [the quality baseline](../Fixtures/QualityBaseline/README.md) reproduce `baseline.json` exactly: first page, target rank, paging, selection, one-shot commits, five learning commits with the observations before selections 2 to 5 (`training`), the learned state after the runtime restarts on the same user directory, and the retained state after the retention pass of ten unrelated Han commits in that directory.
- `swift_engine_regressions` carries the expectations of the Swift engine regressions for basic cases, context ranking, custom phrases, input settings and ASCII boundaries, plus the stale-selection contract.
- `swift_personal_learning_and_data` covers learning management at the idle boundary, export/import between isolated user directories, a macOS-format document with disclosed unsupported preferences, and rejected snapshots rolling back.

`fixtures/ranking-reference.json` and `fixtures/quality-evidence.json` are frozen references from the last Swift engine (revision 38eb53c; `quality-evidence.json` names its earlier recording revision, with the Swift engine sources unchanged between them). Their recorders were deleted with the Swift engine, so nothing can regenerate them: change a case only for a reasoned behavior change, by applying that rule to the recorded results, and never by re-recording from the Rust core.

Quality recording happens in the frontend. The input loop performs synchronous Rime
work only, with schema and shared phrase-table reloads deferred to idle boundaries. The settings path
writes the phrase file. See the [runtime contract](runtime-contract.md) for the
ABI's ownership rules and the ranker's fallback boundaries.

### Verification fixtures

The Rust runtime probe and the parity suite serialize Rime use within each process. Native sessions may
outlive a released runtime or engine handle. The runtime and C tests use real probe deployment to check
resource validation and teardown on a missing production schema. The C consumer takes a fixture root
with `shared/`, a scratch directory and an optional production resource root. Its POSIX feature macro
exposes `sleep` in C11 mode for waiting out the native undo window. Production-only checks exercise the
full cache compile and probe as well as maintenance, AI, voice, and quality accessors. A new user directory
writes InkFlow's distribution identity without creating log files.

The fixture databases in `fixtures/swift-user` were restored from the synthetic snapshots in
`macOS/Tests/PersonalDataTests/PersonalDataTests.swift` by the macOS dictionary worker (0.6.2 build 164). Its TSV snapshots
are the byte-for-byte export reference. Tests compare equivalent synthetic rows without ordering
where the expected text was authored manually, since Rime exports in native key order. Import restores
the rows into a second directory, and rejection leaves the existing databases in place. The format-1
document omits absent optional values where Swift's Codable would.

The production parity cases include lookahead across the page boundary, and verify that a negative
English lookup reported to the short-conflict filter is scoped to one segment query. In multi-session
configuration tests, an active composition delays a phrase reload. An undrained commit must survive
settings applying before the frontend reads it. Parity with the Swift engine's original quality runner
uses ten unaffected Han commits in corpus order after each sample, wrapping when needed for retention.

Voice-correction and AI adoption parity reproduce the recorded read, write, clear and restart flows.
Learning-epoch tests use untouched listed entries so the revision alone decides whether a listing or
undo token is stale. Rejected management reads leave Rime's immediate Backspace undo available.
The AI identity grows to include the selected prefix after a partial selection. Learning a correction
registers the full input spelling, and the frozen Swift export checks that no suffix-only, raw typo
or abbreviation code was recorded. The mixed-sentence regression inspects personal evidence for
`google` because exact `google` can lead even without personal evidence.

Replay tests use synthetic cases only. Integer counts match exactly and McNemar floating-point
results are compared with tolerance. Live arms use independent scratch user directories and fixtures
with residual letters that allow either incomplete or unfound outcomes. A record with no provenance
loads as `none`, and one with no walk metadata has no walk counts. Tests verify that reloading a trained
record reproduces its report and that record creation preserves the original when the path exists.

## Performance

`performance.sh` runs `src/bin/performance-baseline.rs`: five fresh release processes, an absent user directory each, the 24-sample quality corpus typed five times with nine candidates, no commits, context and custom phrases empty. Each key operation is `key` + `take_commit` + `snapshot`; startup covers engine creation (prepared cache, context index, Rime start) and the first configured session. Memory is `getrusage` peak RSS, converted to bytes from KiB on Linux. Darwin already reports bytes. The summary prints the distributions beside the [approved review limits](../Fixtures/MigrationBaseline/README.md#approved-review-limits) without failing on them.

Same host (Apple M1 Pro, 32 GiB, macOS 27.0.1), same protocol, both engines on freshly prepared production resources, at faee8df. The Swift column was measured with the Swift baseline product before it was removed (#259); the recorded M5 Pro baseline is not comparable to either.

| Measurement | Swift engine | Rust engine | Approved limit |
| --- | ---: | ---: | ---: |
| Headless startup median, ms | 304.61 | 150.58 | 2,300 |
| Peak RSS after input max, MiB | 58.95 | 51.69 | 344 |
| First-pass key median / p95 / p99, ms | 0.609 / 1.952 / 2.543 | 0.585 / 1.856 / 2.309 | p99 2.6 |
| Repeated-pass key median / p95 / p99, ms | 0.582 / 1.879 / 2.289 | 0.547 / 1.759 / 2.153 | p95 1.8, p99 2.3 |
| First key of each process, ms | 13.35–15.33 | 14.19–20.24 | 25 |

Key latency is the same Rime work in both engines; the Rust engine's lower startup and RSS come from mapping no Swift runtime and reading only the prepared index. The one 20 ms first key was the first process after a rebuild (cold file cache); the other four match Swift. Recapture the Rust column on the same machine after toolchain or OS changes.

## Replay

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

### Replay files

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

## Personal learning and portable personal data

`Engine::personal_learning_entries`, `delete_personal_learning` and `undo_personal_learning` port `EnginePersonalLearning.swift` over the same Lua `learning_manage` channel: they run only when every session is idle and Rime's native undo window (4 s after the last commit) has passed, otherwise `Busy`; entries and undo tokens carry a learning revision that any commit, Backspace/Delete, new session or invalidation supersedes (`Conflict`). As on macOS, the newest commit may still be in Rime's pending transaction until the next transaction or teardown, and a native restore revives a deleted count with one confirmation. Never call this API from a key callback. The active native Rime memories own the namespaces. There is no
separate index of personal entries. Listings sort by source, code and text and expose strings borrowed
until the listing is freed. If management gives no usable answer, refresh and retry. A failed native
write may already be partial, so it invalidates the learning revision too. Rime may undo a commit
through Backspace even when it returns the key unhandled for the client.

`src/personal.rs` defines the portable backup: `Backup::from_json`/`to_json` read and write the macOS format-1 document (`format`, `rime`, `settings`, `dictionaries`). Supported data are the three Rime user dictionaries (`pinyin_simp`, `inkflow_shared_english`, `inkflow_voice_alias`), custom phrases, the candidate count and the input options. macOS-only preferences (shortcuts, font size, layout, thunder mode, voice rules) are skipped and listed in `Backup::unsupported`; unknown fields are rejected like on macOS. Written documents carry neutral values for those fields; macOS additionally requires the three fuzzy options to agree and exactly one paging pair. `personal::export` snapshots closed dictionaries through the existing native helper on a copy; `personal::import` restores snapshots into a staging directory, then moves originals aside and installs the new databases, restoring the originals on any failure; `personal::recover` finishes an interrupted import. `None` in a backup is explicit absence and removes the local dictionary. None of this runs while an engine is initialized in the process (`EngineActive`); frontends stop the engine first and apply the returned settings through `set_configuration` afterwards. Backups never imply that live databases can be shared between engines.

The exported TSV is borrowed until the export is released. Unknown names and absent dictionaries
return null. Export snapshots a closed copy in `user/PersonalData/staging` and removes that staging
directory afterwards. During import, keep the engine stopped through dictionary replacement and apply
the returned configuration to the recreated engine. Backup phrase strings remain valid while the
backup handle is live.

## Interface contract

`native/bridge.h` is the experimental internal C ABI between Rust and the native runtime. It uses Rime's public C API for lifecycle, deployment, input, context, and commits. C++ internals are confined to the existing extension and its registration check. The Rust library exposes safe `Runtime` and `Session` handles.

`include/inkflow_rime.h` is the frontend-facing C ABI over `Engine`/`InputSession` (`src/abi.rs`, ABI version 2), built as `cdylib` and `staticlib` beside the rlib. It covers engine and session lifetime, keys, immutable snapshots with UTF-8 byte offsets, token-identified selection and highlight, paging, commit draining, preceding text, configuration (candidate count, input options as a bitmask, custom phrases), ASCII mode and the mutation observer as a C callback. Every export catches panics and returns a status with a thread-local message; outputs are written only on success; there is no thread affinity. `abi.sh` builds both libraries and runs `tests/abi.c`: the fixture part exercises the real runtime lifetime and resource validation with the tiny probe schema (the engine itself needs the production schema), and the production part needs prepared resources; `test.sh` runs the former, `parity.sh` both. Personal data is exported as `ifr_backup_parse`/`ifr_backup_import`/`ifr_personal_recover` and `ifr_personal_export` (the three dictionaries as the TSV text `IFPersonalDataSnapshot` writes, byte-identical to the macOS worker's export of the same databases per `fixtures/swift-user`); all refuse to run while any engine is initialized. The maintenance operations the macOS frontend calls on the Swift engine are exported too: `ifr_rime_version`; personal-learning management (`ifr_personal_learning_entries`/`_delete`/`_undo`/`_invalidate`, with the statuses `IFR_BUSY`, `IFR_UNAVAILABLE`, `IFR_CONFLICT` and `IFR_TOO_LARGE` for the outcomes the Swift callers tell apart); `ifr_resources_compile` and `ifr_resources_probe`, the compile and probe the dictionary worker runs, which live in `src/resources.rs` and which `prepare-resources` now calls; and `ifr_session_requested_ascii_mode`. Everything bound to an engine (learning management, requested ASCII, probe beside a live engine) needs the production schema, so `test.sh` covers only its argument handling and `parity.sh` runs the rest. The AI, voice and quality hooks the macOS frontend reads from the Swift engine are exported too, so the `IFEngine` facade can keep `EngineAI.swift`, `VoiceLexicon.swift` and the quality recorder on top of `ifr_*`: `ifr_session_call` with `ifr_reply_status`/`ifr_reply_body`/`ifr_reply_free` is `InputSession::call`, the Lua channel behind `voice_learning`, `voice_aliases`, `voice_lexicon`, `ai_learning`, `ai_readings` and `clear_english_learning` (never from a key callback; `IFR_NO_REPLY` is Swift's `nil`: no session, no module, a reply that does not fit, an unframable request); a successful `voice_learning`, `ai_learning` or `clear_english_learning` advances the learning revision, as `markDirty` and `invalidatePersonalLearning` do, so earlier listings and undo tokens return `IFR_CONFLICT`, and a clear also drops every session's cached learning view (the facade keeps the idle checks, the undo-window delay and the lexicon signalling, and AI pronunciation stays in Swift); `ifr_snapshot_raw_caret` is `get_caret_pos`, a byte offset into `ifr_snapshot_input`; `ifr_snapshot_candidate_native_index`/`_native_rank`/`_personal_source`/`_consumed_input`/`_evidence` are the per-candidate evidence `qualitySnapshot` records (`_evidence` is the ranking row with Rime's candidate type and the corrected flag, which `inkflow_input_coverage.lua` computes by decoding the candidate's code with a dictionary-only Memory declared by the schema's `inkflow_input_coverage` node and comparing the syllables with the typed letters). `parity.sh` runs the channel-operation cases ported from the Swift tests (`propertyChannel`, `voiceCorrectionLearning`, the start of `personalManagement`, and the AI adoption scenario of `AIAdoptionLearningTests` with the userdb export of `test-ai-learning.sh`) and compares the evidence of 25 states with `fixtures/quality-evidence.json`, which was recorded from the Swift engine's `IFEngine.qualitySnapshot()` for the steps in `fixtures/quality-evidence-cases.json`.

- One process-wide Rust mutex serializes **all** Rime calls, including initialization, deployment, reads, destruction, and finalization. The engine's policy lock serializes every `InputSession` of an `Engine` and nests outside that mutex. Sessions can move between threads. No GUI event loop, Swift actor, or thread affinity is required. Another engine must not call librime outside this lock in the same process; old/new comparisons need separate processes.
- There is at most one runtime. A second initialization returns `AlreadyRunning`. Sessions retain an `Arc` to the runtime, so dropping its public handle cannot finalize live sessions. The last session/runtime owner finalizes Rime. A poisoned lock fails subsequent normal operations; destructors still attempt cleanup without panicking.
- Callers supply existing shared-resource and writable user directories. Initialization, source deployment, and session creation are setup work. `Runtime::with_cache` separates target-native cache files from personal data. `prepare` runs Rime's schema-list maintenance and checks its completion notification. Preparation is rejected while sessions exist. The wrapper does not prepare resources, download, access SQLite, or record telemetry from `process_key`.
- All text and paths crossing this ABI are NUL-terminated UTF-8. Embedded NUL and non-UTF-8 paths are rejected. Snapshot caret/selection offsets count **bytes in the returned UTF-8 preedit**. Rust validates character boundaries; frontends must convert to UTF-16 or other platform units. Candidate text and comments are independent strings.
- Keys are Rime/X11 keysyms with Rime modifier masks, not macOS virtual key codes or Linux hardware scan codes. `process_key` returns whether Rime handled the event. Raw `Session` does not expose document context or a mobile-editing API. Frontends supply bounded context
  through the policy engine. `change_page` delegates paging to Rime. `InputSession::select` and `highlight` accept a zero-based displayed index and the latest snapshot from that session. They reject snapshots from other sessions, superseded snapshots, and out-of-range indices before calling Rime: the snapshot must be the session's latest ordered page, and any mutation supersedes it, while repeated reads keep one identity.
- Snapshots are copied into Rust-owned strings and vectors while the lock is held. They remain valid after another event, another snapshot, session destruction, and runtime teardown. Page and highlighted indices are zero-based native menu metadata; an empty menu has no selectable entry regardless of those fields.
- `take_commit` consumes Rime's pending commit once and returns `None` when empty. Call it after each key or candidate selection before processing the next action. The prototype does not queue multiple uncollected commits. On an allocation or UTF-8 conversion error, a retrieved commit may already have been consumed; stop the session rather than replaying the key.
- Internal C callers must pass valid borrowed pointers and zero-initialized outputs. Status 0 is success, -1 native failure, -2 invalid session/schema, and -3 a caught C++ exception. A false/unhandled key is not an error. Native snapshots and commit buffers must be freed with their matching ABI functions, never Rust's allocator. Snapshot free clears the struct; it also accepts a zeroed snapshot.
- Every throwing C++ entry point catches exceptions before returning to Rust. The ABI has no callbacks into Rust, so Rust unwinding cannot cross it. Invalid pointers remain programmer errors, and allocator aborts/native crashes are not recoverable status codes. A native exception can leave engine state partially changed; callers must stop using the runtime and restart it.

See also the [shared dictionary generator](dictionary/README.md), which supplies Chinese source generation and spelling profiles for build preparation and the Swift update worker, and, before packaging, [the distribution review](licenses.md).
