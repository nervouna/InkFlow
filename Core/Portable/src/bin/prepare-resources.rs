use inkflow_rime::resources;
use std::{error::Error, fs, path::PathBuf};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 2 {
        return Err("Usage: prepare-resources SHARED_SOURCE_DIRECTORY NEW_WORK_DIRECTORY".into());
    }
    let shared = PathBuf::from(&args[0]).canonicalize()?;
    let root = PathBuf::from(&args[1]);
    fs::create_dir(&root)?;
    let root = root.canonicalize()?;
    let cache = root.join("cache");
    let compiler = root.join("compile-user");
    let probe = root.join("probe-user");
    for path in [&cache, &compiler, &probe] {
        fs::create_dir(path)?;
    }
    resources::compile(&shared, &compiler, &cache)?;
    resources::probe(&shared, &probe, &cache)?;
    fs::remove_dir_all(compiler)?;
    fs::remove_dir_all(probe)?;
    fs::write(
        root.join("complete"),
        b"target-native compilation and five isolated worker smoke cases passed\n",
    )?;
    println!(
        "PASS target-native production cache, 32 spelling profiles, Chinese/English/mixed/Emoji selection and one-shot commits"
    );
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("Resource preparation failed: {error}");
        std::process::exit(1);
    }
}
