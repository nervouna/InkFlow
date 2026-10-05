use inkflow_rime::{Error, Runtime};
use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "inkflow-probe-{}-{}-中文",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("shared/lua")).unwrap();
        fs::create_dir(root.join("user")).unwrap();
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures");
        for file in [
            "default.yaml",
            "probe.schema.yaml",
            "probe.dict.yaml",
            "lua/probe.lua",
        ] {
            fs::copy(source.join(file), root.join("shared").join(file)).unwrap();
        }
        Self(root)
    }
    fn runtime(&self) -> Runtime {
        Runtime::new(&self.0.join("shared"), &self.0.join("user")).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

// One test owns the process-global Rime runtime; concurrency is exercised inside it.
#[test]
fn desktop_runtime_contract() {
    let fixture = Fixture::new();
    let mut runtime = fixture.runtime();
    assert!(matches!(
        Runtime::new(&fixture.0.join("shared"), &fixture.0.join("user")),
        Err(Error::AlreadyRunning)
    ));
    runtime
        .deploy(&fixture.0.join("shared/probe.schema.yaml"))
        .unwrap();
    assert!(fixture.0.join("user/build/probe.table.bin").exists());
    assert!(matches!(
        runtime.session("bad\0schema"),
        Err(Error::InvalidString)
    ));
    assert!(matches!(runtime.session("missing"), Err(Error::Native(-2))));
    let mut session = runtime.session("probe").unwrap();
    assert_eq!(runtime.prepare(), Err(Error::SessionsActive));
    assert_eq!(
        runtime.deploy(&fixture.0.join("shared/probe.schema.yaml")),
        Err(Error::SessionsActive)
    );
    assert!(session.snapshot().unwrap().preedit.is_empty());
    assert_eq!(session.take_commit().unwrap(), None);
    for byte in b"nihao" {
        assert!(session.process_key(*byte as i32, 0).unwrap());
    }
    let before = session.snapshot().unwrap();
    assert_eq!(before.preedit, "ni hao");
    assert_eq!(before.caret_bytes, 6);
    assert_eq!(before.candidates[0].text, "你好");
    assert_eq!(before.candidates[0].comment, "Lua ✓");
    println!(
        "composition={:?}; first={:?}; comment={:?}",
        before.preedit, before.candidates[0].text, before.candidates[0].comment
    );
    assert!(session.process_key(0x20, 0).unwrap());
    assert_eq!(session.take_commit().unwrap().as_deref(), Some("你好"));
    assert_eq!(session.take_commit().unwrap(), None);
    assert!(session.snapshot().unwrap().preedit.is_empty());
    assert_eq!(before.candidates[0].text, "你好");
    session.process_key('n' as i32, 0).unwrap();
    session.clear().unwrap();
    assert!(session.snapshot().unwrap().preedit.is_empty());
    assert!(!session.process_key(0xff1b, 0).unwrap());

    let mut second = runtime.session("probe").unwrap();
    for byte in b"ni" {
        session.process_key(*byte as i32, 0).unwrap();
        second.process_key(*byte as i32, 0).unwrap();
    }
    let first_page = session.snapshot().unwrap();
    assert_eq!(first_page.candidates.len(), 5);
    assert!(!first_page.last_page);
    assert_eq!(
        second.select_candidate(&first_page, 0),
        Err(Error::StaleSnapshot)
    );
    let other = second.snapshot().unwrap();
    assert_eq!(
        session.select_candidate(&other, 0),
        Err(Error::StaleSnapshot)
    );
    assert_eq!(
        session.select_candidate(&first_page, usize::MAX),
        Err(Error::InvalidCandidate)
    );
    assert!(session.change_page(false).unwrap());
    assert_eq!(
        session.select_candidate(&first_page, 0),
        Err(Error::StaleSnapshot)
    );
    let last_page = session.snapshot().unwrap();
    assert_eq!(last_page.page, 1);
    assert!(last_page.last_page);
    assert_eq!(last_page.candidates[0].text, "腻");
    assert!(session.change_page(true).unwrap());
    assert_eq!(
        session.select_candidate(&last_page, 0),
        Err(Error::StaleSnapshot)
    );
    let current = session.snapshot().unwrap();
    let refreshed = session.snapshot().unwrap();
    assert_eq!(
        session.select_candidate(&current, 0),
        Err(Error::StaleSnapshot)
    );
    session.select_candidate(&refreshed.clone(), 1).unwrap();
    assert_eq!(session.take_commit().unwrap().as_deref(), Some("尼"));
    assert_eq!(session.take_commit().unwrap(), None);
    assert_eq!(
        session.select_candidate(&refreshed, 1),
        Err(Error::StaleSnapshot)
    );
    second.clear().unwrap();
    assert_eq!(
        second.select_candidate(&other, 0),
        Err(Error::StaleSnapshot)
    );
    for byte in b"ni" {
        session.process_key(*byte as i32, 0).unwrap();
    }
    let edited = session.snapshot().unwrap();
    session.process_key('h' as i32, 0).unwrap();
    assert_eq!(
        session.select_candidate(&edited, 0),
        Err(Error::StaleSnapshot)
    );
    session.clear().unwrap();
    let empty = session.snapshot().unwrap();
    assert_eq!(
        session.select_candidate(&empty, 0),
        Err(Error::InvalidCandidate)
    );
    assert!(!session.process_key(0xff1b, 0).unwrap());
    assert_eq!(
        session.select_candidate(&empty, 0),
        Err(Error::StaleSnapshot)
    );
    let no_page = session.snapshot().unwrap();
    assert!(!session.change_page(false).unwrap());
    assert_eq!(
        session.select_candidate(&no_page, 0),
        Err(Error::StaleSnapshot)
    );
    let destroyed = {
        let mut temporary = runtime.session("probe").unwrap();
        for byte in b"ni" {
            temporary.process_key(*byte as i32, 0).unwrap();
        }
        temporary.snapshot().unwrap()
    };
    let mut replacement = runtime.session("probe").unwrap();
    for byte in b"ni" {
        replacement.process_key(*byte as i32, 0).unwrap();
    }
    let mut displayed = replacement.snapshot().unwrap();
    assert_eq!(
        replacement.select_candidate(&destroyed, 0),
        Err(Error::StaleSnapshot)
    );
    displayed
        .candidates
        .resize(20, displayed.candidates[0].clone());
    assert_eq!(
        replacement.select_candidate(&displayed, 19),
        Err(Error::InvalidCandidate)
    );
    replacement.clear().unwrap();
    drop(replacement);
    let thread = std::thread::spawn(move || {
        for _ in 0..25 {
            for byte in b"ni" {
                second.process_key(*byte as i32, 0).unwrap();
            }
            let snapshot = second.snapshot().unwrap();
            assert_eq!(snapshot.candidates[0].text, "你");
            assert_eq!(snapshot.preedit, "你");
            assert_eq!(snapshot.caret_bytes, 3);
            assert_eq!(snapshot.selection_bytes, 0..3);
            second.process_key(0x20, 0).unwrap();
            assert_eq!(second.take_commit().unwrap().as_deref(), Some("你"));
        }
    });
    for _ in 0..25 {
        for byte in b"hao" {
            session.process_key(*byte as i32, 0).unwrap();
        }
        assert_eq!(session.snapshot().unwrap().candidates[0].text, "好");
        session.clear().unwrap();
    }
    thread.join().unwrap();
    drop(runtime);
    // Sessions retain the runtime even after its public handle is gone.
    session.process_key('n' as i32, 0).unwrap();
    drop(session);
    assert_eq!(before.preedit, "ni hao");

    let runtime = fixture.runtime();
    let mut session = runtime.session("probe").unwrap();
    for byte in b"nihao" {
        session.process_key(*byte as i32, 0).unwrap();
    }
    assert_eq!(session.snapshot().unwrap().candidates[0].text, "你好");
    session.process_key(0x20, 0).unwrap();
    assert_eq!(session.take_commit().unwrap().as_deref(), Some("你好"));
    drop(session);
    drop(runtime);
    let cache = fixture.0.join("separate-cache");
    let compiler = fixture.0.join("compile-user");
    let serving = fixture.0.join("serving-user");
    for directory in [&cache, &compiler, &serving] {
        fs::create_dir(directory).unwrap();
    }
    let mut prepared = Runtime::with_cache(&fixture.0.join("shared"), &compiler, &cache).unwrap();
    prepared.prepare().unwrap();
    assert!(cache.join("probe.table.bin").exists());
    assert!(!compiler.join("build/probe.table.bin").exists());
    drop(prepared);
    let prepared = Runtime::with_cache(&fixture.0.join("shared"), &serving, &cache).unwrap();
    let mut prepared_session = prepared.session("probe").unwrap();
    for key in b"nihao" {
        prepared_session.process_key(i32::from(*key), 0).unwrap();
    }
    assert_eq!(
        prepared_session.snapshot().unwrap().candidates[0].text,
        "你好"
    );
    assert!(!serving.join("build/probe.table.bin").exists());
    drop(prepared_session);
    drop(prepared);
    println!(
        "PASS explicit-cache preparation/serving, lifetime, target deployment, Lua, UTF-8 ownership, commits, snapshot-safe selection, paging, serialized sessions, restart"
    );
}
