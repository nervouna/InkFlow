use inkflow_dictionary::{SourceSpec, git_blob, sha256};
use std::{
    fs,
    path::PathBuf,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn cli_checks_inputs_before_publishing_and_refuses_replacement() {
    let root = std::env::temp_dir().join(format!(
        "inkflow-dictionary-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&root).unwrap();
    let _scratch = Scratch(root.clone());
    let references = std::env::var_os("INKFLOW_DICTIONARY_REFERENCE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures"));
    let mut catalog: Vec<SourceSpec> =
        serde_json::from_slice(&fs::read(references.join("catalog.json")).unwrap()).unwrap();
    let data = "---\n...\n甲\tjia\t100\n".as_bytes();
    for spec in &mut catalog {
        spec.pinned_byte_count = data.len();
        spec.pinned_blob_sha = git_blob(data);
        spec.pinned_sha256 = sha256(data);
        fs::write(root.join(format!("{}.yaml", spec.id)), data).unwrap();
    }
    fs::write(
        root.join("catalog.json"),
        serde_json::to_vec(&catalog).unwrap(),
    )
    .unwrap();
    fs::write(root.join("corrections.tsv"), b"").unwrap();
    let run = |output: &str| {
        Command::new(env!("CARGO_BIN_EXE_inkflow-dictionary"))
            .current_dir(&root)
            .args([
                "generate",
                "catalog.json",
                ".",
                "legacy.yaml",
                "corrections.tsv",
                output,
            ])
            .output()
            .unwrap()
    };
    assert!(run("output").status.success());
    let dictionary = root.join("output/pinyin_simp.dict.yaml");
    let before = fs::read(&dictionary).unwrap();
    assert!(!run("output").status.success());
    assert_eq!(fs::read(&dictionary).unwrap(), before);
    fs::write(root.join("frost-8105.yaml"), b"bad").unwrap();
    assert!(!run("invalid").status.success());
    assert!(!root.join("invalid").exists());
    assert_eq!(fs::read(&dictionary).unwrap(), before);
    let output = Command::new(env!("CARGO_BIN_EXE_inkflow-dictionary"))
        .current_dir(&root)
        .args(["spelling", "output/pinyin_simp.dict.yaml", "spelling"])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(fs::read_dir(root.join("spelling")).unwrap().count(), 32);
}
