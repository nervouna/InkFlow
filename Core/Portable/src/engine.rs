//! Session coordination and InkFlow policy, matching InkFlowRime/Engine.swift.
//!
//! Rime keeps editing, segmentation, lookup, paging and its own learning. This layer owns
//! equivalent-span ordering and selection, digit/arrow key policy, custom phrases, input
//! preferences, candidate counts and safe configuration boundaries. One policy lock
//! serializes every session of an engine; the native engine lock nests inside it.
//!
//! Quality recording stays outside: an optional [`Observer`] receives each mutation with
//! the displayed snapshots before and after, after the policy lock is released, so it can
//! neither change input nor block a key event on storage.
use crate::{
    Error, Result, Runtime, Session,
    phrases::{CustomPhrase, PhraseError, phrase_tsv},
    preferences::InputPreferences,
    ranking::{ContextRanker, Metadata, parse_metadata},
};
use std::{
    collections::BTreeMap,
    fs,
    ops::Range,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard},
};
use unicode_segmentation::UnicodeSegmentation;

pub const SCHEMA: &str = "inkflow_pinyin";
pub const PHRASE_FILE: &str = "custom_phrase.txt";
/// Preceding-text graphemes retained for context ranking.
pub const CONTEXT_LIMIT: usize = 16;
const PATCHED_NODES: [&str; 4] = ["menu", "translator", "key_binder", "punctuator"];

/// A configuration that could not be applied. The code is stable; frontends localize it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigurationError {
    Phrases(PhraseError),
    /// custom_phrase.txt could not be written; the file keeps its previous content.
    PhraseWrite,
    /// This session could not reload the schema after a phrase change; it retries on use.
    SessionReload,
    /// The compiled spelling profile is missing from the prepared cache.
    MissingPrism,
    SchemaOpen,
    PatchInit,
    PatchLoad,
    /// The temporary schema configuration could not be restored; restart the engine.
    SchemaRestore,
    /// The schema did not accept the patched configuration.
    SchemaApply,
}

impl ConfigurationError {
    pub fn code(self) -> &'static str {
        match self {
            ConfigurationError::Phrases(error) => error.code(),
            ConfigurationError::PhraseWrite => "phrase-write",
            ConfigurationError::SessionReload => "session-reload",
            ConfigurationError::MissingPrism => "missing-prism",
            ConfigurationError::SchemaOpen => "schema-open",
            ConfigurationError::PatchInit => "patch-init",
            ConfigurationError::PatchLoad => "patch-load",
            ConfigurationError::SchemaRestore => "schema-restore",
            ConfigurationError::SchemaApply => "schema-apply",
        }
    }
}

#[derive(Debug)]
pub enum EngineError {
    Native(Error),
    /// A required prepared resource is missing; the path is relative to its root.
    MissingResource(String),
    Configuration(ConfigurationError),
    ContextIndex(String),
    Io(std::io::Error),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Native(error) => write!(f, "native: {error}"),
            EngineError::MissingResource(path) => write!(f, "missing resource {path}"),
            EngineError::Configuration(error) => write!(f, "configuration: {}", error.code()),
            EngineError::ContextIndex(error) => write!(f, "context index: {error}"),
            EngineError::Io(error) => write!(f, "io: {error}"),
        }
    }
}
impl std::error::Error for EngineError {}
impl From<Error> for EngineError {
    fn from(error: Error) -> Self {
        EngineError::Native(error)
    }
}
impl From<std::io::Error> for EngineError {
    fn from(error: std::io::Error) -> Self {
        EngineError::Io(error)
    }
}

/// Prepared resources and the isolated writable user directory of one engine.
pub struct Configuration {
    pub shared: PathBuf,
    pub user: PathBuf,
    /// Target-native compiled cache. `None` compiles into `user/build` before any session.
    pub cache: Option<PathBuf>,
    /// The prepared `pinyin_simp.context.bin`; `None` keeps Rime's native order.
    pub context_index: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub text: String,
    pub comment: String,
    /// Position in Rime's current page; quality records keep both ranks.
    pub native_index: usize,
    /// Bounded ranking evidence for this candidate when ordering applied.
    pub evidence: Option<Metadata>,
}

/// The displayed page in InkFlow order. Offsets count UTF-8 bytes of `preedit`.
#[derive(Debug, Clone)]
pub struct Snapshot {
    token: Arc<()>,
    pub input: String,
    pub preedit: String,
    pub caret_bytes: usize,
    pub selection_bytes: Range<usize>,
    pub candidates: Vec<Candidate>,
    pub page: i32,
    /// Display index of Rime's highlighted candidate.
    pub highlighted: usize,
    pub last_page: bool,
}

impl PartialEq for Snapshot {
    fn eq(&self, other: &Self) -> bool {
        self.input == other.input
            && self.preedit == other.preedit
            && self.caret_bytes == other.caret_bytes
            && self.selection_bytes == other.selection_bytes
            && self.candidates == other.candidates
            && self.page == other.page
            && self.highlighted == other.highlighted
            && self.last_page == other.last_page
    }
}
impl Eq for Snapshot {}

impl Snapshot {
    /// Once a segment is selected, the immediate prefix is inside the mark.
    pub fn has_selected_prefix(&self) -> bool {
        self.selection_bytes.start > 0
    }
    pub fn texts(&self) -> Vec<&str> {
        self.candidates.iter().map(|c| c.text.as_str()).collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    Key { key: i32, modifiers: i32 },
    Select(usize),
    Highlight(usize),
    Commit,
    Clear,
    ToggleAscii,
}

/// One completed mutation of a session, delivered outside the policy lock.
#[derive(Debug, Clone)]
pub struct Mutation {
    pub session: u64,
    pub action: Action,
    pub handled: bool,
    pub before: Snapshot,
    pub after: Snapshot,
}

pub type Observer = dyn Fn(&Mutation) + Send + Sync;

struct Core {
    session: Option<Session>,
    lost: bool,
    candidate_count: usize,
    requested_count: usize,
    requested_input: InputPreferences,
    input: Option<InputPreferences>,
    saved_ascii: bool,
    buffered_commit: String,
    error: Option<ConfigurationError>,
    preceding: String,
    ordered_content: Option<crate::Snapshot>,
    order: Vec<usize>,
    metadata: Option<Vec<Metadata>>,
    token: Arc<()>,
}

impl Core {
    fn new(session: Session) -> Self {
        Self {
            session: Some(session),
            lost: false,
            candidate_count: 5,
            requested_count: 5,
            requested_input: InputPreferences::default(),
            input: None,
            saved_ascii: false,
            buffered_commit: String::new(),
            error: None,
            preceding: String::new(),
            ordered_content: None,
            order: Vec::new(),
            metadata: None,
            token: Arc::new(()),
        }
    }
    fn available(&self) -> bool {
        self.session.is_some() && !self.lost
    }
    fn reset_ordering(&mut self) {
        self.order.clear();
        self.metadata = None;
        self.ordered_content = None;
        self.token = Arc::new(());
    }
    fn detach(&mut self) {
        self.session = None;
        self.reset_ordering();
        self.preceding.clear();
    }
}

struct State {
    /// Custom phrases are Rime's native custom_phrase.txt in the user directory. The file is
    /// written only when settings change; every live session reloads it at the next shared idle.
    requested_phrases: Vec<CustomPhrase>,
    requested_tsv: String,
    file_tsv: String,
    file_error: bool,
    loaded_tsv: String,
    loaded_phrases: Vec<CustomPhrase>,
    sessions: BTreeMap<u64, Core>,
    next: u64,
}

pub struct Engine {
    state: Mutex<State>,
    observer: Mutex<Option<Arc<Observer>>>,
    runtime: Runtime,
    ranker: Option<ContextRanker>,
    user: PathBuf,
    compiled: PathBuf,
}

fn content(raw: &crate::Snapshot) -> crate::Snapshot {
    let mut content = raw.clone();
    content.highlighted = 0;
    content
}

impl Engine {
    /// Initialization, compilation and the first phrase-file sync are setup work.
    pub fn new(configuration: Configuration) -> std::result::Result<Arc<Self>, EngineError> {
        fs::create_dir_all(&configuration.user)?;
        let ranker = match &configuration.context_index {
            Some(path) => Some(
                ContextRanker::from_index(fs::read(path)?).map_err(EngineError::ContextIndex)?,
            ),
            None => None,
        };
        let compiled = configuration
            .cache
            .clone()
            .unwrap_or_else(|| configuration.user.join("build"));
        let mut runtime =
            Runtime::with_cache(&configuration.shared, &configuration.user, &compiled)?;
        if configuration.cache.is_none() {
            runtime.prepare()?;
        }
        for file in
            ["pinyin_simp.table.bin", "pinyin_simp.prism.bin"]
                .into_iter()
                .map(str::to_owned)
                .chain((0..32).map(|mask| {
                    format!("{}.prism.bin", crate::preferences::spelling_profile(mask))
                }))
        {
            if !compiled.join(&file).is_file() {
                return Err(EngineError::MissingResource(file));
            }
        }
        let file = configuration.user.join(PHRASE_FILE);
        let file_tsv = fs::read_to_string(&file).unwrap_or_else(|_| phrase_tsv(&[]));
        let mut state = State {
            requested_phrases: Vec::new(),
            requested_tsv: phrase_tsv(&[]),
            file_tsv,
            file_error: false,
            loaded_tsv: String::new(),
            loaded_phrases: Vec::new(),
            sessions: BTreeMap::new(),
            next: 1,
        };
        // No session exists yet: whatever the file holds now is what they all load.
        if let Some(error) = sync_phrase_file(&mut state, &file) {
            return Err(EngineError::Configuration(error));
        }
        state.loaded_tsv = state.file_tsv.clone();
        state.loaded_phrases = state.requested_phrases.clone();
        Ok(Arc::new(Self {
            state: Mutex::new(state),
            observer: Mutex::new(None),
            runtime,
            ranker,
            user: configuration.user,
            compiled,
        }))
    }

    /// Replace the observer. It runs after each mutation, outside every engine lock.
    pub fn set_observer(&self, observer: Option<Arc<Observer>>) {
        *self.observer.lock().unwrap_or_else(|e| e.into_inner()) = observer;
    }

    pub fn context_ranking_ready(&self) -> bool {
        self.ranker.is_some()
    }

    fn lock(&self) -> Result<MutexGuard<'_, State>> {
        self.state.lock().map_err(|_| Error::Poisoned)
    }

    pub fn session(self: &Arc<Self>) -> Result<InputSession> {
        let mut state = self.lock()?;
        let id = state.next;
        state.next += 1;
        let core = Core::new(self.runtime.session(SCHEMA)?);
        state.sessions.insert(id, core);
        let session = InputSession {
            engine: self.clone(),
            id,
        };
        if let Err(error) = self.restore(&mut state, id) {
            state.sessions.remove(&id);
            return Err(error);
        }
        Ok(session)
    }

    fn restore(&self, state: &mut State, id: u64) -> Result<()> {
        let core = state.sessions.get_mut(&id).unwrap();
        core.lost = false;
        if core.session.is_none() {
            core.session = Some(self.runtime.session(SCHEMA)?);
        }
        core.candidate_count = 5;
        core.input = None;
        core.error = None;
        core.reset_ordering();
        core.preceding.clear();
        self.apply_configuration_if_idle(state, id)?;
        let core = state.sessions.get_mut(&id).unwrap();
        if let Some(error) = core.error {
            core.detach();
            return Err(Error::Configuration(error.code()));
        }
        self.apply_runtime_options(core)
    }

    /// A session that could not be recreated during a phrase reload is retried on its next use.
    fn recover(&self, state: &mut State, id: u64) -> Result<()> {
        if !state.sessions[&id].lost {
            return Ok(());
        }
        if self.restore(state, id).is_err() {
            let core = state.sessions.get_mut(&id).unwrap();
            core.detach();
            core.lost = true;
        }
        Ok(())
    }

    fn raw(core: &mut Core) -> Result<crate::Snapshot> {
        match &mut core.session {
            Some(session) if !core.lost => session.snapshot(),
            _ => Ok(crate::Snapshot {
                token: Arc::new(()),
                preedit: String::new(),
                caret_bytes: 0,
                selection_bytes: 0..0,
                candidates: Vec::new(),
                page: 0,
                highlighted: 0,
                last_page: true,
            }),
        }
    }

    fn display(core: &mut Core) -> Result<Snapshot> {
        let raw = Self::raw(core)?;
        let input = match &mut core.session {
            Some(session) if !core.lost => session.input()?,
            _ => String::new(),
        };
        let order: Vec<usize> = if core.order.len() == raw.candidates.len() {
            core.order.clone()
        } else {
            (0..raw.candidates.len()).collect()
        };
        let candidates = order
            .iter()
            .map(|&native| Candidate {
                text: raw.candidates[native].text.clone(),
                comment: raw.candidates[native].comment.clone(),
                native_index: native,
                evidence: core
                    .metadata
                    .as_ref()
                    .and_then(|rows| rows.get(native).cloned()),
            })
            .collect();
        let highlighted = usize::try_from(raw.highlighted)
            .ok()
            .and_then(|native| order.iter().position(|&i| i == native))
            .unwrap_or(0);
        Ok(Snapshot {
            token: core.token.clone(),
            input,
            preedit: raw.preedit,
            caret_bytes: raw.caret_bytes,
            selection_bytes: raw.selection_bytes,
            candidates,
            page: raw.page,
            highlighted,
            last_page: raw.last_page,
        })
    }

    fn read_commit(core: &mut Core) -> Result<String> {
        match &mut core.session {
            Some(session) if !core.lost => Ok(session.take_commit()?.unwrap_or_default()),
            _ => Ok(String::new()),
        }
    }

    fn all_sessions_idle(state: &mut State) -> Result<bool> {
        for core in state.sessions.values_mut() {
            let commit = Self::read_commit(core)?;
            core.buffered_commit.push_str(&commit);
            if !Self::raw(core)?.preedit.is_empty() || !core.buffered_commit.is_empty() {
                return Ok(false);
            }
        }
        Ok(true)
    }

    fn apply_configuration_if_idle(&self, state: &mut State, id: u64) -> Result<()> {
        self.recover(state, id)?;
        let core = state.sessions.get_mut(&id).unwrap();
        if !core.available() {
            return Ok(());
        }
        if state.loaded_tsv != state.file_tsv {
            // Rime shares one loaded custom_phrase table among every session that holds it, so
            // the phrases change for all sessions at once. A composing session keeps its
            // snapshot and retries on its next idle key; its count still applies below.
            let core = state.sessions.get_mut(&id).unwrap();
            if Self::raw(core)?.preedit.is_empty() && Self::all_sessions_idle(state)? {
                return self.reload_sessions(state, id);
            }
        } else if state.requested_tsv == state.loaded_tsv {
            state.loaded_phrases = state.requested_phrases.clone();
        }
        let core = state.sessions.get_mut(&id).unwrap();
        if core.candidate_count == core.requested_count
            && core.input.as_ref() == Some(&core.requested_input)
        {
            if Self::raw(core)?.preedit.is_empty() {
                self.apply_runtime_options(core)?;
            }
            return Ok(());
        }
        if !Self::raw(core)?.preedit.is_empty() {
            return Ok(());
        }
        match self.recreate_schema(core)? {
            Ok(()) => core.error = None,
            Err(error) => core.error = Some(error),
        }
        Ok(())
    }

    /// The one deploy after a phrase change: release every session's dictionary handles first,
    /// so the next session reads the current file instead of the cached table, then recreate
    /// each session and reapply its own settings. All sessions are idle, so nothing is lost.
    fn reload_sessions(&self, state: &mut State, caller: u64) -> Result<()> {
        let mut ids: Vec<u64> = state
            .sessions
            .iter()
            .filter(|(_, core)| core.available())
            .map(|(id, _)| *id)
            .collect();
        if !ids.contains(&caller) {
            ids.push(caller);
        }
        for id in &ids {
            state.sessions.get_mut(id).unwrap().session = None;
        }
        state.loaded_tsv = state.file_tsv.clone();
        state.loaded_phrases = state.requested_phrases.clone();
        for id in ids {
            let core = state.sessions.get_mut(&id).unwrap();
            match self.runtime.session(SCHEMA) {
                Ok(session) => core.session = Some(session),
                Err(_) => {
                    // Siblings already loaded the current file; this session retries alone on its next use.
                    core.detach();
                    core.lost = true;
                    core.error = Some(ConfigurationError::SessionReload);
                    continue;
                }
            }
            core.candidate_count = 5;
            core.input = None;
            core.reset_ordering();
            self.apply_configuration_if_idle(state, id)?;
        }
        Ok(())
    }

    fn recreate_schema(
        &self,
        core: &mut Core,
    ) -> Result<std::result::Result<(), ConfigurationError>> {
        let profile = core.requested_input.spelling_profile();
        if !self.compiled.join(format!("{profile}.prism.bin")).is_file() {
            return Ok(Err(ConfigurationError::MissingPrism));
        }
        let yaml = format!(
            "{}\nmenu:\n  page_size: {}\ntranslator:\n  dictionary: pinyin_simp\n  prism: {profile}\n  preedit_format: ['xform/([nl])v/$1ü/', 'xform/([jqxy])v/$1u/']",
            core.requested_input.schema_patch(),
            core.requested_count
        );
        // select_schema resets the commit buffer as well as the schema. Preserve completed text
        // even if settings arrive before the frontend has drained the previous key's commit.
        let commit = Self::read_commit(core)?;
        core.buffered_commit.push_str(&commit);
        let session = core.session.as_mut().unwrap();
        let outcome = match session.apply_schema_patch(SCHEMA, &yaml, &PATCHED_NODES)? {
            Ok(outcome) => outcome,
            Err(crate::PatchFailure::SchemaOpen) => return Ok(Err(ConfigurationError::SchemaOpen)),
            Err(crate::PatchFailure::PatchInit) => return Ok(Err(ConfigurationError::PatchInit)),
            Err(crate::PatchFailure::PatchLoad) => return Ok(Err(ConfigurationError::PatchLoad)),
        };
        let loaded = outcome.patched && outcome.selected;
        if loaded {
            core.candidate_count = core.requested_count;
            core.input = Some(core.requested_input.clone());
        }
        self.apply_runtime_options(core)?;
        if !outcome.restored {
            return Ok(Err(ConfigurationError::SchemaRestore));
        }
        if !loaded {
            return Ok(Err(ConfigurationError::SchemaApply));
        }
        Ok(Ok(()))
    }

    fn apply_runtime_options(&self, core: &mut Core) -> Result<()> {
        let Some(input) = core.input.clone() else {
            return Ok(());
        };
        let ascii = core.saved_ascii;
        let Some(session) = core.session.as_mut().filter(|_| !core.lost) else {
            return Ok(());
        };
        use crate::preferences::InputOption;
        session.set_option("ascii_mode", ascii)?;
        session.set_option(
            "ascii_punct",
            ascii || input.get(InputOption::EnglishPunctuation),
        )?;
        session.set_option("emoji_suggestion", input.get(InputOption::Emoji))?;
        session.set_option("traditional", input.get(InputOption::Traditional))
    }

    fn input_ranking_metadata(
        core: &mut Core,
        page: i32,
        count: usize,
        input_length: usize,
    ) -> Result<Option<Vec<Metadata>>> {
        let Ok(page) = usize::try_from(page) else {
            return Ok(None);
        };
        let Some(offset) = page.checked_mul(core.candidate_count) else {
            return Ok(None);
        };
        if !(1..=9).contains(&count) {
            return Ok(None);
        }
        let session = core.session.as_mut().unwrap();
        let reply = session.call(
            "input_coverage",
            &[&offset.to_string(), &count.to_string()],
            512,
        )?;
        Ok(reply
            .filter(|reply| reply.status == "ok")
            .and_then(|reply| parse_metadata(&reply.body, offset, count, input_length)))
    }

    fn update_ordering(&self, state: &mut State, id: u64, force: bool) -> Result<()> {
        let loaded_phrases = &state.loaded_phrases;
        let core = state.sessions.get_mut(&id).unwrap();
        if !core.available() {
            return Ok(());
        }
        let raw = Self::raw(core)?;
        let current = content(&raw);
        if !force && core.ordered_content.as_ref() == Some(&current) {
            return Ok(());
        }
        // Explicit custom codes keep the user's ordered phrases ahead of ordinary words.
        // Use the applied snapshot so deferred settings cannot change a live composition.
        let input = core.session.as_mut().unwrap().input()?;
        let has_custom_code = loaded_phrases.iter().any(|phrase| phrase.code == input);
        // Once a segment is selected, the immediate prefix is inside the mark.
        // Leave these remaining candidates to Rime instead of applying older document text.
        core.order = (0..raw.candidates.len()).collect();
        core.metadata = None;
        if raw.selection_bytes.start == 0 && !has_custom_code {
            let metadata =
                Self::input_ranking_metadata(core, raw.page, raw.candidates.len(), input.len())?;
            if let Some(ranker) = &self.ranker {
                let texts: Vec<String> = raw.candidates.iter().map(|c| c.text.clone()).collect();
                core.order = ranker.order(&texts, &core.preceding, metadata.as_deref());
            }
            core.metadata = metadata;
        }
        if let Some(&first) = core.order.first() {
            core.session.as_mut().unwrap().highlight(first)?;
        }
        core.ordered_content = Some(content(&Self::raw(core)?));
        if raw.preedit.is_empty() {
            core.preceding.clear();
        }
        core.token = Arc::new(());
        Ok(())
    }

    fn perform_key(&self, state: &mut State, id: u64, key: i32, modifiers: i32) -> Result<bool> {
        let core = state.sessions.get_mut(&id).unwrap();
        let displayed = Self::display(core)?;
        if modifiers == 0 && (49..=57).contains(&key) {
            let index = (key - 49) as usize;
            if index < displayed.candidates.len() {
                self.select_display(state, id, index)?;
                return Ok(true);
            }
        }
        if modifiers == 0 && (key == 0xff52 || key == 0xff54) && !displayed.candidates.is_empty() {
            let delta = if key == 0xff54 { 1 } else { -1 };
            return self.move_highlight(state, id, delta, key);
        }
        let handled = core.session.as_mut().unwrap().process_key(key, modifiers)?;
        self.update_ordering(state, id, false)?;
        Ok(handled)
    }

    fn select_display(&self, state: &mut State, id: u64, index: usize) -> Result<bool> {
        let core = state.sessions.get_mut(&id).unwrap();
        let Some(&native) = core.order.get(index) else {
            return Ok(false);
        };
        let handled = core.session.as_mut().unwrap().select_native(native)?;
        self.update_ordering(state, id, false)?;
        Ok(handled)
    }

    fn highlight_display(core: &mut Core, index: usize) -> Result<()> {
        let Some(&native) = core.order.get(index) else {
            return Ok(());
        };
        core.session.as_mut().unwrap().highlight(native)?;
        // Highlighting a partial choice can change Rime's preedit and cursor.
        // Record the new content without overriding explicit user navigation.
        core.ordered_content = Some(content(&Self::raw(core)?));
        Ok(())
    }

    fn move_highlight(&self, state: &mut State, id: u64, delta: isize, key: i32) -> Result<bool> {
        let core = state.sessions.get_mut(&id).unwrap();
        let before = Self::display(core)?;
        let next = before.highlighted as isize + delta;
        if next >= 0 && (next as usize) < core.order.len() {
            Self::highlight_display(core, next as usize)?;
            return Ok(true);
        }
        // Let Rime decide whether another page exists, starting at its native edge.
        let edge = if delta > 0 { core.order.len() - 1 } else { 0 };
        let session = core.session.as_mut().unwrap();
        session.highlight(edge)?;
        let handled = session.process_key(key, 0)?;
        self.update_ordering(state, id, false)?;
        let core = state.sessions.get_mut(&id).unwrap();
        if Self::display(core)?.page != before.page {
            if delta < 0 {
                let last = core.order.len().saturating_sub(1);
                Self::highlight_display(core, last)?;
            }
        } else if !core.order.is_empty() {
            Self::highlight_display(core, before.highlighted)?;
        }
        Ok(handled)
    }
}

/// Returns the failure; the file keeps its previous content on failure.
fn sync_phrase_file(state: &mut State, file: &Path) -> Option<ConfigurationError> {
    if state.requested_tsv == state.file_tsv {
        return None;
    }
    if state.file_error {
        return Some(ConfigurationError::PhraseWrite);
    }
    if write_private(file, state.requested_tsv.as_bytes()).is_err() {
        state.file_error = true;
        return Some(ConfigurationError::PhraseWrite);
    }
    state.file_tsv = state.requested_tsv.clone();
    None
}

fn write_private(file: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let temporary = file.with_extension("txt.tmp");
    fs::write(&temporary, bytes)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    }
    fs::rename(&temporary, file)
}

/// One input context's session. Every method is synchronous and thread-agnostic.
pub struct InputSession {
    engine: Arc<Engine>,
    id: u64,
}

impl InputSession {
    pub fn id(&self) -> u64 {
        self.id
    }
    pub fn engine(&self) -> &Arc<Engine> {
        &self.engine
    }

    fn mutate<T>(
        &self,
        action: Action,
        handled: impl Fn(&T) -> bool,
        body: impl FnOnce(&mut State, u64) -> Result<T>,
    ) -> Result<T> {
        let observer = self
            .engine
            .observer
            .lock()
            .map_err(|_| Error::Poisoned)?
            .clone();
        let mut state = self.engine.lock()?;
        let before = match &observer {
            Some(_) => Some(Engine::display(state.sessions.get_mut(&self.id).unwrap())?),
            None => None,
        };
        let result = body(&mut state, self.id)?;
        let Some(observer) = observer else {
            return Ok(result);
        };
        let after = Engine::display(state.sessions.get_mut(&self.id).unwrap())?;
        drop(state);
        observer(&Mutation {
            session: self.id,
            action,
            handled: handled(&result),
            before: before.unwrap(),
            after,
        });
        Ok(result)
    }

    pub fn available(&self) -> bool {
        self.engine
            .lock()
            .map(|state| state.sessions[&self.id].available())
            .unwrap_or(false)
    }

    /// Keys and modifiers use Rime/X11 keysyms and masks. Digits select displayed candidates;
    /// Up/Down move the displayed highlight; everything else goes to Rime.
    pub fn key(&self, key: i32, modifiers: i32) -> Result<bool> {
        let engine = self.engine.clone();
        self.mutate(
            Action::Key { key, modifiers },
            |h| *h,
            |state, id| {
                engine.recover(state, id)?;
                if !state.sessions[&id].available() {
                    return Ok(false);
                }
                // Apply existing idle configuration before capturing the values this key actually uses.
                engine.apply_configuration_if_idle(state, id)?;
                engine.perform_key(state, id, key, modifiers)
            },
        )
    }

    /// Select a displayed candidate of `snapshot`, which must be this session's latest.
    pub fn select(&self, snapshot: &Snapshot, index: usize) -> Result<bool> {
        let engine = self.engine.clone();
        let token = snapshot.token.clone();
        self.mutate(
            Action::Select(index),
            |h| *h,
            |state, id| {
                let core = state.sessions.get_mut(&id).unwrap();
                if !core.available() {
                    return Ok(false);
                }
                if !Arc::ptr_eq(&core.token, &token) {
                    return Err(Error::StaleSnapshot);
                }
                if index >= core.order.len() {
                    return Err(Error::InvalidCandidate);
                }
                engine.select_display(state, id, index)
            },
        )
    }

    pub fn highlight(&self, snapshot: &Snapshot, index: usize) -> Result<()> {
        let token = snapshot.token.clone();
        self.mutate(
            Action::Highlight(index),
            |_| true,
            |state, id| {
                let core = state.sessions.get_mut(&id).unwrap();
                if !core.available() {
                    return Ok(());
                }
                if !Arc::ptr_eq(&core.token, &token) {
                    return Err(Error::StaleSnapshot);
                }
                if index >= core.order.len() {
                    return Err(Error::InvalidCandidate);
                }
                Engine::highlight_display(core, index)
            },
        )
    }

    /// Commit the composition as Rime would for a commit key.
    pub fn commit(&self) -> Result<bool> {
        let engine = self.engine.clone();
        self.mutate(
            Action::Commit,
            |h| *h,
            |state, id| {
                let core = state.sessions.get_mut(&id).unwrap();
                if !core.available() {
                    return Ok(false);
                }
                let handled = core.session.as_mut().unwrap().commit_composition()?;
                engine.update_ordering(state, id, false)?;
                Ok(handled)
            },
        )
    }

    pub fn clear(&self) -> Result<()> {
        let engine = self.engine.clone();
        self.mutate(
            Action::Clear,
            |_| true,
            |state, id| {
                let core = state.sessions.get_mut(&id).unwrap();
                if !core.available() {
                    return Ok(());
                }
                core.session.as_mut().unwrap().clear()?;
                engine.update_ordering(state, id, false)
            },
        )
    }

    /// Drain completed text once, including text preserved across a settings reload.
    pub fn take_commit(&self) -> Result<String> {
        let mut state = self.engine.lock()?;
        let core = state.sessions.get_mut(&self.id).unwrap();
        let commit = Engine::read_commit(core)?;
        let text = std::mem::take(&mut core.buffered_commit) + &commit;
        Ok(text)
    }

    /// Read-only; repeated reads return the same selection identity until a mutation.
    pub fn snapshot(&self) -> Result<Snapshot> {
        let mut state = self.engine.lock()?;
        Engine::display(state.sessions.get_mut(&self.id).unwrap())
    }

    /// Bounded document text before the caret; applied to the live composition.
    pub fn set_preceding_text(&self, text: &str) -> Result<()> {
        let graphemes: Vec<&str> = text.graphemes(true).collect();
        let start = graphemes.len().saturating_sub(CONTEXT_LIMIT);
        let prefix: String = graphemes[start..].concat();
        let mut state = self.engine.lock()?;
        let core = state.sessions.get_mut(&self.id).unwrap();
        if prefix == core.preceding {
            return Ok(());
        }
        core.preceding = prefix;
        if Engine::raw(core)?.preedit.is_empty() {
            return Ok(());
        }
        self.engine.update_ordering(&mut state, self.id, true)
    }

    pub fn set_candidate_count(&self, count: usize) -> Result<()> {
        let (phrases, input) = {
            let state = self.engine.lock()?;
            (
                state.requested_phrases.clone(),
                state.sessions[&self.id].requested_input.clone(),
            )
        };
        self.set_configuration(count, &phrases, Some(&input))
    }

    /// Settings apply at this session's next idle boundary; phrases apply to every idle session.
    pub fn set_configuration(
        &self,
        candidate_count: usize,
        phrases: &[CustomPhrase],
        input: Option<&InputPreferences>,
    ) -> Result<()> {
        let mut state = self.engine.lock()?;
        if let Err(error) = CustomPhrase::validate(phrases) {
            state.sessions.get_mut(&self.id).unwrap().error =
                Some(ConfigurationError::Phrases(error));
            return Ok(());
        }
        if phrases != state.requested_phrases.as_slice() {
            state.requested_phrases = phrases.to_vec();
            state.requested_tsv = phrase_tsv(phrases);
            state.file_error = false;
        }
        // The settings path writes the file; key events only ever reload it. Frontends push
        // the same settings on every refresh, so a failed write is retried only when the
        // phrases change or the engine restarts, and the whole configuration waits.
        if let Some(error) = sync_phrase_file(&mut state, &self.engine.user.join(PHRASE_FILE)) {
            state.sessions.get_mut(&self.id).unwrap().error = Some(error);
            return Ok(());
        }
        let core = state.sessions.get_mut(&self.id).unwrap();
        core.requested_count = if (3..=9).contains(&candidate_count) {
            candidate_count
        } else {
            5
        };
        if let Some(input) = input {
            core.requested_input = input.clone();
        }
        core.error = None;
        self.engine.apply_configuration_if_idle(&mut state, self.id)
    }

    pub fn configuration_error(&self) -> Option<ConfigurationError> {
        self.engine
            .lock()
            .ok()
            .and_then(|state| state.sessions[&self.id].error)
    }

    pub fn candidate_count(&self) -> usize {
        self.engine
            .lock()
            .map(|state| state.sessions[&self.id].candidate_count)
            .unwrap_or(5)
    }

    /// The preferences applied to this session, once a composition boundary accepted them.
    pub fn input_preferences(&self) -> Option<InputPreferences> {
        self.engine
            .lock()
            .ok()
            .and_then(|state| state.sessions[&self.id].input.clone())
    }

    pub fn requested_ascii_mode(&self) -> bool {
        self.engine
            .lock()
            .map(|state| state.sessions[&self.id].saved_ascii)
            .unwrap_or(false)
    }

    /// Rime's live ASCII switch, or the requested value while the session is unavailable.
    pub fn ascii_mode(&self) -> Result<bool> {
        let mut state = self.engine.lock()?;
        let core = state.sessions.get_mut(&self.id).unwrap();
        match core.session.as_mut().filter(|_| !core.lost) {
            Some(session) => session.option("ascii_mode"),
            None => Ok(core.saved_ascii),
        }
    }

    /// Requested ASCII mode; it starts after the current composition finishes.
    pub fn set_ascii_mode(&self, value: bool) -> Result<()> {
        let mut state = self.engine.lock()?;
        state.sessions.get_mut(&self.id).unwrap().saved_ascii = value;
        self.engine.apply_configuration_if_idle(&mut state, self.id)
    }

    pub fn toggle_ascii_mode(&self) -> Result<bool> {
        let engine = self.engine.clone();
        self.mutate(
            Action::ToggleAscii,
            |h| *h,
            |state, id| {
                let core = state.sessions.get_mut(&id).unwrap();
                if !core.available() {
                    return Ok(false);
                }
                core.saved_ascii = !core.saved_ascii;
                engine.apply_configuration_if_idle(state, id)?;
                Ok(true)
            },
        )
    }

    /// Bounded Lua channel request for optional features; never from a key callback.
    pub fn call(
        &self,
        op: &str,
        fields: &[&str],
        capacity: usize,
    ) -> Result<Option<crate::channel::Reply>> {
        let mut state = self.engine.lock()?;
        let core = state.sessions.get_mut(&self.id).unwrap();
        match core.session.as_mut().filter(|_| !core.lost) {
            Some(session) => session.call(op, fields, capacity),
            None => Ok(None),
        }
    }
}

impl Drop for InputSession {
    fn drop(&mut self) {
        let mut state = self.engine.state.lock().unwrap_or_else(|e| e.into_inner());
        state.sessions.remove(&self.id);
    }
}
