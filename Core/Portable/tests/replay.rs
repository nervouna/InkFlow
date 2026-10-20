//! List-mode replay (`src/bin/replay.rs`) on the synthetic cases of `fixtures/replay-cases.json`.
use serde_json::Value;
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
