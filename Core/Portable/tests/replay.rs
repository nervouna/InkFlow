//! List-mode and engine-mode replay (`src/bin/replay.rs`) on the synthetic cases of
//! `fixtures/replay-cases.json`. The live engine arms need prepared resources: set
//! INKFLOW_PORTABLE_RESOURCES as for `parity.rs`.
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
};

const FIXTURE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/fixtures/replay-cases.json");

fn replay(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_replay"))
        .args(args)
        .output()
        .unwrap()
}

fn fixture() -> Value {
    serde_json::from_str(&fs::read_to_string(FIXTURE).unwrap()).unwrap()
}

fn report(args: &[&str]) -> Value {
    let output = replay(args);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

/// Integers must match exactly; the McNemar p-values are floats.
fn assert_same(actual: &Value, expected: &Value, path: &str) {
    match (actual, expected) {
        (Value::Object(a), Value::Object(e)) => {
            assert_eq!(a.len(), e.len(), "{path}: {a:?}");
            for (key, value) in e {
                assert_same(&a[key], value, &format!("{path}/{key}"));
            }
        }
        (Value::Number(a), Value::Number(e)) if a.is_f64() || e.is_f64() => {
            let (a, e) = (a.as_f64().unwrap(), e.as_f64().unwrap());
            assert!((a - e).abs() < 1e-9, "{path}: {a} != {e}");
        }
        _ => assert_eq!(actual, expected, "{path}"),
    }
}

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        let path =
            std::env::temp_dir().join(format!("inkflow-replay-{name}-{}", std::process::id()));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn write(&self, name: &str, text: &str) -> String {
        let path = self.0.join(name);
        fs::write(&path, text).unwrap();
        path.to_str().unwrap().to_owned()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        fs::remove_dir_all(Path::new(&self.0)).ok();
    }
}

/// The prepared `IFCX` index of a dictionary, as `ContextRanker::from_index` reads it.
fn context_index(dictionary: &str) -> Vec<u8> {
    let mut tables = vec![BTreeMap::<Vec<u8>, u64>::new(); 7];
    for line in dictionary.lines() {
        let fields: Vec<_> = line.split('\t').collect();
        let key: Vec<u8> = fields[0]
            .chars()
            .flat_map(|c| {
                [
                    (c as u32 >> 16) as u8,
                    (c as u32 >> 8) as u8,
                    c as u32 as u8,
                ]
            })
            .collect();
        tables[fields[0].chars().count() - 2].insert(key, fields[2].parse().unwrap());
    }
    let longest = (2..=8).rev().find(|&n| !tables[n - 2].is_empty()).unwrap();
    let mut data = b"IFCX".to_vec();
    data.extend(1u32.to_le_bytes());
    data.extend((longest as u32).to_le_bytes());
    for table in &tables {
        data.extend((table.len() as u32).to_le_bytes());
    }
    for table in &tables {
        for (key, frequency) in table {
            data.extend(key);
            data.extend(frequency.to_le_bytes());
        }
    }
    data
}

/// The exporter's form: a header line, then one case per line.
fn lines(generated_at: &str) -> String {
    let cases = fixture()["cases"].clone();
    let cases = cases.as_array().unwrap();
    let mut text = format!(
        "{{\"generated_at\":\"{generated_at}\",\"cases\":{}}}\n",
        cases.len()
    );
    for case in cases {
        text += &format!("{case}\n");
    }
    text
}

#[test]
fn list_mode_counts_match_the_fixture() {
    let expected = fixture()["expected"].clone();
    let actual = report(&["list", FIXTURE, "--json"]);
    assert_same(&actual, &expected, "");
    println!("PASS {} replay cases", expected["cases"]);
}

#[test]
fn json_lines_with_a_context_index_give_the_same_counts() {
    let scratch = Scratch::new("lines");
    let cases = scratch.write("cases.jsonl", &lines("2999-01-01T00:00:00.000Z"));
    let index = scratch.0.join("context.bin");
    fs::write(
        &index,
        context_index(fixture()["dictionary"].as_str().unwrap()),
    )
    .unwrap();
    let actual = report(&[
        "list",
        &cases,
        "--context-index",
        index.to_str().unwrap(),
        "--json",
    ]);
    assert_same(&actual, &fixture()["expected"], "");
}

#[test]
fn without_a_ranker_only_the_ranked_arm_is_left_out() {
    let scratch = Scratch::new("no-ranker");
    let cases = scratch.write("cases.jsonl", &lines("2999-01-01T00:00:00.000Z"));
    let actual = report(&["list", &cases, "--json"]);
    assert!(actual["arms"]["ranked"].is_null());
    assert_same(
        &actual["arms"]["displayed"],
        &fixture()["expected"]["arms"]["displayed"],
        "displayed",
    );
}

#[test]
fn table_names_the_arms_classes_and_p_value() {
    let output = replay(&["list", FIXTURE]);
    assert!(output.status.success());
    let table = String::from_utf8(output.stdout).unwrap();
    for word in [
        "displayed",
        "ranked",
        "McNemar",
        "distinct",
        "dictionary_leader",
        "off_page",
    ] {
        assert!(table.contains(word), "{word} missing from\n{table}");
    }
}

#[test]
fn refuses_old_or_unreadable_headers_and_other_files() {
    let scratch = Scratch::new("refuse");
    for stamp in ["2020-01-01T00:00:00.000Z", "yesterday"] {
        let cases = scratch.write("old.jsonl", &lines(stamp));
        let output = replay(&["list", &cases, "--json"]);
        assert!(!output.status.success(), "{stamp}");
        assert!(output.stdout.is_empty());
        let message = String::from_utf8_lossy(&output.stderr);
        assert!(message.contains("generated_at"), "{message}");
    }
    let body = lines("2999-01-01T00:00:00.000Z");
    let headerless = body.split_once('\n').unwrap().1;
    let cases = scratch.write("headerless.jsonl", headerless);
    assert!(!replay(&["list", &cases, "--json"]).status.success());
    assert!(
        !replay(&["list", "/nonexistent/cases.jsonl"])
            .status
            .success()
    );
    assert!(!replay(&["engine", FIXTURE]).status.success());
    let old = scratch.write("old.jsonl", &lines("2020-01-01T00:00:00.000Z"));
    assert!(String::from_utf8_lossy(&replay(&["list", &old]).stderr).contains("delete"));
}

/// A recorded arm file: for every fixture case, the first and the longest whole-input text it shows.
fn record(
    scratch: &Scratch,
    name: &str,
    first: impl Fn(&Value) -> String,
    longest: impl Fn(&Value) -> String,
) -> String {
    let mut text = format!(
        "{{\"generated_at\":\"2999-01-01T00:00:00.000Z\",\"arm\":\"{name}\",\"cases\":54}}\n"
    );
    for case in fixture()["cases"].as_array().unwrap() {
        let row =
            json!({"id": case["decision_id"], "first": first(case), "longest": longest(case)});
        text += &format!("{row}\n");
    }
    scratch.write(&format!("{name}.jsonl"), &text)
}

/// The text of the fixture candidate whose `field` equals `value`.
fn candidate_text(case: &Value, field: &str, value: u64) -> String {
    let candidates = case["candidates"].as_array().unwrap();
    let found = candidates.iter().find(|c| c[field].as_u64() == Some(value));
    found.map_or(String::new(), |c| c["text"].as_str().unwrap().to_owned())
}

#[test]
fn recorded_arms_give_the_list_mode_counts_pairwise() {
    let scratch = Scratch::new("recorded");
    let native = record(
        &scratch,
        "native",
        |case| candidate_text(case, "native_rank", 1),
        |_| String::new(),
    );
    let displayed = record(
        &scratch,
        "displayed",
        |case| candidate_text(case, "display_index", 0),
        |case| case["committed_text"].as_str().unwrap().to_owned(),
    );
    let actual = report(&[
        "engine",
        FIXTURE,
        "--arm",
        &format!("native=@{native}"),
        "--arm",
        &format!("displayed=@{displayed}"),
        "--json",
    ]);
    let expected = fixture()["expected"].clone();
    assert_eq!(actual["cases"], expected["cases"]);
    assert_eq!(actual["pairs"].as_array().unwrap().len(), 1);
    let pair = &actual["pairs"][0];
    assert_eq!(
        (&pair["base"], &pair["arm"]),
        (&json!("native"), &json!("displayed"))
    );
    // The pairwise machinery is list mode's: the displayed leader against Rime's first candidate.
    assert_same(
        &pair["scopes"],
        &expected["arms"]["displayed"]["scopes"],
        "scopes",
    );
    // The segmentation cases are judged again on the whole-input candidate: none for native,
    // the committed text for displayed.
    let segmentation = &expected["arms"]["displayed"]["scopes"]["segmentation"]["cases"];
    let whole = &pair["whole_input"];
    let cases = segmentation["cases"].as_u64().unwrap();
    assert!(cases > 0);
    assert_eq!(whole["cases"]["cases"], json!(cases));
    assert_eq!(whole["cases"]["native_hits"], json!(0));
    assert_eq!(whole["cases"]["hits"], json!(cases));
    assert_eq!(whole["cases"]["fixed"], json!(cases));
    assert_eq!(whole["cases"]["broken"], json!(0));
    let distinct = whole["distinct"]["fixed"].as_u64().unwrap();
    assert!((1..=cases).contains(&distinct));
    assert!(whole["p"].as_f64().unwrap() < 0.5);
    // Reproduction against the recorded displayed leader.
    let all = fixture()["cases"].as_array().unwrap().len() as u64;
    assert_eq!(
        actual["arms"]["displayed"]["reproduces_displayed"],
        json!(all)
    );
    let same = fixture()["cases"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|case| {
            candidate_text(case, "native_rank", 1) == candidate_text(case, "display_index", 0)
        })
        .count();
    assert_eq!(
        actual["arms"]["native"]["reproduces_displayed"],
        json!(same)
    );
    assert_eq!(
        actual["arms"]["native"]["first_hits"]["all"]["cases"]["hits"],
        expected["arms"]["displayed"]["scopes"]["all"]["cases"]["native_hits"]
    );
    // The table names both arms, the scopes and the whole-input row.
    let table = String::from_utf8(
        replay(&[
            "engine",
            FIXTURE,
            "--arm",
            &format!("native=@{native}"),
            "--arm",
            &format!("displayed=@{displayed}"),
        ])
        .stdout,
    )
    .unwrap();
    for word in [
        "displayed vs native",
        "McNemar",
        "whole_input",
        "function_word",
        "= displayed",
    ] {
        assert!(table.contains(word), "{word} missing from\n{table}");
    }
}

#[test]
fn engine_arguments_and_record_files_are_checked() {
    let scratch = Scratch::new("engine-args");
    let good = record(&scratch, "good", |_| "x".into(), |_| String::new());
    let arm = format!("good=@{good}");
    let existing = scratch.write("exists.jsonl", "keep\n");
    let inside = format!("{}/record-in-repository.jsonl", env!("CARGO_MANIFEST_DIR"));
    let old = scratch.write(
        "old.jsonl",
        "{\"generated_at\":\"2020-01-01T00:00:00.000Z\"}\n",
    );
    let sparse = scratch.write(
        "sparse.jsonl",
        "{\"generated_at\":\"2999-01-01T00:00:00.000Z\"}\n",
    );
    let refused: [(&[&str], &str); 10] = [
        (&["engine", FIXTURE, "--arm", "good"], "NAME=VALUE"),
        (&["engine", FIXTURE, "--arm", "=@x"], "NAME=VALUE"),
        (&["engine", FIXTURE, "--arm", "a b=@x"], "NAME=VALUE"),
        (
            &["engine", FIXTURE, "--arm", "good=@/nonexistent/arm.jsonl"],
            "cannot read",
        ),
        (
            &["engine", FIXTURE, "--arm", "good=/nonexistent/resources"],
            "prepared resources",
        ),
        (
            &["engine", FIXTURE, "--arm", &arm, "--arm", &arm],
            "different",
        ),
        (
            &[
                "engine",
                FIXTURE,
                "--arm",
                &arm,
                "--record",
                &format!("good={existing}"),
            ],
            "only a live",
        ),
        (
            &["engine", FIXTURE, "--arm", &format!("good=@{old}")],
            "delete",
        ),
        (
            &["engine", FIXTURE, "--arm", &format!("good=@{sparse}")],
            "no record of case",
        ),
        (
            &[
                "engine",
                FIXTURE,
                "--arm",
                "live=/nonexistent",
                "--record",
                &format!("live={inside}"),
            ],
            "outside the repository",
        ),
    ];
    for (args, message) in refused {
        let output = replay(args);
        assert!(!output.status.success(), "{args:?}");
        assert!(output.stdout.is_empty(), "{args:?}");
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(error.contains(message), "{args:?}: {error}");
    }
    assert!(!Path::new(&inside).exists());
    let overwrite = replay(&[
        "engine",
        FIXTURE,
        "--arm",
        "live=/nonexistent",
        "--record",
        &format!("live={existing}"),
    ]);
    assert!(String::from_utf8_lossy(&overwrite.stderr).contains("exists"));
    assert_eq!(fs::read_to_string(&existing).unwrap(), "keep\n");
}

fn resources() -> Option<String> {
    std::env::var("INKFLOW_PORTABLE_RESOURCES").ok()
}

#[test]
fn engine_mode_runs_the_real_engine_and_records_its_arms() {
    let Some(resources) = resources() else {
        println!("SKIP engine replay: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let scratch = Scratch::new("engine-live");
    let recorded = scratch.0.join("a.jsonl");
    let recorded = recorded.to_str().unwrap();
    // Two engines in turn on the same resources must show the same thing: arms do not leak into each other.
    let live = report(&[
        "engine",
        FIXTURE,
        "--arm",
        &format!("a={resources}"),
        "--arm",
        &format!("b={resources}"),
        "--record",
        &format!("a={recorded}"),
        "--json",
    ]);
    let cases = fixture()["cases"].as_array().unwrap().len() as u64;
    assert_eq!(live["cases"], json!(cases));
    let first = &live["arms"]["a"]["first_hits"]["all"]["cases"];
    assert_eq!(first["cases"], json!(cases));
    assert!(first["hits"].as_u64().unwrap() > 0, "{first}");
    assert!(live["arms"]["a"]["reproduces_displayed"].as_u64().unwrap() > 0);
    let pair = &live["pairs"][0];
    for (scope, counts) in pair["scopes"].as_object().unwrap() {
        assert_eq!(counts["cases"]["fixed"], json!(0), "{scope}");
        assert_eq!(counts["cases"]["broken"], json!(0), "{scope}");
    }
    assert_eq!(pair["whole_input"]["cases"]["fixed"], json!(0));
    assert_eq!(pair["whole_input"]["cases"]["broken"], json!(0));
    // The record: a header, then every case once; owner-only; some long input shows a whole-input sentence.
    let body = fs::read_to_string(recorded).unwrap();
    let mut lines = body.lines();
    let header: Value = serde_json::from_str(lines.next().unwrap()).unwrap();
    assert_eq!(header["arm"], json!("a"));
    let rows: Vec<Value> = lines.map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(rows.len() as u64, cases);
    assert!(
        rows.iter()
            .all(|row| !row["first"].as_str().unwrap().is_empty())
    );
    assert!(
        rows.iter()
            .any(|row| !row["longest"].as_str().unwrap().is_empty())
    );
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(recorded).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    // A recorded arm stands in for the live one.
    let replayed = report(&[
        "engine",
        FIXTURE,
        "--arm",
        &format!("a=@{recorded}"),
        "--arm",
        &format!("b={resources}"),
        "--json",
    ]);
    assert_eq!(
        replayed["arms"]["a"]["first_hits"],
        live["arms"]["a"]["first_hits"]
    );
    assert_eq!(
        replayed["arms"]["a"]["whole_input_hits"],
        live["arms"]["a"]["whole_input_hits"]
    );
    assert_eq!(
        replayed["arms"]["a"]["reproduces_displayed"],
        live["arms"]["a"]["reproduces_displayed"]
    );
    assert_eq!(replayed["pairs"], live["pairs"]);
    // Nothing is written over an earlier record.
    let again = replay(&[
        "engine",
        FIXTURE,
        "--arm",
        &format!("a={resources}"),
        "--record",
        &format!("a={recorded}"),
    ]);
    assert!(!again.status.success());
    println!("PASS engine replay on {cases} fixture cases");
}
