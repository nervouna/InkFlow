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
    println!(
        "PASS lifetime, target deployment, Lua, UTF-8 ownership, commits, serialized sessions, restart"
    );
}
