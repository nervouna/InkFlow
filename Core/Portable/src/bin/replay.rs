//! Offline replay of recorded decisions, to score a ranking change before it ships.
//!
//! `replay list CASES [--context-index PATH] [--json]` reads the cases that
//! `quality.py replay-cases` exports and scores three arms against what the user chose:
//! `native` (Rime's first candidate), `displayed` (the candidate shown first when recorded) and
//! `ranked` (the context ranker run again on the case). The README section "Replay and the
//! first-choice target" defines the counts and the ship rule.
//!
//! `replay engine CASES --arm NAME=RESOURCES|NAME=@FILE ... [--record NAME=FILE ...] [--json]`
//! runs the real engine once per arm on prepared resources and compares the arms with each other
//! (see "Engine-mode replay" in the README).
use inkflow_rime::{
    engine::{Configuration, Engine},
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
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const USAGE: &str = "Usage: replay list CASES [--context-index PATH] [--json]\n       \
                     replay engine CASES --arm NAME=RESOURCES|NAME=@FILE ... [--record NAME=FILE ...] [--json]";
/// Replay files hold typed text, which quality records keep for 28 days.
const MAX_AGE_SECONDS: i64 = 28 * 24 * 60 * 60;
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
}

/// Every case, and one case per distinct (raw_input, selected_text) pair: its first.
#[derive(Default, Clone, Copy)]
struct Scope {
    cases: Tally,
    distinct: Tally,
}

impl Scope {
    fn p(&self) -> f64 {
        mcnemar(self.distinct.fixed, self.distinct.broken)
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

/// What one arm showed for one case: the first candidate of the first page, the longest candidate
/// that consumes the whole input, and whether each equals the gold text.
struct Outcome {
    id: String,
    first: String,
    longest: String,
    first_hit: bool,
    longest_hit: bool,
}

impl Outcome {
    fn new(case: &Case, first: String, longest: String) -> Self {
        let hit = |shown: &str, gold: &str| !shown.is_empty() && shown == gold;
        Self {
            id: case.id.clone(),
            first_hit: hit(&first, &case.selected),
            longest_hit: hit(&longest, &case.committed),
            first,
            longest,
        }
    }

    fn json(&self) -> Value {
        json!({
            "id": self.id,
            "first": self.first,
            "longest": self.longest,
            "first_hit": self.first_hit,
            "longest_hit": self.longest_hit,
        })
    }
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

/// Run every case on the first page of a fresh engine. Nothing is selected or committed, so
/// nothing is learned; the user directory starts absent and is deleted afterwards.
fn run_live(name: &str, resources: &Path, cases: &[Case]) -> Result<Vec<Outcome>> {
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
    let mut outcomes = Vec::with_capacity(cases.len());
    for case in cases {
        session.clear()?;
        session.set_preceding_text(&case.preceding)?;
        for byte in case.raw_input.bytes() {
            session.key(i32::from(byte), i32::from(byte.is_ascii_uppercase()))?;
            session.take_commit()?;
        }
        let page = session.snapshot()?;
        let first = page.candidates.first().map(|c| c.text.clone());
        let longest = longest_whole_input(&page.candidates, case.raw_input.len());
        outcomes.push(Outcome::new(case, first.unwrap_or_default(), longest));
    }
    session.clear()?;
    Ok(outcomes)
}

fn record_row(value: &Value) -> Result<(String, String, String)> {
    Ok((
        text(value, "id")?,
        text(value, "first")?,
        text(value, "longest")?,
    ))
}

/// The outcomes a `--record` run wrote, matched to the cases by decision id.
fn load_record(name: &str, path: &str, cases: &[Case]) -> Result<Vec<Outcome>> {
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
        let (id, first, longest) =
            record_row(&value).map_err(|error| fail(format!("line {number}: {error}")))?;
        if recorded.insert(id, (first, longest)).is_some() {
            return Err(fail(format!("line {number}: a case is recorded twice")).into());
        }
    }
    cases
        .iter()
        .map(|case| {
            let (first, longest) = recorded
                .get(&case.id)
                .ok_or_else(|| fail(format!("no record of case {}", case.id)))?;
            Ok(Outcome::new(case, first.clone(), longest.clone()))
        })
        .collect()
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
fn write_record(path: &str, name: &str, generated_at: &str, outcomes: &[Outcome]) -> Result<()> {
    let mut body =
        json!({"generated_at": generated_at, "arm": name, "cases": outcomes.len()}).to_string();
    body.push('\n');
    for outcome in outcomes {
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
    let (mut path, mut arms, mut records, mut as_json) = (None, Vec::new(), Vec::new(), false);
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
    let mut recorded = HashSet::new();
    for (name, _) in &records {
        let live = arms
            .iter()
            .any(|(arm, source)| arm == name && matches!(source, Source::Live(_)));
        if !live {
            return Err(format!("--record {name}: only a live --arm can be recorded").into());
        }
        if !recorded.insert(name) {
            return Err(format!("--record {name} is given twice").into());
        }
    }
    Ok(EngineArgs {
        path,
        arms,
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
}

fn facts(cases: &[Case]) -> Vec<Facts> {
    let mut pairs = HashSet::new();
    let mut wholes = HashSet::new();
    cases
        .iter()
        .map(|case| Facts {
            scopes: scopes(case),
            leader: case
                .candidates
                .iter()
                .find(|c| c.display_index == 0)
                .map(|c| c.text.clone())
                .unwrap_or_default(),
            distinct: pairs.insert((&case.raw_input, &case.selected)),
            distinct_whole: wholes.insert((&case.raw_input, &case.committed)),
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
}

/// An arm's hits over every case and over the distinct pairs of one scope.
#[derive(Default, Clone, Copy)]
struct Hits {
    cases: Count,
    distinct: Count,
}

/// One arm over all cases: first-candidate hits per scope, whole-input hits on the
/// segmentation cases, and how often its first candidate was the recorded displayed leader.
struct ArmReport {
    name: String,
    source: String,
    reproduces: u64,
    scopes: [Hits; 10],
    whole: Hits,
}

struct Run {
    name: String,
    source: String,
    outcomes: Vec<Outcome>,
}

fn arm_report(run: &Run, facts: &[Facts]) -> ArmReport {
    let mut report = ArmReport {
        name: run.name.clone(),
        source: run.source.clone(),
        reproduces: 0,
        scopes: [Hits::default(); 10],
        whole: Hits::default(),
    };
    for (fact, outcome) in facts.iter().zip(&run.outcomes) {
        report.reproduces += u64::from(!fact.leader.is_empty() && outcome.first == fact.leader);
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
        }
        if fact.scopes[SEGMENTATION] {
            report.whole.cases.add(b.longest_hit, a.longest_hit);
            if fact.distinct_whole {
                report.whole.distinct.add(b.longest_hit, a.longest_hit);
            }
        }
    }
    report
}

fn hits_json(hits: &Hits) -> Value {
    json!({"cases": hits.cases.json(), "distinct": hits.distinct.json()})
}

fn engine_json(cases: usize, distinct: u64, arms: &[ArmReport], pairs: &[PairReport]) -> Value {
    let mut by_arm = Map::new();
    for arm in arms {
        let mut scopes = Map::new();
        for (name, hits) in SCOPES.iter().zip(&arm.scopes) {
            scopes.insert((*name).to_owned(), hits_json(hits));
        }
        by_arm.insert(
            arm.name.clone(),
            json!({
                "source": arm.source,
                "reproduces_displayed": arm.reproduces,
                "first_hits": scopes,
                "whole_input_hits": hits_json(&arm.whole),
            }),
        );
    }
    let pairs: Vec<_> = pairs
        .iter()
        .map(|pair| {
            let mut scopes = Map::new();
            for (name, scope) in SCOPES.iter().zip(&pair.scopes) {
                scopes.insert((*name).to_owned(), scope_json(scope));
            }
            json!({
                "base": pair.base,
                "arm": pair.arm,
                "scopes": scopes,
                "whole_input": scope_json(&pair.whole),
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

fn print_engine(path: &str, cases: usize, distinct: u64, arms: &[ArmReport], pairs: &[PairReport]) {
    println!(
        "Replay engine of {path}: {cases} cases, {distinct} distinct (raw_input, selected_text) pairs."
    );
    println!(
        "Each live arm ran the real engine on its prepared resources: absent user directory, nine \
         candidates, default input options, no selection or commit."
    );
    println!(
        "The records came from a trained user dictionary, so compare the arms only with each other."
    );
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
        let (outcomes, source) = match source {
            Source::Live(resources) => (
                run_live(name, resources, &cases)?,
                format!("live on {}", resources.display()),
            ),
            Source::Recorded(file) => (
                load_record(name, file, &cases)?,
                format!("recorded in {file}"),
            ),
        };
        runs.push(Run {
            name: name.clone(),
            source,
            outcomes,
        });
    }
    let generated_at = generated_at.unwrap_or_else(now_stamp);
    for (name, file) in &args.records {
        let run = runs.iter().find(|run| run.name == *name);
        write_record(
            file,
            name,
            &generated_at,
            &run.expect("a live arm").outcomes,
        )?;
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
