use std::{collections::HashMap, ops::Range};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CandidateClass {
    NonAscii,
    Ascii,
    Mixed,
    Other,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Native,
    English,
    Mixed,
    Custom,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Metadata {
    pub coverage: Range<usize>,
    pub class: CandidateClass,
    pub exact: bool,
    pub personal: u8,
    pub source: Source,
    pub lead: bool,
    pub pinyin: bool,
    pub sentence: bool,
    pub candidate_type: String,
    pub corrected: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PersonalSource {
    ExactEnglish,
    ExactMixed,
}

impl Metadata {
    pub fn personal_source(&self) -> Option<PersonalSource> {
        if !self.exact || self.personal == 0 {
            return None;
        }
        match self.source {
            Source::English => Some(PersonalSource::ExactEnglish),
            Source::Mixed => Some(PersonalSource::ExactMixed),
            Source::Native | Source::Custom => None,
        }
    }

    pub fn row(&self) -> String {
        let class = match self.class {
            CandidateClass::NonAscii => "n",
            CandidateClass::Ascii => "a",
            CandidateClass::Mixed => "m",
            CandidateClass::Other => "o",
        };
        let exact = if self.sentence {
            3
        } else if self.lead {
            2
        } else if self.pinyin {
            4
        } else {
            u8::from(self.exact)
        };
        let source = match self.source {
            Source::Native => "n",
            Source::English => "e",
            Source::Mixed => "m",
            Source::Custom => "c",
        };
        format!(
            "{},{},{class},{exact},{},{source},{},{}",
            self.coverage.start,
            self.coverage.end,
            self.personal,
            self.candidate_type,
            u8::from(self.corrected),
        )
    }
}

fn is_candidate_type(kind: &str) -> bool {
    let mut bytes = kind.bytes();
    kind.len() <= 32
        && bytes.next().is_none_or(|b| b.is_ascii_lowercase() || b == b'_')
        && bytes.all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

pub fn parse_metadata(
    value: &str,
    offset: usize,
    count: usize,
    input_length: usize,
) -> Option<Vec<Metadata>> {
    if !(1..=9).contains(&count) || input_length == 0 {
        return None;
    }
    let mut rows = value.split(';');
    if rows.next()? != format!("{offset},{count}") {
        return None;
    }
    let mut result = Vec::with_capacity(count);
    for row in rows {
        if result.len() == count {
            return None;
        }
        let fields: Vec<_> = row.split(',').collect();
        if !matches!(fields.len(), 6 | 8)
            || fields[..2]
                .iter()
                .any(|v| v.is_empty() || !v.bytes().all(|b| b.is_ascii_digit()))
        {
            return None;
        }
        let start = fields[0].parse::<isize>().ok()?;
        let end = fields[1].parse::<isize>().ok()?;
        if start >= end || end as usize > input_length {
            return None;
        }
        let class = match fields[2] {
            "n" => CandidateClass::NonAscii,
            "a" => CandidateClass::Ascii,
            "m" => CandidateClass::Mixed,
            "o" => CandidateClass::Other,
            _ => return None,
        };
        let (exact, lead, sentence, pinyin) = match fields[3] {
            "4" => (true, false, false, true),
            "3" => (true, false, true, false),
            "2" => (true, true, false, false),
            "1" => (true, false, false, false),
            "0" => (false, false, false, false),
            _ => return None,
        };
        let personal = match fields[4] {
            "0" => 0,
            "1" => 1,
            "2" => 2,
            "3" => 3,
            _ => return None,
        };
        let source = match fields[5] {
            "n" => Source::Native,
            "e" => Source::English,
            "m" => Source::Mixed,
            "c" => Source::Custom,
            _ => return None,
        };
        if personal > 0 && !(exact && matches!(source, Source::English | Source::Mixed)) {
            return None;
        }
        if lead
            && !(source == Source::English
                && class == CandidateClass::Ascii
                && start == 0
                && end as usize == input_length)
        {
            return None;
        }
        if pinyin
            && !(source == Source::English
                && class == CandidateClass::Ascii
                && personal > 0
                && start == 0
                && end as usize == input_length)
        {
            return None;
        }
        if sentence
            && !(source == Source::Native
                && class == CandidateClass::NonAscii
                && start == 0
                && end as usize == input_length)
        {
            return None;
        }
        let (candidate_type, corrected) = if fields.len() == 8 {
            let kind = fields[6];
            if !is_candidate_type(kind) {
                return None;
            }
            let corrected = match fields[7] {
                "0" => false,
                "1" => true,
                _ => return None,
            };
            (kind.to_string(), corrected)
        } else {
            (String::new(), false)
        };
        result.push(Metadata {
            coverage: start as usize..end as usize,
            class,
            exact,
            personal,
            source,
            lead,
            pinyin,
            sentence,
            candidate_type,
            corrected,
        });
    }
    (result.len() == count).then_some(result)
}

pub fn is_han(grapheme: &str) -> bool {
    let mut chars = grapheme.chars();
    matches!(
        chars.next(),
        Some(
            '\u{3400}'..='\u{4dbf}'
            | '\u{4e00}'..='\u{9fff}'
            | '\u{f900}'..='\u{faff}'
            | '\u{20000}'..='\u{2fa1f}'
            | '\u{30000}'..='\u{323af}',
        )
    ) && chars.next().is_none()
}
fn all_han(text: &str) -> bool {
    text.graphemes(true).all(is_han)
}
fn normalized(text: &str) -> String {
    text.nfc().collect()
}
fn consistent(candidate: &str, row: &Metadata) -> bool {
    let letter = candidate.bytes().any(|b| b.is_ascii_alphabetic());
    let non_ascii = !candidate.is_ascii();
    let class = match (letter, non_ascii) {
        (true, false) => CandidateClass::Ascii,
        (true, true) => CandidateClass::Mixed,
        (false, true) => CandidateClass::NonAscii,
        (false, false) => CandidateClass::Other,
    };
    row.class == class
        && match row.source {
            Source::English => class == CandidateClass::Ascii,
            Source::Mixed => class == CandidateClass::Mixed,
            Source::Native | Source::Custom => row.personal == 0,
        }
}
fn technical(text: &str) -> bool {
    let bounded: String = text
        .graphemes(true)
        .rev()
        .take(16)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    let mut run = 0;
    for scalar in bounded.chars() {
        run = if scalar.is_ascii_alphanumeric() {
            run + 1
        } else {
            0
        };
        if run >= 2 {
            return true;
        }
    }
    let canonical = normalized(&bounded);
    ["代码", "编程", "开发", "命令", "终端", "接口", "版本"]
        .iter()
        .any(|suffix| canonical.ends_with(suffix))
}

enum Phrases {
    Map(HashMap<String, HashMap<String, i64>>),
    Index {
        data: Vec<u8>,
        tables: [(usize, usize); PHRASE_LIMIT - 1],
        reading_bytes: usize,
    },
}
const PHRASE_LIMIT: usize = 8;
const SYLLABLE_ENGLISH_PLACE: usize = 3;
const INDEX_HEADER: usize = 12 + (PHRASE_LIMIT - 1) * 4;

fn encode(text: &str) -> Vec<u8> {
    text.nfc()
        .flat_map(|scalar| {
            let value = scalar as u32;
            [(value >> 16) as u8, (value >> 8) as u8, value as u8]
        })
        .collect()
}

impl Phrases {
    fn frequency(&self, phrase: &str, input: Option<&str>) -> Option<i64> {
        match self {
            Phrases::Map(map) => map.get(&normalized(phrase)).and_then(|readings| {
                readings
                    .iter()
                    .filter(|(reading, _)| input.is_none_or(|input| reading.starts_with(input)))
                    .map(|(_, frequency)| *frequency)
                    .max()
            }),
            Phrases::Index {
                data, tables, reading_bytes,
            } => {
                let key = encode(phrase);
                let length = key.len() / 3;
                if !(2..=PHRASE_LIMIT).contains(&length) {
                    return None;
                }
                let (offset, count) = tables[length - 2];
                let record = length * 3 + reading_bytes + 8;
                let (mut low, mut high) = (0, count);
                while low < high {
                    let mid = (low + high) / 2;
                    let start = offset + mid * record;
                    if data[start..start + key.len()] < key[..] {
                        low = mid + 1;
                    } else {
                        high = mid;
                    }
                }
                let mut best = None;
                for position in low..count {
                    let start = offset + position * record;
                    if data[start..start + key.len()] != key[..] {
                        break;
                    }
                    let reading = &data[start + key.len()..start + key.len() + reading_bytes];
                    if *reading_bytes == 0 || input.is_none_or(|input| reading.starts_with(input.as_bytes())) {
                        let bytes = &data[start + record - 8..start + record];
                        let frequency = u64::from_le_bytes(bytes.try_into().unwrap()) as i64;
                        best = Some(best.unwrap_or(0).max(frequency));
                    }
                }
                best
            }
        }
    }
}

pub struct ContextRanker {
    frequencies: Phrases,
    longest: usize,
}
impl ContextRanker {
    pub fn from_index(data: Vec<u8>) -> Result<Self, String> {
        if data.len() < INDEX_HEADER || &data[..4] != b"IFCX" {
            return Err("Expected an InkFlow context index".into());
        }
        let field = |position: usize| {
            u32::from_le_bytes(data[4 * position..4 * position + 4].try_into().unwrap()) as usize
        };
        let reading_bytes = match field(1) {
            1 => 0,
            2 => 6,
            version => return Err(format!("Unsupported context index version {version}")),
        };
        let mut tables = [(0, 0); PHRASE_LIMIT - 1];
        let mut offset = INDEX_HEADER;
        for length in 2..=PHRASE_LIMIT {
            let count = field(length + 1);
            tables[length - 2] = (offset, count);
            offset = offset
                .checked_add(
                    count
                        .checked_mul(length * 3 + reading_bytes + 8)
                        .ok_or("Oversized context index")?,
                )
                .ok_or("Oversized context index")?;
        }
        if field(2) > PHRASE_LIMIT || offset != data.len() {
            return Err("Unsupported or truncated context index".into());
        }
        Ok(Self {
            longest: field(2),
            frequencies: Phrases::Index {
                data, tables, reading_bytes,
            },
        })
    }

    pub fn from_dictionary(text: &str) -> Self {
        let mut frequencies = HashMap::<String, HashMap<String, i64>>::new();
        let mut longest = 0;
        let mut start = 0;
        for (end, grapheme) in text
            .grapheme_indices(true)
            .chain(std::iter::once((text.len(), "\n")))
        {
            if grapheme != "\n" {
                continue;
            }
            let line = &text[start..end];
            start = end + 1;
            let fields: Vec<_> = line.split('\t').filter(|field| !field.is_empty()).collect();
            if fields.len() < 3 {
                continue;
            }
            let Ok(frequency) = fields[2].parse::<i64>() else {
                continue;
            };
            let phrase = fields[0];
            let count = phrase.graphemes(true).count();
            if frequency < 0 || !(2..=8).contains(&count) || !all_han(phrase) {
                continue;
            }
            let syllables: Vec<_> = fields[1].split_whitespace().collect();
            let reading = syllables.last().copied().unwrap_or("");
            let reading = if syllables.len() == count
                && reading.len() <= 6
                && reading.bytes().all(|byte| byte.is_ascii_lowercase())
            {
                reading
            } else {
                ""
            };
            let entry = frequencies
                .entry(normalized(phrase))
                .or_default()
                .entry(reading.to_string())
                .or_default();
            *entry = (*entry).max(frequency);
            longest = longest.max(count);
        }
        Self {
            frequencies: Phrases::Map(frequencies),
            longest,
        }
    }

    pub(crate) fn can_extend_document(&self, word: &str) -> bool {
        let length = word.graphemes(true).count();
        (1..self.longest).contains(&length) && all_han(word)
    }

    pub fn order(
        &self,
        candidates: &[String],
        preceding: &str,
        metadata: Option<&[Metadata]>,
        input: &str,
    ) -> Vec<usize> {
        let original: Vec<_> = (0..candidates.len()).collect();
        let Some(rows) = metadata else {
            return original;
        };
        if candidates.is_empty()
            || rows.len() != candidates.len()
            || rows.iter().any(|r| r.coverage.is_empty() || r.personal > 3)
            || candidates.iter().zip(rows).any(|(c, r)| !consistent(c, r))
        {
            return original;
        }
        let eligible: Vec<_> = original
            .iter()
            .copied()
            .filter(|&i| rows[i].coverage == rows[0].coverage)
            .collect();
        let prefix: Vec<_> = preceding
            .graphemes(true)
            .rev()
            .take(self.longest.saturating_sub(1))
            .take_while(|g| is_han(g))
            .collect();
        let first_length = candidates[0].graphemes(true).count();
        let literal_input = !input.is_empty() && input.bytes().all(|byte| byte.is_ascii_lowercase());
        let phrase = |count: usize, tail: &str| -> String {
            prefix[..count]
                .iter()
                .rev()
                .copied()
                .chain(std::iter::once(tail))
                .collect()
        };
        let word_start = (2..=prefix.len())
            .rev()
            .find(|&count| self.frequencies.frequency(&phrase(count, ""), None).is_some())
            .unwrap_or(1);
        let scores: Vec<_> = candidates
            .iter()
            .enumerate()
            .map(|(i, candidate)| {
                if !eligible.contains(&i)
                    || prefix.is_empty()
                    || candidate.graphemes(true).count() != first_length
                    || !all_han(candidate)
                {
                    return (0, 0);
                }
                let reading = (first_length == 1
                    && rows[i].coverage == (0..input.len())
                    && !rows[i].corrected
                    && literal_input)
                    .then_some(input);
                for count in (word_start..=prefix.len()).rev() {
                    if count + first_length > PHRASE_LIMIT {
                        continue;
                    }
                    if let Some(frequency) = self.frequencies.frequency(&phrase(count, candidate), reading) {
                        return (count, frequency);
                    }
                }
                (0, 0)
            })
            .collect();
        let han = || {
            eligible
                .iter()
                .copied()
                .filter(|&i| all_han(&candidates[i]))
        };
        let native_han = han().next();
        let leading_han = han().min_by_key(|&i| (std::cmp::Reverse(scores[i]), i));
        let is_technical = technical(preceding);
        let technical_lead = eligible.iter().copied().find(|&i| rows[i].lead);
        let learned_lead = eligible.iter().copied().find(|&i| {
            rows[0].sentence
                && rows[i].exact
                && rows[i].personal > 0
                && rows[i].source == Source::English
        });
        let tier = |i: usize| {
            let row = &rows[i];
            if row.source == Source::Custom {
                0
            } else if Some(i) == technical_lead
                || Some(i) == learned_lead
                || (is_technical
                    && row.exact
                    && row.personal > 0
                    && row.source == Source::English
                    && !row.pinyin)
            {
                1
            } else if row.exact && row.personal > 0 && row.source == Source::Mixed {
                2
            } else if Some(i) == leading_han || Some(i) == native_han {
                3
            } else if row.exact && matches!(row.source, Source::English | Source::Mixed) {
                4
            } else if row.exact {
                5
            } else {
                6
            }
        };
        let mut ranked = eligible.clone();
        ranked.sort_by_key(|&i| {
            (
                tier(i),
                std::cmp::Reverse(rows[i].personal),
                std::cmp::Reverse(scores[i]),
                i,
            )
        });
        let syllable = eligible.iter().any(|&i| {
            let row = &rows[i];
            row.source == Source::Native
                && row.exact
                && !row.corrected
                && matches!(row.candidate_type.as_str(), "phrase" | "user_phrase")
                && candidates[i].graphemes(true).count() == 1
                && all_han(&candidates[i])
        });
        if syllable {
            let unconfirmed = |i: usize| {
                let row = &rows[i];
                row.exact && row.personal == 0 && row.source == Source::English && tier(i) == 4
            };
            let (deferred, mut kept): (Vec<_>, Vec<_>) = ranked
                .iter()
                .copied()
                .enumerate()
                .partition(|&(place, i)| place < SYLLABLE_ENGLISH_PLACE && unconfirmed(i));
            let completion = kept
                .iter()
                .position(|&(_, i)| !rows[i].exact && rows[i].source == Source::English);
            let at = completion.unwrap_or(kept.len()).min(SYLLABLE_ENGLISH_PLACE);
            kept.splice(at..at, deferred);
            ranked = kept.into_iter().map(|(_, i)| i).collect();
        }
        let mut result = original;
        for (slot, candidate) in eligible.into_iter().zip(ranked) {
            result[slot] = candidate;
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(exact: bool, personal: u8, source: Source) -> Metadata {
        Metadata {
            coverage: 0..5,
            class: CandidateClass::Ascii,
            exact,
            personal,
            source,
            lead: false,
            pinyin: false,
            sentence: false,
            candidate_type: String::new(),
            corrected: false,
        }
    }

    #[test]
    fn document_continuations_must_fit_the_index() {
        let ranker = ContextRanker::from_dictionary("午餐\twu can\t10\n");
        assert!(ranker.can_extend_document("餐"));
        assert!(!ranker.can_extend_document("午餐"));
        assert!(!ranker.can_extend_document("a"));
        assert!(!ranker.can_extend_document(""));
        assert!(!ContextRanker::from_dictionary("").can_extend_document("餐"));
    }

    #[test]
    fn personal_source_names_exact_personal_english_and_mixed() {
        use PersonalSource::{ExactEnglish, ExactMixed};
        assert_eq!(
            row(true, 1, Source::English).personal_source(),
            Some(ExactEnglish)
        );
        assert_eq!(
            row(true, 3, Source::Mixed).personal_source(),
            Some(ExactMixed)
        );
        for none in [
            row(true, 0, Source::English),
            row(false, 2, Source::English),
            row(true, 0, Source::Mixed),
            row(true, 1, Source::Native),
            row(true, 2, Source::Custom),
            row(false, 0, Source::Native),
        ] {
            assert_eq!(none.personal_source(), None, "{none:?}");
        }
    }
}
