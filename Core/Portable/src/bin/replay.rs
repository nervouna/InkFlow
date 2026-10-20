//! Offline replay of recorded decisions, to score a ranking change before it ships.
//!
//! `replay list CASES [--context-index PATH] [--json]` reads the cases that
//! `quality.py replay-cases` exports and scores three arms against what the user chose:
//! `native` (Rime's first candidate), `displayed` (the candidate shown first when recorded) and
//! `ranked` (the context ranker run again on the case). The README section "Replay and the
//! first-choice target" defines the counts and the ship rule.
use inkflow_rime::ranking::{ContextRanker, is_han, parse_metadata};
use serde_json::{Map, Value, json};
use std::{
    collections::HashSet,
    error::Error,
    f64::consts::LN_2,
    fs,
    time::{SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const USAGE: &str = "Usage: replay list CASES [--context-index PATH] [--json]";
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
    raw_input: String,
    preceding: String,
    page: u64,
    candidates: Vec<Candidate>,
    selected_index: Option<usize>,
    selected: String,
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
        raw_input: text(value, "raw_input")?,
        preceding: text(value, "preceding_context")?,
        page: value["page"].as_u64().ok_or("page is not a count")?,
        candidates: candidates.iter().map(candidate).collect::<Result<_>>()?,
        selected_index: value["selected_display_index"].as_u64().map(|i| i as usize),
        selected: text(value, "selected_text")?,
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

/// The cases and, for the checked-in fixture, the dictionary its ranker uses.
fn load(path: &str) -> Result<(Vec<Case>, Option<String>)> {
    let body = fs::read_to_string(path).map_err(|error| format!("cannot read {path}: {error}"))?;
    // The fixture is one JSON document without records, so it has no age. An export is JSON Lines.
    if let Ok(document) = serde_json::from_str::<Value>(&body)
        && let Some(cases) = document["cases"].as_array()
    {
        let dictionary = document["dictionary"].as_str().map(str::to_owned);
        return Ok((cases.iter().map(case).collect::<Result<_>>()?, dictionary));
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
    Ok((cases, None))
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

fn arm_json(arm: &Arm) -> Value {
    let mut scopes = Map::new();
    for (name, scope) in SCOPES.iter().zip(&arm.scopes) {
        scopes.insert(
            (*name).to_owned(),
            json!({"cases": scope.cases.json(), "distinct": scope.distinct.json(), "p": scope.p()}),
        );
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

fn print_arm(name: &str, arm: &Arm) {
    let all = arm.scopes[0];
    println!(
        "\n{name} vs native: {} cases scored, hits {} vs {}; skipped {} without evidence, {} unparsable",
        arm.scored, all.cases.hits, all.cases.native_hits, arm.without_evidence, arm.unparsable,
    );
    println!(
        "{:<18}{:>7}{:>8}{:>6}{:>7}{:>8} |{:>9}{:>8}{:>6}{:>7}{:>8} |{:>11}",
        "scope",
        "cases",
        "native",
        "arm",
        "fixed",
        "broken",
        "distinct",
        "native",
        "arm",
        "fixed",
        "broken",
        "McNemar p"
    );
    for (label, scope) in SCOPES.iter().zip(&arm.scopes) {
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

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) != Some("list") {
        return Err(USAGE.into());
    }
    let (mut path, mut index, mut as_json) = (None, None, false);
    let mut rest = args[1..].iter();
    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--json" => as_json = true,
            "--context-index" => index = Some(rest.next().ok_or(USAGE)?),
            other if path.is_none() && !other.starts_with("--") => path = Some(other),
            _ => return Err(USAGE.into()),
        }
    }
    let path = path.ok_or(USAGE)?;
    let (cases, dictionary) = load(path)?;
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
