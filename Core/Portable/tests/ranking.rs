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
                        u8::from(row.exact),
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
