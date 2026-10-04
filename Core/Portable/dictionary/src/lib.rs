//! Offline dictionary generation. Inputs and provenance are supplied by the caller.
mod model;
mod spelling;
pub use model::*;
pub use spelling::spelling;

use std::collections::{HashMap, HashSet};
use std::fmt::Write;
use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Hash, PartialEq, Eq)]
struct Key {
    text: String,
    reading: String,
}
struct Value {
    text: String,
    weight: u32,
}
type Rows = HashMap<Key, Value>;

// Foundation's whitespace sets are part of the existing parser contract.
fn whitespace(c: char) -> bool {
    matches!(
        c as u32,
        0x09 | 0x20 | 0xa0 | 0x1680 | 0x2000..=0x200b | 0x202f | 0x205f | 0x3000
    )
}
fn whitespace_or_newline(c: char) -> bool {
    whitespace(c) || matches!(c as u32, 0x0a..=0x0d | 0x85 | 0x2028 | 0x2029)
}

// Swift splits on the LF Character, so the CRLF grapheme is not a separator.
// Preserve that behavior during migration rather than silently accepting new input.
fn lines(input: &str) -> impl Iterator<Item = &str> {
    let mut position = 0;
    std::iter::from_fn(move || {
        if position > input.len() {
            return None;
        }
        let start = position;
        while let Some(offset) = input[position..].find('\n') {
            let end = position + offset;
            position = end + 1;
            if end > 0 && input.as_bytes()[end - 1] == b'\r' {
                continue;
            }
            return Some(&input[start..end]);
        }
        position = input.len() + 1;
        Some(&input[start..])
    })
}

pub fn normalized_reading(value: &str) -> Result<String> {
    let normalized = value
        .nfc()
        .collect::<String>()
        .to_lowercase()
        .replace('ü', "v");
    let syllables: Vec<_> = normalized.split_whitespace().collect();
    if syllables.is_empty()
        || syllables.len() > 128
        || syllables
            .iter()
            .any(|s| s.len() > 8 || !s.bytes().all(|b| b.is_ascii_lowercase()))
    {
        return Err(Error::new("invalid-reading"));
    }
    Ok(syllables.join(" "))
}

fn row(fields: &[&str], source: &str, line: usize) -> Result<(Key, Value)> {
    let text = fields[0];
    let han = text.chars().any(|c| {
        matches!(c as u32,
        0x3007 | 0x3400..=0x9fff | 0xf900..=0xfaff | 0x20000..=0x323af)
    });
    let weight = fields[2].parse::<u32>();
    if !han
        || text.graphemes(true).count() > 256
        || text != text.trim_matches(whitespace_or_newline)
        || text.chars().any(|c| {
            matches!(
                get_general_category(c),
                GeneralCategory::Control | GeneralCategory::Format
            )
        })
        || fields[2].is_empty()
        || !fields[2].bytes().all(|b| b.is_ascii_digit())
        || !matches!(weight, Ok(w) if w <= MAX_WEIGHT)
    {
        return Err(Error::new("source-format").at(source, Some(line)));
    }
    let reading = normalized_reading(fields[1]).map_err(|e| e.at(source, Some(line)))?;
    // Swift String keys compare canonically, while output retains the first spelling.
    Ok((
        Key {
            text: text.nfc().collect(),
            reading,
        },
        Value {
            text: text.to_owned(),
            weight: weight.unwrap(),
        },
    ))
}

fn read_rows(
    data: &[u8],
    source: &str,
    default_weight: Option<u32>,
    mut receive: impl FnMut(Key, Value),
) -> Result<usize> {
    let input =
        std::str::from_utf8(data).map_err(|_| Error::new("source-format").at(source, None))?;
    let mut header = false;
    let mut body = false;
    let mut count = 0;
    for (offset, raw) in lines(input).enumerate() {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let error = || Error::new("source-format").at(source, Some(offset + 1));
        if line.len() > 8192 {
            return Err(error());
        }
        if !body {
            if line == "---" {
                header = true;
            }
            if line == "..." && header {
                body = true;
            }
            continue;
        }
        let trimmed = line.trim_matches(whitespace);
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let mut fields: Vec<_> = line.split('\t').collect();
        let fallback = default_weight.map(|w| w.to_string());
        if fields.len() == 2
            && let Some(ref weight) = fallback
        {
            fields.push(weight);
        }
        if fields.len() != 3 {
            return Err(error());
        }
        let (key, value) = row(&fields, source, offset + 1)?;
        receive(key, value);
        count += 1;
        if count > 3_000_000 {
            return Err(Error::new("source-format").at(source, None));
        }
    }
    if !body || count == 0 {
        return Err(Error::new("source-format").at(source, None));
    }
    Ok(count)
}

fn corrections(data: &[u8]) -> Result<Vec<(Key, Value)>> {
    if data.len() > 1_048_576 {
        return Err(Error::new("correction-format"));
    }
    let input = std::str::from_utf8(data).map_err(|_| Error::new("correction-format"))?;
    let mut seen = HashSet::new();
    let mut rows = Vec::new();
    for (offset, raw) in lines(input).enumerate() {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let trimmed = line.trim_matches(whitespace);
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let fields: Vec<_> = line.split('\t').collect();
        if fields.len() != 4 || fields[3].trim_matches(whitespace).is_empty() {
            return Err(Error {
                code: "correction-format",
                source: None,
                line: Some(offset + 1),
            });
        }
        let entry = row(&fields[..3], "corrections", offset + 1)?;
        if !seen.insert(entry.0.clone()) {
            return Err(Error {
                code: "correction-duplicate",
                source: None,
                line: Some(offset + 1),
            });
        }
        rows.push(entry);
    }
    Ok(rows)
}

fn bucket(reading: &str) -> usize {
    reading.split(' ').count().min(5) - 1
}
fn median_multiplier(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    let middle = values.len() / 2;
    let median = if values.len().is_multiple_of(2) {
        (values[middle - 1] + values[middle]) / 2.0
    } else {
        values[middle]
    };
    median.exp()
}
fn calibrate(source: &Rows, baseline: &Rows, name: &str) -> Result<Calibration> {
    let mut groups: [Vec<f64>; 5] = std::array::from_fn(|_| Vec::new());
    for (key, value) in source {
        if value.weight > 0
            && let Some(reference) = baseline.get(key)
            && reference.weight > 0
        {
            groups[bucket(&key.reading)]
                .push((f64::from(reference.weight) / f64::from(value.weight)).ln());
        }
    }
    let all: Vec<_> = groups.iter().flatten().copied().collect();
    if all.is_empty() {
        return Err(Error::new("calibration-empty").at(name, None));
    }
    let pair_count = all.len();
    let overall = median_multiplier(all);
    let buckets = groups
        .into_iter()
        .enumerate()
        .map(|(index, values)| Bucket {
            syllables: index + 1,
            pair_count: values.len(),
            used_overall: values.len() < 100,
            multiplier: if values.len() < 100 {
                overall
            } else {
                median_multiplier(values)
            },
        })
        .collect();
    Ok(Calibration {
        source_group: name.to_owned(),
        pair_count,
        overall_multiplier: overall,
        buckets,
    })
}

pub fn generate(
    inputs: &[Input],
    correction_data: &[u8],
    catalog: &[SourceSpec],
) -> Result<Generation> {
    if !inputs
        .iter()
        .map(|i| &i.receipt.id)
        .eq(catalog.iter().map(|s| &s.id))
    {
        return Err(Error::new("source-set"));
    }
    let mut groups: HashMap<String, Rows> = HashMap::new();
    let mut receipts = Vec::new();
    for (spec, input) in catalog.iter().zip(inputs) {
        validate(input)?;
        let receipt = &input.receipt;
        if receipt.repository != spec.repository || receipt.path != spec.path {
            return Err(Error::new("source-location").at(&spec.id, None));
        }
        if spec.group == "legacy"
            && (receipt.commit != spec.pinned_commit
                || receipt.blob_sha != spec.pinned_blob_sha
                || receipt.sha256 != spec.pinned_sha256)
        {
            return Err(Error::new("legacy-changed").at(&spec.id, None));
        }
        let group = groups.entry(spec.group.clone()).or_default();
        let count = read_rows(
            &input.data,
            &spec.id,
            spec.default_weight,
            |mut key, value| {
                if spec.id == "selected-computer"
                    && key.text == "串行打印机"
                    && key.reading == "chuan hang da yin ji"
                {
                    key.reading = "chuan xing da yin ji".to_owned();
                }
                group.entry(key).or_insert(value);
            },
        )?;
        let mut receipt = receipt.clone();
        receipt.record_count = count;
        receipts.push(receipt);
    }
    let frost = groups
        .remove("frost")
        .ok_or_else(|| Error::new("source-set"))?;
    let mut calibrations = Vec::new();
    for name in ["ice", "legacy"] {
        let group = groups
            .get(name)
            .ok_or_else(|| Error::new("source-set").at(name, None))?;
        calibrations.push(calibrate(group, &frost, name)?);
    }
    let mut union = frost;
    for calibration in &calibrations {
        for (key, mut value) in groups.remove(&calibration.source_group).unwrap() {
            if value.weight > 0 {
                let mapped =
                    f64::from(value.weight) * calibration.buckets[bucket(&key.reading)].multiplier;
                value.weight = mapped.round().clamp(1.0, f64::from(MAX_WEIGHT)) as u32;
            }
            union.entry(key).or_insert(value);
        }
    }
    for (key, value) in groups.remove("specialty").unwrap_or_default() {
        union.entry(key).or_insert(value);
    }
    for (key, value) in corrections(correction_data)? {
        union
            .entry(key)
            .and_modify(|previous| previous.weight = value.weight)
            .or_insert(value);
    }
    let mut rows: Vec<_> = union.into_iter().collect();
    rows.sort_by(|(a, va), (b, vb)| {
        if a.text == b.text {
            a.reading.cmp(&b.reading)
        } else {
            va.text.cmp(&vb.text)
        }
    });
    let mut body = String::with_capacity(rows.len() * 36);
    for (key, value) in &rows {
        writeln!(body, "{}\t{}\t{}", value.text, key.reading, value.weight).unwrap();
    }
    let version = format!(
        "r{RECIPE_VERSION}-{}",
        sha256(format!("recipe:{RECIPE_VERSION}\n{body}").as_bytes())
    );
    let dictionary = format!("# Generated by InkFlow from Rime Frost, Rime Ice, rime-selected and pinned pinyin_simp.\n# Baseline weights are retained; specialty data fills gaps. See bundled Licenses.\n---\nname: pinyin_simp\nversion: '{version}'\nsort: by_weight\nuse_preset_vocabulary: false\n...\n{body}").into_bytes();
    let manifest = Manifest {
        format_version: 1,
        recipe_version: RECIPE_VERSION,
        content_version: version,
        entry_count: rows.len(),
        content_sha256: sha256(body.as_bytes()),
        dictionary_sha256: sha256(&dictionary),
        corrections_sha256: sha256(correction_data),
        sources: receipts,
        calibrations,
    };
    Ok(Generation {
        dictionary,
        manifest,
    })
}
