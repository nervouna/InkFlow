//! Old/new comparison against the recorded Swift quality baseline: candidate order,
//! paging, selection, commits and learning after restart on equivalent isolated fixtures.
//! Needs prepared production resources: set INKFLOW_PORTABLE_RESOURCES to a directory
//! holding `shared/` and `prepared/cache/` from `Core/Portable/prepare-resources.sh`.
use inkflow_rime::{
    engine::{Configuration, Engine, InputSession},
    preferences::InputPreferences,
};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
};

// Rime is process-global: one parity test runs at a time.
static RUNTIME: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn resources() -> Option<(PathBuf, std::sync::MutexGuard<'static, ()>)> {
    let path = std::env::var_os("INKFLOW_PORTABLE_RESOURCES").map(PathBuf::from)?;
    Some((path, RUNTIME.lock().unwrap_or_else(|e| e.into_inner())))
}

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("inkflow-parity-{}-{name}", std::process::id()));
    if root.exists() {
        fs::remove_dir_all(&root).unwrap();
    }
    fs::create_dir_all(&root).unwrap();
    root
}

fn engine(resources: &Path, user: &Path) -> Arc<Engine> {
    Engine::new(Configuration {
        shared: resources.join("shared"),
        user: user.to_path_buf(),
        cache: Some(resources.join("prepared/cache")),
        context_index: Some(resources.join("shared/pinyin_simp.context.bin")),
    })
    .unwrap()
}

fn configured(engine: &Arc<Engine>) -> InputSession {
    let session = engine.session().unwrap();
    session
        .set_configuration(9, &[], Some(&InputPreferences::default()))
        .unwrap();
    assert_eq!(session.configuration_error(), None);
    session.set_preceding_text("").unwrap();
    session
}

/// The Swift runner's fixed recipe: type, record the first page, find and select the target.
fn observe(session: &InputSession, input: &str, target: &str, page_limit: usize) -> Value {
    session.clear().unwrap();
    session.set_preceding_text("").unwrap();
    for byte in input.bytes() {
        let modifiers = i32::from(byte.is_ascii_uppercase());
        assert!(
            session.key(i32::from(byte), modifiers).unwrap(),
            "unhandled {input}"
        );
        assert!(
            session.take_commit().unwrap().is_empty(),
            "early commit {input}"
        );
    }
    let first_page = session.snapshot().unwrap();
    let (mut offset, mut paging, mut exhausted, mut rank, mut committed) =
        (0, 0, false, None, None);
    for page in 0..page_limit {
        let snapshot = session.snapshot().unwrap();
        if let Some(index) = snapshot.candidates.iter().position(|c| c.text == target) {
            rank = Some(offset + index + 1);
            session.select(&snapshot, index).unwrap();
            let text = session.take_commit().unwrap();
            assert!(
                text == target && session.snapshot().unwrap().preedit.is_empty(),
                "selection did not consume complete input: {input}"
            );
            committed = Some(text);
            break;
        }
        if page + 1 == page_limit {
            break;
        }
        session.key(0xff56, 0).unwrap();
        if session.snapshot().unwrap().page == snapshot.page {
            exhausted = true;
            break;
        }
        paging += 1;
        offset += snapshot.candidates.len();
    }
    session.clear().unwrap();
    let texts: Vec<&str> = first_page.texts();
    // Swift's Codable omits absent optionals.
    let mut observation = json!({
        "first": texts.first().copied().unwrap_or(""),
        "topThree": texts.iter().take(3).collect::<Vec<_>>(),
        "targetRank": rank,
        "inputOperations": input.len(),
        "pagingOperations": paging,
        "selectionOperations": if committed.is_some() { 1 } else { 0 },
        "totalOperations": committed.as_ref().map(|_| input.len() + paging + 1),
        "committedText": committed,
        "searchExhausted": exhausted,
    });
    observation
        .as_object_mut()
        .unwrap()
        .retain(|_, value| !value.is_null());
    observation
}

#[test]
fn swift_quality_baseline() {
    let Some((resources, _runtime)) = resources() else {
        println!("SKIP quality-baseline parity: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("../Fixtures/QualityBaseline");
    let corpus: Value =
        serde_json::from_str(&fs::read_to_string(fixtures.join("corpus.json")).unwrap()).unwrap();
    let baseline: Value =
        serde_json::from_str(&fs::read_to_string(fixtures.join("baseline.json")).unwrap()).unwrap();
    assert_eq!(baseline["corpus"], corpus);
    assert_eq!(corpus["candidateCount"], 9);
    let page_limit = corpus["pageLimit"].as_u64().unwrap() as usize;
    let selections = corpus["learningSelections"].as_u64().unwrap() as usize;
    let expected: Vec<(&str, bool)> = InputPreferences::default().recorded_values();
    for (name, value) in expected {
        assert_eq!(baseline["inputOptions"][name], json!(value), "{name}");
    }
    let users = scratch("quality-baseline");
    let mut results = Vec::new();
    let mut drift = Vec::new();
    for (index, sample) in corpus["samples"].as_array().unwrap().iter().enumerate() {
        let id = sample["id"].as_str().unwrap();
        let input = sample["input"].as_str().unwrap();
        let target = sample["target"].as_str().unwrap();
        let user = users.join(id);
        let (initial, training) = {
            let engine = engine(&resources, &user);
            let session = configured(&engine);
            let initial = observe(&session, input, target, page_limit);
            let mut training = 0;
            if !initial["committedText"].is_null() {
                training = 1;
                for _ in 1..selections {
                    let repeat = observe(&session, input, target, page_limit);
                    assert_eq!(
                        repeat["committedText"],
                        json!(target),
                        "learning target disappeared: {id}"
                    );
                    training += 1;
                }
            }
            (initial, training)
        };
        let engine = engine(&resources, &user);
        let learned = observe(&configured(&engine), input, target, page_limit);
        drop(engine);
        let result = json!({"sample": sample, "initial": initial, "trainingCommits": training, "learned": learned});
        let recorded = &baseline["results"][index];
        println!(
            "{id}: rank {} → {}; training commits {}{}",
            initial["targetRank"],
            learned["targetRank"],
            training,
            if *recorded == result { "" } else { " DRIFT" }
        );
        if *recorded != result {
            drift.push(id.to_owned());
        }
        results.push(result);
    }
    let output =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../build/portable/quality-baseline.json");
    fs::write(
        &output,
        serde_json::to_string_pretty(&json!({"results": results})).unwrap(),
    )
    .unwrap();
    fs::remove_dir_all(&users).unwrap();
    assert!(
        drift.is_empty(),
        "quality baseline drift: {}; inspect {}",
        drift.join(", "),
        output.display()
    );
    println!(
        "PASS Swift/Rust quality baseline: {} samples, initial and persisted learned states",
        results.len()
    );
}

fn type_keys(session: &InputSession, text: &str) {
    for byte in text.bytes() {
        session.key(i32::from(byte), 0).unwrap();
    }
}

fn texts(session: &InputSession) -> Vec<String> {
    session
        .snapshot()
        .unwrap()
        .texts()
        .iter()
        .map(|s| s.to_string())
        .collect()
}

fn all_candidates(session: &InputSession) -> Vec<String> {
    let mut all = Vec::new();
    for _ in 0..1000 {
        let snapshot = session.snapshot().unwrap();
        all.extend(snapshot.texts().iter().map(|s| s.to_string()));
        session.key(0xff56, 0).unwrap();
        if session.snapshot().unwrap().page == snapshot.page {
            for _ in 0..snapshot.page {
                session.key(0xff55, 0).unwrap();
            }
            assert_eq!(session.snapshot().unwrap().page, 0);
            return all;
        }
    }
    panic!("candidate enumeration must reach the final page");
}

/// Expectations copied from Core/Tests/InkFlowEngineTestSupport/EngineRegression.swift:
/// runCases, contextReranking, contextCustomPhrasePriority, customPhrases and inputSettings.
#[test]
fn swift_engine_regressions() {
    use inkflow_rime::{Error, engine::Action, phrases::CustomPhrase, preferences::InputOption};
    let Some((resources, _runtime)) = resources() else {
        println!("SKIP engine regression parity: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let user = scratch("engine-regressions");
    let engine = engine(&resources, &user);
    let mutations = Arc::new(std::sync::Mutex::new(Vec::new()));
    let log = mutations.clone();
    engine.set_observer(Some(Arc::new(move |mutation| {
        log.lock().unwrap().push((
            mutation.action.clone(),
            mutation.handled,
            mutation.before.input.clone(),
            mutation.after.input.clone(),
        ));
    })));

    // runCases: basic composition, cancel, backspace, paging, digits, counts and session isolation.
    let a = engine.session().unwrap();
    let b = engine.session().unwrap();
    type_keys(&a, "nihao");
    assert!(texts(&a).contains(&"你好".to_string()));
    assert!(b.snapshot().unwrap().preedit.is_empty());
    let shown = a.snapshot().unwrap();
    a.select(&shown, 0).unwrap();
    assert_eq!(a.take_commit().unwrap(), "你好");
    assert_eq!(
        a.select(&shown, 0),
        Err(Error::StaleSnapshot),
        "a delayed selection cannot reuse a superseded page"
    );
    type_keys(&a, "zhongguo");
    assert!(texts(&a).contains(&"中国".to_string()));
    a.key(0xff1b, 0).unwrap();
    assert!(a.snapshot().unwrap().preedit.is_empty());
    type_keys(&a, "ni");
    a.key(0xff08, 0).unwrap();
    assert_eq!(a.snapshot().unwrap().preedit, "n");
    a.clear().unwrap();
    type_keys(&a, "shi");
    let first = texts(&a);
    assert_eq!(first.len(), 5);
    assert!(a.key(0xff56, 0).unwrap());
    assert_eq!(a.snapshot().unwrap().page, 1);
    let second = texts(&a);
    assert!(second.len() == 5 && second != first);
    a.key(0xff55, 0).unwrap();
    assert!(a.snapshot().unwrap().page == 0 && texts(&a) == first);
    assert!(a.key(50, 0).unwrap());
    assert_eq!(a.take_commit().unwrap(), first[1]);
    type_keys(&a, "shi");
    a.key(0xff56, 0).unwrap();
    let second = texts(&a);
    assert!(a.key(53, 0).unwrap());
    assert_eq!(a.take_commit().unwrap(), second[4]);
    type_keys(&a, "nihao");
    a.key(32, 0).unwrap();
    assert_eq!(a.take_commit().unwrap(), "你好");
    a.set_ascii_mode(true).unwrap();
    assert!(!a.key(97, 0).unwrap());
    a.set_ascii_mode(false).unwrap();
    type_keys(&a, "nihao");
    a.commit().unwrap();
    assert_eq!(a.take_commit().unwrap(), "你好");
    a.clear().unwrap();
    type_keys(&a, "shi");
    let before = a.snapshot().unwrap();
    a.set_candidate_count(9).unwrap();
    assert!(
        a.snapshot().unwrap() == before && a.take_commit().unwrap().is_empty(),
        "a composing session keeps its page size"
    );
    a.clear().unwrap();
    type_keys(&a, "shi");
    assert_eq!(texts(&a).len(), 9);
    a.key(0xff56, 0).unwrap();
    let nine = texts(&a);
    assert_eq!(nine.len(), 9);
    assert!(a.key(57, 0).unwrap());
    assert_eq!(a.take_commit().unwrap(), nine[8]);
    {
        let fresh = engine.session().unwrap();
        type_keys(&fresh, "shi");
        assert_eq!(texts(&fresh).len(), 5);
        fresh.clear().unwrap();
        fresh.set_candidate_count(9).unwrap();
        type_keys(&fresh, "shi");
        assert_eq!(texts(&fresh).len(), 9);
    }
    b.clear().unwrap();
    type_keys(&b, "shi");
    assert_eq!(texts(&b).len(), 5, "every session keeps its own count");
    b.clear().unwrap();
    a.set_candidate_count(3).unwrap();
    type_keys(&a, "shi");
    assert_eq!(texts(&a).len(), 3);
    a.clear().unwrap();

    // contextReranking: bundled phrases, stable fallback, arrows, partial selection.
    let prepared = |prefix: &str, input: &str, count: usize| {
        let session = engine.session().unwrap();
        session.set_candidate_count(count).unwrap();
        session.set_preceding_text(prefix).unwrap();
        type_keys(&session, input);
        session
    };
    let coverage = prepared("什么", "neng", 9);
    assert_eq!(
        texts(&coverage)[0],
        "能",
        "context must not promote partial 呢 above complete 能"
    );
    assert!(coverage.key(32, 0).unwrap());
    assert!(
        coverage.take_commit().unwrap() == "能" && coverage.snapshot().unwrap().preedit.is_empty()
    );
    for count in [3, 5, 9] {
        let contextual = prepared("什么", "neng", count);
        let native = prepared("", "neng", count);
        assert_eq!(
            texts(&contextual),
            texts(&native),
            "same-length partial choices retain native order"
        );
        let first_page = texts(&contextual);
        assert!(contextual.key(0xff56, 0).unwrap() && contextual.snapshot().unwrap().page == 1);
        assert!(contextual.key(0xff55, 0).unwrap() && texts(&contextual) == first_page);
        let partial = first_page
            .iter()
            .position(|c| c == "呢")
            .expect("呢 on the neng first page");
        let page = contextual.snapshot().unwrap();
        contextual.highlight(&page, partial).unwrap();
        contextual.set_preceding_text("什么").unwrap();
        assert_eq!(
            contextual.snapshot().unwrap().highlighted,
            partial,
            "an unchanged prefix preserves explicit selection"
        );
        assert!(contextual.key(32, 0).unwrap());
        assert!(
            contextual.take_commit().unwrap().is_empty()
                && contextual.snapshot().unwrap().preedit == "呢ng"
        );
        let page = native.snapshot().unwrap();
        native.select(&page, partial).unwrap();
        assert_eq!(
            texts(&contextual),
            texts(&native),
            "selected-prefix bypass preserves native remaining candidates"
        );
        assert!(contextual.snapshot().unwrap().has_selected_prefix());
    }
    for (prefix, input, expected) in [
        ("准备午", "can", "餐"),
        ("正式宣", "bu", "布"),
        ("最新软", "jian", "件"),
        ("非常感", "xie", "谢"),
    ] {
        let session = prepared(prefix, input, 9);
        let snapshot = session.snapshot().unwrap();
        assert_eq!(
            snapshot.texts()[0],
            expected,
            "bundled dictionary context {prefix} + {input}"
        );
        assert_eq!(snapshot.highlighted, 0);
        assert!(session.key(32, 0).unwrap());
        assert_eq!(session.take_commit().unwrap(), expected);
    }
    for count in [3, 5, 9] {
        let session = engine.session().unwrap();
        session.set_candidate_count(count).unwrap();
        type_keys(&session, "can");
        let original = texts(&session);
        session.set_preceding_text("准备午").unwrap();
        let ranked = session.snapshot().unwrap();
        assert!(ranked.texts()[0] == "餐" && ranked.candidates.len() == count);
        let mut rest: Vec<&str> = ranked.texts()[1..].to_vec();
        let mut others: Vec<&str> = original
            .iter()
            .map(|s| s.as_str())
            .filter(|s| *s != "餐")
            .collect();
        assert_eq!(rest, others, "other candidates keep their native order");
        rest.sort();
        others.sort();
        assert_eq!(
            session.snapshot().unwrap(),
            ranked,
            "snapshot reads must be side-effect free"
        );
        assert!(session.key(0xff54, 0).unwrap());
        assert_eq!(session.snapshot().unwrap().highlighted, 1);
        session.set_preceding_text("准备午").unwrap();
        assert_eq!(session.snapshot().unwrap().highlighted, 1);
        assert!(session.key(32, 0).unwrap());
        assert_eq!(session.take_commit().unwrap(), ranked.texts()[1]);
    }
    for count in [3, 5, 9] {
        let session = prepared("多", "can", count);
        let candidates = texts(&session);
        assert_eq!(candidates.len(), count);
        assert!(
            candidates[0].chars().all(|c| c as u32 > 127),
            "context keeps Chinese first for short English conflicts"
        );
        let index = candidates
            .iter()
            .position(|c| c == "can")
            .expect("exact short English on the first page");
        assert!(
            index < 3,
            "exact short English stays in the top three: {candidates:?}"
        );
        let page = session.snapshot().unwrap();
        session.select(&page, index).unwrap();
        assert!(
            session.take_commit().unwrap() == "can"
                && session.snapshot().unwrap().preedit.is_empty()
        );
    }
    for prefix in [
        "",
        "完全无关",
        "准备午，",
        "准备午 ",
        "准备午\n",
        "准备午😀",
    ] {
        assert_eq!(
            texts(&prepared(prefix, "can", 5)),
            texts(&prepared("", "can", 5)),
            "{prefix:?}"
        );
    }
    for index in 0..5 {
        for digit in [false, true] {
            let session = prepared("准备午", "can", 5);
            let page = session.snapshot().unwrap();
            let expected = page.texts()[index].to_string();
            if digit {
                assert!(session.key(49 + index as i32, 0).unwrap());
            } else {
                session.select(&page, index).unwrap();
            }
            assert!(
                session.take_commit().unwrap() == expected
                    && session.snapshot().unwrap().preedit.is_empty()
            );
        }
    }
    for (action, expected) in [
        ("commit", "餐"),
        ("space", "餐"),
        ("comma", "餐，"),
        ("return", "can"),
    ] {
        let session = prepared("准备午", "can", 5);
        match action {
            "commit" => {
                session.commit().unwrap();
            }
            "space" => assert!(session.key(32, 0).unwrap()),
            "comma" => assert!(session.key(44, 0).unwrap()),
            _ => assert!(session.key(0xff0d, 0).unwrap()),
        }
        assert_eq!(session.take_commit().unwrap(), expected, "{action}");
        assert!(session.snapshot().unwrap().preedit.is_empty());
    }
    let session = prepared("正式宣", "bu", 5);
    let first = texts(&session);
    assert!(session.key(0xff56, 0).unwrap() && session.snapshot().unwrap().page == 1);
    assert_ne!(texts(&session), first);
    assert!(session.key(0xff55, 0).unwrap() && texts(&session) == first);
    let page = session.snapshot().unwrap();
    session.highlight(&page, first.len() - 1).unwrap();
    assert!(session.key(0xff54, 0).unwrap());
    let moved = session.snapshot().unwrap();
    assert!(
        moved.page == 1 && moved.highlighted == 0,
        "Down at the page edge continues on the next page"
    );
    assert!(session.key(0xff52, 0).unwrap());
    let back = session.snapshot().unwrap();
    assert!(
        back.page == 0 && back.highlighted == first.len() - 1,
        "Up at the page start returns to the previous page's end"
    );
    session.clear().unwrap();
    type_keys(&session, "can");
    assert_eq!(
        texts(&session),
        texts(&prepared("", "can", 5)),
        "clearing discards the old prefix"
    );
    session.set_preceding_text("准备午").unwrap();
    assert_eq!(texts(&session)[0], "餐");
    assert!(session.key(0xff08, 0).unwrap());
    assert_eq!(session.snapshot().unwrap().preedit, "ca");
    assert!(session.key(0xff1b, 0).unwrap());
    assert!(session.snapshot().unwrap().preedit.is_empty());
    let partial = prepared("迷", "nihao", 5);
    let plain = prepared("", "nihao", 5);
    assert_eq!(
        texts(&partial),
        texts(&plain),
        "do not promote the shorter 你 through 迷你"
    );
    let index = texts(&partial).iter().position(|c| c == "你").unwrap();
    partial.select(&partial.snapshot().unwrap(), index).unwrap();
    plain.select(&plain.snapshot().unwrap(), index).unwrap();
    assert!(
        partial.take_commit().unwrap().is_empty()
            && !partial.snapshot().unwrap().preedit.is_empty()
    );
    assert!(partial.snapshot().unwrap().has_selected_prefix());
    assert_eq!(texts(&partial), texts(&plain));
    partial.select(&partial.snapshot().unwrap(), 0).unwrap();
    assert_eq!(partial.take_commit().unwrap(), "你好");

    // Phrase reloads wait for every live session to be idle; release the composing ones.
    drop((a, b, coverage, session, partial, plain));

    // contextCustomPhrasePriority and customPhrases: priority, deferred reload, pending commits.
    let session = engine.session().unwrap();
    let phrase = CustomPhrase::validated("p1", "can", "残").unwrap();
    session
        .set_configuration(5, std::slice::from_ref(&phrase), None)
        .unwrap();
    assert_eq!(session.configuration_error(), None);
    session.set_preceding_text("准备午").unwrap();
    type_keys(&session, "can");
    assert_eq!(
        texts(&session)[0],
        "残",
        "an exact custom phrase retains priority over contextual 餐"
    );
    session.set_configuration(3, &[], None).unwrap();
    assert_eq!(
        texts(&session)[0],
        "残",
        "deferred deletion preserves the current custom phrase snapshot"
    );
    assert!(session.key(32, 0).unwrap());
    assert_eq!(session.take_commit().unwrap(), "残");
    session.set_preceding_text("准备午").unwrap();
    type_keys(&session, "can");
    assert_eq!(
        texts(&session)[0],
        "餐",
        "context ranking resumes after the custom code is deleted at idle"
    );
    assert!(session.key(32, 0).unwrap());
    assert_eq!(session.take_commit().unwrap(), "餐");
    let phrases: Vec<CustomPhrase> = ["地址甲", "地址乙", "地址丙", "地址丁", "地址戊", "地址己"]
        .iter()
        .enumerate()
        .map(|(i, text)| CustomPhrase::validated(&format!("dz{i}"), "dz", text).unwrap())
        .chain([
            CustomPhrase::validated("n1", "nihao", "您好朋友").unwrap(),
            CustomPhrase::validated("n2", "nihao", "你好").unwrap(),
            CustomPhrase::validated("bq", "bq", "#标签").unwrap(),
        ])
        .collect();
    let a = engine.session().unwrap();
    let b = engine.session().unwrap();
    a.set_configuration(3, &phrases, None).unwrap();
    b.set_configuration(3, &phrases, None).unwrap();
    assert_eq!(a.configuration_error(), None);
    type_keys(&a, "bq");
    assert_eq!(
        texts(&a)[0],
        "#标签",
        "hash text survives Rime's TSV comment rule"
    );
    a.clear().unwrap();
    type_keys(&a, "nihao");
    assert_eq!(
        texts(&a)[..2],
        ["您好朋友", "你好"],
        "custom phrases precede ordinary candidates"
    );
    assert_eq!(
        all_candidates(&a).iter().filter(|c| *c == "你好").count(),
        1,
        "no duplicate suggestions"
    );
    a.clear().unwrap();
    type_keys(&a, "dza");
    assert!(!texts(&a).contains(&"地址甲".to_string()));
    a.clear().unwrap();
    type_keys(&a, "dz");
    assert_eq!(texts(&a), ["地址甲", "地址乙", "地址丙"]);
    a.key(0xff56, 0).unwrap();
    assert!(a.snapshot().unwrap().page == 1 && texts(&a) == ["地址丁", "地址戊", "地址己"]);
    a.key(50, 0).unwrap();
    assert_eq!(a.take_commit().unwrap(), "地址戊");
    type_keys(&a, "dz");
    let old = a.snapshot().unwrap();
    let changed = CustomPhrase::validated("dz0", "dz", "更新地址").unwrap();
    a.set_configuration(5, &[changed.clone()], None).unwrap();
    a.set_configuration(3, &[changed.clone()], None).unwrap();
    assert!(
        a.snapshot().unwrap() == old
            && a.take_commit().unwrap().is_empty()
            && a.candidate_count() == 3
    );
    a.key(32, 0).unwrap();
    // Applying settings between a completed composition and draining its commit must not lose text.
    a.set_configuration(3, &[changed.clone()], None).unwrap();
    assert_eq!(a.take_commit().unwrap(), "地址甲");
    type_keys(&a, "dz");
    assert!(texts(&a)[0] == "更新地址" && a.candidate_count() == 3);
    a.clear().unwrap();
    type_keys(&b, "dz");
    assert!(
        texts(&b)[0] == "更新地址" && b.candidate_count() == 3,
        "every idle session reloads the saved phrases together"
    );
    b.clear().unwrap();
    {
        let fresh = engine.session().unwrap();
        fresh
            .set_configuration(3, &[changed.clone()], None)
            .unwrap();
        type_keys(&fresh, "dz");
        assert_eq!(texts(&fresh)[0], "更新地址");
    }
    a.set_ascii_mode(true).unwrap();
    a.set_configuration(9, &[], None).unwrap();
    assert!(
        !a.key(97, 0).unwrap(),
        "schema reload must preserve ASCII mode"
    );
    a.set_ascii_mode(false).unwrap();
    type_keys(&a, "dz");
    assert!(!texts(&a).contains(&"更新地址".to_string()));
    a.clear().unwrap();
    let invalid = CustomPhrase {
        id: "x".into(),
        code: "x\ty".into(),
        text: "invalid".into(),
    };
    a.set_configuration(5, &[invalid], None).unwrap();
    assert!(a.configuration_error().is_some());
    a.set_configuration(5, &[], None).unwrap();
    assert_eq!(a.configuration_error(), None);
    assert_eq!(
        fs::read_to_string(user.join("custom_phrase.txt")).unwrap(),
        "# no comment\n",
        "Rime's native custom_phrase.txt holds the saved phrases"
    );

    // inputSettings: spelling profiles, fuzzy pairs, traditional/emoji, punctuation and paging.
    let session = engine.session().unwrap();
    let defaults = InputPreferences::default();
    let configure = |preferences: &InputPreferences| {
        session
            .set_configuration(9, &[], Some(preferences))
            .unwrap();
        assert_eq!(session.configuration_error(), None);
    };
    let contains = |input: &str, expected: &str| {
        session.clear().unwrap();
        type_keys(&session, input);
        for _ in 0..100 {
            let before = session.snapshot().unwrap();
            if before.texts().contains(&expected) {
                return true;
            }
            session.key(0xff56, 0).unwrap();
            if before.page == session.snapshot().unwrap().page {
                break;
            }
        }
        false
    };
    let exact = defaults
        .clone()
        .with(InputOption::Abbreviation, false)
        .with(InputOption::TypoTolerance, false);
    configure(&defaults);
    assert!(contains("hlw", "互联网") && contains("zhguo", "中国"));
    configure(&exact);
    assert!(!contains("hlw", "互联网"), "abbreviation off");
    assert!(session.input_preferences() == Some(exact.clone()) && session.candidate_count() == 9);
    for (option, input, output) in [
        (InputOption::FuzzyZ, "zongguo", "中国"),
        (InputOption::FuzzyC, "canpin", "产品"),
        (InputOption::FuzzyS, "sanghai", "上海"),
    ] {
        configure(&exact);
        assert!(!contains(input, output), "fuzzy off {input}");
        configure(&exact.clone().with(option, true));
        assert!(contains(input, output), "fuzzy on {input}");
    }
    configure(&exact);
    assert!(!contains("nnihao", "你好"), "typo off");
    configure(&exact.clone().with(InputOption::TypoTolerance, true));
    assert!(contains("nnihao", "你好") && contains("hzidao", "知道"));
    session.clear().unwrap();
    configure(&defaults);
    type_keys(&session, "hulianwang");
    let before = session.snapshot().unwrap();
    let traditional = defaults
        .clone()
        .with(InputOption::Traditional, true)
        .with(InputOption::Emoji, false);
    session
        .set_configuration(9, &[], Some(&traditional))
        .unwrap();
    assert!(
        session.snapshot().unwrap() == before && session.take_commit().unwrap().is_empty(),
        "pending options preserve the composing snapshot"
    );
    session.key(32, 0).unwrap();
    session
        .set_configuration(9, &[], Some(&traditional))
        .unwrap();
    assert_eq!(
        session.take_commit().unwrap(),
        "互联网",
        "settings reload preserves a pending simplified commit"
    );
    assert!(
        contains("hulianwang", "互聯網"),
        "traditional next composition"
    );
    session.clear().unwrap();
    configure(&defaults.clone().with(InputOption::Traditional, true));
    assert!(contains("weixiao", "😊"), "traditional retains Emoji");
    configure(&traditional);
    assert!(!contains("weixiao", "😊"), "Emoji off");
    for (option, inputs, outputs) in [
        (InputOption::CornerQuotes, "{}", "「」"),
        (InputOption::MiddleDot, "`", "·"),
        (InputOption::FullwidthPipe, "|", "｜"),
        (InputOption::IdeographicComma, "\\", "、"),
    ] {
        for enabled in [false, true] {
            session.clear().unwrap();
            configure(&defaults.clone().with(option, enabled));
            let expected: Vec<char> = if enabled {
                outputs.chars().collect()
            } else {
                inputs.chars().collect()
            };
            for (input, output) in inputs.chars().zip(expected) {
                let handled = session.key(input as i32, 0).unwrap();
                let commit = session.take_commit().unwrap();
                assert_eq!(
                    if handled { commit } else { input.to_string() },
                    output.to_string(),
                    "{option:?} = {enabled}"
                );
            }
        }
    }
    session.clear().unwrap();
    configure(&defaults.clone().with(InputOption::EnglishPunctuation, true));
    for input in "{},.`|\\".chars() {
        let handled = session.key(input as i32, 0).unwrap();
        let output = session.take_commit().unwrap();
        assert_eq!(
            if handled { output } else { input.to_string() },
            input.to_string(),
            "English punctuation {input}"
        );
    }
    for (option, previous, next) in [
        (InputOption::BracketPaging, 91, 93),
        (InputOption::MinusEqualPaging, 45, 61),
    ] {
        for enabled in [false, true] {
            session.clear().unwrap();
            configure(&defaults.clone().with(option, enabled));
            type_keys(&session, "shi");
            session.key(next, 0).unwrap();
            assert_eq!(
                session.snapshot().unwrap().page,
                i32::from(enabled),
                "independent paging {option:?} = {enabled}"
            );
            if enabled {
                session.key(previous, 0).unwrap();
                assert_eq!(session.snapshot().unwrap().page, 0);
            }
            session.take_commit().unwrap();
        }
    }
    session.clear().unwrap();
    configure(&defaults);
    type_keys(&session, "nihao");
    let composing = session.snapshot().unwrap();
    session.set_ascii_mode(true).unwrap();
    assert!(
        session.requested_ascii_mode()
            && !session.ascii_mode().unwrap()
            && session.snapshot().unwrap() == composing
    );
    session.key(32, 0).unwrap();
    assert_eq!(session.take_commit().unwrap(), "你好");
    assert!(
        !session.key(97, 0).unwrap() && session.ascii_mode().unwrap(),
        "ASCII starts only after the old composition finishes"
    );
    session.set_ascii_mode(false).unwrap();
    assert!(session.key(44, 0).unwrap());
    assert_eq!(session.take_commit().unwrap(), "，");
    let retained = engine.session().unwrap();
    type_keys(&retained, "hlw");
    let retained_state = retained.snapshot().unwrap();
    retained.set_configuration(9, &[], Some(&exact)).unwrap();
    configure(&exact);
    assert_eq!(
        retained.snapshot().unwrap(),
        retained_state,
        "another live session keeps its composing prism"
    );
    assert!(
        retained.input_preferences() == Some(defaults.clone())
            && session.input_preferences() == Some(exact.clone())
    );
    retained.clear().unwrap();
    type_keys(&retained, "hlw");
    assert!(
        !texts(&retained).contains(&"互联网".to_string()),
        "deferred abbreviation off applies after cancellation"
    );
    retained.clear().unwrap();
    let prism = resources.join(format!(
        "prepared/cache/{}.prism.bin",
        exact.spelling_profile()
    ));
    let hidden = prism.with_extension("test-backup");
    configure(&defaults);
    fs::rename(&prism, &hidden).unwrap();
    session.set_configuration(9, &[], Some(&exact)).unwrap();
    let failed = session.configuration_error()
        == Some(inkflow_rime::engine::ConfigurationError::MissingPrism)
        && session.input_preferences() == Some(defaults.clone());
    fs::rename(&hidden, &prism).unwrap();
    assert!(failed, "a missing prism must not mark settings applied");
    configure(&exact);
    assert_eq!(session.input_preferences(), Some(exact));

    let recorded = mutations.lock().unwrap();
    assert!(
        recorded
            .iter()
            .any(|(action, handled, before, after)| *action
                == Action::Key {
                    key: 32,
                    modifiers: 0
                }
                && *handled
                && before == "nihao"
                && after.is_empty()),
        "the observer sees each mutation with the input before and after"
    );
    assert!(
        recorded
            .iter()
            .any(|(action, _, _, _)| matches!(action, Action::Select(_)))
    );
    drop(recorded);
    drop(engine);
    fs::remove_dir_all(&user).unwrap();
    println!(
        "PASS Swift engine regressions on the Rust engine: basic cases, context ranking, custom phrases, input settings, ASCII boundaries, stale selection, observer"
    );
}
