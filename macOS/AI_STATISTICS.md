# Local AI statistics and timing queries

Both CLIs use Python's standard library and existing databases only. They validate
application ID, schema version, tables and required columns, then use SQLite
`mode=ro` and `query_only`. Missing, incompatible, busy or damaged databases exit 2
without creation or repair. Empty compatible results exit 0. Each command uses one
read snapshot per database and closes it before rendering. AI summaries stream
metadata; SQLite aggregates events and selects percentile endpoints. Ordinary
timing aggregates composition JSON in SQLite. Full event/key histories are not
loaded into Python.

## Commands and scope

Run from the repository root:

```sh
python_bin=$(mise which python)
ai_query=macOS/Tools/ai-statistics.py
quality_query=.agents/skills/inkflow-quality-analysis/scripts/quality.py
"$python_bin" "$ai_query" summary --since 2026-09-09 --until 2026-09-10 --format json
"$python_bin" "$ai_query" list --model YOUR_REQUESTED_MODEL --limit 20 --format json
"$python_bin" "$ai_query" inspect ATTEMPT_ID --format json \
  --quality-db "$HOME/Library/Application Support/InkFlow/quality.sqlite3"
"$python_bin" "$quality_query" timing --since 2026-09-09 --format json
```

AI defaults to `~/Library/Application Support/InkFlow/ai-statistics.sqlite3`;
`--db PATH` selects another existing file. All saved history is the default.
`--since` is inclusive and `--until` exclusive on **attempts.scheduled_at**, stored
as UTC epoch seconds with fractional precision. Dates mean local midnight;
timestamps require `Z` or an explicit offset. AI epoch filters are not rounded to
the ordinary database's millisecond ISO timestamp precision. `--model`,
`--strategy`, and `--app` match requested model, strategy version, and app bundle ID
exactly. Returned model remains a separate field.

`summary` reports coverage, rates, usage/cost, latency, equality, retention and
writer counters. `list` discovers IDs newest first, with `--limit 1..1000` (default
50). Neither selects sample text. `inspect ATTEMPT_ID` applies the same filters and
deliberately exposes retained input, current-page candidates and response text,
safe configuration/pricing snapshots, and first-observed events. Use `--format
json|table|csv`; table nulls display as `N/A` and CSV is long-form path/value data.

Optional `inspect --quality-db PATH` looks up only exact scheduled/dispatch
composition IDs, deduplicating equal IDs while retaining both association labels.
It returns composition outcome and operations/timing, without candidate or commit
text. Missing IDs remain unknown; joins never use nearby timestamps. The databases
have separate consistent snapshots, not a shared atomic snapshot.

## Event and rate meanings

Counts are distinct attempts with the named first-observed event. These facts are
not a mutually exclusive funnel: UI cancellation can precede a late response.

| Event | Observed fact |
| --- | --- |
| scheduled | Debounce attempt created; it may never dispatch |
| dispatched | Suggestion service invoked |
| transportStarted | Actual network attempt began; request denominator |
| responseObserved | HTTP response/usage observed before cancellation or content validation |
| transportEnded | Transport ended, with independent reason/status |
| serviceReturned / serviceFailed | Service returned a valid result or failed |
| shown | First successful suggestion presentation, deduplicated |
| adoptionRequested | Preview consumed for adoption |
| insertionIssued / insertionReturned | Controller invoked / returned from editor insertion |
| uiEnded | UI lifecycle ended independently of later accounting |

`display_adoption = count(shown AND insertionIssued) / count(shown)`.
`request_conversion = count(transportStarted AND insertionIssued) /
count(transportStarted)`. `display_rate` uses `shown AND transportStarted` over
`transportStarted`. Missing denominator evidence cannot inflate the numerator;
zero denominators yield null. Ratios are fractions, not percentages. For example,
100 network attempts, 80 shown and 20 issued insertions belonging to both cohorts
produce 25% display adoption and 20% request conversion.

Completion requires UI end, a return/failure for any dispatched service, and a
transport end for any network attempt. Pending, interrupted, closed-incomplete and
unknown-incomplete remain separate. Failure and undisplayed terminal reason counts
are additional facts, not rejection rates. No event proves attention, editor
rendering or permanent document retention. Crashes/drops can leave incomplete
records.

## Usage, estimates and comparisons

Usage states are `unobserved`, `missing`, `partial`, `invalid`, `valid`. Token totals
include available fields from valid/partial records, each with its own known-attempt
count; no observations means a null total. Invalid usage is excluded. Cached tokens
are a subset of prompt tokens and reasoning tokens a subset of completion tokens.
Neither is added again to totals or cost.

Known costs are read as Decimal strings and summed separately by currency.
`cost_per_issued_adoption` divides **all cost-known attempt costs** in a currency by
`shown AND insertionIssued` within that same cost-known cohort, including costs of
unadopted requests. `mean_adopted_request_cost` instead averages only cost-known
adopted requests, with `adopted_request_cost` showing their total. That average is
not the cost of obtaining an adoption. Missing cost coverage is separate; neither
ratio imputes missing prices/usage as zero. Zero adoption denominators yield null.
Division uses 28 significant decimal digits. Estimates are not verified bills.

`matches_first_candidate` and `matches_candidate_page` compare the trimmed full
replacement with **selectedPrefix + each raw candidate on the captured current
page**. This is equality, not correctness, all-Rime recall or keystrokes saved.
Known/true/false/unknown counts and suggestion length survive expiry. The first
`serviceReturned` text supersedes bounded raw response content. `response_truncated`
is sticky history: a complete canonical return can have valid comparisons despite
that flag. Exceptionally, a return more than 30 days late or a forward clock jump
can lose comparison evidence after cleanup; usage, cost and status are independent.

Latency fields use monotonic milliseconds: network start to response, schedule or
dispatch to first show, and last edit to first show. Last-edit latency prefers the
dispatch association, falling back to the scheduled association when necessary.
`ordinary_visible_at_dispatch` is accumulated observed candidate visibility after
the last edit at dispatch. Distributions give known/unknown counts, units, P50 and
P95 using linear interpolation at `(n-1)*p` in the sorted known samples.

Writer counters are `whole_db_lifetime_unfiltered`, even for empty filtered
cohorts. Cumulative command counters are summed with known-run coverage;
buffered/peak/disabled/error-code diagnostics stay per run. These are command
counts, not request/drop denominators. Fatal failure or crash can lose the final
counter update.

## Local retention and optional pricing

The input method creates the store at startup. There is no separate statistics
toggle: using AI records attempts; disabling AI stops new scheduling. The 500 ms
strategy is unchanged and there is no settings statistics dashboard. Statistics
reuse bounded context, Pinyin and candidates already read, without requesting extra
document content. `preceding_available` and `following_available` distinguish
unavailable context from genuinely empty text.

Only `samples` holds AI user text: `input_json`, `candidates_json`, `response_text`.
Expiry is scheduled time + 30 days. The writer cleans at startup, on flush and every
30 seconds while running, with secure deletion and DELETE journaling. Deletion
cannot be guaranteed while stopped. Late events do not recreate expired samples.
Readonly inspection also hides expired rows before cleanup. `absent` cannot
separate never captured, dropped and already-cleaned samples; `expired` means a row
still exists but its content is hidden. Numeric metadata, events and configuration
snapshots persist. This policy does **not** delete legacy ordinary `quality.sqlite3`
input, candidate or preceding-context records. Logs exclude user text/credentials;
neither statistics database stores the AI API key.

Optional `~/Library/Application Support/InkFlow/ai-pricing.json` is read at startup
(at most 128 KiB, version 1, at most 256 rules). No prices are built in. These example
rates are **synthetic test values, not a provider tariff**:

```json
{
  "version": 1,
  "rules": [{
    "id": "synthetic-example-v1",
    "provider": "https://fixture.example",
    "model": "fixture-model",
    "currency": "USD",
    "inputPerMillion": 2,
    "cachedInputPerMillion": 0.2,
    "outputPerMillion": 4
  }]
}
```

Use normalized provider origin `scheme://host[:port]` without API path, query,
fragment or credentials. Rates must be finite nonnegative numbers; currency is
three uppercase ASCII letters. Optional `effectiveFrom` (inclusive) and
`effectiveUntil` (exclusive) use ISO8601 timestamps. Exactly one valid rule must
match origin, requested model and request time; otherwise price is unknown. Each
attempt retains its immutable rule. File changes take effect at next process
startup and do not reprice history. A different returned model makes cost unknown.
Missing cache usage/rates affecting cost remain unknown. Setting cached-input
price explicitly equal to input price permits uniformly priced estimates without
a separate cache count.

For this synthetic example, 250 prompt tokens including 100 cached, plus 50 output
tokens including 10 reasoning, cost `(150*2 + 100*0.2 + 50*4)/1e6 = 0.00052 USD`.
Reasoning is already included in the 50 output tokens.

## Ordinary timing and verification

See the [ordinary query contract](../.agents/skills/inkflow-quality-analysis/references/query-contract.md#input-timing)
for composition filtering, retained key intervals, last-edit versus remaining-phase
waits, and visibility observation limits. Old timing stays unknown.

Focused checks use synthetic databases and actual Swift writer fixtures:

```sh
bash macOS/scripts/test-ai-statistics.sh
bash macOS/scripts/test-ai-statistics-query.sh
bash macOS/scripts/test-quality-query.sh --require-engine
```

The last command requires `test-quality-capture.sh` evidence. Full `test.sh` orders
the writer before AI queries and capture before ordinary queries. Pass an explicit
writer fixture directory to `test-ai-statistics-query.sh` for repeatable review.
No real service/user database is used. These checks establish query/storage
behavior, not installation or live editor acceptance.
