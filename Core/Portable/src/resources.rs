//! Compiling and probing target-native resources: the two operations the macOS dictionary
//! worker runs against a candidate resource set, and `prepare-resources` against a build.
//!
//! Both are setup work with an isolated writable user directory, never on a key path, and
//! need exclusive use of Rime: they fail with `Native(Error::AlreadyRunning)` while any
//! runtime is initialized in the process, and release Rime before returning.
use crate::{Error, Runtime, preferences::spelling_profile};
use std::{fs, path::Path};

#[derive(Debug)]
pub enum ResourceError {
    /// Rime could not start, deploy or answer.
    Native(Error),
    Io(std::io::Error),
    /// A compiled file the engine needs is missing or empty; the name is relative to the cache.
    Missing(String),
    /// The compiled cache does not produce the expected candidates; the message names the input.
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

/// Compile `shared` into `cache` through Rime's maintenance, using `user` as scratch, then
/// check that every compiled file the engine loads exists and is not empty.
pub fn compile(shared: &Path, user: &Path, cache: &Path) -> Result<(), ResourceError> {
    fs::create_dir_all(user)?;
    fs::create_dir_all(cache)?;
    {
        let mut runtime = Runtime::with_cache(shared, user, cache)?;
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
    for mask in 0..32 {
        required.push(format!("{}.schema.yaml", spelling_profile(mask)));
        required.push(format!("{}.prism.bin", spelling_profile(mask)));
    }
    for file in required {
        if !fs::metadata(cache.join(&file)).is_ok_and(|meta| meta.len() > 0) {
            return Err(ResourceError::Missing(file));
        }
    }
    Ok(())
}

/// Serve the compiled `cache` from a clean `user` directory and select a Chinese, an English,
/// a mixed and an Emoji candidate, as the existing worker's smoke cases do. This makes no
/// ranking claim.
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
                session.select_candidate(&snapshot, index).map_err(step)?;
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
