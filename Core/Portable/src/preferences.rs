//! Input preferences, matching InkFlowDomain/InputPreferences.swift.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum InputOption {
    Abbreviation,
    TypoTolerance,
    FuzzyZ,
    FuzzyC,
    FuzzyS,
    Emoji,
    BracketPaging,
    MinusEqualPaging,
    EnglishPunctuation,
    CornerQuotes,
    MiddleDot,
    FullwidthPipe,
    IdeographicComma,
    Traditional,
}

impl InputOption {
    pub const ALL: [InputOption; 14] = [
        InputOption::Abbreviation,
        InputOption::TypoTolerance,
        InputOption::FuzzyZ,
        InputOption::FuzzyC,
        InputOption::FuzzyS,
        InputOption::Emoji,
        InputOption::BracketPaging,
        InputOption::MinusEqualPaging,
        InputOption::EnglishPunctuation,
        InputOption::CornerQuotes,
        InputOption::MiddleDot,
        InputOption::FullwidthPipe,
        InputOption::IdeographicComma,
        InputOption::Traditional,
    ];

    /// The Swift raw value; the quality configuration records options by this name.
    pub fn name(self) -> &'static str {
        match self {
            InputOption::Abbreviation => "abbreviation",
            InputOption::TypoTolerance => "typoTolerance",
            InputOption::FuzzyZ => "fuzzyZ",
            InputOption::FuzzyC => "fuzzyC",
            InputOption::FuzzyS => "fuzzyS",
            InputOption::Emoji => "emoji",
            InputOption::BracketPaging => "bracketPaging",
            InputOption::MinusEqualPaging => "minusEqualPaging",
            InputOption::EnglishPunctuation => "englishPunctuation",
            InputOption::CornerQuotes => "cornerQuotes",
            InputOption::MiddleDot => "middleDot",
            InputOption::FullwidthPipe => "fullwidthPipe",
            InputOption::IdeographicComma => "ideographicComma",
            InputOption::Traditional => "traditional",
        }
    }

    pub fn default_value(self) -> bool {
        !matches!(
            self,
            InputOption::FuzzyZ
                | InputOption::FuzzyC
                | InputOption::FuzzyS
                | InputOption::EnglishPunctuation
                | InputOption::Traditional
        )
    }
}

/// A value snapshot belongs to one composition, even while persisted preferences change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InputPreferences {
    values: [bool; 14],
}

impl Default for InputPreferences {
    fn default() -> Self {
        Self {
            values: InputOption::ALL.map(InputOption::default_value),
        }
    }
}

impl InputPreferences {
    fn slot(option: InputOption) -> usize {
        InputOption::ALL.iter().position(|o| *o == option).unwrap()
    }

    pub fn get(&self, option: InputOption) -> bool {
        self.values[Self::slot(option)]
    }

    pub fn with(mut self, option: InputOption, value: bool) -> Self {
        self.values[Self::slot(option)] = value;
        self
    }

    pub fn recorded_values(&self) -> Vec<(&'static str, bool)> {
        InputOption::ALL
            .iter()
            .map(|o| (o.name(), self.get(*o)))
            .collect()
    }

    pub fn spelling_profile(&self) -> String {
        let bits = [
            InputOption::Abbreviation,
            InputOption::TypoTolerance,
            InputOption::FuzzyZ,
            InputOption::FuzzyC,
            InputOption::FuzzyS,
        ];
        let mask = bits.iter().enumerate().fold(0, |mask, (bit, option)| {
            mask | (usize::from(self.get(*option)) << bit)
        });
        spelling_profile(mask)
    }

    /// Replace entire config nodes so Rime's existing components retain their own snapshots.
    pub fn schema_patch(&self) -> String {
        let mut bindings = Vec::new();
        if self.get(InputOption::BracketPaging) {
            bindings.push("{ when: has_menu, accept: bracketleft, send: Page_Up }");
            bindings.push("{ when: has_menu, accept: bracketright, send: Page_Down }");
        }
        if self.get(InputOption::MinusEqualPaging) {
            bindings.push("{ when: has_menu, accept: minus, send: Page_Up }");
            bindings.push("{ when: has_menu, accept: equal, send: Page_Down }");
        }
        let pick =
            |option, on: &'static str, off: &'static str| if self.get(option) { on } else { off };
        format!(
            "key_binder:\n  bindings: [{}]\npunctuator:\n  half_shape:\n    ',': '，'\n    '.': '。'\n    '?': '？'\n    '!': '！'\n    ':': '：'\n    ';': '；'\n    '(': '（'\n    ')': '）'\n    '{{': '{}'\n    '}}': '{}'\n    '[': '【'\n    ']': '】'\n    '<': '《'\n    '>': '》'\n    '\\': '{}'\n    '|': '{}'\n    '`': '{}'\n    '~': '～'\n    '$': '¥'\n    '^': '……'\n    '_': '——'\n    '\"': {{ pair: ['“', '”'] }}\n    \"'\": {{ pair: ['‘', '’'] }}",
            bindings.join(", "),
            pick(InputOption::CornerQuotes, "「", "{"),
            pick(InputOption::CornerQuotes, "」", "}"),
            pick(InputOption::IdeographicComma, "、", "\\"),
            pick(InputOption::FullwidthPipe, "｜", "|"),
            pick(InputOption::MiddleDot, "·", "`"),
        )
    }
}

pub fn spelling_profile(mask: usize) -> String {
    format!("inkflow_spelling_{mask}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swift_defaults_and_profiles() {
        let defaults = InputPreferences::default();
        assert_eq!(defaults.spelling_profile(), "inkflow_spelling_3");
        assert!(!defaults.get(InputOption::Traditional) && defaults.get(InputOption::Emoji));
        let all = defaults
            .clone()
            .with(InputOption::FuzzyZ, true)
            .with(InputOption::FuzzyC, true)
            .with(InputOption::FuzzyS, true);
        assert_eq!(all.spelling_profile(), "inkflow_spelling_31");
        let patch = defaults.schema_patch();
        assert!(patch.starts_with("key_binder:\n  bindings: [{ when: has_menu, accept: bracketleft, send: Page_Up }, { when: has_menu, accept: bracketright, send: Page_Down }, { when: has_menu, accept: minus, send: Page_Up }, { when: has_menu, accept: equal, send: Page_Down }]\npunctuator:\n  half_shape:\n    ',': '，'\n"));
        assert!(patch.contains("    '{': '「'\n    '}': '」'\n    '[': '【'"));
        assert!(patch.contains("    '\\': '、'\n    '|': '｜'\n    '`': '·'\n    '~': '～'"));
        let plain = defaults
            .with(InputOption::CornerQuotes, false)
            .with(InputOption::IdeographicComma, false)
            .with(InputOption::FullwidthPipe, false)
            .with(InputOption::MiddleDot, false)
            .with(InputOption::BracketPaging, false)
            .with(InputOption::MinusEqualPaging, false)
            .schema_patch();
        assert!(plain.contains("  bindings: []\n"));
        assert!(
            plain.contains("    '{': '{'\n    '}': '}'\n")
                && plain.contains("    '\\': '\\'\n    '|': '|'\n    '`': '`'\n")
        );
        assert!(plain.ends_with("    '\"': { pair: ['“', '”'] }\n    \"'\": { pair: ['‘', '’'] }"));
    }
}
