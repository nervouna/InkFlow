use inkflow_rime::{
    Error, Runtime,
    personal::{self, DICTIONARIES, PersonalError},
    resources::{self, ResourceError},
};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

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

#[test]
fn desktop_runtime_contract() {
    let _turn = RIME.lock().unwrap_or_else(|e| e.into_inner());
    let fixture = Fixture::new();
    let mut runtime = fixture.runtime();
    assert!(matches!(
        Runtime::new(&fixture.0.join("shared"), &fixture.0.join("user")),
        Err(Error::AlreadyRunning)
    ));
    runtime.prepare().unwrap();
    assert!(fixture.0.join("user/build/probe.table.bin").exists());
    assert!(matches!(
        runtime.session("bad\0schema"),
        Err(Error::InvalidString)
    ));
    assert!(matches!(runtime.session("missing"), Err(Error::Native(-2))));
    let mut session = runtime.session("probe").unwrap();
    assert_eq!(runtime.prepare(), Err(Error::SessionsActive));
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
    assert!(session.change_page(false).unwrap());
    let last_page = session.snapshot().unwrap();
    assert_eq!(last_page.page, 1);
    assert!(last_page.last_page);
    assert_eq!(last_page.candidates[0].text, "腻");
    assert!(session.change_page(true).unwrap());
    session.clear().unwrap();
    second.clear().unwrap();
    assert!(!session.change_page(false).unwrap());
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
        "PASS cache preparation/serving, lifetime, Lua, UTF-8 ownership, commits, paging, serialized sessions, restart"
    );
}

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

#[test]
fn maintenance_operations_on_the_probe_fixture() {
    let _turn = RIME.lock().unwrap_or_else(|e| e.into_inner());
    let fixture = Fixture::new();

    assert_eq!(
        inkflow_rime::rime_version().unwrap(),
        personal::RIME_VERSION
    );

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
    let runtime = fixture.runtime();
    assert!(matches!(
        resources::compile(&shared, &compiler, &cache),
        Err(ResourceError::Native(Error::AlreadyRunning))
    ));
    assert!(matches!(
        resources::probe(&shared, &probing, &cache),
        Err(ResourceError::Native(Error::AlreadyRunning))
    ));
    let busy = fixture.0.join("busy-user");
    fs::create_dir_all(busy.join("pinyin_simp.userdb")).unwrap();
    assert!(matches!(
        personal::export(&busy),
        Err(PersonalError::EngineActive)
    ));
    drop(runtime);

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

#[test]
fn product_traits_record_installation_without_logs() {
    let _turn = RIME.lock().unwrap_or_else(|e| e.into_inner());
    let fixture = Fixture::new();
    {
        let mut runtime = fixture.runtime();
        runtime.prepare().unwrap();
        let mut session = runtime.session("probe").unwrap();
        for byte in b"nihao" {
            session.process_key(*byte as i32, 0).unwrap();
        }
        assert_eq!(session.snapshot().unwrap().candidates[0].text, "你好");
    }
    let installation = fs::read_to_string(fixture.0.join("user/installation.yaml")).unwrap();
    assert!(
        installation.lines().any(|line| {
            line.strip_prefix("distribution_code_name: ")
                .is_some_and(|value| value.trim_matches('"') == "inkflow")
        }),
        "{installation}"
    );
    let mut logs = Vec::new();
    collect_log_files(&fixture.0.join("user"), &mut logs);
    assert_eq!(logs, Vec::<PathBuf>::new());
    println!(
        "PASS product traits: installation record is InkFlow's and the user directory has no logs"
    );
}

fn collect_log_files(directory: &Path, found: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect_log_files(&path, found);
        }
        if path.file_name().unwrap().to_string_lossy().contains(".log") {
            found.push(path);
        }
    }
}
