use inkflow_rime::ranking::{CandidateClass, ContextRanker, Source, parse_metadata};
use serde_json::{Value, json};

#[test]
fn swift_ranking_reference() {
    let cases: Vec<Value> =
        serde_json::from_str(include_str!("../fixtures/ranking-cases.json")).unwrap();
    let expected: Value =
        serde_json::from_str(include_str!("../fixtures/ranking-reference.json")).unwrap();
    assert_eq!(cases.len(), expected.as_object().unwrap().len());
    for case in &cases {
        let candidates: Vec<String> = serde_json::from_value(case["candidates"].clone()).unwrap();
        let metadata = case["metadata"].as_str().and_then(|value| {
            parse_metadata(
                value,
                case["offset"].as_u64().unwrap() as usize,
                candidates.len(),
                case["inputLength"].as_u64().unwrap() as usize,
            )
        });
        let parsed = metadata.as_ref().map(|rows| {
            rows.iter()
                .map(|row| {
                    let class = match row.class {
                        CandidateClass::NonAscii => "n",
                        CandidateClass::Ascii => "a",
                        CandidateClass::Mixed => "m",
                        CandidateClass::Other => "o",
                    };
                    let source = match row.source {
                        Source::Native => "n",
                        Source::English => "e",
                        Source::Mixed => "m",
                        Source::Custom => "c",
                    };
                    format!(
                        "{},{},{},{},{},{}",
                        row.coverage.start,
                        row.coverage.end,
                        class,
                        if row.sentence {
                            3
                        } else if row.lead {
                            2
                        } else if row.pinyin {
                            4
                        } else {
                            u8::from(row.exact)
                        },
                        row.personal,
                        source
                    )
                })
                .collect::<Vec<_>>()
        });
        let ranker = ContextRanker::from_dictionary(case["dictionary"].as_str().unwrap());
        let order = ranker.order(
            &candidates,
            case["context"].as_str().unwrap(),
            metadata.as_deref(),
        );
        assert_eq!(
            json!({"parsed": parsed, "order": order}),
            expected[case["name"].as_str().unwrap()],
            "{}",
            case["name"]
        );
    }
    println!("PASS {} Swift/Rust ranking cases", cases.len());
}

fn parse_rows(rows: &[&str], input_length: usize) -> Option<Vec<inkflow_rime::ranking::Metadata>> {
    let value = format!("0,{};{}", rows.len(), rows.join(";"));
    parse_metadata(&value, 0, rows.len(), input_length)
}

#[test]
fn parse_metadata_reads_candidate_type_and_corrected() {
    let rows = parse_rows(
        &[
            "0,7,n,1,0,n,phrase,0",
            "0,7,n,1,0,n,user_phrase,1",
            "0,3,n,0,0,n,completion,0",
            "0,7,n,3,0,n,sentence,0",
            "0,7,n,0,0,c,user_table,0",
            "0,7,a,1,2,e,english_personal_2,0",
            "0,7,m,1,3,m,mixed_personal_3,0",
        ],
        7,
    )
    .unwrap();
    let facts: Vec<_> = rows
        .iter()
        .map(|row| (row.candidate_type.as_str(), row.corrected))
        .collect();
    assert_eq!(
        facts,
        [
            ("phrase", false),
            ("user_phrase", true),
            ("completion", false),
            ("sentence", false),
            ("user_table", false),
            ("english_personal_2", false),
            ("mixed_personal_3", false),
        ]
    );
    assert_eq!(rows[0].coverage, 0..7);
    assert_eq!(rows[0].source, Source::Native);
    assert!(rows[3].sentence);
    assert_eq!(rows[4].source, Source::Custom);
    assert_eq!(rows[5].personal, 2);
    assert_eq!(rows[5].source, Source::English);
    assert_eq!(rows[6].personal, 3);
    assert_eq!(rows[6].source, Source::Mixed);
    let longest = "a".repeat(32);
    let row = format!("0,7,n,1,0,n,{longest},0");
    assert_eq!(parse_rows(&[&row], 7).unwrap()[0].candidate_type, longest);
}

#[test]
fn parse_metadata_keeps_accepting_six_field_rows() {
    let rows = parse_rows(&["0,7,n,1,0,n", "0,7,a,1,3,e"], 7).unwrap();
    for row in &rows {
        assert_eq!(row.candidate_type, "");
        assert!(!row.corrected);
    }
    assert_eq!(rows[1].personal, 3);
    let mixed = parse_rows(&["0,7,n,1,0,n", "0,7,n,1,0,n,phrase,1"], 7).unwrap();
    assert_eq!(mixed[0].candidate_type, "");
    assert_eq!(mixed[1].candidate_type, "phrase");
    assert!(mixed[1].corrected);
}

#[test]
fn parse_metadata_rejects_bad_candidate_facts() {
    let too_long = format!("0,7,n,1,0,n,{},0", "a".repeat(33));
    let rejected = [
        "0,7,n,1,0,n,phrase",
        "0,7,n,1,0,n,phrase,0,0",
        "0,7,n,1,0,n,phrase,",
        "0,7,n,1,0,n,phrase,2",
        "0,7,n,1,0,n,phrase,01",
        "0,7,n,1,0,n,phrase,true",
        "0,7,n,1,0,n,Phrase,0",
        "0,7,n,1,0,n,user-phrase,0",
        "0,7,n,1,0,n,1phrase,0",
        "0,7,n,1,0,n,user phrase,0",
        "0,7,n,1,0,n,短语,0",
        too_long.as_str(),
    ];
    for row in rejected {
        assert!(parse_rows(&[row], 7).is_none(), "{row}");
    }
    for row in ["0,7,n,1,0,n,phrase,0", "0,7,n,1,0,n,_x9,1", "0,7,n,1,0,n,phrase1,0", "0,7,n,1,0,n,,0"] {
        assert!(parse_rows(&[row], 7).is_some(), "{row}");
    }
}

/// The row an engine keeps as evidence is the row it parsed, whichever form it arrived in.
#[test]
fn metadata_row_round_trips_through_parse_metadata() {
    for row in [
        "0,7,n,1,0,n,phrase,0",
        "0,7,n,1,0,n,user_phrase,1",
        "0,3,n,0,0,n,completion,0",
        "0,7,n,3,0,n,sentence,0",
        "0,7,a,2,0,e,english_exact,0",
        "0,7,m,1,3,m,mixed_personal_3,0",
        "0,7,a,1,2,e,english_personal_2,0",
        "0,7,a,4,2,e,english_personal_2,0",
        "0,7,m,1,0,m,,0",
        "2,7,o,0,0,c,user_table,0",
    ] {
        let parsed = parse_rows(&[row], 7).unwrap();
        assert_eq!(parsed[0].row(), row);
    }
    let legacy = parse_rows(&["0,7,n,1,0,n"], 7).unwrap();
    assert_eq!(legacy[0].row(), "0,7,n,1,0,n,,0");
}

/// Provenance does not reorder Han candidates: the same page orders the same with or without it. Its one use in
/// ranking is the single-syllable test below.
#[test]
fn candidate_facts_do_not_change_the_order() {
    let dictionary = "午餐\twu can\t100\n午参\twu can\t100\n午惨\twu can\t50\n";
    let ranker = ContextRanker::from_dictionary(dictionary);
    let candidates: Vec<String> = ["惨", "餐", "参"].map(String::from).to_vec();
    let order = |rows: [&str; 3]| {
        let metadata = parse_rows(&rows, 7);
        ranker.order(&candidates, "准备午", metadata.as_deref())
    };
    let plain = order(["0,7,n,1,0,n", "0,7,n,1,0,n", "0,7,n,1,0,n"]);
    let facts = order([
        "0,7,n,1,0,n,completion,1",
        "0,7,n,1,0,n,user_phrase,0",
        "0,7,n,1,0,n,sentence,1",
    ]);
    assert_eq!(plain, facts);
}

/// A personal English row the native side marked as complete Pinyin (`exact` = 4) stays behind the best Han
/// candidate in a technical context. The same row without the mark leads (rule 14).
#[test]
fn complete_pinyin_personal_english_stays_behind_han_in_a_technical_context() {
    let ranker = ContextRanker::from_dictionary("");
    let candidates: Vec<String> = ["呢", "ne"].map(String::from).to_vec();
    let order = |english: &str| {
        let metadata = parse_rows(&["0,2,n,1,0,n,phrase,0", english], 2);
        ranker.order(&candidates, "正在使用 Swift ", metadata.as_deref())
    };
    assert_eq!(order("0,2,a,4,1,e,english_personal_1,0"), [0, 1]);
    assert_eq!(order("0,2,a,1,1,e,english_personal_1,0"), [1, 0]);
}

/// A marked row takes the place of exact English behind the Han candidate and keeps its bucket there.
#[test]
fn complete_pinyin_personal_english_keeps_its_bucket_among_english() {
    let ranker = ContextRanker::from_dictionary("");
    let candidates: Vec<String> = ["哦", "Ne", "o", "O"].map(String::from).to_vec();
    let metadata = parse_rows(
        &[
            "0,1,n,1,0,n,phrase,0",
            "0,1,a,1,0,e,english_exact,0",
            "0,1,a,4,1,e,english_personal_1,0",
            "0,1,a,4,3,e,english_personal_3,0",
        ],
        1,
    );
    let order = ranker.order(&candidates, "正在使用 Swift ", metadata.as_deref());
    assert_eq!(order, [0, 3, 2, 1]);
    // Without a technical signal the order is the same: the mark changes nothing there.
    assert_eq!(ranker.order(&candidates, "", metadata.as_deref()), order);
}

/// The mark names a whole-input personal English row; anything else is malformed and returns the page
/// to native order.
#[test]
fn parse_metadata_rejects_a_misplaced_complete_pinyin_mark() {
    for row in [
        "0,7,a,4,0,e,english_exact,0",
        "0,7,m,4,1,m,mixed_personal_1,0",
        "0,7,n,4,0,n,phrase,0",
        "0,7,a,4,1,c,user_table,0",
        "0,7,o,4,1,e,english_personal_1,0",
        "0,3,a,4,1,e,english_personal_1,0",
        "1,7,a,4,1,e,english_personal_1,0",
        "0,7,a,5,1,e,english_personal_1,0",
    ] {
        assert!(parse_rows(&[row], 7).is_none(), "{row}");
    }
    let rows = parse_rows(&["0,7,a,4,2,e,english_personal_2,0"], 7).unwrap();
    assert!(rows[0].exact && rows[0].pinyin && !rows[0].lead && !rows[0].sentence);
}

fn order_of(candidates: &[&str], rows: &[&str], input_length: usize) -> Vec<usize> {
    let candidates: Vec<String> = candidates.iter().map(|text| text.to_string()).collect();
    let metadata = parse_rows(rows, input_length);
    assert!(metadata.is_some());
    ContextRanker::from_dictionary("").order(&candidates, "", metadata.as_deref())
}

/// One complete syllable (an uncorrected single character covers the input): exact English the user never
/// confirmed takes the fourth place, so the homophones stay together in the first three.
#[test]
fn single_syllable_defers_unconfirmed_exact_english_to_the_fourth_place() {
    let page = ["吧", "BA", "把", "八", "爸"];
    let han = "0,2,n,1,0,n,phrase,0";
    let english = "0,2,a,1,0,e,english_exact,0";
    assert_eq!(order_of(&page, &[han, english, han, han, han], 2), [0, 2, 3, 1, 4]);
    // A learned character is the same evidence as a dictionary one.
    let learned = "0,2,n,1,0,n,user_phrase,0";
    assert_eq!(order_of(&page, &[learned, english, han, han, han], 2), [0, 2, 3, 1, 4]);
    // A short page: behind the candidates that are there.
    assert_eq!(order_of(&page[..3], &[han, english, han], 2), [0, 2, 1]);
    // Two unconfirmed spellings keep their order.
    assert_eq!(
        order_of(&["他", "ta", "Ta", "她", "它", "塔"], &[han, english, english, han, han, han], 2),
        [0, 3, 4, 1, 2, 5]
    );
}

/// The rule leaves alone: confirmed English, input that is not one syllable, and pages without the facts.
#[test]
fn single_syllable_rule_keeps_every_other_page() {
    let han = "0,2,n,1,0,n,phrase,0";
    let english = "0,2,a,1,0,e,english_exact,0";
    let same = [0, 1, 2, 3, 4];
    // The user's own word keeps the second place.
    let personal = "0,2,a,1,1,e,english_personal_1,0";
    assert_eq!(order_of(&["吧", "BA", "把", "八", "爸"], &[han, personal, han, han, han], 2), same);
    // An abbreviation or a typo correction reached every character: not a complete syllable.
    let corrected = "0,2,n,1,0,n,phrase,1";
    assert_eq!(
        order_of(&["吧", "BA", "把", "八", "爸"], &[corrected, english, corrected, corrected, corrected], 2),
        same
    );
    // Words, not single characters.
    let word = "0,5,n,1,0,n,phrase,0";
    let word_english = "0,5,a,1,0,e,english_exact,0";
    assert_eq!(
        order_of(&["我们", "women", "我门", "窝们", "卧们"], &[word, word_english, word, word, word], 5),
        same
    );
    // A completion is not evidence of a complete syllable.
    let completion = "0,2,n,1,0,n,completion,0";
    assert_eq!(
        order_of(&["吧", "BA", "把", "八", "爸"], &[completion, english, completion, completion, completion], 2),
        same
    );
    // Rows without the type and corrected facts.
    let legacy = ["0,2,n,1,0,n", "0,2,a,1,0,e", "0,2,n,1,0,n", "0,2,n,1,0,n", "0,2,n,1,0,n"];
    assert_eq!(order_of(&["吧", "BA", "把", "八", "爸"], &legacy, 2), same);
    // English already at or behind the fourth place stays there.
    assert_eq!(order_of(&["吧", "把", "八", "BA", "爸"], &[han, han, han, english, han], 2), same);
}
