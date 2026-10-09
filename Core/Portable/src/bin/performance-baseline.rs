//! Headless key-latency and memory capture of the Rust engine, following the protocol of
//! Core/Tests/PerformanceBaseline/PerformanceBaseline.swift: one fresh process per trial,
//! an absent user directory, the quality corpus typed five times without commits.
use inkflow_rime::{
    engine::{Configuration, Engine},
    preferences::InputPreferences,
};
use serde_json::{Value, json};
use std::{error::Error, fs, path::PathBuf, time::Instant};

#[repr(C)]
struct Rusage {
    utime: [i64; 2],
    stime: [i64; 2],
    maxrss: i64,
    rest: [i64; 13],
}
unsafe extern "C" {
    fn getrusage(who: i32, usage: *mut Rusage) -> i32;
}
/// Process peak RSS in bytes (Darwin reports bytes, Linux KiB).
fn peak_resident_bytes() -> Result<i64, Box<dyn Error>> {
    let mut usage = Rusage {
        utime: [0; 2],
        stime: [0; 2],
        maxrss: 0,
        rest: [0; 13],
    };
    if unsafe { getrusage(0, &mut usage) } != 0 {
        return Err("getrusage failed".into());
    }
    Ok(if cfg!(target_os = "macos") {
        usage.maxrss
    } else {
        usage.maxrss * 1024
    })
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).map(PathBuf::from).collect();
    let [resources, user, corpus, output] = args.as_slice() else {
        return Err("Usage: performance-baseline RESOURCES ABSENT_USER CORPUS OUTPUT".into());
    };
    if user.exists() {
        return Err("User directory must start absent".into());
    }
    let corpus: Value = serde_json::from_slice(&fs::read(corpus)?)?;
    let count = corpus["candidateCount"].as_u64().ok_or("corpus")? as usize;
    let samples = corpus["samples"].as_array().ok_or("corpus")?;
    if count != 9 || samples.is_empty() {
        return Err("Unsupported corpus".into());
    }
    let start = Instant::now();
    let engine = Engine::new(Configuration {
        shared: resources.join("shared"),
        user: user.clone(),
        cache: Some(resources.join("prepared/cache")),
        context_index: Some(resources.join("shared/pinyin_simp.context.bin")),
    })?;
    let session = engine.session()?;
    session.set_configuration(count, &[], Some(&InputPreferences::default()))?;
    if session.configuration_error().is_some() {
        return Err("Configuration failed".into());
    }
    session.set_preceding_text("")?;
    let startup = start.elapsed().as_secs_f64() * 1000.0;
    let startup_resident = peak_resident_bytes()?;
    let mut timings = Vec::new();
    for pass in 0..5 {
        for sample in samples {
            let id = sample["id"].as_str().ok_or("sample")?;
            let input = sample["input"].as_str().ok_or("sample")?;
            session.clear()?;
            session.set_preceding_text("")?;
            for (offset, byte) in input.bytes().enumerate() {
                let began = Instant::now();
                let handled = session.key(i32::from(byte), i32::from(byte.is_ascii_uppercase()))?;
                let commit = session.take_commit()?;
                let snapshot = session.snapshot()?;
                let elapsed = began.elapsed().as_secs_f64() * 1000.0;
                if !handled || !commit.is_empty() || snapshot.preedit.is_empty() {
                    return Err(format!("Unexpected input result in {id} at {offset}").into());
                }
                timings.push(
                    json!({"pass": pass, "sample": id, "offset": offset, "milliseconds": elapsed}),
                );
            }
        }
    }
    session.clear()?;
    let report = json!({
        "formatVersion": 1,
        "startupMilliseconds": startup,
        "peakResidentBytesAfterStartup": startup_resident,
        "peakResidentBytesAfterInput": peak_resident_bytes()?,
        "inputOptions": InputPreferences::default()
            .recorded_values()
            .into_iter()
            .map(|(name, value)| (name.to_owned(), json!(value)))
            .collect::<serde_json::Map<_, _>>(),
        "candidateCount": count,
        "timings": timings,
    });
    fs::write(output, serde_json::to_vec_pretty(&report)?)?;
    println!(
        "PASS performance baseline: {} key operations; startup_ms={startup}",
        report["timings"].as_array().unwrap().len()
    );
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("FAIL performance baseline: {error}");
        std::process::exit(1);
    }
}
