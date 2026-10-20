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
        "0,7,m,1,0,m,,0",
        "2,7,o,0,0,c,user_table,0",
    ] {
        let parsed = parse_rows(&[row], 7).unwrap();
        assert_eq!(parsed[0].row(), row);
    }
    let legacy = parse_rows(&["0,7,n,1,0,n"], 7).unwrap();
    assert_eq!(legacy[0].row(), "0,7,n,1,0,n,,0");
}

/// Provenance is recorded, not ranked on: the same page orders the same with or without it.
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
