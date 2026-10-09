use inkflow_dictionary::*;
use serde::Deserialize;
use serde_json::Value;
use std::{collections::BTreeMap, fs, path::PathBuf};

#[derive(Default, Deserialize)]
struct Case {
    name: String,
    #[serde(default)]
    bodies: BTreeMap<String, String>,
    header: Option<String>,
    #[serde(default)]
    corrections: String,
}

fn references() -> PathBuf {
    std::env::var_os("INKFLOW_DICTIONARY_REFERENCE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures"))
}
fn catalog() -> Vec<SourceSpec> {
    serde_json::from_slice(&fs::read(references().join("catalog.json")).unwrap()).unwrap()
}
fn fixture(case: &Case) -> (Vec<Input>, Vec<SourceSpec>) {
    let mut catalog = catalog();
    let inputs = catalog
        .iter_mut()
        .map(|spec| {
            let header = case
                .header
                .as_deref()
                .unwrap_or("---\nimport_tables: [ignored]\n...\n");
            let body = case
                .bodies
                .get(&spec.id)
                .map(String::as_str)
                .unwrap_or("甲\tjia\t100\n");
            let data = format!("{header}{body}").into_bytes();
            spec.pinned_byte_count = data.len();
            spec.pinned_blob_sha = git_blob(&data);
            spec.pinned_sha256 = sha256(&data);
            Input {
                receipt: spec.pinned_receipt(),
                data,
            }
        })
        .collect();
    (inputs, catalog)
}

fn equivalent(actual: &Value, expected: &Value, path: &str) {
    match (actual, expected) {
        (Value::Object(a), Value::Object(b)) => {
            assert_eq!(
                a.keys().collect::<Vec<_>>(),
                b.keys().collect::<Vec<_>>(),
                "{path}"
            );
            for (key, value) in a {
                equivalent(value, &b[key], &format!("{path}.{key}"));
            }
        }
        (Value::Array(a), Value::Array(b)) => {
            assert_eq!(a.len(), b.len(), "{path}");
            for (index, (a, b)) in a.iter().zip(b).enumerate() {
                equivalent(a, b, &format!("{path}[{index}]"));
            }
        }
        (Value::Number(a), Value::Number(b))
            if path.ends_with("multiplier") || path.ends_with("Multiplier") =>
        {
            let (a, b) = (a.as_f64().unwrap(), b.as_f64().unwrap());
            assert!(
                (a - b).abs() <= b.abs().max(1.0) * 1e-12,
                "{path}: {a} != {b}"
            );
        }
        _ => assert_eq!(actual, expected, "{path}"),
    }
}

#[test]
fn swift_reference_contract() {
    let cases: Vec<Case> = serde_json::from_str(include_str!("../fixtures/cases.json")).unwrap();
    let expected: BTreeMap<String, Value> =
        serde_json::from_slice(&fs::read(references().join("reference.json")).unwrap()).unwrap();
    assert_eq!(cases.len(), expected.len());
    for case in &cases {
        let (inputs, catalog) = fixture(case);
        match generate(&inputs, case.corrections.as_bytes(), &catalog) {
            Ok(result) => {
                let schemas: BTreeMap<_, _> = spelling(&result.dictionary)
                    .unwrap()
                    .into_iter()
                    .map(|(name, bytes)| (name, sha256(&bytes)))
                    .collect();
                let actual =
                    serde_json::json!({"manifest": result.manifest, "spellingSHA256": schemas});
                equivalent(&actual, &expected[&case.name], &case.name);
            }
            Err(error) => {
                let expected = &expected[&case.name]["error"];
                assert_eq!(Some(error.code), expected["code"].as_str(), "{}", case.name);
                assert_eq!(
                    error.source.as_deref(),
                    expected["source"].as_str(),
                    "{}",
                    case.name
                );
                assert_eq!(
                    error.line.map(|v| v as u64),
                    expected["line"].as_u64(),
                    "{}",
                    case.name
                );
            }
        }
    }
    println!(
        "PASS {} Swift/Rust contract cases, manifests, 32 spelling profiles and context indexes",
        cases.len()
    );
}

#[test]
fn receipts_and_input_boundaries() {
    let default = Case::default();
    let (mut inputs, catalog) = fixture(&default);
    assert_eq!(
        git_blob(b"hello\n"),
        "ce013625030ba8dba906f756967f9e9ca394464a"
    );
    assert_eq!(
        generate(&inputs[..inputs.len() - 1], b"", &catalog)
            .err()
            .unwrap()
            .code,
        "source-set"
    );
    inputs[0].receipt.commit = "A".repeat(40);
    assert_eq!(validate(&inputs[0]).unwrap_err().code, "invalid-receipt");
    inputs[0].receipt.commit = catalog[0].pinned_commit.clone();
    inputs[0].data.pop();
    assert_eq!(validate(&inputs[0]).unwrap_err().code, "source-size");
    inputs[0].data.push(b' ');
    assert_eq!(validate(&inputs[0]).unwrap_err().code, "source-checksum");

    let (mut inputs, catalog) = fixture(&default);
    inputs[0].receipt.repository = "other/repository".to_owned();
    assert_eq!(
        generate(&inputs, b"", &catalog).err().unwrap().code,
        "source-location"
    );
    let (mut inputs, catalog) = fixture(&default);
    inputs.last_mut().unwrap().receipt.commit = "0".repeat(40);
    assert_eq!(
        generate(&inputs, b"", &catalog).err().unwrap().code,
        "legacy-changed"
    );

    let (mut inputs, mut catalog) = fixture(&default);
    inputs[0].data = vec![0xff];
    inputs[0].receipt.byte_count = 1;
    inputs[0].receipt.blob_sha = git_blob(&inputs[0].data);
    inputs[0].receipt.sha256 = sha256(&inputs[0].data);
    catalog[0].pinned_blob_sha = inputs[0].receipt.blob_sha.clone();
    catalog[0].pinned_sha256 = inputs[0].receipt.sha256.clone();
    assert_eq!(
        generate(&inputs, b"", &catalog).err().unwrap().code,
        "source-format"
    );
    let (inputs, catalog) = fixture(&default);
    assert_eq!(
        generate(&inputs, &[0xff], &catalog).err().unwrap().code,
        "correction-format"
    );
    assert_eq!(
        generate(&inputs, &vec![b' '; 1_048_577], &catalog)
            .err()
            .unwrap()
            .code,
        "correction-format"
    );
    assert_eq!(spelling(b"bad").unwrap_err().code, "source-format");
}

#[test]
fn output_ownership_and_determinism() {
    let (inputs, catalog) = fixture(&Case::default());
    let a = generate(&inputs, b"", &catalog).unwrap();
    let b = generate(&inputs, b"", &catalog).unwrap();
    assert_eq!(a.dictionary, b.dictionary);
    assert_eq!(
        serde_json::to_value(&a.manifest).unwrap(),
        serde_json::to_value(&b.manifest).unwrap()
    );
    drop(inputs);
    drop(catalog);
    assert_eq!(a.manifest.entry_count, 1);
    assert_eq!(sha256(&a.dictionary), a.manifest.dictionary_sha256);
}
