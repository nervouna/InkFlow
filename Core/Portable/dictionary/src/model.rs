use serde::{Deserialize, Serialize};
use sha1::Sha1;
use sha2::{Digest, Sha256};

pub const RECIPE_VERSION: u32 = 2;
pub const MAX_SOURCE_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_WEIGHT: u32 = i32::MAX as u32;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceSpec {
    pub id: String,
    pub group: String,
    pub name: String,
    pub repository: String,
    pub branch: String,
    pub path: String,
    pub pinned_commit: String,
    #[serde(rename = "pinnedBlobSHA")]
    pub pinned_blob_sha: String,
    #[serde(rename = "pinnedSHA256")]
    pub pinned_sha256: String,
    pub pinned_byte_count: usize,
    pub default_weight: Option<u32>,
}

impl SourceSpec {
    pub fn pinned_receipt(&self) -> Receipt {
        Receipt {
            id: self.id.clone(),
            name: self.name.clone(),
            repository: self.repository.clone(),
            path: self.path.clone(),
            commit: self.pinned_commit.clone(),
            blob_sha: self.pinned_blob_sha.clone(),
            sha256: self.pinned_sha256.clone(),
            byte_count: self.pinned_byte_count,
            record_count: 0,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub id: String,
    pub name: String,
    pub repository: String,
    pub path: String,
    pub commit: String,
    #[serde(rename = "blobSHA")]
    pub blob_sha: String,
    pub sha256: String,
    pub byte_count: usize,
    pub record_count: usize,
}

pub struct Input {
    pub receipt: Receipt,
    pub data: Vec<u8>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Bucket {
    pub syllables: usize,
    pub pair_count: usize,
    pub multiplier: f64,
    pub used_overall: bool,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Calibration {
    pub source_group: String,
    pub pair_count: usize,
    pub overall_multiplier: f64,
    pub buckets: Vec<Bucket>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub format_version: u32,
    pub recipe_version: u32,
    pub content_version: String,
    pub entry_count: usize,
    #[serde(rename = "contentSHA256")]
    pub content_sha256: String,
    #[serde(rename = "dictionarySHA256")]
    pub dictionary_sha256: String,
    #[serde(rename = "correctionsSHA256")]
    pub corrections_sha256: String,
    pub sources: Vec<Receipt>,
    pub calibrations: Vec<Calibration>,
}

pub struct Generation {
    pub dictionary: Vec<u8>,
    pub manifest: Manifest,
}

#[derive(Debug, PartialEq)]
pub struct Error {
    pub code: &'static str,
    pub source: Option<String>,
    pub line: Option<usize>,
}
impl Error {
    pub(crate) fn new(code: &'static str) -> Self {
        Self {
            code,
            source: None,
            line: None,
        }
    }
    pub(crate) fn at(mut self, source: &str, line: Option<usize>) -> Self {
        self.source = Some(source.to_owned());
        self.line = line;
        self
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.code)?;
        if let Some(source) = &self.source {
            write!(f, ": {source}")?;
        }
        if let Some(line) = self.line {
            write!(f, ": line {line}")?;
        }
        Ok(())
    }
}
impl std::error::Error for Error {}
pub type Result<T> = std::result::Result<T, Error>;

pub fn sha256(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
pub fn git_blob(data: &[u8]) -> String {
    let mut hash = Sha1::new();
    hash.update(format!("blob {}\0", data.len()));
    hash.update(data);
    format!("{:x}", hash.finalize())
}

pub fn validate(input: &Input) -> Result<()> {
    let r = &input.receipt;
    let error = |code| Error::new(code).at(&r.id, None);
    if [(&r.commit, 40), (&r.blob_sha, 40), (&r.sha256, 64)]
        .iter()
        .any(|(value, len)| {
            value.len() != *len
                || !value
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
    {
        return Err(error("invalid-receipt"));
    }
    if input.data.is_empty()
        || input.data.len() > MAX_SOURCE_BYTES
        || input.data.len() != r.byte_count
    {
        return Err(error("source-size"));
    }
    if git_blob(&input.data) != r.blob_sha || sha256(&input.data) != r.sha256 {
        return Err(error("source-checksum"));
    }
    Ok(())
}
