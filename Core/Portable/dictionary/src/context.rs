//! Context-ranking index, byte-identical to `IFContextRanker.buildIndex` in
//! InkFlowDomain/CandidateRanking.swift: a sorted, fixed-width table per phrase
//! length so the ranker reads it whole and never parses the dictionary.
use crate::{Error, Result};
use std::collections::HashMap;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

pub const CONTEXT_INDEX_FILENAME: &str = "pinyin_simp.context.bin";
const MAGIC: &[u8] = b"IFCX";
const VERSION: u32 = 1;
const PHRASE_LIMIT: usize = 8;

pub fn context_index(dictionary: &[u8]) -> Result<Vec<u8>> {
    let text = std::str::from_utf8(dictionary).map_err(|_| Error::new("context-index"))?;
    let mut frequencies: HashMap<Vec<u8>, u64> = HashMap::new();
    let mut longest = 0;
    for line in text.split('\n') {
        let fields: Vec<_> = line.split('\t').filter(|f| !f.is_empty()).collect();
        if fields.len() < 3 {
            continue;
        }
        let Ok(frequency) = fields[2].parse::<i64>() else {
            continue;
        };
        if frequency < 0 {
            continue;
        }
        let Some(key) = encode(fields[0]) else {
            continue;
        };
        let entry = frequencies.entry(key).or_insert(0);
        *entry = (*entry).max(frequency as u64);
        longest = longest.max(fields[0].graphemes(true).count());
    }
    let mut tables = vec![Vec::new(); PHRASE_LIMIT - 1];
    for (key, frequency) in frequencies {
        tables[key.len() / 3 - 2].push((key, frequency));
    }
    let mut data = Vec::new();
    data.extend_from_slice(MAGIC);
    for value in [VERSION, longest as u32]
        .into_iter()
        .chain(tables.iter().map(|table| table.len() as u32))
    {
        data.extend_from_slice(&value.to_le_bytes());
    }
    for table in &mut tables {
        table.sort();
        for (key, frequency) in table.iter() {
            data.extend_from_slice(key);
            data.extend_from_slice(&frequency.to_le_bytes());
        }
    }
    Ok(data)
}

/// Three bytes per canonical scalar for a phrase of 2–8 Han graphemes; `None` otherwise.
fn encode(phrase: &str) -> Option<Vec<u8>> {
    let mut count = 0;
    for grapheme in phrase.graphemes(true) {
        let mut scalars = grapheme.chars();
        match (scalars.next(), scalars.next()) {
            (Some(scalar), None) if is_han(scalar) => count += 1,
            _ => return None,
        }
    }
    if !(2..=PHRASE_LIMIT).contains(&count) {
        return None;
    }
    let mut bytes = Vec::with_capacity(count * 3);
    for scalar in phrase.nfc() {
        let value = scalar as u32;
        bytes.extend_from_slice(&[(value >> 16) as u8, (value >> 8) as u8, value as u8]);
    }
    Some(bytes)
}

fn is_han(scalar: char) -> bool {
    matches!(scalar as u32,
        0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2FA1F | 0x30000..=0x323AF)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(index: &[u8]) -> Vec<u32> {
        index[4..40]
            .chunks(4)
            .map(|c| u32::from_le_bytes(c.try_into().unwrap()))
            .collect()
    }

    #[test]
    fn sorted_fixed_width_tables_per_phrase_length() {
        let index = context_index(
            "---\nname: x\n...\n你好\tni hao\t5\n你好\tni hao\t9\n世界你好\tshi jie ni hao\t2\n\
             一\tyi\t3\nabc\tabc\t4\n坏\tbad\n负\tfu\t-1\n九个汉字九个汉字九\t...\t1\n"
                .as_bytes(),
        )
        .unwrap();
        assert_eq!(&index[..4], b"IFCX");
        assert_eq!(fields(&index), [1, 4, 1, 0, 1, 0, 0, 0, 0]);
        let record = &index[40..40 + 2 * 3 + 8];
        assert_eq!(&record[..6], &[0x00, 0x4F, 0x60, 0x00, 0x59, 0x7D]);
        assert_eq!(u64::from_le_bytes(record[6..].try_into().unwrap()), 9);
        assert_eq!(index.len(), 40 + (6 + 8) + (12 + 8));
    }

    #[test]
    fn empty_dictionary_has_only_a_header() {
        assert_eq!(context_index(b"").unwrap().len(), 40);
        assert_eq!(context_index(&[0xFF]).unwrap_err().code, "context-index");
    }
}
