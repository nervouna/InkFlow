//! The only host–Lua bridge: one request property that the Lua modules observe
//! synchronously, answered in one result property. Protocol version 1:
//!
//! ```text
//! request = "1\t<op>\t<field>\t<field>..."   fields carry no tab, CR or LF
//! result  = "1\t<op>\t<status>\n<body>"       status: ok, failed, unknown or conflict
//! ```
pub const VERSION: &str = "1";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    pub status: String,
    pub body: String,
}

/// `None` when a field would break the line-oriented framing.
pub fn request(op: &str, fields: &[&str]) -> Option<String> {
    if op.is_empty()
        || !op.bytes().all(|b| b.is_ascii_lowercase() || b == b'_')
        || fields
            .iter()
            .any(|f| f.bytes().any(|b| matches!(b, b'\t' | b'\n' | b'\r')))
    {
        return None;
    }
    let mut request = format!("{VERSION}\t{op}");
    for field in fields {
        request.push('\t');
        request.push_str(field);
    }
    Some(request)
}

/// `None` for another protocol version, another operation or a malformed header.
pub fn reply(result: &str, op: &str) -> Option<Reply> {
    let (header, body) = match result.split_once('\n') {
        Some((header, body)) => (header, body),
        None => (result, ""),
    };
    let fields: Vec<_> = header.split('\t').collect();
    if fields.len() != 3
        || fields[0] != VERSION
        || fields[1] != op
        || fields[2].is_empty()
        || !fields[2].bytes().all(|b| b.is_ascii_lowercase())
    {
        return None;
    }
    Some(Reply {
        status: fields[2].to_owned(),
        body: body.to_owned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swift_framing_rules() {
        assert_eq!(
            request("input_coverage", &["9", "3"]).as_deref(),
            Some("1\tinput_coverage\t9\t3")
        );
        assert_eq!(
            request("learning_invalidate", &[]).as_deref(),
            Some("1\tlearning_invalidate")
        );
        for (op, fields) in [
            ("", vec!["a"]),
            ("Input", vec![]),
            ("ai-learning", vec![]),
            ("ai_learning", vec!["a\tb"]),
            ("ai_learning", vec!["a\nb"]),
            ("ai_learning", vec!["a\rb"]),
        ] {
            assert_eq!(request(op, &fields), None, "{op} {fields:?}");
        }
        assert_eq!(
            reply("1\tvoice_lexicon\tok\n你好\tni hao\t2\n", "voice_lexicon"),
            Some(Reply {
                status: "ok".into(),
                body: "你好\tni hao\t2\n".into()
            })
        );
        assert_eq!(
            reply("1\tai_learning\tfailed", "ai_learning").map(|r| r.status),
            Some("failed".into())
        );
        assert_eq!(
            reply("1\tai_learning\tfailed\n", "ai_learning").map(|r| r.body),
            Some(String::new())
        );
        assert_eq!(
            reply("1\tinput_coverage\tok\n9,3;0,4,n,1,0,n", "input_coverage").map(|r| r.body),
            Some("9,3;0,4,n,1,0,n".into())
        );
        for result in [
            "",
            "ok",
            "2\tai_learning\tok",
            "1\tai_readings\tok",
            "1\tai_learning\t",
            "1\tai_learning\tOK",
            "1\tai_learning\tok\textra",
            "1\tai_learning",
            "\n1\tai_learning\tok",
        ] {
            assert_eq!(reply(result, "ai_learning"), None, "{result:?}");
        }
    }
}
