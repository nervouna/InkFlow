//! Old/new comparison against the recorded Swift quality baseline: candidate order,
//! paging, selection, commits and learning after restart on equivalent isolated fixtures.
//! Needs prepared production resources: set INKFLOW_PORTABLE_RESOURCES to a directory
//! holding `shared/` and `prepared/cache/` from `Core/Portable/prepare-resources.sh`.
use inkflow_rime::{
    channel::Reply,
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

/// Expectations from Core/Sources/InkFlowRime/EnginePersonalLearning.swift and
/// macOS/Tests/PersonalDataTests.swift: management at the idle boundary, portable
/// backup/import on isolated user directories, and rollback on a rejected snapshot.
#[test]
fn swift_personal_learning_and_data() {
    use inkflow_rime::engine::{LearningError, LearningSource};
    use inkflow_rime::personal::{self, Backup, DICTIONARIES, PersonalError};
    let Some((resources, _runtime)) = resources() else {
        println!("SKIP personal data parity: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let root = scratch("personal-data");
    let source = root.join("source");
    let trained = engine(&resources, &source);
    let session = configured(&trained);
    assert_eq!(
        trained.personal_learning_entries().unwrap(),
        vec![],
        "a fresh user directory has no learning"
    );
    for _ in 0..5 {
        type_keys(&session, "email");
        let page = session.snapshot().unwrap();
        let index = page
            .texts()
            .iter()
            .position(|c| *c == "email")
            .expect("email candidate");
        session.select(&page, index).unwrap();
        assert_eq!(session.take_commit().unwrap(), "email");
    }
    type_keys(&session, "emai");
    assert_eq!(
        trained.personal_learning_entries(),
        Err(LearningError::Busy),
        "composition blocks management"
    );
    session.clear().unwrap();
    assert_eq!(
        trained.personal_learning_entries(),
        Err(LearningError::Busy),
        "the native undo window blocks management"
    );
    std::thread::sleep(std::time::Duration::from_secs(4));
    let entries = trained.personal_learning_entries().unwrap();
    let email = entries
        .iter()
        .find(|e| e.source == LearningSource::English && e.code == "email" && e.text == "email")
        .expect("learned email");
    // Rime batches user-dictionary writes per transaction; the newest commit can still be
    // pending until the next transaction or teardown, exactly as with the Swift engine.
    assert!(matches!(email.commits, 4 | 5), "{entries:?}");
    let commits = email.commits;
    let undo = trained.delete_personal_learning(email).unwrap();
    assert_eq!(
        trained.delete_personal_learning(email),
        Err(LearningError::Conflict),
        "a stale entry cannot be deleted twice"
    );
    assert!(
        trained
            .personal_learning_entries()
            .unwrap()
            .iter()
            .all(|e| e.code != "email"),
        "deleted learning disappears"
    );
    trained.undo_personal_learning(&undo).unwrap();
    assert_eq!(
        trained.undo_personal_learning(&undo),
        Err(LearningError::Conflict)
    );
    let restored = trained.personal_learning_entries().unwrap();
    // Native restore revives the tombstoned count with one confirmation, as on macOS.
    assert!(
        restored
            .iter()
            .any(|e| e.code == "email" && e.commits >= commits),
        "undo restores the entry: {restored:?}"
    );
    type_keys(&session, "nihao");
    session.key(32, 0).unwrap();
    assert_eq!(session.take_commit().unwrap(), "你好");
    assert_eq!(
        trained.delete_personal_learning(&restored[0]),
        Err(LearningError::Conflict),
        "a commit invalidates captured entries"
    );
    assert_eq!(
        trained.personal_learning_entries(),
        Err(LearningError::Busy),
        "a new commit reopens the undo window"
    );
    std::thread::sleep(std::time::Duration::from_secs(4));
    assert!(trained.personal_learning_entries().is_ok());
    drop(session);
    drop(trained);

    // Export the trained directory and import it into a fresh one.
    fs::remove_dir_all(source.join("inkflow_voice_alias.userdb")).unwrap();
    let dictionaries = personal::export(&source).unwrap();
    assert!(
        dictionaries["pinyin_simp"].is_some() && dictionaries["inkflow_shared_english"].is_some()
    );
    assert_eq!(
        dictionaries["inkflow_voice_alias"], None,
        "an absent dictionary exports as absent"
    );
    let backup = Backup {
        rime: personal::RIME_VERSION.into(),
        candidate_count: 7,
        input: InputPreferences::default(),
        phrases: vec![inkflow_rime::phrases::CustomPhrase::validated("p", "dz", "地址").unwrap()],
        dictionaries,
        unsupported: vec![],
    };
    let document = backup.to_json().unwrap();
    let parsed = Backup::from_json(&document).unwrap();
    assert!(
        parsed.candidate_count == 7
            && parsed.phrases == backup.phrases
            && parsed.dictionaries == backup.dictionaries
    );
    let target = root.join("target");
    fs::create_dir_all(&target).unwrap();
    personal::import(&target, &parsed.dictionaries).unwrap();
    assert!(
        target.join("pinyin_simp.userdb").is_dir()
            && !target.join("inkflow_voice_alias.userdb").exists()
    );
    {
        let engine = engine(&resources, &target);
        let session = configured(&engine);
        session
            .set_configuration(parsed.candidate_count, &parsed.phrases, Some(&parsed.input))
            .unwrap();
        let imported = engine.personal_learning_entries().unwrap();
        assert!(
            imported.iter().any(|e| e.source == LearningSource::English
                && e.code == "email"
                && e.commits >= commits),
            "English learning survives import: {imported:?}"
        );
        type_keys(&session, "dz");
        assert_eq!(
            texts(&session)[0],
            "地址",
            "imported phrases apply through settings"
        );
        session.clear().unwrap();
        assert_eq!(
            personal::export(&target).unwrap_err().to_string(),
            PersonalError::EngineActive.to_string(),
            "personal data never runs beside a live engine"
        );
    }
    assert_eq!(
        personal::export(&target).unwrap()["inkflow_shared_english"],
        parsed.dictionaries["inkflow_shared_english"],
        "import preserves the snapshot rows"
    );

    // A macOS-format document with synthetic rows restores into existing data, and a rejected
    // snapshot leaves the originals in place.
    let synthetic = |name: &str, row: &str| {
        format!(
            "# Rime user dictionary\n#@/db_name\t{name}\n#@/db_type\tuserdb\n#@/rime_version\t1.17.0\n#@/user_id\tsynthetic-source\n#@/tick\t99\n{row}\tc=7 d=0.123456789 t=42\nce shi \t测试\tc=-3 d=0.0000123 t=17\n"
        )
    };
    let mut macos: serde_json::Map<String, Value> = serde_json::from_slice(&document).unwrap();
    macos["dictionaries"] = json!({
        "pinyin_simp": synthetic("pinyin_simp", "ni hao \t你好"),
        "inkflow_shared_english": synthetic("inkflow_shared_english", "backupword \tBackupWord"),
        "inkflow_voice_alias": synthetic("inkflow_voice_alias", "beifen \t备份别名"),
    });
    macos["settings"]["shortcuts"]["inputMode"] =
        json!({"keyCode": 60, "modifierBits": 131072, "keyLabel": "右 Shift"});
    let restored = Backup::from_json(&serde_json::to_vec(&macos).unwrap()).unwrap();
    assert_eq!(
        restored.unsupported,
        [
            "settings.integers.fontSize",
            "settings.integers.thunderMode",
            "settings.integers.vertical",
            "settings.shortcuts"
        ]
    );
    personal::import(&target, &restored.dictionaries).unwrap();
    {
        let engine = engine(&resources, &target);
        let _session = configured(&engine);
        let learned = engine.personal_learning_entries().unwrap();
        assert!(
            learned.iter().any(|e| e.source == LearningSource::English
                && e.text == "BackupWord"
                && e.commits == 7),
            "English learning survives destination identity: {learned:?}"
        );
        assert!(
            learned.iter().any(|e| e.source == LearningSource::Voice
                && e.text == "备份别名"
                && e.commits == 7),
            "voice learning survives destination identity"
        );
        assert!(
            learned.iter().all(|e| e.code != "email"),
            "import replaces the previous dictionaries"
        );
    }
    let before = personal::export(&target).unwrap();
    let mut broken = restored.dictionaries.clone();
    broken.insert(
        "pinyin_simp".into(),
        Some(synthetic("pinyin_simp", "ni hao \t你好") + "x \tx\tc=NaN d=1 t=1\n"),
    );
    assert!(matches!(
        personal::import(&target, &broken),
        Err(PersonalError::NativeSnapshot)
    ));
    assert_eq!(
        personal::export(&target).unwrap(),
        before,
        "a rejected import leaves every dictionary unchanged"
    );
    for suffix in [
        "malformed\n",
        "x \tx\tc=1 d=inf t=1\n",
        "x \tx\tc=1 d=1 t=-1\n",
        "ni hao \t你好\tc=1 d=1 t=1\n",
        "#unknown\n",
    ] {
        let mut broken = restored.dictionaries.clone();
        broken.insert(
            "pinyin_simp".into(),
            Some(synthetic("pinyin_simp", "ni hao \t你好") + suffix),
        );
        assert!(
            matches!(
                personal::import(&target, &broken),
                Err(PersonalError::NativeSnapshot)
            ),
            "{suffix:?}"
        );
    }
    let mut absent = restored.dictionaries.clone();
    for name in DICTIONARIES {
        absent.insert(name.into(), None);
    }
    personal::import(&target, &absent).unwrap();
    assert!(
        DICTIONARIES
            .iter()
            .all(|name| !target.join(format!("{name}.userdb")).exists()),
        "absence in the backup removes the local dictionaries"
    );
    assert_eq!(personal::export(&target).unwrap(), absent);
    fs::create_dir_all(target.join("PersonalData/transaction/old/pinyin_simp.userdb")).unwrap();
    fs::write(target.join("PersonalData/transaction/journal.json"), r#"{"phase":"applying","originals":{"pinyin_simp":true,"inkflow_shared_english":false,"inkflow_voice_alias":false}}"#).unwrap();
    assert!(matches!(
        personal::import(&target, &absent),
        Err(PersonalError::RecoveryRequired)
    ));
    personal::recover(&target).unwrap();
    assert!(
        target.join("pinyin_simp.userdb").is_dir()
            && !target.join("PersonalData/transaction").exists(),
        "recovery restores the original"
    );
    fs::remove_dir_all(&root).unwrap();
    println!(
        "PASS personal learning and data: idle-boundary management, delete/undo/conflict, export/import on isolated directories, macOS document import with disclosure, rejected snapshots roll back"
    );
}

fn user_dictionary(name: &str, rows: &[(&str, &str, i32)]) -> String {
    let mut text = format!(
        "# Rime user dictionary\n#@/db_name\t{name}\n#@/db_type\tuserdb\n#@/rime_version\t1.17.0\n#@/user_id\tsynthetic-source\n#@/tick\t99\n"
    );
    for (code, word, commits) in rows {
        text += &format!("{code} \t{word}\tc={commits} d=0.5 t=30\n");
    }
    text
}

/// Transitions recorded by the Swift engine in Core/Tests/AIAdoptionLearningTests
/// (`personalManagement`) and macOS/Tests/PersonalDataTests.swift, on the same state: a
/// canonical English record and a voice alias for two spellings of one word. The Swift
/// seeding went through voice-correction learning, which `swift_voice_correction_learning`
/// ports; the rows are restored from a snapshot here.
#[test]
fn swift_personal_learning_management() {
    use inkflow_rime::engine::{LearningEntry, LearningError, LearningSource};
    use inkflow_rime::personal::{self, DICTIONARIES};
    let Some((resources, _runtime)) = resources() else {
        println!("SKIP learning management parity: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let root = scratch("learning-management");
    let user = root.join("user");
    fs::create_dir_all(&user).unwrap();
    let mut seeded: std::collections::BTreeMap<String, Option<String>> = DICTIONARIES
        .iter()
        .map(|name| (name.to_string(), None))
        .collect();
    seeded.insert(
        "inkflow_shared_english".into(),
        Some(user_dictionary(
            "inkflow_shared_english",
            &[("codex", "Codex", 2), ("codex", "CODEX", 1)],
        )),
    );
    seeded.insert(
        "inkflow_voice_alias".into(),
        Some(user_dictionary(
            "inkflow_voice_alias",
            &[("codux", "Codex", 2), ("codux", "CODEX", 1)],
        )),
    );
    personal::import(&user, &seeded).unwrap();

    let engine = engine(&resources, &user);
    let first = configured(&engine);
    let entry = |source, text: &str| -> LearningEntry {
        engine
            .personal_learning_entries()
            .unwrap()
            .into_iter()
            .find(|e| e.source == source && e.text == text)
            .expect("seeded entry")
    };
    let commits = |source, text: &str| entry(source, text).commits;
    let listed = engine.personal_learning_entries().unwrap();
    assert_eq!(
        listed.iter().map(LearningEntry::id).collect::<Vec<_>>(),
        [
            "english\tcodex\tCODEX",
            "english\tcodex\tCodex",
            "voice\tcodux\tCODEX",
            "voice\tcodux\tCodex"
        ],
        "both namespaces, case variants kept apart, sorted by identity"
    );

    // A later learn supersedes a captured entry.
    let stale = entry(LearningSource::English, "Codex");
    let second = configured(&engine);
    assert_eq!(
        engine.delete_personal_learning(&stale),
        Err(LearningError::Conflict)
    );

    // Delete only the exact alias; the canonical record and the other spelling stay.
    let alias = entry(LearningSource::Voice, "Codex");
    let undo = engine.delete_personal_learning(&alias).unwrap();
    let remaining = engine.personal_learning_entries().unwrap();
    assert!(
        remaining
            .iter()
            .all(|e| !(e.source == LearningSource::Voice && e.text == "Codex"))
    );
    assert_eq!(
        remaining.iter().filter(|e| e.text == "CODEX").count(),
        2,
        "the other display identity is unchanged"
    );
    assert_eq!(commits(LearningSource::English, "Codex"), 2);
    // Native undo restores the count with one more confirmation, once.
    engine.undo_personal_learning(&undo).unwrap();
    assert_eq!(commits(LearningSource::Voice, "Codex"), 3);
    assert_eq!(
        engine.undo_personal_learning(&undo),
        Err(LearningError::Conflict)
    );

    // Another session's composition blocks management; the undo stays valid.
    let canonical = engine
        .delete_personal_learning(&entry(LearningSource::English, "Codex"))
        .unwrap();
    type_keys(&second, "codex");
    assert_eq!(
        engine.undo_personal_learning(&canonical),
        Err(LearningError::Busy)
    );
    second.clear().unwrap();
    engine.undo_personal_learning(&canonical).unwrap();
    assert_eq!(commits(LearningSource::English, "Codex"), 3);

    // A learn after a delete obsoletes its undo.
    let obsolete = engine
        .delete_personal_learning(&entry(LearningSource::Voice, "Codex"))
        .unwrap();
    type_keys(&first, "ceshi");
    let page = first.snapshot().unwrap();
    let index = page.texts().iter().position(|c| *c == "测试").unwrap();
    first.select(&page, index).unwrap();
    assert_eq!(first.take_commit().unwrap(), "测试");
    assert_eq!(
        engine.undo_personal_learning(&obsolete),
        Err(LearningError::Conflict)
    );
    assert_eq!(
        engine.personal_learning_entries(),
        Err(LearningError::Busy),
        "the commit opens the native undo window"
    );
    // A rejected management read must not finish Rime's immediate-undo transaction.
    first.key(0xff08, 0).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(4100));
    engine.personal_learning_entries().unwrap();
    type_keys(&first, "ni");
    assert_eq!(
        engine.personal_learning_entries(),
        Err(LearningError::Busy),
        "composition blocks management"
    );
    first.clear().unwrap();

    // Invalidation supersedes captured entries.
    let captured = entry(LearningSource::English, "CODEX");
    engine.invalidate_personal_learning().unwrap();
    assert_eq!(
        engine.delete_personal_learning(&captured),
        Err(LearningError::Conflict)
    );
    drop((first, second));
    drop(engine);
    fs::remove_dir_all(&root).unwrap();
    println!(
        "PASS Swift personal learning management: identity, delete/undo, stale and obsolete conflicts, busy boundaries, invalidation"
    );
}

/// The user directory below is what the Swift engine's own personal-data worker restored
/// from the synthetic snapshots of macOS/Tests/PersonalDataTests.swift (the app's
/// InkFlowDictionaryWorker, 0.6.2 build 164); the `.userdb.txt` files are that worker's
/// export of the same databases. The Rust export must write the same bytes.
#[test]
fn swift_personal_snapshot_export() {
    use inkflow_rime::personal::{self, DICTIONARIES};
    let _runtime = RUNTIME.lock().unwrap_or_else(|e| e.into_inner());
    let recorded = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/swift-user");
    let root = scratch("swift-export");
    let user = root.join("user");
    fs::create_dir_all(&user).unwrap();
    for name in DICTIONARIES {
        copy_tree(
            &recorded.join(format!("{name}.userdb")),
            &user.join(format!("{name}.userdb")),
        );
    }
    let exported = personal::export(&user).unwrap();
    for name in DICTIONARIES {
        let swift = fs::read_to_string(recorded.join(format!("{name}.userdb.txt"))).unwrap();
        assert_eq!(
            exported[name].as_deref(),
            Some(swift.as_str()),
            "{name}: the Swift worker's export of the same database"
        );
    }
    // The export is a complete backup: macOS-format document, parsed and imported again.
    let backup = personal::Backup {
        rime: personal::RIME_VERSION.into(),
        candidate_count: 5,
        input: InputPreferences::default(),
        phrases: vec![],
        dictionaries: exported.clone(),
        unsupported: vec![],
    };
    let parsed = personal::Backup::from_json(&backup.to_json().unwrap()).unwrap();
    let target = root.join("target");
    personal::import(&target, &parsed.dictionaries).unwrap();
    assert_eq!(personal::export(&target).unwrap(), exported);
    fs::remove_dir_all(&root).unwrap();
    println!("PASS Swift personal snapshot export: byte-identical to the recorded worker output");
}

/// The channel round trip `IFEngine.call` makes, with the capacities the Swift callers pass.
fn call(session: &InputSession, op: &str, fields: &[&str], capacity: usize) -> Option<Reply> {
    session.call(op, fields, capacity).unwrap()
}

fn status(session: &InputSession, op: &str, fields: &[&str]) -> String {
    call(session, op, fields, 4096)
        .unwrap_or_else(|| panic!("no reply to {op}"))
        .status
}

/// `IFEngine.aiInputIdentity`: the raw input, the raw-input caret and the preedit before the
/// selection, read from one snapshot.
fn ai_identity(session: &InputSession) -> Option<(String, usize, String)> {
    let snapshot = session.snapshot().unwrap();
    (!snapshot.input.is_empty()).then(|| {
        (
            snapshot.input.clone(),
            snapshot.raw_caret_bytes,
            snapshot.preedit[..snapshot.selection_bytes.start].to_owned(),
        )
    })
}

/// Type `input`, list every candidate and clear, as the Swift tests' `candidates` helper does.
fn candidates_of(session: &InputSession, input: &str) -> Vec<String> {
    session.clear().unwrap();
    type_keys(session, input);
    let all = all_candidates(session);
    session.clear().unwrap();
    all
}

/// Type `input`, commit its first candidate with Space and, as the Swift tests' `ordinaryCommit`
/// does, end the undo window with Tab or undo the commit with Backspace.
fn ordinary_commit(session: &InputSession, input: &str, expected: &str, undo: bool) {
    session.clear().unwrap();
    type_keys(session, input);
    session.key(32, 0).unwrap();
    assert_eq!(session.take_commit().unwrap(), expected);
    session.key(if undo { 0xff08 } else { 0xff09 }, 0).unwrap();
}

fn choose(session: &InputSession, input: &str, target: &str) {
    session.clear().unwrap();
    type_keys(session, input);
    let page = session.snapshot().unwrap();
    let index = page
        .texts()
        .iter()
        .position(|c| *c == target)
        .unwrap_or_else(|| panic!("missing {target} for {input}"));
    session.select(&page, index).unwrap();
    assert_eq!(session.take_commit().unwrap(), target);
}

/// The reading `AIPronunciation.resolve` accepts from `ai_readings` rows: one phrase reading
/// whose syllable count is the text's.
fn phrase_readings(body: &str, text: &str) -> Vec<String> {
    body.lines()
        .filter_map(|line| line.strip_prefix("P\t"))
        .filter(|code| code.split(' ').count() == text.chars().count())
        .map(str::to_owned)
        .collect()
}

fn character_readings(body: &str, character: &str) -> Vec<String> {
    body.lines()
        .filter_map(|line| line.strip_prefix(&format!("C\t{character}\t")))
        .flat_map(|codes| codes.split(' ').map(str::to_owned).collect::<Vec<_>>())
        .collect()
}

/// Core/Tests/InkFlowEngineTestSupport/EngineRegression.swift `propertyChannel`: the live
/// dispatch half. Version 1 framing is covered by the unit tests of `src/channel.rs`.
#[test]
fn swift_property_channel() {
    let Some((resources, _runtime)) = resources() else {
        println!("SKIP property channel parity: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let user = scratch("property-channel");
    let engine = engine(&resources, &user);
    let session = configured(&engine);
    assert_eq!(
        call(&session, "learning_invalidate", &[], 512),
        Some(Reply {
            status: "ok".into(),
            body: String::new()
        }),
        "a live module answers a version 1 request"
    );
    assert_eq!(
        call(&session, "no_such_operation", &[], 512),
        None,
        "no module answers an unknown operation"
    );
    assert_eq!(
        status(&session, "ai_learning", &["bad code", "你好"]),
        "failed",
        "modules validate their own fields"
    );
    assert_eq!(
        status(&session, "input_coverage", &["0", "3"]),
        "failed",
        "input coverage without a composition fails closed"
    );
    for (op, fields) in [
        ("", vec!["a"]),
        ("Input", vec![]),
        ("ai-learning", vec![]),
        ("ai_learning", vec!["a\tb"]),
        ("ai_learning", vec!["a\nb"]),
        ("ai_learning", vec!["a\rb"]),
    ] {
        assert_eq!(
            call(&session, op, &fields, 512),
            None,
            "framing characters and bad operation names fail closed: {op} {fields:?}"
        );
    }
    assert_eq!(
        call(&session, "voice_aliases", &[], 8),
        None,
        "a reply that does not fit is no reply"
    );
    drop(session);
    drop(engine);
    fs::remove_dir_all(&user).unwrap();
    println!("PASS Swift property channel: live dispatch, field validation, bounded replies");
}

/// Core/Tests/AIAdoptionLearningTests `voiceCorrectionLearning` (write, read, clear and
/// cleared-read scenarios) and the start of `personalManagement`, through the channel
/// operations `IFEngine.learnVoiceCorrection`, `readVoiceAliases` and
/// `clearPersonalEnglishLearning` run. The facade keeps the code checks and idle gating.
#[test]
fn swift_voice_correction_learning() {
    use inkflow_rime::engine::{LearningError, LearningSource};
    use inkflow_rime::ranking::PersonalSource;
    let Some((resources, _runtime)) = resources() else {
        println!("SKIP voice correction parity: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let aliases = |session: &InputSession| {
        let reply = call(session, "voice_aliases", &[], 64 * 1024 + 64).expect("alias reply");
        assert_eq!(reply.status, "ok");
        reply.body
    };
    let learn = |session: &InputSession, source: &str, canonical: &str, text: &str| {
        status(session, "voice_learning", &[source, canonical, text]) == "ok"
    };
    let root = scratch("voice-correction");

    // voice-correction-write
    let user = root.join("user");
    {
        let engine = engine(&resources, &user);
        let session = configured(&engine);
        assert_eq!(
            candidates_of(&session, "nihao")[0],
            "你好",
            "voice learning preserves the Chinese baseline"
        );
        assert!(
            learn(&session, "codux", "codex", "Codex"),
            "one attributable correction updates both Rime namespaces"
        );
        assert!(
            !learn(&session, "co dux", "codex", "Codex"),
            "malformed source aliases fail closed"
        );
        assert_eq!(
            aliases(&session),
            "codux\tCodex\t1\n",
            "the exact voice-only alias is readable with its native count"
        );
        assert!(
            candidates_of(&session, "codex").contains(&"Codex".to_string()),
            "the canonical display is persisted to shared keyboard English"
        );
        type_keys(&session, "codex");
        let shown = session.snapshot().unwrap();
        let personal = shown.candidates.iter().find(|c| c.text == "Codex").unwrap();
        assert_eq!(
            (personal.personal_source(), personal.consumed_input()),
            (Some(PersonalSource::ExactEnglish), Some(0..5)),
            "canonical personal exact evidence reaches quality capture without dictionary text metadata"
        );
        session.clear().unwrap();
        assert!(
            !candidates_of(&session, "codux").contains(&"Codex".to_string()),
            "a voice-only alias never leaks into keyboard completion"
        );
        let files: Vec<_> = fs::read_dir(&user)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            files.contains(&"inkflow_shared_english.userdb".to_string())
                && files.contains(&"inkflow_voice_alias.userdb".to_string()),
            "voice correction uses the two named Rime user dictionaries: {files:?}"
        );
    }
    // voice-correction-read
    {
        let engine = engine(&resources, &user);
        let session = configured(&engine);
        assert_eq!(
            aliases(&session),
            "codux\tCodex\t1\n",
            "restarted voice aliases keep their native count"
        );
        assert!(candidates_of(&session, "codex").contains(&"Codex".to_string()));
        assert!(!candidates_of(&session, "codux").contains(&"Codex".to_string()));
    }

    // voice-correction-clear, then cleared-read
    let user = root.join("clear");
    {
        let engine = engine(&resources, &user);
        let session = configured(&engine);
        assert!(learn(&session, "codux", "codex", "Codex"));
        assert!(
            learn(&session, "codux", "codex", "Codex"),
            "reset fixture retains arbitrary prior commit counts"
        );
        assert_eq!(aliases(&session), "codux\tCodex\t2\n");
        choose(&session, "ceshi", "测试");
        session.key(0xff09, 0).unwrap();
        assert_eq!(
            call(&session, "clear_english_learning", &[], 512).map(|r| r.status),
            Some("ok".into()),
            "explicit lifecycle action clears both English namespaces"
        );
        assert_eq!(
            aliases(&session),
            "",
            "voice alias namespace is empty immediately after clear"
        );
        assert!(
            candidates_of(&session, "world").contains(&"world".to_string()),
            "reset never deletes the public English dictionary"
        );
    }
    {
        let engine = engine(&resources, &user);
        let session = configured(&engine);
        assert_eq!(
            aliases(&session),
            "",
            "cleared voice aliases stay empty after restart"
        );
        assert_eq!(
            candidates_of(&session, "ceshi")[0],
            "测试",
            "clearing English learning preserves Chinese userdb"
        );
    }

    // personalManagement: every learn and clear supersedes captured listings and undo tokens. The
    // entries below are never touched by the learn that follows their capture, so the learning
    // revision alone decides; Swift's own flow also changed the captured entry's count.
    let user = root.join("management");
    {
        let engine = engine(&resources, &user);
        let first = configured(&engine);
        assert_eq!(
            engine.personal_learning_entries(),
            Ok(vec![]),
            "empty available management snapshot"
        );
        assert!(learn(&first, "codux", "codex", "Codex"), "seed learning");
        assert!(
            learn(&first, "codux", "codex", "CODEX"),
            "distinct case identity"
        );
        let entry = |source, text: &str| {
            engine
                .personal_learning_entries()
                .unwrap()
                .into_iter()
                .find(|e| e.source == source && e.text == text)
                .expect("learned entry")
        };
        let stale = entry(LearningSource::English, "CODEX");
        assert!(learn(&first, "codux", "codex", "Codex"), "repeat learning");
        assert_eq!(
            engine.delete_personal_learning(&stale),
            Err(LearningError::Conflict),
            "a learn supersedes a captured entry it did not touch"
        );
        assert_eq!(entry(LearningSource::English, "Codex").commits, 2);
        assert_eq!(entry(LearningSource::Voice, "Codex").commits, 2);
        assert_eq!(entry(LearningSource::Voice, "CODEX").commits, 1);
        let obsolete = engine
            .delete_personal_learning(&entry(LearningSource::Voice, "CODEX"))
            .unwrap();
        assert!(
            learn(&first, "codux", "codex", "Codex"),
            "learn after a deletion"
        );
        assert_eq!(
            engine.undo_personal_learning(&obsolete),
            Err(LearningError::Conflict),
            "a learn after a delete obsoletes its undo"
        );
        let undo = engine
            .delete_personal_learning(&entry(LearningSource::English, "CODEX"))
            .unwrap();
        assert_eq!(
            call(&first, "clear_english_learning", &[], 512).map(|r| r.status),
            Some("ok".into())
        );
        assert_eq!(
            engine.undo_personal_learning(&undo),
            Err(LearningError::Conflict),
            "a clear supersedes an undo token that the cleared counts would accept"
        );
        assert_eq!(engine.personal_learning_entries(), Ok(vec![]));
        // A refused operation changes nothing.
        assert!(learn(&first, "codux", "codex", "Codex"));
        let listing = engine.personal_learning_entries().unwrap();
        assert!(!learn(&first, "co dux", "codex", "Codex"));
        assert_eq!(
            engine.personal_learning_entries().unwrap(),
            listing,
            "a refused learn leaves the listing as it was"
        );
        engine.delete_personal_learning(&listing[0]).unwrap();
    }
    fs::remove_dir_all(&root).unwrap();
    println!(
        "PASS Swift voice correction learning: alias counts, evidence, clear, restart, listings and undo tokens superseded"
    );
}

/// Core/Tests/AIAdoptionLearningTests main scenario (write and restart): the AI input identity,
/// native readings, the unobserved clear before an adoption, and one adoption improving the
/// ordinary rank of a novel word. The pronunciation resolver stays in Swift: the codes below are
/// the ones it resolves for the same typed inputs.
#[test]
fn swift_ai_adoption_learning() {
    let Some((resources, _runtime)) = resources() else {
        println!("SKIP AI adoption parity: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let reverse = resources
        .join("prepared/cache/pinyin_simp.reverse.bin")
        .to_string_lossy()
        .into_owned();
    let readings = |session: &InputSession, input: &str, text: &str| {
        let reply = call(session, "ai_readings", &[&reverse, input, text], 128 * 1024)
            .expect("readings reply");
        assert_eq!(reply.status, "ok");
        reply.body
    };
    let user = scratch("ai-adoption");
    let words = [
        ("xingmoliang", "星墨量"),
        ("xingmolan", "星墨蓝"),
        ("xingmohai", "星墨海"),
        ("xingmohao", "星墨好"),
    ];
    let typed = [
        ("xingmoliang", "xing mo liang "),
        ("xml", "xing mo lan "),
        ("xingmoha", "xing mo hai "),
        ("xingmohoa", "xing mo hao "),
    ];
    let existing = {
        let observed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let engine = engine(&resources, &user);
        let count = observed.clone();
        engine.set_observer(Some(Arc::new(move |_| {
            count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        })));
        let session = configured(&engine);
        let lexicon = |session: &InputSession| {
            call(session, "voice_lexicon", &[], 512 * 1024 + 64).expect("lexicon reply")
        };
        assert_eq!(
            lexicon(&session).status,
            "ok",
            "bundled Lua supports bounded user dictionary lookup"
        );

        // With AI never requested, its bridge must not change ordinary undo.
        ordinary_commit(&session, "nihao", "你好", true);

        // AIHeadlessPipelineTests and AIControllerNativeTests: paging and highlighting keep the
        // request identity, and a partial selection adds the selected prefix to it.
        type_keys(&session, "nihao");
        let identity = ai_identity(&session);
        assert_eq!(identity, Some(("nihao".into(), 5, String::new())));
        session.key(0xff56, 0).unwrap();
        let paged = session.snapshot().unwrap();
        assert_ne!(paged.page, 0, "page down goes through actual Rime");
        session.highlight(&paged, 2).unwrap();
        assert_eq!(
            ai_identity(&session),
            identity,
            "paging and highlighting retain request identity"
        );
        session.key(0xff55, 0).unwrap();
        let first = session.snapshot().unwrap();
        let partial = first.texts().iter().position(|c| *c == "你").unwrap();
        session.select(&first, partial).unwrap();
        let (raw, _, prefix) = ai_identity(&session).unwrap();
        assert_eq!(
            (raw.as_str(), prefix.as_str()),
            ("nihao", "你"),
            "a partial Rime selection is the selected prefix"
        );
        session.clear().unwrap();

        type_keys(&session, "yh");
        assert_eq!(ai_identity(&session), Some(("yh".into(), 2, String::new())));
        let bank = readings(&session, "yh", "银行");
        assert!(
            phrase_readings(&bank, "银行").contains(&"yin hang".to_string()),
            "existing native phrase resolves abbreviated polyphone: {bank:?}"
        );
        session.clear().unwrap();
        type_keys(&session, "h");
        let row = readings(&session, "h", "行");
        assert!(
            character_readings(&row, "行")
                .iter()
                .filter(|code| code.starts_with('h'))
                .count()
                > 1,
            "unification must not hide alternate readings: {row:?}"
        );
        let observed_before = observed.load(std::sync::atomic::Ordering::SeqCst);
        session.clear_unobserved().unwrap();
        assert_eq!(
            observed.load(std::sync::atomic::Ordering::SeqCst),
            observed_before,
            "consumed adoption clears without a quality record"
        );
        assert!(
            session.snapshot().unwrap().preedit.is_empty()
                && session.take_commit().unwrap().is_empty(),
            "preparing AI delivery never commits a default candidate"
        );

        let dictionary =
            fs::read_to_string(resources.join("shared/pinyin_simp.dict.yaml")).unwrap();
        for (_, word) in words {
            assert!(
                !dictionary.contains(&format!("\n{word}\t")),
                "fixture must be novel"
            );
        }
        for (index, (full, word)) in words.iter().enumerate() {
            assert_ne!(
                candidates_of(&session, full)[0],
                *word,
                "novel fixture ranks first"
            );
            let (input, code) = typed[index];
            type_keys(&session, input);
            let (raw, _, prefix) = ai_identity(&session).unwrap();
            assert_eq!((raw.as_str(), prefix.as_str()), (input, ""));
            if index == 1 {
                let mut off = InputPreferences::default();
                off = off.with(inkflow_rime::preferences::InputOption::Abbreviation, false);
                session.set_configuration(9, &[], Some(&off)).unwrap();
                assert_eq!(
                    session
                        .input_preferences()
                        .unwrap()
                        .get(inkflow_rime::preferences::InputOption::Abbreviation),
                    true,
                    "active composition retains its own preference snapshot"
                );
            }
            let readings = readings(&session, input, word);
            assert!(
                phrase_readings(&readings, word).len() <= 1,
                "the typed input has at most one phrase reading to resolve: {readings:?}"
            );
            session.clear_unobserved().unwrap();
            assert_eq!(
                status(&session, "ai_learning", &[code, word]),
                "ok",
                "learn {input} → {word}"
            );
            assert!(
                session.snapshot().unwrap().preedit.is_empty()
                    && session.take_commit().unwrap().is_empty(),
                "consumed adoption clears without an ordinary commit before platform insertion"
            );
            session
                .set_configuration(9, &[], Some(&InputPreferences::default()))
                .unwrap();
            assert_eq!(
                candidates_of(&session, full)[0],
                *word,
                "one adoption improves ordinary rank {word}"
            );
        }
        // Whole original input includes the selected prefix: no suffix-only code is registered.
        assert_eq!(
            status(&session, "ai_learning", &["xing mo liang ", "星墨量"]),
            "ok"
        );
        for refused in [
            ["xing mo liang", "星墨量"],
            ["Xing mo liang ", "星墨量"],
            ["xing mo liang ", ""],
        ] {
            assert_eq!(
                status(&session, "ai_learning", &refused),
                "failed",
                "{refused:?}"
            );
        }
        let before = candidates_of(&session, "zhangwei");
        let existing = before
            .iter()
            .skip(1)
            .find(|c| c.chars().count() == 2)
            .expect("existing-word fixture")
            .clone();
        let body = readings(&session, "zhangwei", &existing);
        let codes = phrase_readings(&body, &existing);
        let code = if codes.len() == 1 {
            codes[0].clone()
        } else {
            existing
                .chars()
                .map(|c| {
                    let choices = character_readings(&body, &c.to_string());
                    assert_eq!(choices.len(), 1, "unambiguous character {c}: {body:?}");
                    choices[0].clone()
                })
                .collect::<Vec<_>>()
                .join(" ")
        };
        assert_eq!(
            status(&session, "ai_learning", &[&format!("{code} "), &existing]),
            "ok"
        );
        assert_eq!(
            candidates_of(&session, "zhangwei")[0],
            existing,
            "existing-word adoption improves preference"
        );
        std::thread::sleep(std::time::Duration::from_millis(4100));
        let voice = lexicon(&session);
        assert!(
            voice
                .body
                .lines()
                .any(|row| row == "星墨海\txing mo hai \t1"),
            "voice reads the ordinary learned entry and canonical code: {:?}",
            voice.body
        );
        // Ordinary undo must also survive prior lookup and adoption callbacks.
        ordinary_commit(&session, "zaijian", "再见", true);
        ordinary_commit(&session, "ceshi", "测试", false);
        existing
    };

    // Restart: the learned words recall first, and no unrelated user dictionary appears.
    let engine = engine(&resources, &user);
    let session = configured(&engine);
    for (full, word) in words {
        assert_eq!(
            candidates_of(&session, full)[0],
            word,
            "restart ordinary recall {word}"
        );
    }
    assert_eq!(
        candidates_of(&session, "zhangwei")[0],
        existing,
        "existing preference persists"
    );
    let files: Vec<_> = fs::read_dir(&user)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".userdb"))
        .collect();
    assert!(
        files.contains(&"pinyin_simp.userdb".to_string())
            && files.contains(&"inkflow_shared_english.userdb".to_string()),
        "{files:?}"
    );
    assert!(
        files
            .iter()
            .all(|name| name == "pinyin_simp.userdb" || name == "inkflow_shared_english.userdb"),
        "AI adoption does not create unrelated user dictionaries: {files:?}"
    );
    drop((session, engine));

    // The canonical userdb export of macOS/scripts/test-ai-learning.sh: only correct full codes
    // with exact adoption counts, no raw typo or abbreviation, and the undone commits absent.
    let exported = inkflow_rime::personal::export(&user).unwrap();
    let rows: Vec<(String, String, i64)> = exported["pinyin_simp"]
        .as_deref()
        .unwrap()
        .lines()
        .filter(|line| !line.starts_with('#'))
        .filter_map(|line| {
            let fields: Vec<_> = line.split('\t').collect();
            let count = fields
                .get(2)?
                .strip_prefix("c=")?
                .split(' ')
                .next()?
                .parse()
                .ok()?;
            Some((fields[1].to_owned(), fields[0].trim_end().to_owned(), count))
        })
        .collect();
    let count = |text: &str| {
        rows.iter()
            .find(|row| row.0 == text)
            .map(|row| (row.1.clone(), row.2))
    };
    for (text, code, commits) in [
        ("星墨量", "xing mo liang", 2),
        ("星墨蓝", "xing mo lan", 1),
        ("星墨海", "xing mo hai", 1),
        ("星墨好", "xing mo hao", 1),
        ("测试", "ce shi", 1),
    ] {
        assert_eq!(count(text), Some((code.to_owned(), commits)), "{text}");
    }
    for text in ["你好", "再见"] {
        assert!(
            count(text).is_none_or(|(_, commits)| commits <= 0),
            "{text}: an immediate Backspace undoes the commit before and after AI callbacks"
        );
    }
    assert!(
        rows.iter()
            .all(|row| !row.1.contains("xml") && !row.1.contains("xingmoha")),
        "no raw typo or abbreviation is registered: {rows:?}"
    );
    fs::remove_dir_all(&user).unwrap();
    println!(
        "PASS Swift AI adoption learning: input identity, readings, unobserved clear, novel-word adoption, existing-word preference, restart, canonical userdb export"
    );
}

/// What `IFEngine.qualitySnapshot()` records for the displayed page, from the Rust snapshot:
/// the raw input and its caret, the selected prefix, and per displayed candidate the native
/// index and rank and the personal-learning source with its consumed input range.
fn quality_evidence(session: &InputSession, label: &str) -> Value {
    use inkflow_rime::ranking::PersonalSource;
    let shown = session.snapshot().unwrap();
    let size = session.candidate_count();
    let page = usize::try_from(shown.page).unwrap();
    let candidates: Vec<Value> = shown
        .candidates
        .iter()
        .enumerate()
        .map(|(display, candidate)| {
            let consumed = candidate.consumed_input();
            json!({
                "text": candidate.text,
                "displayIndex": display,
                "displayRank": page * size + display + 1,
                "nativeIndex": candidate.native_index,
                "nativeRank": candidate.native_rank,
                "source": candidate.personal_source().map(|source| match source {
                    PersonalSource::ExactEnglish => "personal_exact_english",
                    PersonalSource::ExactMixed => "personal_exact_mixed",
                }),
                "consumedInputStart": consumed.clone().map(|range| range.start),
                "consumedInputEnd": consumed.map(|range| range.end),
            })
        })
        .collect();
    json!({
        "label": label,
        "rawInput": shown.input,
        "caret": shown.raw_caret_bytes,
        "selectedPrefix": &shown.preedit[..shown.selection_bytes.start],
        "page": shown.page,
        "pageSize": size,
        "highlightedDisplayIndex": shown.highlighted,
        "candidates": candidates,
    })
}

/// The quality evidence of `fixtures/quality-evidence-cases.json` against the recording of the
/// Swift engine's `qualitySnapshot()` for the same steps (`quality-evidence-reference.sh`, at the
/// revision named in `fixtures/quality-evidence.json`): raw input and caret, selected prefix, native
/// index and rank, and the personal-learning source with its consumed input span, for every
/// displayed candidate.
#[test]
fn swift_quality_evidence() {
    use inkflow_rime::phrases::CustomPhrase;
    let Some((resources, _runtime)) = resources() else {
        println!("SKIP quality evidence parity: INKFLOW_PORTABLE_RESOURCES is not set");
        return;
    };
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures");
    let read = |name: &str| -> Value {
        serde_json::from_str(&fs::read_to_string(fixtures.join(name)).unwrap()).unwrap()
    };
    let spec = read("quality-evidence-cases.json");
    let recorded = read("quality-evidence.json");
    let count = spec["candidateCount"].as_u64().unwrap() as usize;
    assert_eq!(count, 9);
    let user = scratch("quality-evidence");
    let engine = engine(&resources, &user);
    let session = configured(&engine);
    // Seeds are voice corrections, which write the shared English and voice-alias memories.
    for seed in spec["seeds"].as_array().unwrap() {
        let (source, text) = (seed[0].as_str().unwrap(), seed[1].as_str().unwrap());
        assert_eq!(
            status(
                &session,
                "voice_learning",
                &[source, &text.to_lowercase(), text]
            ),
            "ok",
            "seed {seed}"
        );
    }
    let mut compared = 0;
    let (mut english, mut mixed, mut reordered, mut later_page) = (0, 0, 0, 0);
    let mut mismatches = Vec::new();
    for item in spec["cases"].as_array().unwrap() {
        let name = item["name"].as_str().unwrap();
        session.clear().unwrap();
        session.set_preceding_text("").unwrap();
        let mut records = Vec::new();
        for step in item["steps"].as_array().unwrap() {
            if let Some(text) = step["type"].as_str() {
                type_keys(&session, text);
            } else if let Some(key) = step["key"].as_i64() {
                for _ in 0..step["repeat"].as_u64().unwrap_or(1) {
                    session.key(key as i32, 0).unwrap();
                }
            } else if let Some(context) = step["preceding"].as_str() {
                session.set_preceding_text(context).unwrap();
            } else if step["clear"].is_boolean() {
                session.clear().unwrap();
            } else if let Some(text) = step["select"].as_str() {
                let page = session.snapshot().unwrap();
                let index = page.texts().iter().position(|c| *c == text).unwrap();
                session.select(&page, index).unwrap();
            } else if let Some(index) = step["highlight"].as_u64() {
                let page = session.snapshot().unwrap();
                session.highlight(&page, index as usize).unwrap();
            } else if let Some(delta) = step["page"].as_i64() {
                session
                    .key(if delta > 0 { 0xff56 } else { 0xff55 }, 0)
                    .unwrap();
            } else if let Some(phrases) = step["phrases"].as_array() {
                let phrases: Vec<CustomPhrase> = phrases
                    .iter()
                    .enumerate()
                    .map(|(n, p)| {
                        CustomPhrase::validated(
                            &format!("phrase-{n}"),
                            p[0].as_str().unwrap(),
                            p[1].as_str().unwrap(),
                        )
                        .unwrap()
                    })
                    .collect();
                session
                    .set_configuration(count, &phrases, Some(&InputPreferences::default()))
                    .unwrap();
                assert_eq!(session.configuration_error(), None);
            } else if let Some(label) = step["record"].as_str() {
                records.push(quality_evidence(&session, label));
            } else {
                panic!("unknown step {step}");
            }
        }
        session.clear().unwrap();
        let expected = recorded["cases"][name].as_array().expect(name);
        assert_eq!(records.len(), expected.len(), "{name}: records");
        for (actual, swift) in records.iter().zip(expected) {
            compared += 1;
            if actual != swift {
                mismatches.push(format!(
                    "{name} / {}:\n  swift: {swift}\n  rust:  {actual}",
                    swift["label"]
                ));
            }
            for candidate in actual["candidates"].as_array().unwrap() {
                match candidate["source"].as_str() {
                    Some("personal_exact_english") => english += 1,
                    Some("personal_exact_mixed") => mixed += 1,
                    _ => {}
                }
                reordered += usize::from(candidate["nativeIndex"] != candidate["displayIndex"]);
                later_page += usize::from(candidate["nativeRank"].as_u64().unwrap() > count as u64);
            }
        }
    }
    drop((session, engine));
    fs::remove_dir_all(&user).unwrap();
    assert!(
        mismatches.is_empty(),
        "quality evidence differs from the Swift recording ({} of {compared}):\n{}",
        mismatches.len(),
        mismatches.join("\n")
    );
    // The corpus must keep exercising every kind of evidence the recorder reads.
    assert!(
        english > 0 && mixed > 0 && reordered > 0 && later_page > 0,
        "english {english}, mixed {mixed}, reordered {reordered}, later page {later_page}"
    );
    println!(
        "PASS Swift quality evidence: {compared} recorded states, {english} personal English and {mixed} personal mixed candidates, {reordered} reordered, {later_page} on later pages"
    );
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        fs::copy(entry.path(), to.join(entry.file_name())).unwrap();
    }
}
