use std::{collections::HashSet, ffi::CStr};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustomPhrase {
    pub id: String,
    pub code: String,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhraseError {
    InvalidCode,
    ControlCharacter,
    EmptyText,
    InvalidData,
    Duplicate,
}

impl PhraseError {
    pub fn code(self) -> &'static CStr {
        match self {
            PhraseError::InvalidCode => c"invalid-code",
            PhraseError::ControlCharacter => c"control-character",
            PhraseError::EmptyText => c"empty-text",
            PhraseError::InvalidData => c"invalid-data",
            PhraseError::Duplicate => c"duplicate",
        }
    }
}

impl CustomPhrase {
    pub fn validated(id: &str, code: &str, text: &str) -> Result<Self, PhraseError> {
        let code = code.trim().to_ascii_lowercase();
        if code.is_empty() || !code.bytes().all(|b| b.is_ascii_lowercase()) {
            return Err(PhraseError::InvalidCode);
        }
        if text
            .chars()
            .any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}'))
        {
            return Err(PhraseError::ControlCharacter);
        }
        let text = text.trim();
        if text.is_empty() {
            return Err(PhraseError::EmptyText);
        }
        Ok(Self {
            id: id.to_owned(),
            code,
            text: text.to_owned(),
        })
    }

    pub fn validate(phrases: &[CustomPhrase]) -> Result<(), PhraseError> {
        let mut ids = HashSet::new();
        let mut pairs = HashSet::new();
        for phrase in phrases {
            let valid = Self::validated(&phrase.id, &phrase.code, &phrase.text)?;
            if valid != *phrase || !ids.insert(&phrase.id) {
                return Err(PhraseError::InvalidData);
            }
            if !pairs.insert((&phrase.code, &phrase.text)) {
                return Err(PhraseError::Duplicate);
            }
        }
        Ok(())
    }
}

pub fn phrase_tsv(phrases: &[CustomPhrase]) -> String {
    let mut tsv = String::from("# no comment\n");
    for (index, phrase) in phrases.iter().enumerate() {
        tsv.push_str(&format!(
            "{}\t{}\t{}\n",
            phrase.text,
            phrase.code,
            phrases.len() - index
        ));
    }
    tsv
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swift_validation_rules() {
        let phrase = CustomPhrase::validated("a", " Dz ", " 地址 ").unwrap();
        assert_eq!((phrase.code.as_str(), phrase.text.as_str()), ("dz", "地址"));
        assert_eq!(
            CustomPhrase::validated("a", "", "x"),
            Err(PhraseError::InvalidCode)
        );
        assert_eq!(
            CustomPhrase::validated("a", "x\ty", "x"),
            Err(PhraseError::InvalidCode)
        );
        assert_eq!(
            CustomPhrase::validated("a", "x", "a\tb"),
            Err(PhraseError::ControlCharacter)
        );
        assert_eq!(
            CustomPhrase::validated("a", "x", "  "),
            Err(PhraseError::EmptyText)
        );
        let raw = |code: &str, text: &str| CustomPhrase {
            id: "a".into(),
            code: code.into(),
            text: text.into(),
        };
        assert_eq!(
            CustomPhrase::validate(&[raw("x\ty", "invalid")]),
            Err(PhraseError::InvalidCode)
        );
        assert_eq!(
            CustomPhrase::validate(&[raw("x", "a\tb")]),
            Err(PhraseError::ControlCharacter)
        );
        assert_eq!(
            CustomPhrase::validate(&[raw("x", "")]),
            Err(PhraseError::EmptyText)
        );
        assert_eq!(
            CustomPhrase::validate(&[raw("X", "ok")]),
            Err(PhraseError::InvalidData)
        );
        assert_eq!(
            CustomPhrase::validate(&[raw("x", " ok ")]),
            Err(PhraseError::InvalidData)
        );
        let twice = CustomPhrase::validated("b", "dz", "地址").unwrap();
        assert_eq!(
            CustomPhrase::validate(&[phrase.clone(), twice]),
            Err(PhraseError::Duplicate)
        );
        let same_id = CustomPhrase::validated("a", "dz", "其他").unwrap();
        assert_eq!(
            CustomPhrase::validate(&[phrase.clone(), same_id]),
            Err(PhraseError::InvalidData)
        );
        let emoji = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        assert_eq!(CustomPhrase::validated("e", "fam", emoji).unwrap().text, emoji);
        assert_eq!(
            CustomPhrase::validated("e", "\u{212A}", "x"),
            Err(PhraseError::InvalidCode)
        );
        assert_eq!(phrase_tsv(&[]), "# no comment\n");
        let second = CustomPhrase::validated("c", "dz", "# no comment").unwrap();
        assert_eq!(
            phrase_tsv(&[phrase, second]),
            "# no comment\n地址\tdz\t2\n# no comment\tdz\t1\n"
        );
    }
}
