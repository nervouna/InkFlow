use inkflow_dictionary::{Input, MAX_SOURCE_BYTES, SourceSpec, generate, spelling};
use std::{collections::BTreeMap, error::Error, fs, io::Read, path::Path};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn read(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(limit as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(format!("Input exceeds {limit} bytes: {}", path.display()).into());
    }
    Ok(bytes)
}

fn write_new(directory: &Path, files: BTreeMap<String, Vec<u8>>) -> Result<()> {
    // Preparation callers publish their own completed staging tree.
    fs::create_dir(directory)?;
    let result = (|| {
        for (name, bytes) in files {
            fs::write(directory.join(name), bytes)?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(directory);
    }
    result
}

fn dictionary(
    catalog: &[SourceSpec],
    sources: &str,
    legacy: &str,
    corrections: &str,
    output: &str,
) -> Result<()> {
    let mut inputs = Vec::new();
    for spec in catalog {
        if spec.id.is_empty()
            || !spec
                .id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        {
            return Err("Invalid source identifier".into());
        }
        let path = if spec.group == "legacy" {
            Path::new(legacy).to_owned()
        } else {
            Path::new(sources).join(format!("{}.yaml", spec.id))
        };
        inputs.push(Input {
            receipt: spec.pinned_receipt(),
            data: read(&path, MAX_SOURCE_BYTES)?,
        });
    }
    let corrections = read(Path::new(corrections), 1_048_576)?;
    let result = generate(&inputs, &corrections, catalog)?;
    let mut manifest = serde_json::to_vec_pretty(&result.manifest)?;
    manifest.push(b'\n');
    write_new(
        Path::new(output),
        BTreeMap::from([
            ("pinyin_simp.dict.yaml".to_owned(), result.dictionary),
            ("dictionary-manifest.json".to_owned(), manifest),
        ]),
    )
}

fn run(args: &[String]) -> Result<()> {
    match args {
        [command] if command == "sources" => {
            for spec in inkflow_dictionary::catalog()?.iter().filter(|s| s.group != "legacy") {
                println!("{}\t{}\t{}\thttps://raw.githubusercontent.com/{}/{}/{}",
                    spec.id, spec.pinned_sha256, spec.pinned_byte_count, spec.repository, spec.pinned_commit, spec.path);
            }
        }
        [command] if command == "catalog" => {
            print!("{}", std::str::from_utf8(inkflow_dictionary::CATALOG_JSON)?);
        }
        [command, sources, legacy, corrections, output] if command == "generate" => {
            dictionary(&inkflow_dictionary::catalog()?, sources, legacy, corrections, output)?;
        }
        [command, catalog, sources, legacy, corrections, output] if command == "generate" => {
            let catalog: Vec<SourceSpec> = serde_json::from_slice(&read(Path::new(catalog), 1_048_576)?)?;
            dictionary(&catalog, sources, legacy, corrections, output)?;
        }
        [command, dictionary, output] if command == "spelling" => {
            let dictionary = read(Path::new(dictionary), MAX_SOURCE_BYTES)?;
            write_new(Path::new(output), spelling(&dictionary)?)?;
        }
        _ => return Err("Usage: dictionary-generator sources | catalog | generate [CATALOG] SOURCES LEGACY CORRECTIONS NEW_OUTPUT | spelling DICTIONARY NEW_OUTPUT".into()),
    }
    Ok(())
}

fn main() {
    if let Err(error) = run(&std::env::args().skip(1).collect::<Vec<_>>()) {
        eprintln!("dictionary-generator: {error}");
        std::process::exit(1);
    }
}
