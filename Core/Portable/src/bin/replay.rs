//! Offline replay of recorded decisions, to score a ranking change before it ships.
//!
//! `replay list CASES [--context-index PATH] [--json]` reads the cases that
//! `quality.py replay-cases` exports and scores three arms against what the user chose:
//! `native` (Rime's first candidate), `displayed` (the candidate shown first when recorded) and
//! `ranked` (the context ranker run again on the case). The README section "Replay and the
//! first-choice target" defines the counts and the ship rule.
//!
//! `replay engine CASES --arm NAME=RESOURCES|NAME=@FILE ... [--train NAME ...] [--record NAME=FILE ...]
//! [--json]` runs the real engine once per arm on prepared resources and compares the arms with each other;
//! an arm named by `--train` learns from the recorded decisions as it goes (see "Engine-mode replay" in the
//! README).
use inkflow_rime::{
    engine::{Configuration, Engine, InputSession, Snapshot},
    preferences::InputPreferences,
    ranking::{ContextRanker, is_han, parse_metadata},
};
use serde_json::{Map, Value, json};
use std::{
    collections::{HashMap, HashSet},
    error::Error,
    f64::consts::LN_2,
    fs,
    io::Write,
    ops::Range,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const USAGE: &str = "Usage: replay list CASES [--context-index PATH] [--json]\n       \
                     replay engine CASES --arm NAME=RESOURCES|NAME=@FILE ... [--train NAME ...] \
                     [--record NAME=FILE ...] [--json]";
/// Instrument constant: replay files hold typed text, which quality records keep for 28 days.
const MAX_AGE_SECONDS: i64 = 28 * 24 * 60 * 60;
/// Instrument constant: the pages searched for a selected text, the quality baseline's `pageLimit`.
const PAGE_LIMIT: usize = 20;
/// Instrument constant: a rate over fewer units gets its interval and no verdict (design section 8).
const MIN_UNITS: u64 = 200;
/// The 95% two-sided normal quantile, `NormalDist().inv_cdf(0.975)` as `quality.py` computes it.
const Z95: f64 = 1.959_963_984_540_053_4;
/// The X11 keysym of Page_Down.
const PAGE_DOWN: i32 = 0xff56;
/// Instrument constants, not product rules.
const FUNCTION_WORDS: [&str; 10] = ["的", "地", "得", "在", "再", "吧", "把", "他", "她", "它"];
const DICTIONARY_TYPES: [&str; 3] = ["phrase", "user_phrase", "user_table"];
/// Scopes of the breakdown: the whole set, the classes, then the buckets of the selected text's length
/// that the target is judged on. A case may belong to several classes.
const SCOPES: [&str; 10] = [
    "all",
    "dictionary_leader",
    "decoder_leader",
    "segmentation",
    "single_char",
    "off_page",
    "function_word",
    "length_1",
    "length_2",
    "length_3_plus",
];

struct Candidate {
    text: String,
    display_index: usize,
    native_index: usize,
    native_rank: usize,
    kind: Option<String>,
    evidence: Option<String>,
}

struct Case {
    id: String,
    composition: String,
    raw_input: String,
    preceding: String,
    page: u64,
    candidates: Vec<Candidate>,
    selected_index: Option<usize>,
    selected: String,
    committed: String,
}

fn text(value: &Value, key: &str) -> Result<String> {
    let text = value[key].as_str();
    Ok(text.ok_or_else(|| format!("{key} is not text"))?.to_owned())
}

fn count(value: &Value, key: &str) -> Result<usize> {
    let count = value[key].as_u64();
    Ok(count.ok_or_else(|| format!("{key} is not a count"))? as usize)
}

fn candidate(value: &Value) -> Result<Candidate> {
    Ok(Candidate {
        text: text(value, "text")?,
        display_index: count(value, "display_index")?,
        native_index: count(value, "native_index")?,
        native_rank: count(value, "native_rank")?,
        kind: value["type"].as_str().map(str::to_owned),
        evidence: value["evidence"].as_str().map(str::to_owned),
    })
}

fn case(value: &Value) -> Result<Case> {
    let candidates = value["candidates"]
        .as_array()
        .ok_or("candidates is not a list")?;
    Ok(Case {
        id: value["decision_id"].as_str().unwrap_or_default().to_owned(),
        composition: value["composition_id"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
        raw_input: text(value, "raw_input")?,
        preceding: text(value, "preceding_context")?,
        page: value["page"].as_u64().ok_or("page is not a count")?,
        candidates: candidates.iter().map(candidate).collect::<Result<_>>()?,
        selected_index: value["selected_display_index"].as_u64().map(|i| i as usize),
        selected: text(value, "selected_text")?,
        committed: value["committed_text"]
            .as_str()
            .unwrap_or_default()
            .to_owned(),
    })
}

/// Seconds since the epoch of `YYYY-MM-DDTHH:MM:SS[.fff]Z`, the form `quality.py` writes.
fn unix_seconds(stamp: &str) -> Option<i64> {
    let (date, time) = stamp.strip_suffix('Z')?.split_once('T')?;
    let number = |part: Option<&str>| part?.parse::<i64>().ok();
    let mut date = date.split('-');
    let (year, month, day) = (
        number(date.next())?,
        number(date.next())?,
        number(date.next())?,
    );
    let mut time = time.split(':');
    let (hour, minute) = (number(time.next())?, number(time.next())?);
    let second = number(time.next()?.split('.').next())?;
    if date.next().is_some() || time.next().is_some() || !(1..=12).contains(&month) {
        return None;
    }
    // Days since 1970-01-01 from the civil calendar (Hinnant's days_from_civil).
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let day_of_year = (153 * ((month + 9) % 12) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

fn check_age(header: &Value) -> Result<()> {
    let stamp = header["generated_at"]
        .as_str()
        .ok_or("the first line is not a header with generated_at")?;
    let generated =
        unix_seconds(stamp).ok_or_else(|| format!("generated_at {stamp:?} is not a UTC time"))?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs() as i64;
    if now - generated > MAX_AGE_SECONDS {
        return Err(format!(
            "generated_at {stamp} is {} days ago, past the 28-day retention of the records; \
             delete this file and export the cases again",
            (now - generated) / 86_400
        )
        .into());
    }
    Ok(())
}

struct Loaded {
    cases: Vec<Case>,
    /// The dictionary the checked-in fixture's own ranker uses.
    dictionary: Option<String>,
    /// The export's `generated_at`; the fixture has none.
    generated_at: Option<String>,
}

fn load(path: &str) -> Result<Loaded> {
    let body = fs::read_to_string(path).map_err(|error| format!("cannot read {path}: {error}"))?;
    // The fixture is one JSON document without records, so it has no age. An export is JSON Lines.
    if let Ok(document) = serde_json::from_str::<Value>(&body)
        && let Some(cases) = document["cases"].as_array()
    {
        return Ok(Loaded {
            cases: cases.iter().map(case).collect::<Result<_>>()?,
            dictionary: document["dictionary"].as_str().map(str::to_owned),
            generated_at: None,
        });
    }
    let mut lines = body.lines();
    let header = serde_json::from_str::<Value>(lines.next().unwrap_or_default())
        .map_err(|error| format!("the first line is not a header: {error}"))?;
    check_age(&header)?;
    let mut cases = Vec::new();
    for (number, line) in (2..).zip(lines).filter(|(_, line)| !line.is_empty()) {
        let value = serde_json::from_str::<Value>(line)
            .map_err(|error| format!("line {number}: {error}"))?;
        cases.push(case(&value).map_err(|error| format!("line {number}: {error}"))?);
    }
    Ok(Loaded {
        cases,
        dictionary: None,
        generated_at: header["generated_at"].as_str().map(str::to_owned),
    })
}

#[derive(Clone, Copy)]
enum Verdict {
    Hit,
    Miss,
    NoEvidence,
    Unparsable,
}

impl Verdict {
    fn of(hit: bool) -> Self {
        if hit { Self::Hit } else { Self::Miss }
    }
}

/// The context ranker run again on the page in Rime's order, as the engine ran it.
fn ranked_pick(case: &Case, ranker: &ContextRanker) -> std::result::Result<String, Verdict> {
    let mut page: Vec<_> = case.candidates.iter().collect();
    page.sort_by_key(|candidate| candidate.native_index);
    let rows: Option<Vec<_>> = page.iter().map(|c| c.evidence.as_deref()).collect();
    let Some(rows) = rows.filter(|rows| !rows.is_empty()) else {
        return Err(Verdict::NoEvidence);
    };
    let in_order = page.iter().enumerate().all(|(i, c)| c.native_index == i);
    let metadata = parse_metadata(
        &format!("0,{};{}", rows.len(), rows.join(";")),
        0,
        rows.len(),
        case.raw_input.len(),
    );
    let Some(metadata) = metadata.filter(|_| in_order) else {
        return Err(Verdict::Unparsable);
    };
    let texts: Vec<String> = page.iter().map(|c| c.text.clone()).collect();
    let order = ranker.order(&texts, &case.preceding, Some(&metadata));
    Ok(texts[order[0]].clone())
}

/// Whether the selected candidate's evidence ends before the end of the input.
fn ends_early(case: &Case) -> bool {
    let selected = case
        .candidates
        .iter()
        .find(|c| Some(c.display_index) == case.selected_index && c.text == case.selected);
    let row = selected.and_then(|c| c.evidence.as_deref());
    let metadata =
        row.and_then(|row| parse_metadata(&format!("0,1;{row}"), 0, 1, case.raw_input.len()));
    case.page == 0 && metadata.is_some_and(|rows| rows[0].coverage.end < case.raw_input.len())
}

/// Membership in each of `SCOPES`, decided from the case alone. The leader is Rime's first candidate.
fn scopes(case: &Case) -> [bool; 10] {
    let leader = case.candidates.iter().find(|c| c.native_rank == 1);
    let kind = leader.and_then(|c| c.kind.as_deref());
    let length = case.selected.chars().count();
    [
        true,
        kind.is_some_and(|kind| DICTIONARY_TYPES.contains(&kind)),
        kind == Some("sentence"),
        ends_early(case),
        is_han(&case.selected),
        case.page > 0,
        FUNCTION_WORDS.contains(&case.selected.as_str()),
        length == 1,
        length == 2,
        length >= 3,
    ]
}

struct Scored {
    pair: (String, String),
    native: bool,
    displayed: Verdict,
    ranked: Option<Verdict>,
    scopes: [bool; 10],
}

fn score(case: &Case, ranker: Option<&ContextRanker>) -> Scored {
    let hit = |pick: Option<&Candidate>| pick.is_some_and(|c| c.text == case.selected);
    let ranked = ranker.map(|ranker| match ranked_pick(case, ranker) {
        Ok(pick) => Verdict::of(pick == case.selected),
        Err(skipped) => skipped,
    });
    Scored {
        pair: (case.raw_input.clone(), case.selected.clone()),
        native: hit(case.candidates.iter().find(|c| c.native_rank == 1)),
        displayed: Verdict::of(hit(case.candidates.iter().find(|c| c.display_index == 0))),
        ranked,
        scopes: scopes(case),
    }
}

/// Counts of one arm against native over one scope.
#[derive(Default, Clone, Copy)]
struct Tally {
    cases: u64,
    native_hits: u64,
    hits: u64,
    fixed: u64,
    broken: u64,
}

impl Tally {
    fn add(&mut self, native: bool, hit: bool) {
        self.cases += 1;
        self.native_hits += u64::from(native);
        self.hits += u64::from(hit);
        self.fixed += u64::from(hit && !native);
        self.broken += u64::from(native && !hit);
    }

    fn json(&self) -> Value {
        json!({
            "cases": self.cases,
            "native_hits": self.native_hits,
            "hits": self.hits,
            "fixed": self.fixed,
            "broken": self.broken,
        })
    }

    /// Errors the arm introduced per error it fixed: the odds of the regression share. Unavailable
    /// without a fixed case.
    fn er(&self) -> Option<f64> {
        (self.fixed > 0).then(|| self.broken as f64 / self.fixed as f64)
    }

    /// Broken over fixed plus broken, with its 95% Wilson interval.
    fn regression(&self) -> Option<Interval> {
        wilson(self.broken, self.fixed + self.broken)
    }

    /// Engine mode's block: the counts, ER and the regression share.
    fn paired_json(&self) -> Value {
        let mut block = self.json();
        block["er"] = json!(self.er());
        block["regression_share"] = json!(self.regression().map(|interval| interval.rate));
        block["wilson_low"] = json!(self.regression().map(|interval| interval.low));
        block["wilson_high"] = json!(self.regression().map(|interval| interval.high));
        block
    }
}

/// A proportion with its 95% Wilson score interval.
#[derive(Clone, Copy)]
struct Interval {
    rate: f64,
    low: f64,
    high: f64,
}

/// `quality.py`'s `wilson`: unavailable without observations.
fn wilson(successes: u64, total: u64) -> Option<Interval> {
    if total == 0 {
        return None;
    }
    let n = total as f64;
    let rate = successes as f64 / n;
    let squared = Z95 * Z95;
    let center = rate + squared / (2.0 * n);
    let margin = Z95 * (rate * (1.0 - rate) / n + squared / (4.0 * n * n)).sqrt();
    let scale = 1.0 + squared / n;
    let low = if successes == 0 {
        0.0
    } else {
        ((center - margin) / scale).max(0.0)
    };
    let high = if successes == total {
        1.0
    } else {
        ((center + margin) / scale).min(1.0)
    };
    Some(Interval { rate, low, high })
}

/// Every case, one case per distinct (raw_input, selected_text) pair (its first) and, in engine mode, one
/// per pair that occurs more than once (its last).
#[derive(Default, Clone, Copy)]
struct Scope {
    cases: Tally,
    distinct: Tally,
    repeat: Tally,
}

impl Scope {
    fn p(&self) -> f64 {
        mcnemar(self.distinct.fixed, self.distinct.broken)
    }

    fn repeat_p(&self) -> f64 {
        mcnemar(self.repeat.fixed, self.repeat.broken)
    }
}

#[derive(Default)]
struct Arm {
    scored: u64,
    without_evidence: u64,
    unparsable: u64,
    scopes: [Scope; 10],
}

fn tally(cases: &[Scored], verdict: impl Fn(&Scored) -> Verdict) -> Arm {
    let mut arm = Arm::default();
    let mut seen = HashSet::new();
    for case in cases {
        let hit = match verdict(case) {
            Verdict::Hit => true,
            Verdict::Miss => false,
            Verdict::NoEvidence => {
                arm.without_evidence += 1;
                continue;
            }
            Verdict::Unparsable => {
                arm.unparsable += 1;
                continue;
            }
        };
        arm.scored += 1;
        let first = seen.insert(&case.pair);
        for (counts, _) in arm
            .scopes
            .iter_mut()
            .zip(case.scopes)
            .filter(|(_, member)| *member)
        {
            counts.cases.add(case.native, hit);
            if first {
                counts.distinct.add(case.native, hit);
            }
        }
    }
    arm
}

/// Exact two-sided McNemar test: twice the lower binomial tail of the discordant pairs at one half.
fn mcnemar(fixed: u64, broken: u64) -> f64 {
    let n = (fixed + broken) as usize;
    if n == 0 {
        return 1.0;
    }
    let mut ln_factorial = vec![0.0_f64; n + 1];
    for i in 1..=n {
        ln_factorial[i] = ln_factorial[i - 1] + (i as f64).ln();
    }
    let tail: f64 = (0..=fixed.min(broken) as usize)
        .map(|k| (ln_factorial[n] - ln_factorial[k] - ln_factorial[n - k] - n as f64 * LN_2).exp())
        .sum();
    (2.0 * tail).min(1.0)
}

fn scope_json(scope: &Scope) -> Value {
    json!({"cases": scope.cases.json(), "distinct": scope.distinct.json(), "p": scope.p()})
}

fn arm_json(arm: &Arm) -> Value {
    let mut scopes = Map::new();
    for (name, scope) in SCOPES.iter().zip(&arm.scopes) {
        scopes.insert((*name).to_owned(), scope_json(scope));
    }
    json!({
        "scored": arm.scored,
        "skipped": {"without_evidence": arm.without_evidence, "unparsable": arm.unparsable},
        "scopes": scopes,
    })
}

fn p_text(p: f64) -> String {
    if p < 1e-4 {
        format!("{p:.2e}")
    } else {
        format!("{p:.4}")
    }
}

/// The scope table: counts of every case, then of the distinct pairs, of an arm against `base`.
fn print_scopes(base: &str, rows: &[(&str, Scope)]) {
    println!(
        "{:<18}{:>7}{:>8}{:>6}{:>7}{:>8} |{:>9}{:>8}{:>6}{:>7}{:>8} |{:>11}",
        "scope",
        "cases",
        base,
        "arm",
        "fixed",
        "broken",
        "distinct",
        base,
        "arm",
        "fixed",
        "broken",
        "McNemar p"
    );
    for (label, scope) in rows {
        let (c, d) = (scope.cases, scope.distinct);
        println!(
            "{label:<18}{:>7}{:>8}{:>6}{:>7}{:>8} |{:>9}{:>8}{:>6}{:>7}{:>8} |{:>11}",
            c.cases,
            c.native_hits,
            c.hits,
            c.fixed,
            c.broken,
            d.cases,
            d.native_hits,
            d.hits,
            d.fixed,
            d.broken,
            p_text(scope.p()),
        );
    }
}

fn print_arm(name: &str, arm: &Arm) {
    let all = arm.scopes[0];
    println!(
        "\n{name} vs native: {} cases scored, hits {} vs {}; skipped {} without evidence, {} unparsable",
        arm.scored, all.cases.hits, all.cases.native_hits, arm.without_evidence, arm.unparsable,
    );
    let rows: Vec<_> = SCOPES.iter().copied().zip(arm.scopes).collect();
    print_scopes("native", &rows);
}

fn list(args: &[String]) -> Result<()> {
    let (mut path, mut index, mut as_json) = (None, None, false);
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--json" => as_json = true,
            "--context-index" => index = Some(rest.next().ok_or(USAGE)?),
            other if path.is_none() && !other.starts_with("--") => path = Some(other),
            _ => return Err(USAGE.into()),
        }
    }
    let path = path.ok_or(USAGE)?;
    let Loaded {
        cases, dictionary, ..
    } = load(path)?;
    let (ranker, source) = match (index, dictionary) {
        (Some(index), _) => (
            Some(ContextRanker::from_index(fs::read(index)?)?),
            format!("context index {index}"),
        ),
        (None, Some(dictionary)) => (
            Some(ContextRanker::from_dictionary(&dictionary)),
            "the fixture's own dictionary".to_owned(),
        ),
        (None, None) => (
            None,
            "none: the ranked arm needs --context-index".to_owned(),
        ),
    };
    let scored: Vec<_> = cases
        .iter()
        .map(|case| score(case, ranker.as_ref()))
        .collect();
    let displayed = tally(&scored, |case| case.displayed);
    let ranked = ranker
        .as_ref()
        .map(|_| tally(&scored, |case| case.ranked.expect("scored with a ranker")));
    if as_json {
        let report = json!({
            "cases": scored.len(),
            "arms": {"displayed": arm_json(&displayed), "ranked": ranked.as_ref().map(arm_json)},
        });
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(());
    }
    println!(
        "Replay list of {path}: {} cases, {} distinct (raw_input, selected_text) pairs.",
        scored.len(),
        displayed.scopes[0].distinct.cases,
    );
    println!("Ranker: {source}. Distinct counts keep the first case of each pair.");
    print_arm("displayed", &displayed);
    if let Some(ranked) = &ranked {
        print_arm("ranked", ranked);
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Engine mode
// ---------------------------------------------------------------------------------------------

/// Index of `segmentation` in `SCOPES`: the cases the whole-input candidate is judged on.
const SEGMENTATION: usize = 3;

/// Where a page's first candidate comes from, a coarser view of the design's provenance dimension.
/// `Learned` is `user_phrase` or an English or mixed candidate with a personal source, `Dictionary` is
/// `phrase` or `user_table`, `Assembled` is `sentence`. `Other` folds `completion` and the English and mixed
/// types without a personal source. `NoEvidence` is a page without evidence: after a selected prefix, or for
/// a custom-phrase code.
#[derive(Clone, Copy)]
enum Provenance {
    Learned,
    Dictionary,
    Assembled,
    Other,
    NoEvidence,
}

impl Provenance {
    /// In declaration order, which indexes the leader counts.
    const ALL: [Self; 5] = [
        Self::Learned,
        Self::Dictionary,
        Self::Assembled,
        Self::Other,
        Self::NoEvidence,
    ];

    fn name(self) -> &'static str {
        match self {
            Self::Learned => "learned",
            Self::Dictionary => "dictionary",
            Self::Assembled => "assembled",
            Self::Other => "other",
            Self::NoEvidence => "none",
        }
    }

    fn parse(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|provenance| provenance.name() == name)
    }

    fn of(candidate: Option<&inkflow_rime::engine::Candidate>) -> Self {
        let Some(evidence) = candidate.and_then(|candidate| candidate.evidence.as_ref()) else {
            return Self::NoEvidence;
        };
        match evidence.candidate_type.as_str() {
            "user_phrase" => Self::Learned,
            _ if evidence.personal_source().is_some() => Self::Learned,
            "phrase" | "user_table" => Self::Dictionary,
            "sentence" => Self::Assembled,
            _ => Self::Other,
        }
    }
}

/// What one arm showed for one case: the first candidate of the first page with its provenance, the
/// longest candidate that consumes the whole input, and whether each equals the gold text.
struct Outcome {
    id: String,
    first: String,
    first_provenance: Provenance,
    longest: String,
    first_hit: bool,
    longest_hit: bool,
}

impl Outcome {
    fn new(case: &Case, first: String, first_provenance: Provenance, longest: String) -> Self {
        let hit = |shown: &str, gold: &str| !shown.is_empty() && shown == gold;
        Self {
            id: case.id.clone(),
            first_hit: hit(&first, &case.selected),
            longest_hit: hit(&longest, &case.committed),
            first,
            first_provenance,
            longest,
        }
    }

    fn json(&self) -> Value {
        json!({
            "id": self.id,
            "first": self.first,
            "first_provenance": self.first_provenance.name(),
            "longest": self.longest,
            "first_hit": self.first_hit,
            "longest_hit": self.longest_hit,
        })
    }
}

/// What became of the compositions of one arm. The training counts say what the final selection of a
/// walkable composition did: `trained` committed the recorded text, `incomplete` left letters behind,
/// `commit_mismatch` committed something else. Only a trained arm makes that selection.
#[derive(Default, Clone, Copy)]
struct Walk {
    compositions: u64,
    walkable: u64,
    unwalkable: u64,
    unfound: u64,
    trained: u64,
    incomplete: u64,
    commit_mismatch: u64,
}

impl Walk {
    fn walk_json(&self) -> Value {
        json!({
            "compositions": self.compositions,
            "walkable": self.walkable,
            "unwalkable": self.unwalkable,
            "unfound": self.unfound,
        })
    }

    fn training_json(&self) -> Value {
        json!({
            "trained": self.trained,
            "incomplete": self.incomplete,
            "commit_mismatch": self.commit_mismatch,
        })
    }

    /// The counts a record's header carries; a record from before the walk has none.
    fn from_header(header: &Value) -> Option<Self> {
        let (walk, training) = (&header["walk"], &header["training"]);
        let count = |part: &Value, key: &str| part[key].as_u64().unwrap_or_default();
        walk.is_object().then(|| Self {
            compositions: count(walk, "compositions"),
            walkable: count(walk, "walkable"),
            unwalkable: count(walk, "unwalkable"),
            unfound: count(walk, "unfound"),
            trained: count(training, "trained"),
            incomplete: count(training, "incomplete"),
            commit_mismatch: count(training, "commit_mismatch"),
        })
    }
}

/// The cases of one composition, which the file keeps together and in order.
struct Composition {
    cases: Range<usize>,
    walkable: bool,
}

/// Whether the decisions replay as one composition: each later input extends the one before, and the
/// selected texts in order make the text that was committed.
fn walkable(cases: &[Case]) -> bool {
    let extends = cases
        .windows(2)
        .all(|pair| pair[1].raw_input.starts_with(&pair[0].raw_input));
    let selected: String = cases.iter().map(|case| case.selected.as_str()).collect();
    extends && cases.last().is_some_and(|last| selected == last.committed)
}

fn compositions(cases: &[Case]) -> Result<Vec<Composition>> {
    let mut found = Vec::new();
    let mut seen = HashSet::new();
    let mut start = 0;
    while start < cases.len() {
        let id = &cases[start].composition;
        if id.is_empty() {
            return Err("engine mode needs a composition_id on every case".into());
        }
        if !seen.insert(id) {
            return Err(format!("composition {id} is not adjacent in the file").into());
        }
        let length = cases[start..]
            .iter()
            .take_while(|case| case.composition == *id)
            .count();
        let end = start + length;
        found.push(Composition {
            cases: start..end,
            walkable: walkable(&cases[start..end]),
        });
        start = end;
    }
    Ok(found)
}

/// A scratch user directory, removed when the arm is done.
struct UserDirectory(PathBuf);

impl Drop for UserDirectory {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).ok();
    }
}

/// The longest candidate whose evidence says it consumes the whole input; the earlier one on a tie.
fn longest_whole_input(
    candidates: &[inkflow_rime::engine::Candidate],
    input_length: usize,
) -> String {
    let mut longest = "";
    let mut length = 0;
    for candidate in candidates {
        let whole = candidate
            .evidence
            .as_ref()
            .is_some_and(|evidence| evidence.coverage == (0..input_length));
        let count = candidate.text.chars().count();
        if whole && count > length {
            longest = &candidate.text;
            length = count;
        }
    }
    longest.to_owned()
}

/// Type letters into the composition.
fn type_letters(session: &InputSession, letters: &str) -> Result<()> {
    for byte in letters.bytes() {
        session.key(i32::from(byte), i32::from(byte.is_ascii_uppercase()))?;
        session.take_commit()?;
    }
    Ok(())
}

/// A new composition holding the whole `raw_input` of the case.
fn type_fresh(session: &InputSession, case: &Case) -> Result<()> {
    session.clear()?;
    session.set_preceding_text(&case.preceding)?;
    type_letters(session, &case.raw_input)
}

/// Score the first page now shown for the case.
fn observe(session: &InputSession, case: &Case) -> Result<(Outcome, Snapshot)> {
    let page = session.snapshot()?;
    let first = page.candidates.first();
    let shown = first.map_or_else(String::new, |candidate| candidate.text.clone());
    let longest = longest_whole_input(&page.candidates, case.raw_input.len());
    let outcome = Outcome::new(case, shown, Provenance::of(first), longest);
    Ok((outcome, page))
}

/// Select `text` on the page shown or on a later one, up to `PAGE_LIMIT` pages. False when it is not there.
fn select_text(session: &InputSession, mut page: Snapshot, text: &str) -> Result<bool> {
    for pages in 1..=PAGE_LIMIT {
        if let Some(index) = page.candidates.iter().position(|c| c.text == text) {
            session.select(&page, index)?;
            return Ok(true);
        }
        if pages == PAGE_LIMIT {
            break;
        }
        session.key(PAGE_DOWN, 0)?;
        let next = session.snapshot()?;
        if next.page == page.page {
            break;
        }
        page = next;
    }
    Ok(false)
}

/// Replay one composition. A walkable one is typed once: each decision is scored on the page the user was
/// shown, in the state their earlier selections left, then its text is selected and the extra letters of the
/// next decision are typed. A trained arm also makes the last selection, which commits and so trains; the
/// cold arm leaves it. The walk ends at a text that is not found or at a selection that ends the
/// composition early, and the decisions after it, like every decision of an unwalkable composition, are
/// scored on a fresh composition that trains nothing.
fn walk_composition(
    session: &InputSession,
    cases: &[Case],
    walkable: bool,
    train: bool,
    walk: &mut Walk,
) -> Result<Vec<Outcome>> {
    walk.compositions += 1;
    walk.walkable += u64::from(walkable);
    walk.unwalkable += u64::from(!walkable);
    let last = cases.len() - 1;
    let mut walking = walkable;
    let mut outcomes = Vec::with_capacity(cases.len());
    for (index, case) in cases.iter().enumerate() {
        if walking && index > 0 {
            type_letters(session, &case.raw_input[cases[index - 1].raw_input.len()..])?;
        } else {
            type_fresh(session, case)?;
        }
        let (outcome, page) = observe(session, case)?;
        outcomes.push(outcome);
        if !walking || (index == last && !train) {
            continue;
        }
        if !select_text(session, page, &case.selected)? {
            walk.unfound += 1;
            walking = false;
            continue;
        }
        let commit = session.take_commit()?;
        let remaining = !session.snapshot()?.preedit.is_empty();
        if remaining && index < last {
            continue;
        }
        walking = false;
        if remaining {
            // The next composition's clear discards the letters; nothing is learned.
            walk.incomplete += 1;
        } else if commit == cases[last].committed {
            walk.trained += 1;
        } else {
            walk.commit_mismatch += 1;
        }
    }
    Ok(outcomes)
}

struct Run {
    name: String,
    source: String,
    trained: bool,
    /// The walk counts; a record from before the walk has none.
    walk: Option<Walk>,
    /// Records that carry no `first_provenance`: they load as `none`.
    without_provenance: u64,
    outcomes: Vec<Outcome>,
}

/// Run every composition on a fresh engine, one arm. The user directory starts absent and is deleted
/// afterwards, whatever a trained arm learned in it.
fn run_live(
    name: &str,
    resources: &Path,
    cases: &[Case],
    compositions: &[Composition],
    train: bool,
) -> Result<Run> {
    if !resources.join("prepared/complete").is_file() {
        return Err(format!(
            "arm {name}: {} is not a prepared resources directory",
            resources.display()
        )
        .into());
    }
    let user = UserDirectory(
        std::env::temp_dir().join(format!("inkflow-replay-{}-{name}", std::process::id())),
    );
    fs::remove_dir_all(&user.0).ok();
    let engine = Engine::new(Configuration {
        shared: resources.join("shared"),
        user: user.0.clone(),
        cache: Some(resources.join("prepared/cache")),
        context_index: Some(resources.join("shared/pinyin_simp.context.bin")),
    })
    .map_err(|error| format!("arm {name}: {error}"))?;
    let session = engine.session()?;
    session.set_configuration(9, &[], Some(&InputPreferences::default()))?;
    if let Some(error) = session.configuration_error() {
        return Err(format!("arm {name}: configuration failed: {}", error.code()).into());
    }
    let mut walk = Walk::default();
    let mut outcomes = Vec::with_capacity(cases.len());
    for composition in compositions {
        let cases = &cases[composition.cases.clone()];
        let walked = walk_composition(&session, cases, composition.walkable, train, &mut walk)?;
        outcomes.extend(walked);
    }
    session.clear()?;
    Ok(Run {
        name: name.to_owned(),
        source: format!("live on {}", resources.display()),
        trained: train,
        walk: Some(walk),
        without_provenance: 0,
        outcomes,
    })
}

/// What a record row says about one case.
struct Row {
    first: String,
    provenance: Option<Provenance>,
    longest: String,
}

fn record_row(value: &Value) -> Result<(String, Row)> {
    let provenance = value["first_provenance"]
        .as_str()
        .map(|name| {
            Provenance::parse(name)
                .ok_or_else(|| format!("first_provenance {name:?} is not a provenance"))
        })
        .transpose()?;
    let row = Row {
        first: text(value, "first")?,
        provenance,
        longest: text(value, "longest")?,
    };
    Ok((text(value, "id")?, row))
}

/// The arm a `--record` run wrote, matched to the cases by decision id.
fn load_record(name: &str, path: &str, cases: &[Case]) -> Result<Run> {
    let fail = |message: String| format!("arm {name}: {path}: {message}");
    let body = fs::read_to_string(path).map_err(|error| fail(format!("cannot read: {error}")))?;
    let mut lines = body.lines();
    let header = serde_json::from_str::<Value>(lines.next().unwrap_or_default())
        .map_err(|error| fail(format!("the first line is not a header: {error}")))?;
    check_age(&header).map_err(|error| fail(error.to_string()))?;
    let mut recorded = HashMap::new();
    for (number, line) in (2..).zip(lines).filter(|(_, line)| !line.is_empty()) {
        let value = serde_json::from_str::<Value>(line)
            .map_err(|error| fail(format!("line {number}: {error}")))?;
        let (id, row) =
            record_row(&value).map_err(|error| fail(format!("line {number}: {error}")))?;
        if recorded.insert(id, row).is_some() {
            return Err(fail(format!("line {number}: a case is recorded twice")).into());
        }
    }
    let mut without_provenance = 0;
    let mut outcomes = Vec::with_capacity(cases.len());
    for case in cases {
        let row = recorded
            .get(&case.id)
            .ok_or_else(|| fail(format!("no record of case {}", case.id)))?;
        without_provenance += u64::from(row.provenance.is_none());
        let provenance = row.provenance.unwrap_or(Provenance::NoEvidence);
        outcomes.push(Outcome::new(
            case,
            row.first.clone(),
            provenance,
            row.longest.clone(),
        ));
    }
    Ok(Run {
        name: name.to_owned(),
        source: format!("recorded in {path}"),
        trained: header["trained"].as_bool().unwrap_or(false),
        walk: Walk::from_header(&header),
        without_provenance,
        outcomes,
    })
}

/// Typed text stays outside the repository, like the case files.
fn outside_repository(path: &str) -> Result<()> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let Ok(root) = root.canonicalize() else {
        return Ok(());
    };
    let parent = match Path::new(path).parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent,
        _ => Path::new("."),
    };
    let parent = parent
        .canonicalize()
        .map_err(|error| format!("cannot use {path}: {error}"))?;
    if parent.starts_with(&root) {
        return Err(format!(
            "Record files hold typed text; choose a path outside the repository: {path}"
        )
        .into());
    }
    Ok(())
}

/// A new owner-only file, as the case files are; it is never written over another file.
fn write_record(path: &str, generated_at: &str, run: &Run) -> Result<()> {
    let mut header = json!({
        "generated_at": generated_at,
        "arm": run.name,
        "cases": run.outcomes.len(),
        "trained": run.trained,
    });
    if let Some(walk) = run.walk {
        header["walk"] = walk.walk_json();
        if run.trained {
            header["training"] = walk.training_json();
        }
    }
    let mut body = header.to_string();
    body.push('\n');
    for outcome in &run.outcomes {
        body += &outcome.json().to_string();
        body.push('\n');
    }
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| format!("cannot create {path}: {error}"))?;
    if let Err(error) = file.write_all(body.as_bytes()) {
        fs::remove_file(path).ok();
        return Err(format!("cannot write {path}: {error}").into());
    }
    Ok(())
}

/// `YYYY-MM-DDTHH:MM:SS.000Z` of Unix seconds, the form `unix_seconds` reads.
fn stamp(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400) + 719_468;
    let rest = seconds.rem_euclid(86_400);
    // Civil date from days (Hinnant's civil_from_days).
    let era = days.div_euclid(146_097);
    let day_of_era = days.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.000Z",
        rest / 3_600,
        rest % 3_600 / 60,
        rest % 60
    )
}

fn now_stamp() -> String {
    let now = SystemTime::now().duration_since(UNIX_EPOCH);
    stamp(now.map_or(0, |elapsed| elapsed.as_secs() as i64))
}

enum Source {
    Live(PathBuf),
    Recorded(String),
}

struct EngineArgs {
    path: String,
    arms: Vec<(String, Source)>,
    trains: Vec<String>,
    records: Vec<(String, String)>,
    as_json: bool,
}

fn name_value(arg: &str) -> Result<(String, String)> {
    let valid = arg.split_once('=').filter(|(name, value)| {
        let name_ok = name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
        name_ok && !name.is_empty() && !value.is_empty()
    });
    let (name, value) = valid.ok_or_else(|| {
        format!("{arg:?} is not NAME=VALUE (letters, digits, - and _ in the name)")
    })?;
    Ok((name.to_owned(), value.to_owned()))
}

fn parse_engine(args: &[String]) -> Result<EngineArgs> {
    let (mut path, mut arms, mut as_json) = (None, Vec::new(), false);
    let (mut trains, mut records) = (Vec::new(), Vec::new());
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--json" => as_json = true,
            "--arm" => {
                let (name, value) = name_value(rest.next().ok_or(USAGE)?)?;
                let source = match value.strip_prefix('@') {
                    Some(file) => Source::Recorded(file.to_owned()),
                    None => Source::Live(PathBuf::from(value)),
                };
                arms.push((name, source));
            }
            "--train" => trains.push(rest.next().ok_or(USAGE)?.clone()),
            "--record" => records.push(name_value(rest.next().ok_or(USAGE)?)?),
            other if path.is_none() && !other.starts_with("--") => path = Some(other.to_owned()),
            _ => return Err(USAGE.into()),
        }
    }
    let path = path.ok_or(USAGE)?;
    if arms.is_empty() {
        return Err(format!("engine mode needs at least one --arm\n{USAGE}").into());
    }
    let names: HashSet<_> = arms.iter().map(|(name, _)| name).collect();
    if names.len() != arms.len() {
        return Err("--arm names must be different".into());
    }
    let live = |name: &String| {
        let arm = arms.iter().find(|(arm, _)| arm == name);
        arm.is_some_and(|(_, source)| matches!(source, Source::Live(_)))
    };
    let mut trained = HashSet::new();
    for name in &trains {
        if !live(name) {
            return Err(format!("--train {name}: only a live --arm can be trained").into());
        }
        if !trained.insert(name) {
            return Err(format!("--train {name} is given twice").into());
        }
    }
    let mut recorded = HashSet::new();
    for (name, _) in &records {
        if !live(name) {
            return Err(format!("--record {name}: only a live --arm can be recorded").into());
        }
        if !recorded.insert(name) {
            return Err(format!("--record {name} is given twice").into());
        }
    }
    Ok(EngineArgs {
        path,
        arms,
        trains,
        records,
        as_json,
    })
}

/// Facts about a case that do not depend on the arm.
struct Facts {
    scopes: [bool; 10],
    /// The candidate shown first when the decision was recorded.
    leader: String,
    /// First case of its (raw_input, selected_text) pair.
    distinct: bool,
    /// First case of its (raw_input, committed_text) pair.
    distinct_whole: bool,
    /// Last case of a (raw_input, selected_text) pair that occurs more than once.
    repeat: bool,
    /// Last case of a (raw_input, committed_text) pair that occurs more than once.
    repeat_whole: bool,
}

/// A case's identity as a pair: its raw input and the text it is judged against.
type Key<'a> = (&'a str, &'a str);

fn pair_key(case: &Case) -> Key<'_> {
    (&case.raw_input, &case.selected)
}

fn whole_key(case: &Case) -> Key<'_> {
    (&case.raw_input, &case.committed)
}

/// The index of the last case of each key, and how many cases have it.
fn last_of<'a>(keys: impl Iterator<Item = Key<'a>>) -> HashMap<Key<'a>, (usize, usize)> {
    let mut last = HashMap::new();
    for (index, key) in keys.enumerate() {
        let entry = last.entry(key).or_insert((index, 0));
        entry.0 = index;
        entry.1 += 1;
    }
    last
}

fn facts(cases: &[Case]) -> Vec<Facts> {
    let mut pairs = HashSet::new();
    let mut wholes = HashSet::new();
    let last_pair = last_of(cases.iter().map(pair_key));
    let last_whole = last_of(cases.iter().map(whole_key));
    let repeats = |last: (usize, usize), index: usize| last.1 > 1 && last.0 == index;
    cases
        .iter()
        .enumerate()
        .map(|(index, case)| Facts {
            scopes: scopes(case),
            leader: case
                .candidates
                .iter()
                .find(|c| c.display_index == 0)
                .map(|c| c.text.clone())
                .unwrap_or_default(),
            distinct: pairs.insert(pair_key(case)),
            distinct_whole: wholes.insert(whole_key(case)),
            repeat: repeats(last_pair[&pair_key(case)], index),
            repeat_whole: repeats(last_whole[&whole_key(case)], index),
        })
        .collect()
}

#[derive(Default, Clone, Copy)]
struct Count {
    cases: u64,
    hits: u64,
}

impl Count {
    fn add(&mut self, hit: bool) {
        self.cases += 1;
        self.hits += u64::from(hit);
    }

    fn json(&self) -> Value {
        json!({"cases": self.cases, "hits": self.hits})
    }

    /// The misses among the cases, with their rate and interval; unavailable, never 0%, without cases.
    fn miss_json(&self) -> Value {
        let misses = self.cases - self.hits;
        let interval = wilson(misses, self.cases);
        json!({
            "cases": self.cases,
            "misses": misses,
            "miss_rate": interval.map(|interval| interval.rate),
            "wilson_low": interval.map(|interval| interval.low),
            "wilson_high": interval.map(|interval| interval.high),
        })
    }
}

/// An arm's hits over every case and over the distinct pairs of one scope.
#[derive(Default, Clone, Copy)]
struct Hits {
    cases: Count,
    distinct: Count,
}

/// One arm over all cases: first-candidate hits per scope, whole-input hits on the
/// segmentation cases, how often its first candidate was the recorded displayed leader, and the
/// first candidate's misses by provenance (the `learned` row is L-over).
struct ArmReport {
    name: String,
    source: String,
    trained: bool,
    walk: Option<Walk>,
    without_provenance: u64,
    reproduces: u64,
    leaders: [Hits; 5],
    scopes: [Hits; 10],
    whole: Hits,
}

fn arm_report(run: &Run, facts: &[Facts]) -> ArmReport {
    let mut report = ArmReport {
        name: run.name.clone(),
        source: run.source.clone(),
        trained: run.trained,
        walk: run.walk,
        without_provenance: run.without_provenance,
        reproduces: 0,
        leaders: [Hits::default(); 5],
        scopes: [Hits::default(); 10],
        whole: Hits::default(),
    };
    for (fact, outcome) in facts.iter().zip(&run.outcomes) {
        report.reproduces += u64::from(!fact.leader.is_empty() && outcome.first == fact.leader);
        let leaders = &mut report.leaders[outcome.first_provenance as usize];
        leaders.cases.add(outcome.first_hit);
        if fact.distinct {
            leaders.distinct.add(outcome.first_hit);
        }
        for (hits, _) in report
            .scopes
            .iter_mut()
            .zip(fact.scopes)
            .filter(|(_, member)| *member)
        {
            hits.cases.add(outcome.first_hit);
            if fact.distinct {
                hits.distinct.add(outcome.first_hit);
            }
        }
        if fact.scopes[SEGMENTATION] {
            report.whole.cases.add(outcome.longest_hit);
            if fact.distinct_whole {
                report.whole.distinct.add(outcome.longest_hit);
            }
        }
    }
    report
}

/// `arm` against `base`: fixed is a hit where `base` misses, broken the reverse.
struct PairReport {
    base: String,
    arm: String,
    scopes: [Scope; 10],
    whole: Scope,
}

fn pair_report(base: &Run, arm: &Run, facts: &[Facts]) -> PairReport {
    let mut report = PairReport {
        base: base.name.clone(),
        arm: arm.name.clone(),
        scopes: [Scope::default(); 10],
        whole: Scope::default(),
    };
    for ((fact, b), a) in facts.iter().zip(&base.outcomes).zip(&arm.outcomes) {
        for (scope, _) in report
            .scopes
            .iter_mut()
            .zip(fact.scopes)
            .filter(|(_, member)| *member)
        {
            scope.cases.add(b.first_hit, a.first_hit);
            if fact.distinct {
                scope.distinct.add(b.first_hit, a.first_hit);
            }
            if fact.repeat {
                scope.repeat.add(b.first_hit, a.first_hit);
            }
        }
        if fact.scopes[SEGMENTATION] {
            report.whole.cases.add(b.longest_hit, a.longest_hit);
            if fact.distinct_whole {
                report.whole.distinct.add(b.longest_hit, a.longest_hit);
            }
            if fact.repeat_whole {
                report.whole.repeat.add(b.longest_hit, a.longest_hit);
            }
        }
    }
    report
}

fn hits_json(hits: &Hits) -> Value {
    json!({"cases": hits.cases.json(), "distinct": hits.distinct.json()})
}

fn arm_report_json(arm: &ArmReport) -> Value {
    let mut scopes = Map::new();
    for (name, hits) in SCOPES.iter().zip(&arm.scopes) {
        scopes.insert((*name).to_owned(), hits_json(hits));
    }
    let mut leaders = Map::new();
    for (provenance, hits) in Provenance::ALL.iter().zip(&arm.leaders) {
        let miss = json!({"cases": hits.cases.miss_json(), "distinct": hits.distinct.miss_json()});
        leaders.insert(provenance.name().to_owned(), miss);
    }
    let mut report = json!({
        "source": arm.source,
        "trained": arm.trained,
        "walk": arm.walk.map(|walk| walk.walk_json()),
        "reproduces_displayed": arm.reproduces,
        "without_provenance": arm.without_provenance,
        "leaders": leaders,
        "first_hits": scopes,
        "whole_input_hits": hits_json(&arm.whole),
    });
    if let Some(walk) = arm.walk.filter(|_| arm.trained) {
        report["training"] = walk.training_json();
    }
    report
}

/// A pair's scope in engine mode: the counts with ER and the regression share, and the McNemar p-values of
/// the distinct pairs and of the repeated ones.
fn pair_scope_json(scope: &Scope) -> Value {
    json!({
        "cases": scope.cases.paired_json(),
        "distinct": scope.distinct.paired_json(),
        "repeat": scope.repeat.paired_json(),
        "p": scope.p(),
        "repeat_p": scope.repeat_p(),
    })
}

fn engine_json(cases: usize, distinct: u64, arms: &[ArmReport], pairs: &[PairReport]) -> Value {
    let mut by_arm = Map::new();
    for arm in arms {
        by_arm.insert(arm.name.clone(), arm_report_json(arm));
    }
    let pairs: Vec<_> = pairs
        .iter()
        .map(|pair| {
            let mut scopes = Map::new();
            for (name, scope) in SCOPES.iter().zip(&pair.scopes) {
                scopes.insert((*name).to_owned(), pair_scope_json(scope));
            }
            json!({
                "base": pair.base,
                "arm": pair.arm,
                "scopes": scopes,
                "whole_input": pair_scope_json(&pair.whole),
            })
        })
        .collect();
    json!({"cases": cases, "distinct": distinct, "arms": by_arm, "pairs": pairs})
}

fn share(part: u64, whole: u64) -> String {
    let rate = if whole == 0 {
        0.0
    } else {
        100.0 * part as f64 / whole as f64
    };
    format!("{part} ({rate:.1}%)")
}

/// `12.3% [4.0, 31.0]`, starred under `MIN_UNITS` units (the interval and no verdict), or `unavailable`.
fn rate_text(successes: u64, total: u64) -> String {
    let Some(interval) = wilson(successes, total) else {
        return "unavailable".to_owned();
    };
    let star = if total < MIN_UNITS { "*" } else { "" };
    format!(
        "{:.1}% [{:.1}, {:.1}]{star}",
        100.0 * interval.rate,
        100.0 * interval.low,
        100.0 * interval.high
    )
}

fn er_text(tally: &Tally) -> String {
    tally
        .er()
        .map_or("unavailable".to_owned(), |er| format!("{er:.3}"))
}

fn print_walks(arms: &[ArmReport]) {
    println!(
        "\nWalk: the compositions of the file and what became of them in each arm (the final selection of a"
    );
    println!("walkable composition is made, and trains, only in a trained arm):");
    println!(
        "{:<14}{:>13}{:>10}{:>12}{:>9}{:>9}{:>12}{:>17}",
        "arm",
        "compositions",
        "walkable",
        "unwalkable",
        "unfound",
        "trained",
        "incomplete",
        "commit_mismatch"
    );
    for arm in arms {
        let Some(walk) = arm.walk else {
            println!("{:<14}the record carries no walk counts", arm.name);
            continue;
        };
        let training = |count: u64| {
            if arm.trained {
                count.to_string()
            } else {
                "-".to_owned()
            }
        };
        println!(
            "{:<14}{:>13}{:>10}{:>12}{:>9}{:>9}{:>12}{:>17}",
            arm.name,
            walk.compositions,
            walk.walkable,
            walk.unwalkable,
            walk.unfound,
            training(walk.trained),
            training(walk.incomplete),
            training(walk.commit_mismatch),
        );
    }
}

fn print_leaders(arms: &[ArmReport]) {
    println!(
        "\nMisses of the first candidate by its provenance, against selected_text. The learned row is L-over:"
    );
    println!("an arm with no learned first candidate, as a cold arm has none, has no L-over.");
    println!(
        "{:<14}{:<12}{:>7}{:>8}{:>26} |{:>9}{:>8}{:>26}",
        "arm",
        "provenance",
        "cases",
        "misses",
        "miss rate [95% Wilson]",
        "distinct",
        "misses",
        "miss rate [95% Wilson]"
    );
    for arm in arms {
        for (provenance, hits) in Provenance::ALL.iter().zip(&arm.leaders) {
            let (c, d) = (hits.cases, hits.distinct);
            println!(
                "{:<14}{:<12}{:>7}{:>8}{:>26} |{:>9}{:>8}{:>26}",
                arm.name,
                provenance.name(),
                c.cases,
                c.cases - c.hits,
                rate_text(c.cases - c.hits, c.cases),
                d.cases,
                d.cases - d.hits,
                rate_text(d.cases - d.hits, d.cases),
            );
        }
        if arm.without_provenance > 0 {
            println!(
                "{:<14}{} records carry no first_provenance and count as none; this arm has no L-over",
                arm.name, arm.without_provenance
            );
        }
    }
    println!("* under {MIN_UNITS} units: the interval and no verdict.");
}

/// ER, the regression share and the repeated pairs of an arm against its base.
fn print_repeat(rows: &[(&str, Scope)]) {
    println!(
        "{:<18}{:>13}{:>13} |{:>8}{:>8}{:>6}{:>7}{:>8}{:>13}{:>11}",
        "scope",
        "ER cases",
        "ER distinct",
        "repeat",
        "base",
        "arm",
        "fixed",
        "broken",
        "ER",
        "McNemar p"
    );
    for (label, scope) in rows {
        let r = scope.repeat;
        println!(
            "{label:<18}{:>13}{:>13} |{:>8}{:>8}{:>6}{:>7}{:>8}{:>13}{:>11}",
            er_text(&scope.cases),
            er_text(&scope.distinct),
            r.cases,
            r.native_hits,
            r.hits,
            r.fixed,
            r.broken,
            er_text(&r),
            p_text(scope.repeat_p()),
        );
    }
    let all = rows[0].1;
    println!("regression share, broken of fixed + broken, in the first row:");
    for (label, tally) in [
        ("cases", all.cases),
        ("distinct", all.distinct),
        ("repeat", all.repeat),
    ] {
        let total = tally.fixed + tally.broken;
        println!(
            "  {label:<9}{}/{total} {}",
            tally.broken,
            rate_text(tally.broken, total)
        );
    }
}

fn print_engine(path: &str, cases: usize, distinct: u64, arms: &[ArmReport], pairs: &[PairReport]) {
    println!(
        "Replay engine of {path}: {cases} cases, {distinct} distinct (raw_input, selected_text) pairs."
    );
    println!(
        "Each live arm ran the real engine on its prepared resources: absent user directory, nine \
         candidates, default input options. It walks each composition, scoring every decision before \
         its text is selected."
    );
    let trained: Vec<_> = arms
        .iter()
        .filter(|arm| arm.trained)
        .map(|arm| arm.name.as_str())
        .collect();
    if trained.is_empty() {
        println!(
            "No arm trains: nothing is committed, so nothing is learned. The records came from a trained \
             user dictionary, so compare the arms only with each other."
        );
    } else {
        println!(
            "Training arms: {}. They commit each walkable composition after scoring it, so their user \
             dictionary learns the recorded decisions in file order. A trained arm starts cold while the \
             recorded dictionary did not, so compare the arms only with each other.",
            trained.join(", ")
        );
    }
    for arm in arms {
        println!("arm {:<12} {}", arm.name, arm.source);
    }
    let segmentation = arms
        .first()
        .map_or(0, |arm| arm.scopes[SEGMENTATION].cases.cases);
    println!(
        "\n{:<14}{:>20}{:>22}{:>28}",
        "arm",
        format!("first of {cases}"),
        format!("= displayed of {cases}"),
        format!("whole-input of {segmentation} seg."),
    );
    for arm in arms {
        println!(
            "{:<14}{:>20}{:>22}{:>28}",
            arm.name,
            share(arm.scopes[0].cases.hits, cases as u64),
            share(arm.reproduces, cases as u64),
            share(arm.whole.cases.hits, segmentation),
        );
    }
    print_walks(arms);
    print_leaders(arms);
    println!("\nFirst-candidate hits against selected_text, by scope (every case):");
    print!("{:<18}{:>7}", "scope", "cases");
    for arm in arms {
        print!("{:>14}", arm.name);
    }
    println!();
    for (index, label) in SCOPES.iter().enumerate() {
        let size = arms.first().map_or(0, |arm| arm.scopes[index].cases.cases);
        print!("{label:<18}{size:>7}");
        for arm in arms {
            print!("{:>14}", arm.scopes[index].cases.hits);
        }
        println!();
    }
    for pair in pairs {
        println!(
            "\n{} vs {}: fixed is a hit where {} misses, broken the reverse; whole_input is the longest \
             whole-input candidate against committed_text on the segmentation cases",
            pair.arm, pair.base, pair.base
        );
        let mut rows: Vec<_> = SCOPES.iter().copied().zip(pair.scopes).collect();
        rows.push(("whole_input", pair.whole));
        print_scopes("base", &rows);
        println!(
            "\nER = broken / fixed: the errors {} introduced per error it fixed against {}. repeat has one \
             unit per pair seen more than once, its last case: the view after every selection of the pair.",
            pair.arm, pair.base
        );
        print_repeat(&rows);
    }
}

fn engine(args: &[String]) -> Result<()> {
    let args = parse_engine(args)?;
    let Loaded {
        cases,
        generated_at,
        ..
    } = load(&args.path)?;
    let ids: HashSet<_> = cases.iter().map(|case| case.id.as_str()).collect();
    if ids.len() != cases.len() || ids.contains("") {
        return Err("engine mode needs a different decision_id on every case".into());
    }
    let compositions = compositions(&cases)?;
    for (_, file) in &args.records {
        outside_repository(file)?;
        if Path::new(file).exists() {
            return Err(
                format!("{file} exists; a record file is never written over another").into(),
            );
        }
    }
    let mut runs = Vec::new();
    for (name, source) in &args.arms {
        runs.push(match source {
            Source::Live(resources) => {
                let train = args.trains.contains(name);
                run_live(name, resources, &cases, &compositions, train)?
            }
            Source::Recorded(file) => load_record(name, file, &cases)?,
        });
    }
    let generated_at = generated_at.unwrap_or_else(now_stamp);
    for (name, file) in &args.records {
        let run = runs.iter().find(|run| run.name == *name);
        write_record(file, &generated_at, run.expect("a live arm"))?;
    }
    let facts = facts(&cases);
    let arms: Vec<_> = runs.iter().map(|run| arm_report(run, &facts)).collect();
    let mut pairs = Vec::new();
    for (index, base) in runs.iter().enumerate() {
        for arm in &runs[index + 1..] {
            pairs.push(pair_report(base, arm, &facts));
        }
    }
    let distinct = facts.iter().filter(|fact| fact.distinct).count() as u64;
    if args.as_json {
        let report = engine_json(cases.len(), distinct, &arms, &pairs);
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        print_engine(&args.path, cases.len(), distinct, &arms, &pairs);
    }
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("list") => list(&args[1..]),
        Some("engine") => engine(&args[1..]),
        _ => Err(USAGE.into()),
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("replay: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mcnemar_is_the_exact_two_sided_binomial_test() {
        assert_eq!(mcnemar(0, 0), 1.0);
        assert_eq!(mcnemar(3, 3), 1.0);
        assert!((mcnemar(6, 1) - 0.125).abs() < 1e-12);
        assert!((mcnemar(1, 6) - 0.125).abs() < 1e-12);
        assert!((mcnemar(9, 2) - 134.0 / 2048.0).abs() < 1e-12);
        assert!((mcnemar(10, 0) - 2.0 / 1024.0).abs() < 1e-12);
    }

    #[test]
    fn wilson_matches_the_python_instrument() {
        let close = |actual: f64, expected: f64| (actual - expected).abs() < 1e-12;
        let interval = wilson(2, 14).unwrap();
        assert!(close(interval.rate, 2.0 / 14.0));
        assert!(close(interval.low, 0.040093921271464966));
        assert!(close(interval.high, 0.3994137949697035));
        let interval = wilson(0, 1).unwrap();
        assert!(interval.low == 0.0 && close(interval.high, 0.7934506856227624));
        let interval = wilson(1, 1).unwrap();
        assert!(close(interval.low, 0.20654931437723753) && interval.high == 1.0);
        assert!(wilson(0, 0).is_none());
    }

    fn typed(composition: &str, raw_input: &str, selected: &str, committed: &str) -> Case {
        Case {
            id: String::new(),
            composition: composition.to_owned(),
            raw_input: raw_input.to_owned(),
            preceding: String::new(),
            page: 0,
            candidates: Vec::new(),
            selected_index: None,
            selected: selected.to_owned(),
            committed: committed.to_owned(),
        }
    }

    #[test]
    fn compositions_walk_when_each_input_extends_the_last_and_the_selections_add_up() {
        let cases = [
            typed("a", "beijing", "北京", "北京"),
            typed("b", "beijingdaxue", "北京", "北京大学"),
            typed("b", "beijingdaxue", "大学", "北京大学"),
            typed("c", "zhunbei", "准", "准备"),
            typed("d", "beijingdaxue", "北京", "北京大学"),
            typed("d", "daxue", "大学", "北京大学"),
        ];
        let found = compositions(&cases).unwrap();
        let walks: Vec<_> = found
            .iter()
            .map(|c| (c.cases.clone(), c.walkable))
            .collect();
        assert_eq!(
            walks,
            [(0..1, true), (1..3, true), (3..4, false), (4..6, false)]
        );
        let apart = [
            typed("a", "x", "", ""),
            typed("b", "x", "", ""),
            typed("a", "x", "", ""),
        ];
        let error = compositions(&apart).err().unwrap().to_string();
        assert!(error.contains("not adjacent"), "{error}");
        assert!(compositions(&[typed("", "x", "", "")]).is_err());
    }

    #[test]
    fn stamps_round_trip_through_unix_seconds() {
        assert_eq!(stamp(0), "1970-01-01T00:00:00.000Z");
        for seconds in [
            1,
            86_399,
            951_782_400,
            1_709_251_200,
            1_792_500_840,
            4_102_444_799,
        ] {
            assert_eq!(unix_seconds(&stamp(seconds)), Some(seconds), "{seconds}");
        }
        assert_eq!(stamp(1_792_500_840), "2026-10-20T12:54:00.000Z");
    }

    #[test]
    fn timestamps_read_as_unix_seconds() {
        assert_eq!(unix_seconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            unix_seconds("2026-10-20T12:54:00.123Z"),
            Some(1_792_500_840)
        );
        assert_eq!(
            unix_seconds("2024-03-01T00:00:00.000Z"),
            Some(1_709_251_200)
        );
        for bad in [
            "yesterday",
            "2026-10-20T12:54:00",
            "2026-13-20T12:54:00Z",
            "2026-10-20T12:54Z",
        ] {
            assert_eq!(unix_seconds(bad), None, "{bad}");
        }
    }
}
