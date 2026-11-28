use crate::{Error, Runtime, preferences::spelling_profile};
use std::{fs, path::Path};

#[derive(Debug)]
pub enum ResourceError {
    Native(Error),
    Io(std::io::Error),
    Missing(String),
    Probe(String),
}

impl std::fmt::Display for ResourceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ResourceError::Native(error) => write!(f, "native: {error}"),
            ResourceError::Io(error) => write!(f, "io: {error}"),
            ResourceError::Missing(file) => write!(f, "empty compiled resource {file}"),
            ResourceError::Probe(message) => write!(f, "probe failed: {message}"),
        }
    }
}
impl std::error::Error for ResourceError {}
impl From<Error> for ResourceError {
    fn from(error: Error) -> Self {
        ResourceError::Native(error)
    }
}
impl From<std::io::Error> for ResourceError {
    fn from(error: std::io::Error) -> Self {
        ResourceError::Io(error)
    }
}

pub fn compiled_files() -> Vec<String> {
    let mut files: Vec<String> = [
        "inkflow_pinyin.schema.yaml",
        "pinyin_simp.table.bin",
        "pinyin_simp.prism.bin",
        "pinyin_simp.reverse.bin",
        "easy_en.table.bin",
        "inkflow_mixed.table.bin",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    for mask in 0..32 {
        files.push(format!("{}.schema.yaml", spelling_profile(mask)));
        files.push(format!("{}.prism.bin", spelling_profile(mask)));
    }
    files
}

pub fn compile(shared: &Path, user: &Path, cache: &Path) -> Result<(), ResourceError> {
    fs::create_dir_all(user)?;
    fs::create_dir_all(cache)?;
    {
        let mut runtime = Runtime::with_cache(shared, user, cache)?;
        runtime.prepare()?;
    }
    if !fs::metadata(cache.join("default.yaml")).is_ok_and(|meta| meta.len() > 0) {
        return Err(ResourceError::Missing("default.yaml".to_owned()));
    }
    for file in compiled_files() {
        if !fs::metadata(cache.join(&file)).is_ok_and(|meta| meta.len() > 0) {
            return Err(ResourceError::Missing(file));
        }
    }
    Ok(())
}

pub fn probe(shared: &Path, user: &Path, cache: &Path) -> Result<(), ResourceError> {
    fs::create_dir_all(user)?;
    let runtime = Runtime::with_cache(shared, user, cache)?;
    smoke(&runtime).map_err(ResourceError::Probe)
}

fn smoke(runtime: &Runtime) -> Result<(), String> {
    let step = |error: Error| error.to_string();
    let mut session = runtime.session("inkflow_pinyin").map_err(step)?;
    for (input, target, first_only) in [
        ("xiehouyu", "歇后语", true),
        ("suranqijing", "肃然起敬", true),
        ("email", "email", false),
        ("wofaleemail", "我发了email", false),
        ("nihao", "👋", false),
    ] {
        session.clear().map_err(step)?;
        for key in input.bytes() {
            session.process_key(i32::from(key), 0).map_err(step)?;
        }
        let mut found = false;
        let mut seen = 0;
        while seen < 1000 {
            let snapshot = session.snapshot().map_err(step)?;
            if let Some(index) = snapshot
                .candidates
                .iter()
                .take(1000 - seen)
                .position(|c| c.text == target)
                && (!first_only || index == 0)
            {
                if !session.select_native(index).map_err(step)? {
                    return Err(step(Error::Native(-1)));
                }
                if session.take_commit().map_err(step)?.as_deref() != Some(target)
                    || session.take_commit().map_err(step)?.is_some()
                {
                    return Err(format!("commit {input}"));
                }
                found = true;
                break;
            }
            seen += snapshot.candidates.len().max(1);
            if first_only || snapshot.last_page || !session.change_page(false).map_err(step)? {
                break;
            }
        }
        if !found {
            return Err(format!("candidate {input}"));
        }
    }
    session.clear().map_err(step)
}
