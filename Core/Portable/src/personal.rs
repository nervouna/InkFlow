//! Portable personal data: the macOS format-1 backup document, user-dictionary snapshots
//! through the native helper, and a rollback-first install into an isolated user directory.
//!
//! Supported data: the three Rime user dictionaries, custom phrases, the candidate count and
//! input options. macOS-only preferences (shortcuts, font size, layout, voice rules) are
//! skipped and listed in [`Backup::unsupported`]. Nothing here runs while an engine is
//! initialized in the process; callers stop the engine first.
use crate::{
    Error,
    phrases::CustomPhrase,
    preferences::{InputOption, InputPreferences},
};
use serde_json::{Map, Value, json};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub const DICTIONARIES: [&str; 3] = [
    "pinyin_simp",
    "inkflow_shared_english",
    "inkflow_voice_alias",
];
pub const RIME_VERSION: &str = "1.17.0";
pub const MAXIMUM_DOCUMENT_BYTES: usize = 128 * 1024 * 1024;
const MAXIMUM_SNAPSHOT_BYTES: usize = 32 * 1024 * 1024;
const SNAPSHOT_HEADER: &str = "# Rime user dictionary\n";
const UNSUPPORTED_INTEGERS: [&str; 3] = ["fontSize", "vertical", "thunderMode"];

#[derive(Debug)]
pub enum PersonalError {
    /// Another format, Rime version or dictionary set.
    Incompatible,
    /// A field this core does not know; macOS rejects these too.
    UnknownFields,
    Settings,
    Phrases(crate::phrases::PhraseError),
    /// A dictionary snapshot breaks the TSV contract.
    Snapshot,
    /// The native helper rejected a snapshot or database; the user directory is unchanged.
    NativeSnapshot,
    /// An earlier import was interrupted; call [`recover`] before importing again.
    RecoveryRequired,
    /// An engine is still initialized in this process.
    EngineActive,
    Io(std::io::Error),
}

impl std::fmt::Display for PersonalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PersonalError::Phrases(error) => write!(f, "phrases: {}", error.code()),
            PersonalError::Io(error) => write!(f, "io: {error}"),
            other => write!(f, "{other:?}"),
        }
    }
}
impl std::error::Error for PersonalError {}
impl From<std::io::Error> for PersonalError {
    fn from(error: std::io::Error) -> Self {
        PersonalError::Io(error)
    }
}

/// The portable view of a macOS personal backup document.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Backup {
    pub rime: String,
    pub candidate_count: usize,
    pub input: InputPreferences,
    pub phrases: Vec<CustomPhrase>,
    /// `None` is explicit absence: importing removes the local dictionary.
    pub dictionaries: BTreeMap<String, Option<String>>,
    /// Document keys that were present but skipped because they are not portable.
    pub unsupported: Vec<String>,
}

fn validate_snapshot(snapshot: &str) -> Result<(), PersonalError> {
    if snapshot.len() > MAXIMUM_SNAPSHOT_BYTES
        || !snapshot.starts_with(SNAPSHOT_HEADER)
        || !snapshot.ends_with('\n')
        || snapshot.contains('\0')
        || snapshot.contains('\r')
    {
        return Err(PersonalError::Snapshot);
    }
    Ok(())
}

fn keys(object: &Map<String, Value>) -> Vec<&str> {
    object.keys().map(String::as_str).collect()
}

fn complete(names: &mut Vec<&str>) -> bool {
    names.sort_unstable();
    let mut expected = DICTIONARIES;
    expected.sort_unstable();
    *names == expected
}

impl Backup {
    /// Parse a format-1 document. Unknown fields are rejected; macOS-only fields are disclosed.
    pub fn from_json(bytes: &[u8]) -> Result<Self, PersonalError> {
        if bytes.len() > MAXIMUM_DOCUMENT_BYTES {
            return Err(PersonalError::Incompatible);
        }
        let document: Value =
            serde_json::from_slice(bytes).map_err(|_| PersonalError::Incompatible)?;
        let object = document.as_object().ok_or(PersonalError::Incompatible)?;
        if object.keys().any(|key| {
            !matches!(
                key.as_str(),
                "format" | "rime" | "settings" | "dictionaries"
            )
        }) {
            return Err(PersonalError::UnknownFields);
        }
        let rime = document["rime"].as_str().ok_or(PersonalError::Incompatible)?;
        if document["format"] != json!(1) || rime != RIME_VERSION {
            return Err(PersonalError::Incompatible);
        }
        let snapshots = document["dictionaries"]
            .as_object()
            .ok_or(PersonalError::Incompatible)?;
        if !complete(&mut keys(snapshots)) {
            return Err(PersonalError::Incompatible);
        }
        let mut dictionaries = BTreeMap::new();
        for (name, snapshot) in snapshots {
            let snapshot = match snapshot {
                Value::Null => None,
                Value::String(text) => {
                    validate_snapshot(text)?;
                    Some(text.clone())
                }
                _ => return Err(PersonalError::Incompatible),
            };
            dictionaries.insert(name.clone(), snapshot);
        }
        let settings = document["settings"]
            .as_object()
            .ok_or(PersonalError::Settings)?;
        if settings.keys().any(|key| {
            !matches!(
                key.as_str(),
                "integers" | "shortcuts" | "phrases" | "voiceRules"
            )
        }) {
            return Err(PersonalError::UnknownFields);
        }
        let integers = settings.get("integers").unwrap_or(&Value::Null)
            .as_object()
            .ok_or(PersonalError::Settings)?;
        let integer = |key: &str| {
            integers
                .get(key)
                .and_then(Value::as_i64)
                .ok_or(PersonalError::Settings)
        };
        let candidate_count = integer("candidateCount")?;
        if !(3..=9).contains(&candidate_count) {
            return Err(PersonalError::Settings);
        }
        let mut input = InputPreferences::default();
        for option in InputOption::ALL {
            input = input.with(
                option,
                match integer(&format!("input.{}", option.name()))? {
                    0 => false,
                    1 => true,
                    _ => return Err(PersonalError::Settings),
                },
            );
        }
        let mut unsupported = Vec::new();
        for key in integers.keys() {
            let known = key == "candidateCount"
                || key
                    .strip_prefix("input.")
                    .is_some_and(|name| InputOption::ALL.iter().any(|o| o.name() == name));
            if UNSUPPORTED_INTEGERS.contains(&key.as_str()) {
                unsupported.push(format!("settings.integers.{key}"));
            } else if !known {
                return Err(PersonalError::UnknownFields);
            }
        }
        // Neutral values (unbound shortcuts, no rules) are what this core writes; only real
        // macOS preferences are disclosed as skipped.
        let bound = settings
            .get("shortcuts")
            .and_then(Value::as_object)
            .is_some_and(|map| map.values().any(|binding| !binding["keyCode"].is_null()));
        if bound {
            unsupported.push("settings.shortcuts".into());
        }
        if settings
            .get("voiceRules")
            .and_then(Value::as_array)
            .is_some_and(|rules| !rules.is_empty())
        {
            unsupported.push("settings.voiceRules".into());
        }
        let mut phrases = Vec::new();
        for phrase in settings
            .get("phrases")
            .and_then(Value::as_array)
            .ok_or(PersonalError::Settings)?
        {
            let object = phrase.as_object().ok_or(PersonalError::Settings)?;
            if object
                .keys()
                .any(|key| !matches!(key.as_str(), "id" | "code" | "text"))
            {
                return Err(PersonalError::UnknownFields);
            }
            let field = |key: &str| {
                object
                    .get(key)
                    .and_then(Value::as_str)
                    .ok_or(PersonalError::Settings)
            };
            phrases.push(CustomPhrase {
                id: field("id")?.to_owned(),
                code: field("code")?.to_owned(),
                text: field("text")?.to_owned(),
            });
        }
        CustomPhrase::validate(&phrases).map_err(PersonalError::Phrases)?;
        Ok(Self {
            rime: rime.to_owned(),
            candidate_count: candidate_count as usize,
            input,
            phrases,
            dictionaries,
            unsupported,
        })
    }

    /// Encode a document macOS can read: unsupported preferences take their neutral values.
    /// macOS additionally requires the three fuzzy options to agree and exactly one paging pair.
    pub fn to_json(&self) -> Result<Vec<u8>, PersonalError> {
        let mut names: Vec<&str> = self.dictionaries.keys().map(String::as_str).collect();
        if !complete(&mut names) || !(3..=9).contains(&self.candidate_count) {
            return Err(PersonalError::Incompatible);
        }
        for snapshot in self.dictionaries.values().flatten() {
            validate_snapshot(snapshot)?;
        }
        CustomPhrase::validate(&self.phrases).map_err(PersonalError::Phrases)?;
        let mut integers = Map::new();
        integers.insert("candidateCount".into(), json!(self.candidate_count));
        integers.insert("fontSize".into(), json!(14));
        integers.insert("vertical".into(), json!(0));
        integers.insert("thunderMode".into(), json!(0));
        for option in InputOption::ALL {
            integers.insert(
                format!("input.{}", option.name()),
                json!(i32::from(self.input.get(option))),
            );
        }
        let none = json!({"keyCode": null, "modifierBits": 0, "keyLabel": ""});
        let shortcuts: Map<String, Value> = [
            "inputMode",
            "punctuation",
            "script",
            "voiceHold",
            "voiceToggle",
        ]
        .into_iter()
        .map(|action| (action.to_owned(), none.clone()))
        .collect();
        let phrases: Vec<Value> = self
            .phrases
            .iter()
            .map(|p| json!({"id": p.id, "code": p.code, "text": p.text}))
            .collect();
        let document = json!({
            "format": 1,
            "rime": RIME_VERSION,
            "settings": {"integers": integers, "shortcuts": shortcuts, "phrases": phrases, "voiceRules": []},
            "dictionaries": self.dictionaries,
        });
        let bytes = serde_json::to_vec(&document).map_err(|_| PersonalError::Incompatible)?;
        if bytes.len() > MAXIMUM_DOCUMENT_BYTES {
            return Err(PersonalError::Incompatible);
        }
        Ok(bytes)
    }
}

fn staging(user: &Path) -> Result<PathBuf, PersonalError> {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let root = user
        .join("PersonalData/staging")
        .join(format!("{}-{nanos}", std::process::id()));
    fs::create_dir_all(root.join("databases"))?;
    Ok(root)
}

fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::create_dir(to)?;
    for entry in fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn snapshot(root: &Path, name: &str, file: &Path, restore: bool) -> Result<(), PersonalError> {
    match crate::personal_data_snapshot(root, name, file, restore) {
        Ok(true) => Ok(()),
        Ok(false) => Err(PersonalError::NativeSnapshot),
        Err(Error::AlreadyRunning) => Err(PersonalError::EngineActive),
        Err(_) => Err(PersonalError::NativeSnapshot),
    }
}

/// Snapshot the user directory's closed dictionaries; an absent dictionary is `None`.
pub fn export(user: &Path) -> Result<BTreeMap<String, Option<String>>, PersonalError> {
    let root = staging(user)?;
    let result = (|| {
        let mut dictionaries = BTreeMap::new();
        for name in DICTIONARIES {
            let live = user.join(format!("{name}.userdb"));
            if !live.is_dir() {
                dictionaries.insert(name.to_owned(), None);
                continue;
            }
            // Work on a copy so the live database is never opened by the helper.
            copy_tree(&live, &root.join(format!("databases/{name}.userdb")))?;
            let file = root.join(format!("{name}.userdb.txt"));
            snapshot(&root.join("databases"), name, &file, false)?;
            let text = fs::read_to_string(&file)?;
            validate_snapshot(&text)?;
            dictionaries.insert(name.to_owned(), Some(text));
        }
        Ok(dictionaries)
    })();
    let _ = fs::remove_dir_all(&root);
    result
}

fn transaction(user: &Path) -> PathBuf {
    user.join("PersonalData/transaction")
}

/// Replace the user directory's dictionaries with the snapshots. Originals are kept until every
/// move succeeds and restored on failure; an interrupted run is finished by [`recover`].
pub fn import(
    user: &Path,
    dictionaries: &BTreeMap<String, Option<String>>,
) -> Result<(), PersonalError> {
    let mut names: Vec<&str> = dictionaries.keys().map(String::as_str).collect();
    if !complete(&mut names) {
        return Err(PersonalError::Incompatible);
    }
    if transaction(user).exists() {
        return Err(PersonalError::RecoveryRequired);
    }
    let root = staging(user)?;
    let staged = (|| {
        for (name, snapshot_text) in dictionaries {
            let Some(text) = snapshot_text else { continue };
            validate_snapshot(text)?;
            let file = root.join(format!("{name}.userdb.txt"));
            fs::write(&file, text)?;
            snapshot(&root.join("databases"), name, &file, true)?;
        }
        Ok(())
    })();
    if let Err(error) = staged {
        let _ = fs::remove_dir_all(&root);
        return Err(error);
    }
    let transaction = transaction(user);
    fs::create_dir_all(transaction.join("old"))?;
    let originals: Map<String, Value> = DICTIONARIES
        .iter()
        .map(|name| {
            (
                name.to_string(),
                json!(user.join(format!("{name}.userdb")).is_dir()),
            )
        })
        .collect();
    fs::write(
        transaction.join("journal.json"),
        serde_json::to_vec(&json!({"phase": "applying", "originals": originals})).unwrap(),
    )?;
    fs::rename(root.join("databases"), transaction.join("new"))?;
    let _ = fs::remove_dir_all(&root);
    let installed = install(user, &transaction);
    if installed.is_err() {
        rollback(user, &transaction)?;
        return installed;
    }
    let _ = fs::remove_dir_all(&transaction);
    Ok(())
}

fn install(user: &Path, transaction: &Path) -> Result<(), PersonalError> {
    for name in DICTIONARIES {
        let database = format!("{name}.userdb");
        let live = user.join(&database);
        if live.exists() {
            fs::rename(&live, transaction.join("old").join(&database))?;
        }
        let new = transaction.join("new").join(&database);
        if new.exists() {
            fs::rename(&new, &live)?;
        }
    }
    Ok(())
}

fn rollback(user: &Path, transaction: &Path) -> Result<(), PersonalError> {
    let journal: Value = serde_json::from_slice(&fs::read(transaction.join("journal.json"))?)
        .map_err(|_| PersonalError::RecoveryRequired)?;
    for name in DICTIONARIES {
        let database = format!("{name}.userdb");
        let live = user.join(&database);
        let old = transaction.join("old").join(&database);
        let had_original = journal["originals"][name] == json!(true);
        if old.exists() {
            if live.exists() {
                fs::remove_dir_all(&live)?;
            }
            fs::rename(&old, &live)?;
        } else if !had_original && live.exists() {
            fs::remove_dir_all(&live)?;
        } else if had_original && !live.exists() {
            return Err(PersonalError::RecoveryRequired);
        }
    }
    fs::remove_dir_all(transaction)?;
    Ok(())
}

/// Restore the originals of an interrupted import. No-op without a pending transaction.
pub fn recover(user: &Path) -> Result<(), PersonalError> {
    let transaction = transaction(user);
    if !transaction.exists() {
        return Ok(());
    }
    rollback(user, &transaction)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        format!(
            "# Rime user dictionary\n#@/db_name\t{name}\n#@/db_type\tuserdb\n#@/rime_version\t1.17.0\n#@/tick\t99\nni hao \t你好\tc=7 d=0.123456789 t=42\n"
        )
    }

    #[test]
    fn missing_fields_are_incompatible_not_panics() {
        for document in [
            "{}",
            r#"{"format":1}"#,
            r#"{"format":1,"rime":"1.17.0","settings":{},"dictionaries":{}}"#,
            r#"{"format":1,"rime":"1.17.0","settings":{"phrases":[]},"dictionaries":{"pinyin_simp":null,"inkflow_shared_english":null,"inkflow_voice_alias":null}}"#,
        ] {
            assert!(matches!(
                Backup::from_json(document.as_bytes()),
                Err(PersonalError::Incompatible | PersonalError::Settings)
            ));
        }
    }

    #[test]
    fn macos_document_round_trip() {
        let document = json!({
            "format": 1, "rime": "1.17.0",
            "settings": {
                "integers": {"candidateCount": 9, "fontSize": 18, "vertical": 1, "thunderMode": 0,
                    "input.abbreviation": 1, "input.typoTolerance": 0, "input.fuzzyZ": 1, "input.fuzzyC": 1, "input.fuzzyS": 1,
                    "input.emoji": 0, "input.bracketPaging": 0, "input.minusEqualPaging": 1, "input.englishPunctuation": 1,
                    "input.cornerQuotes": 0, "input.middleDot": 1, "input.fullwidthPipe": 1, "input.ideographicComma": 0, "input.traditional": 1},
                "shortcuts": {"inputMode": {"keyCode": 60, "modifierBits": 131072, "keyLabel": "右 Shift"}},
                "phrases": [{"id": "A", "code": "dz", "text": "地址"}],
                "voiceRules": [{"anything": true}]
            },
            "dictionaries": {"pinyin_simp": fixture("pinyin_simp"), "inkflow_shared_english": null, "inkflow_voice_alias": fixture("inkflow_voice_alias")}
        });
        let backup = Backup::from_json(&serde_json::to_vec(&document).unwrap()).unwrap();
        assert_eq!(backup.candidate_count, 9);
        assert!(
            backup.input.get(InputOption::FuzzyZ)
                && !backup.input.get(InputOption::Emoji)
                && backup.input.get(InputOption::Traditional)
        );
        assert!(
            !backup.input.get(InputOption::TypoTolerance)
                && backup.input.get(InputOption::MinusEqualPaging)
        );
        assert_eq!(
            backup.phrases,
            vec![CustomPhrase::validated("A", "dz", "地址").unwrap()]
        );
        assert_eq!(backup.dictionaries["inkflow_shared_english"], None);
        assert_eq!(
            backup.unsupported,
            [
                "settings.integers.fontSize",
                "settings.integers.thunderMode",
                "settings.integers.vertical",
                "settings.shortcuts",
                "settings.voiceRules"
            ]
        );
        let encoded = backup.to_json().unwrap();
        let again = Backup::from_json(&encoded).unwrap();
        assert!(
            again.candidate_count == 9
                && again.input == backup.input
                && again.phrases == backup.phrases
                && again.dictionaries == backup.dictionaries
        );
        let reencoded: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(reencoded["settings"]["integers"]["fontSize"], json!(14));
        assert_eq!(
            reencoded["settings"]["shortcuts"]["voiceHold"],
            json!({"keyCode": null, "modifierBits": 0, "keyLabel": ""})
        );
        for (mutate, expected) in [
            (json!({"credentials": "never"}), "UnknownFields"),
            (json!({"format": 2}), "Incompatible"),
            (json!({"rime": "1.16.0"}), "Incompatible"),
            (
                json!({"dictionaries": {"pinyin_simp": null}}),
                "Incompatible",
            ),
            (
                json!({"dictionaries": {"pinyin_simp": "no header\n", "inkflow_shared_english": null, "inkflow_voice_alias": null}}),
                "Snapshot",
            ),
            (
                json!({"settings": {"integers": {"candidateCount": 2}, "phrases": []}}),
                "Settings",
            ),
            (
                json!({"settings": {"integers": {"candidateCount": 5}, "phrases": []}}),
                "Settings",
            ),
            (json!({"settings.integers.input.extra": 1}), "UnknownFields"),
        ] {
            let mut broken = document.clone();
            for (key, value) in mutate.as_object().unwrap() {
                if key == "settings.integers.input.extra" {
                    broken["settings"]["integers"]["input.extra"] = value.clone();
                } else {
                    broken[key] = value.clone();
                }
            }
            let error = Backup::from_json(&serde_json::to_vec(&broken).unwrap()).unwrap_err();
            assert_eq!(format!("{error:?}"), expected, "{mutate}");
        }
    }
}
