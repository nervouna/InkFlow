use inkflow_rime::Runtime;
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
    {
        let mut runtime = Runtime::with_cache(&shared, &compiler, &cache)?;
        runtime.prepare()?;
    }
    let mut required = vec![
        "default.yaml".to_owned(),
        "inkflow_pinyin.schema.yaml".to_owned(),
        "pinyin_simp.table.bin".to_owned(),
        "pinyin_simp.prism.bin".to_owned(),
        "easy_en.table.bin".to_owned(),
        "inkflow_mixed.table.bin".to_owned(),
    ];
    for profile in 0..32 {
        required.push(format!("inkflow_spelling_{profile}.schema.yaml"));
        required.push(format!("inkflow_spelling_{profile}.prism.bin"));
    }
    for file in &required {
        if fs::metadata(cache.join(file))?.len() == 0 {
            return Err(format!("Empty compiled resource: {file}").into());
        }
    }
    {
        let runtime = Runtime::with_cache(&shared, &probe, &cache)?;
        let mut session = runtime.session("inkflow_pinyin")?;
        // Match the existing worker's smoke cases; no production ranking claim.
        for (input, target, first_only) in [
            ("xiehouyu", "歇后语", true),
            ("suranqijing", "肃然起敬", true),
            ("email", "email", false),
            ("wofaleemail", "我发了email", false),
            ("nihao", "👋", false),
        ] {
            session.clear()?;
            for key in input.bytes() {
                session.process_key(i32::from(key), 0)?;
            }
            let mut found = false;
            let mut seen = 0;
            while seen < 1000 {
                let snapshot = session.snapshot()?;
                if let Some(index) = snapshot
                    .candidates
                    .iter()
                    .take(1000 - seen)
                    .position(|c| c.text == target)
                    && (!first_only || index == 0)
                {
                    session.select_candidate(&snapshot, index)?;
                    if session.take_commit()?.as_deref() != Some(target)
                        || session.take_commit()?.is_some()
                    {
                        return Err(format!("Commit probe failed: {input}").into());
                    }
                    found = true;
                    break;
                }
                seen += snapshot.candidates.len().max(1);
                if first_only || snapshot.last_page || !session.change_page(false)? {
                    break;
                }
            }
            if !found {
                return Err(format!("Candidate probe failed: {input}").into());
            }
        }
        session.clear()?;
    }
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
