//! Custom phrases, matching InkFlowDomain/CustomPhrase.swift. Validation failures carry a
//! stable code; frontends own the localized message.
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustomPhrase {
    /// Opaque frontend identity (a UUID on macOS); unique within one configuration.
    pub id: String,
    pub code: String,
    pub text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhraseError {
    /// The code must be non-empty ASCII letters a–z.
    InvalidCode,
    /// The text contains a newline, tab or other control character.
    ControlCharacter,
    EmptyText,
    /// A phrase differs from its validated form or repeats an identity.
    InvalidData,
    /// The same code and text appear twice.
    Duplicate,
}

impl PhraseError {
    pub fn code(self) -> &'static str {
        match self {
            PhraseError::InvalidCode => "invalid-code",
            PhraseError::ControlCharacter => "control-character",
            PhraseError::EmptyText => "empty-text",
            PhraseError::InvalidData => "invalid-data",
            PhraseError::Duplicate => "duplicate",
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
            let valid = Self::validated(&phrase.id, &phrase.code, &phrase.text)
                .map_err(|_| PhraseError::InvalidData)?;
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

/// Rime's custom_phrase.txt: text, code, weight. Earlier phrases outrank later ones.
pub fn phrase_tsv(phrases: &[CustomPhrase]) -> String {
    // librime's TSV reader otherwise treats phrases beginning with '#' as comments.
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
        let raw = CustomPhrase {
            id: "a".into(),
            code: "x\ty".into(),
            text: "invalid".into(),
        };
        assert_eq!(
            CustomPhrase::validate(&[raw]),
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
        assert_eq!(phrase_tsv(&[]), "# no comment\n");
        let second = CustomPhrase::validated("c", "dz", "# no comment").unwrap();
        assert_eq!(
            phrase_tsv(&[phrase, second]),
            "# no comment\n地址\tdz\t2\n# no comment\tdz\t1\n"
        );
    }
}
