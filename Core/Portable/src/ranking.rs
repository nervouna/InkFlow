//! Equivalent-span ordering, matching InkFlowDomain/CandidateRanking.swift.
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
        if fields.len() != 6
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
        let exact = match fields[3] {
            "1" => true,
            "0" => false,
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
        result.push(Metadata {
            coverage: start as usize..end as usize,
            class,
            exact,
            personal,
            source,
        });
    }
    (result.len() == count).then_some(result)
}

fn is_han(grapheme: &str) -> bool {
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

pub struct ContextRanker {
    frequencies: HashMap<String, i64>,
    longest: usize,
}
impl ContextRanker {
    /// Build before accepting key events. Ranking itself does not access storage.
    pub fn from_dictionary(text: &str) -> Self {
        let mut frequencies = HashMap::<String, i64>::new();
        let mut longest = 0;
        let mut start = 0;
        // Swift splits LF Characters, not the LF inside a CRLF grapheme.
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
            let entry = frequencies.entry(normalized(phrase)).or_default();
            *entry = (*entry).max(frequency);
            longest = longest.max(count);
        }
        Self {
            frequencies,
            longest,
        }
    }

    pub fn order(
        &self,
        candidates: &[String],
        preceding: &str,
        metadata: Option<&[Metadata]>,
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
                for count in (1..=prefix.len()).rev() {
                    let phrase: String = prefix[..count]
                        .iter()
                        .rev()
                        .copied()
                        .chain(std::iter::once(candidate.as_str()))
                        .collect();
                    if let Some(&frequency) = self.frequencies.get(&normalized(&phrase)) {
                        return (count, frequency);
                    }
                }
                (0, 0)
            })
            .collect();
        let leading_han = eligible
            .iter()
            .copied()
            .filter(|&i| all_han(&candidates[i]))
            .min_by_key(|&i| (std::cmp::Reverse(scores[i]), i));
        let is_technical = technical(preceding);
        let tier = |i: usize| {
            let row = &rows[i];
            if row.source == Source::Custom {
                0
            } else if is_technical && row.exact && row.personal > 0 && row.source == Source::English
            {
                1
            } else if Some(i) == leading_han {
                2
            } else if row.exact && matches!(row.source, Source::English | Source::Mixed) {
                3
            } else if row.exact {
                4
            } else {
                5
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
        let mut result = original;
        for (slot, candidate) in eligible.into_iter().zip(ranked) {
            result[slot] = candidate;
        }
        result
    }
}
