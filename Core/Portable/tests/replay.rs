//! List-mode and engine-mode replay (`src/bin/replay.rs`) on the synthetic cases of
//! `fixtures/replay-cases.json`. The live engine arms, cold and trained, need prepared resources: set
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
    report_of(replay(args))
}

fn report_of(output: Output) -> Value {
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
fn export(generated_at: &str, cases: &[Value]) -> String {
    let mut text = format!(
        "{{\"generated_at\":\"{generated_at}\",\"cases\":{}}}\n",
        cases.len()
    );
    for case in cases {
        text += &format!("{case}\n");
    }
    text
}

fn lines(generated_at: &str) -> String {
    export(generated_at, fixture()["cases"].as_array().unwrap())
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

/// The provenance of the fixture candidate that shows `text`, as the report names it.
fn provenance(case: &Value, text: &str) -> &'static str {
    let candidates = case["candidates"].as_array().unwrap();
    let shown = candidates.iter().find(|c| c["text"] == json!(text));
    match shown.and_then(|c| c["type"].as_str()) {
        Some("user_phrase") => "learned",
        Some("phrase" | "user_table") => "dictionary",
        Some("sentence") => "assembled",
        _ => "none",
    }
}

/// A recorded arm file: for every fixture case, the first text it shows with that text's provenance and the
/// longest whole-input text.
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
        let shown = first(case);
        let row = json!({
            "id": case["decision_id"],
            "first": shown,
            "first_provenance": provenance(case, &shown),
            "longest": longest(case),
        });
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

/// The `native` arm (Rime's first candidate, no whole-input candidate) and the `displayed` arm (the leader
/// when recorded, the committed text as the whole-input candidate) of list mode, as recorded arm files.
fn native_and_displayed(scratch: &Scratch) -> (String, String) {
    let native = record(
        scratch,
        "native",
        |case| candidate_text(case, "native_rank", 1),
        |_| String::new(),
    );
    let displayed = record(
        scratch,
        "displayed",
        |case| candidate_text(case, "display_index", 0),
        |case| case["committed_text"].as_str().unwrap().to_owned(),
    );
    (native, displayed)
}

/// A pair's scopes in list mode's shape: without the repeat block, ER and the regression share.
fn list_shape(scopes: &Value) -> Value {
    let mut scopes = scopes.clone();
    for scope in scopes.as_object_mut().unwrap().values_mut() {
        let scope = scope.as_object_mut().unwrap();
        scope.remove("repeat");
        scope.remove("repeat_p");
        for block in ["cases", "distinct"] {
            let block = scope.get_mut(block).unwrap().as_object_mut().unwrap();
            for key in ["er", "regression_share", "wilson_low", "wilson_high"] {
                block.remove(key);
            }
        }
    }
    scopes
}

#[test]
fn recorded_arms_give_the_list_mode_counts_pairwise() {
    let scratch = Scratch::new("recorded");
    let (native, displayed) = native_and_displayed(&scratch);
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
        &list_shape(&pair["scopes"]),
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

fn number(value: &Value) -> f64 {
    value.as_f64().unwrap()
}

fn close(actual: &Value, expected: f64) {
    assert!(
        (number(actual) - expected).abs() < 1e-12,
        "{actual} != {expected}"
    );
}

/// The misses of `arm`'s first candidates by provenance, on every case and on the distinct pairs.
fn leaders(arm: &Value, provenance: &str) -> [u64; 4] {
    let leaders = &arm["leaders"][provenance];
    let count = |block: &str, key: &str| leaders[block][key].as_u64().unwrap();
    [
        count("cases", "cases"),
        count("cases", "misses"),
        count("distinct", "cases"),
        count("distinct", "misses"),
    ]
}

#[test]
fn recorded_arms_report_er_the_repeated_pairs_and_the_leaders() {
    let scratch = Scratch::new("learning-blocks");
    let (native, displayed) = native_and_displayed(&scratch);
    let args = |native: &str, displayed: &str| {
        report(&[
            "engine",
            FIXTURE,
            "--arm",
            &format!("native=@{native}"),
            "--arm",
            &format!("displayed=@{displayed}"),
            "--json",
        ])
    };
    let actual = args(&native, &displayed);
    let all = &actual["pairs"][0]["scopes"]["all"];
    // ER is broken per fixed: 2 of 12 on the cases, 2 of 9 on the distinct pairs.
    close(&all["cases"]["er"], 2.0 / 12.0);
    close(&all["distinct"]["er"], 2.0 / 9.0);
    // The share of regressions with the Wilson interval of quality.py: 2 of 14.
    close(&all["cases"]["regression_share"], 2.0 / 14.0);
    close(&all["cases"]["wilson_low"], 0.040093921271464966);
    close(&all["cases"]["wilson_high"], 0.3994137949697035);
    // Four pairs recur (can, hui, zai, de); their last cases fix 2 and break none.
    let repeat = &all["repeat"];
    assert_eq!(repeat["cases"], json!(4));
    assert_eq!(
        (&repeat["fixed"], &repeat["broken"]),
        (&json!(2), &json!(0))
    );
    close(&repeat["er"], 0.0);
    close(&all["repeat_p"], 0.5);
    // Without a fixed case ER is unavailable, not 0.
    let none = &actual["pairs"][0]["scopes"]["decoder_leader"];
    assert!(none["cases"]["er"].is_null() && none["cases"]["regression_share"].is_null());
    assert_eq!(none["repeat"]["cases"], json!(0));
    // The leaders of the fixture's first candidates: [cases, misses, distinct, distinct misses].
    let displayed_arm = &actual["arms"]["displayed"];
    assert_eq!(leaders(displayed_arm, "dictionary")[..2], [46, 23]);
    assert_eq!(leaders(displayed_arm, "assembled")[..2], [5, 3]);
    assert_eq!(leaders(displayed_arm, "learned")[..2], [1, 0]);
    assert_eq!(leaders(displayed_arm, "none")[..2], [2, 0]);
    let native_arm = &actual["arms"]["native"];
    assert_eq!(leaders(native_arm, "dictionary")[..2], [46, 32]);
    assert_eq!(leaders(native_arm, "assembled")[..2], [5, 3]);
    assert_eq!(leaders(native_arm, "learned")[..2], [1, 0]);
    assert_eq!(leaders(native_arm, "none")[..2], [2, 1]);
    let provenances = ["learned", "dictionary", "assembled", "other", "none"];
    let distinct: u64 = provenances
        .iter()
        .map(|p| leaders(displayed_arm, p)[2])
        .sum();
    assert_eq!(json!(distinct), actual["distinct"]);
    let dictionary = &displayed_arm["leaders"]["dictionary"]["cases"];
    close(&dictionary["miss_rate"], 0.5);
    close(&dictionary["wilson_low"], 0.36118937082703256);
    close(&dictionary["wilson_high"], 0.6388106291729675);
    // A provenance without cases is unavailable, never 0%.
    let other = &displayed_arm["leaders"]["other"]["cases"];
    assert_eq!(other["cases"], json!(0));
    assert!(other["miss_rate"].is_null() && other["wilson_low"].is_null());
    // Neither arm trained, and a recorded arm without a walk has no counts.
    assert_eq!(displayed_arm["trained"], json!(false));
    assert!(displayed_arm["walk"].is_null() && displayed_arm["training"].is_null());
    // A record from before the provenance loads as none: L-over is unavailable.
    let stripped: String = fs::read_to_string(&displayed)
        .unwrap()
        .lines()
        .map(|line| {
            let mut row: Value = serde_json::from_str(line).unwrap();
            row.as_object_mut().unwrap().remove("first_provenance");
            format!("{row}\n")
        })
        .collect();
    let old = scratch.write("old-displayed.jsonl", &stripped);
    let arm = &args(&native, &old)["arms"]["displayed"];
    assert_eq!(arm["without_provenance"], json!(54));
    assert_eq!(arm["leaders"]["learned"]["cases"]["cases"], json!(0));
    assert!(arm["leaders"]["learned"]["cases"]["miss_rate"].is_null());
    assert_eq!(arm["leaders"]["none"]["cases"]["cases"], json!(54));
    assert_eq!(displayed_arm["without_provenance"], json!(0));
    // The table names L-over, ER, the repeat block and the training bias.
    let table = replay(&[
        "engine",
        FIXTURE,
        "--arm",
        &format!("native=@{native}"),
        "--arm",
        &format!("displayed=@{displayed}"),
    ]);
    let table = String::from_utf8(table.stdout).unwrap();
    for word in [
        "L-over",
        "provenance",
        "ER cases",
        "repeat",
        "regression share",
        "No arm trains",
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
    let mut apart = fixture()["cases"].as_array().unwrap()[..2].to_vec();
    apart.push(apart[0].clone());
    apart[2]["decision_id"] = json!("d99");
    let apart = scratch.write("apart.jsonl", &export("2999-01-01T00:00:00.000Z", &apart));
    let refused: [(&[&str], &str); 14] = [
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
        (
            &["engine", FIXTURE, "--arm", &arm, "--train", "good"],
            "only a live --arm can be trained",
        ),
        (
            &["engine", FIXTURE, "--arm", &arm, "--train", "nosuch"],
            "only a live --arm can be trained",
        ),
        (
            &[
                "engine",
                FIXTURE,
                "--arm",
                "live=/nonexistent",
                "--train",
                "live",
                "--train",
                "live",
            ],
            "given twice",
        ),
        (&["engine", &apart, "--arm", &arm], "not adjacent"),
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

/// Run `replay` with its temporary directory set to `temp`, where a live arm keeps its scratch user directory.
fn replay_in(temp: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_replay"))
        .env("TMPDIR", temp)
        .args(args)
        .output()
        .unwrap()
}

/// No arm leaves its scratch user directory behind.
fn assert_no_user_directory(temp: &Path) {
    let left: Vec<_> = fs::read_dir(temp)
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .filter(|name| name.to_string_lossy().starts_with("inkflow-replay-"))
        .collect();
    assert!(left.is_empty(), "left behind: {left:?}");
}

/// The header and the rows of a record file.
fn read_record(path: &str) -> (Value, Vec<Value>) {
    let body = fs::read_to_string(path).unwrap();
    let mut lines = body.lines().map(|line| serde_json::from_str(line).unwrap());
    (lines.next().unwrap(), lines.collect())
}

fn counts(value: &Value, keys: &[&str]) -> Vec<u64> {
    keys.iter()
        .map(|key| value[*key].as_u64().unwrap())
        .collect()
}

#[test]
fn a_trained_arm_walks_the_fixture_and_cleans_up() {
    let Some(resources) = resources() else {
        println!("SKIP trained replay: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let scratch = Scratch::new("trained");
    let temp = scratch.0.join("tmp");
    fs::create_dir_all(&temp).unwrap();
    let cold_record = scratch.0.join("cold.jsonl");
    let trained_record = scratch.0.join("trained.jsonl");
    let (cold_record, trained_record) = (
        cold_record.to_str().unwrap(),
        trained_record.to_str().unwrap(),
    );
    // Two trained arms on the same resources must agree: training does not depend on anything but the cases.
    let live = report_of(replay_in(
        &temp,
        &[
            "engine",
            FIXTURE,
            "--arm",
            &format!("cold={resources}"),
            "--arm",
            &format!("trained={resources}"),
            "--arm",
            &format!("again={resources}"),
            "--train",
            "trained",
            "--train",
            "again",
            "--record",
            &format!("cold={cold_record}"),
            "--record",
            &format!("trained={trained_record}"),
            "--json",
        ],
    ));
    assert_no_user_directory(&temp);
    let walk_keys = ["compositions", "walkable", "unwalkable", "unfound"];
    let cold = &live["arms"]["cold"];
    assert_eq!(cold["trained"], json!(false));
    assert!(cold["training"].is_null());
    assert_eq!(cold["walk"]["compositions"], json!(54));
    assert_eq!(cold["walk"]["unwalkable"], json!(3));
    for name in ["trained", "again"] {
        let arm = &live["arms"][name];
        assert_eq!(arm["trained"], json!(true));
        let walk = counts(&arm["walk"], &walk_keys);
        assert_eq!(walk[..3], [54, 51, 3]);
        assert_eq!(walk[1] + walk[2], walk[0]);
        // Every walkable composition is accounted for by its final selection or by an unfound text. The fixture's
        // huix, shangbanx, bingx and kaihuixx leave letters behind when their text is found.
        let training = counts(
            &arm["training"],
            &["trained", "incomplete", "commit_mismatch"],
        );
        assert_eq!(training.iter().sum::<u64>() + walk[3], walk[1]);
        assert!(training[1] + walk[3] >= 4, "{arm}");
        let leaders: u64 = ["learned", "dictionary", "assembled", "other", "none"]
            .iter()
            .map(|provenance| leaders(arm, provenance)[0])
            .sum();
        assert_eq!(leaders, 54);
    }
    assert_eq!(
        live["arms"]["trained"]["walk"],
        live["arms"]["again"]["walk"]
    );
    assert_eq!(
        live["arms"]["trained"]["training"],
        live["arms"]["again"]["training"]
    );
    let pairs = live["pairs"].as_array().unwrap();
    assert_eq!(pairs.len(), 3);
    let same = pairs.iter().find(|pair| pair["base"] == "trained").unwrap();
    for (scope, counts) in same["scopes"].as_object().unwrap() {
        for block in ["cases", "distinct", "repeat"] {
            assert_eq!(counts[block]["fixed"], json!(0), "{scope}");
            assert_eq!(counts[block]["broken"], json!(0), "{scope}");
        }
    }
    // Records carry the walk, so a recorded trained arm reloads as the same arm.
    let (header, rows) = read_record(trained_record);
    assert_eq!(header["trained"], json!(true));
    assert_eq!(header["walk"], live["arms"]["trained"]["walk"]);
    assert_eq!(header["training"], live["arms"]["trained"]["training"]);
    assert_eq!(rows.len(), 54);
    assert!(rows.iter().all(|row| row["first_provenance"].is_string()));
    assert_eq!(read_record(cold_record).0["trained"], json!(false));
    let replayed = report(&[
        "engine",
        FIXTURE,
        "--arm",
        &format!("cold=@{cold_record}"),
        "--arm",
        &format!("trained=@{trained_record}"),
        "--json",
    ]);
    for name in ["cold", "trained"] {
        for key in [
            "trained",
            "walk",
            "training",
            "leaders",
            "first_hits",
            "whole_input_hits",
        ] {
            assert_eq!(
                replayed["arms"][name][key], live["arms"][name][key],
                "{name} {key}"
            );
        }
    }
    assert_eq!(replayed["pairs"][0], pairs[0]);
    // The table prints the counts of the walk and the training.
    let table = replay_in(
        &temp,
        &[
            "engine",
            FIXTURE,
            "--arm",
            &format!("cold={resources}"),
            "--arm",
            &format!("trained={resources}"),
            "--train",
            "trained",
        ],
    );
    let table = String::from_utf8(table.stdout).unwrap();
    for word in [
        "Training arms: trained",
        "starts cold",
        "unwalkable",
        "commit_mismatch",
        "learned",
        "ER distinct",
    ] {
        assert!(table.contains(word), "{word} missing from\n{table}");
    }
    assert_no_user_directory(&temp);
    println!("PASS trained replay on the fixture");
}

#[test]
fn a_trained_arm_learns_a_word_chosen_in_earlier_compositions() {
    let Some(resources) = resources() else {
        println!("SKIP learning replay: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let scratch = Scratch::new("learns");
    let temp = scratch.0.join("tmp");
    fs::create_dir_all(&temp).unwrap();
    let case = |n: usize| {
        json!({
            "composition_id": format!("c{n}"),
            "decision_id": format!("d{n}"),
            "raw_input": "pengyou",
            "preceding_context": "",
            "page": 0,
            "candidates": [],
            "selected_display_index": 0,
            "selected_text": "朋友",
            "committed_text": "朋友",
        })
    };
    let cases = scratch.write(
        "cases.jsonl",
        &export("2999-01-01T00:00:00.000Z", &[case(1), case(2), case(3)]),
    );
    let cold = scratch.0.join("cold.jsonl");
    let trained = scratch.0.join("trained.jsonl");
    let (cold, trained) = (cold.to_str().unwrap(), trained.to_str().unwrap());
    let arms = report_of(replay_in(
        &temp,
        &[
            "engine",
            &cases,
            "--arm",
            &format!("cold={resources}"),
            "--arm",
            &format!("trained={resources}"),
            "--train",
            "trained",
            "--record",
            &format!("cold={cold}"),
            "--record",
            &format!("trained={trained}"),
            "--json",
        ],
    ));
    let provenance = |path: &str| -> Vec<(String, String)> {
        let first = |row: &Value, key: &str| row[key].as_str().unwrap().to_owned();
        let rows = read_record(path).1;
        rows.iter()
            .map(|row| (first(row, "first"), first(row, "first_provenance")))
            .collect()
    };
    let word = |provenance: &str| ("朋友".to_owned(), provenance.to_owned());
    assert_eq!(
        provenance(cold),
        [word("dictionary"), word("dictionary"), word("dictionary")]
    );
    assert_eq!(
        provenance(trained),
        [word("dictionary"), word("learned"), word("learned")]
    );
    // L-over: the trained arm has two learned leaders, neither a miss; the cold arm has none.
    assert_eq!(leaders(&arms["arms"]["trained"], "learned")[..2], [2, 0]);
    assert_eq!(leaders(&arms["arms"]["cold"], "learned")[..2], [0, 0]);
    assert_eq!(arms["arms"]["trained"]["training"]["trained"], json!(3));
    // The word is one pair seen three times: the repeat block scores its last case.
    let all = &arms["pairs"][0]["scopes"]["all"];
    assert_eq!(all["repeat"]["cases"], json!(1));
    assert_eq!(all["cases"]["cases"], json!(3));
    assert_no_user_directory(&temp);
    println!("PASS learning replay on three compositions");
}

#[test]
fn a_composition_of_several_decisions_is_walked_once() {
    let Some(resources) = resources() else {
        println!("SKIP walk replay: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let scratch = Scratch::new("several");
    let temp = scratch.0.join("tmp");
    fs::create_dir_all(&temp).unwrap();
    let case = |composition: &str, n: usize, input: &str, selected: &str, committed: &str| {
        json!({
            "composition_id": composition,
            "decision_id": format!("d{n}"),
            "raw_input": input,
            "preceding_context": "",
            "page": 0,
            "candidates": [],
            "selected_display_index": 0,
            "selected_text": selected,
            "committed_text": committed,
        })
    };
    // c1: 北京 is chosen from beijingda, daxue is typed, then 大学 is chosen. c2: the first text is on no page.
    let cases = [
        case("c1", 1, "beijingda", "北京", "北京大学"),
        case("c1", 2, "beijingdaxue", "大学", "北京大学"),
        case("c2", 3, "beijingda", "囧囧囧", "囧囧囧大学"),
        case("c2", 4, "beijingdaxue", "大学", "囧囧囧大学"),
    ];
    let cases = scratch.write("cases.jsonl", &export("2999-01-01T00:00:00.000Z", &cases));
    let cold = scratch.0.join("cold.jsonl");
    let trained = scratch.0.join("trained.jsonl");
    let (cold, trained) = (cold.to_str().unwrap(), trained.to_str().unwrap());
    let arms = report_of(replay_in(
        &temp,
        &[
            "engine",
            &cases,
            "--arm",
            &format!("cold={resources}"),
            "--arm",
            &format!("trained={resources}"),
            "--train",
            "trained",
            "--record",
            &format!("cold={cold}"),
            "--record",
            &format!("trained={trained}"),
            "--json",
        ],
    ));
    let walk = ["compositions", "walkable", "unwalkable", "unfound"];
    for name in ["cold", "trained"] {
        assert_eq!(
            counts(&arms["arms"][name]["walk"], &walk),
            [2, 2, 0, 1],
            "{name}"
        );
        // The second decision of c1 is scored after 北京 was selected: no evidence, and 大学 leads. The second
        // decision of c2 is scored on a fresh composition because its first text was not found: evidence again.
        let path = if name == "cold" { cold } else { trained };
        let rows = read_record(path).1;
        assert_eq!(rows[1]["first"], json!("大学"), "{name}");
        assert_eq!(rows[1]["first_provenance"], json!("none"), "{name}");
        assert_eq!(rows[3]["first"], json!("北京大学"), "{name}");
        assert_ne!(rows[3]["first_provenance"], json!("none"), "{name}");
    }
    // Only c1 trains; c2 trains nothing.
    let training = counts(
        &arms["arms"]["trained"]["training"],
        &["trained", "incomplete", "commit_mismatch"],
    );
    assert_eq!(training, [1, 0, 0]);
    assert_no_user_directory(&temp);
    println!("PASS walk replay on two compositions");
}
