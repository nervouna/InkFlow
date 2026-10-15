use inkflow_rime::{
    Error, Runtime,
    personal::{self, DICTIONARIES, PersonalError},
    resources::{self, ResourceError},
};
use std::{
    collections::BTreeMap,
    fs,
    path::PathBuf,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

// Rime is process-global: the tests of this file take turns.
static RIME: Mutex<()> = Mutex::new(());

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
    let _turn = RIME.lock().unwrap_or_else(|e| e.into_inner());
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

/// The macOS personal-data worker test's synthetic dictionaries (macOS/Tests/PersonalDataTests.swift).
fn synthetic(name: &str) -> String {
    let row = match name {
        "pinyin_simp" => "ni hao \t你好",
        "inkflow_shared_english" => "backupword \tBackupWord",
        _ => "beifen \t备份别名",
    };
    format!(
        "# Rime user dictionary\n#@/db_name\t{name}\n#@/db_type\tuserdb\n#@/rime_version\t1.17.0\n#@/user_id\tsynthetic-source\n#@/tick\t99\n{row}\tc=7 d=0.123456789 t=42\nce shi \t测试\tc=-3 d=0.0000123 t=17\n"
    )
}

fn lines(text: &str) -> Vec<&str> {
    let mut lines: Vec<&str> = text.lines().collect();
    lines.sort_unstable();
    lines
}

// Maintenance operations the macOS frontend calls on the Swift engine today, on the probe
// fixture. The engine-bound ones (personal learning, requested ASCII) need the production
// schema and run in tests/parity.rs and tests/abi.c.
#[test]
fn maintenance_operations_on_the_probe_fixture() {
    let _turn = RIME.lock().unwrap_or_else(|e| e.into_inner());
    let fixture = Fixture::new();

    // The version is the linked librime's and needs no runtime.
    assert_eq!(
        inkflow_rime::rime_version().unwrap(),
        personal::RIME_VERSION
    );

    // Compile deploys the source resources, then names the first production file the fixture
    // lacks; probe needs the production schema.
    let shared = fixture.0.join("shared");
    let cache = fixture.0.join("maintenance-cache");
    let compiler = fixture.0.join("maintenance-compile");
    let probing = fixture.0.join("maintenance-probe");
    match resources::compile(&shared, &compiler, &cache) {
        Err(ResourceError::Missing(file)) => assert_eq!(file, "inkflow_pinyin.schema.yaml"),
        other => panic!("{other:?}"),
    }
    assert!(cache.join("probe.table.bin").exists(), "the deployment ran");
    assert!(
        matches!(
            resources::probe(&shared, &probing, &cache),
            Err(ResourceError::Probe(_))
        ),
        "no inkflow_pinyin schema in the fixture"
    );
    // Both release the runtime; while one lives they report the native conflict.
    let runtime = fixture.runtime();
    assert!(matches!(
        resources::compile(&shared, &compiler, &cache),
        Err(ResourceError::Native(Error::AlreadyRunning))
    ));
    assert!(matches!(
        resources::probe(&shared, &probing, &cache),
        Err(ResourceError::Native(Error::AlreadyRunning))
    ));
    // Personal data waits for every runtime, as for the importer.
    let busy = fixture.0.join("busy-user");
    fs::create_dir_all(busy.join("pinyin_simp.userdb")).unwrap();
    assert!(matches!(
        personal::export(&busy),
        Err(PersonalError::EngineActive)
    ));
    drop(runtime);

    // Snapshot export: absent dictionaries are absent, restored ones export every row in
    // Rime's key order, and the exported text restores into another directory unchanged.
    let user = fixture.0.join("export-user");
    assert_eq!(
        personal::export(&user).unwrap(),
        DICTIONARIES
            .iter()
            .map(|name| (name.to_string(), None))
            .collect::<BTreeMap<_, _>>()
    );
    let incoming: BTreeMap<String, Option<String>> = DICTIONARIES
        .iter()
        .map(|name| (name.to_string(), Some(synthetic(name))))
        .collect();
    personal::import(&user, &incoming).unwrap();
    let exported = personal::export(&user).unwrap();
    for name in DICTIONARIES {
        let text = exported[name].as_deref().unwrap();
        assert_eq!(lines(text), lines(&synthetic(name)), "{name}");
    }
    assert_eq!(
        fs::read_dir(user.join("PersonalData/staging"))
            .unwrap()
            .count(),
        0,
        "export removes its staging copy"
    );
    let again = fixture.0.join("export-again");
    personal::import(&again, &exported).unwrap();
    assert_eq!(personal::export(&again).unwrap(), exported);
    let document = personal::Backup {
        rime: personal::RIME_VERSION.into(),
        candidate_count: 5,
        input: Default::default(),
        phrases: vec![],
        dictionaries: exported.clone(),
        unsupported: vec![],
    };
    assert_eq!(
        personal::Backup::from_json(&document.to_json().unwrap())
            .unwrap()
            .dictionaries,
        exported,
        "the exported snapshots are a valid backup"
    );
    println!(
        "PASS maintenance operations: version, compile/probe contracts, snapshot export round trip"
    );
}
