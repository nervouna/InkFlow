//! The frontend-facing C ABI over [`crate::engine`]. `include/inkflow_rime.h` is the
//! hand-maintained contract; keep both in step.
//!
//! Every export catches panics and returns a status; nothing unwinds across the ABI.
//! Handles are opaque boxes, outputs are written only on `IFR_OK`, and every call is
//! serialized by the engine's own locks, so handles may be used from any thread.
use crate::{
    Error,
    engine::{
        Action, Configuration, ConfigurationError, Engine, EngineError, InputSession, Mutation,
        Snapshot,
    },
    personal::{self, Backup, PersonalError},
    phrases::CustomPhrase,
    preferences::{InputOption, InputPreferences},
};
use std::{
    cell::RefCell,
    ffi::{CStr, CString, c_char, c_int, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    path::{Path, PathBuf},
    ptr, slice,
    sync::Arc,
};

pub const ABI_VERSION: u32 = 1;

pub type Status = i32;
pub const OK: Status = 0;
pub const PANIC: Status = 1;
pub const INVALID_ARGUMENT: Status = 2;
pub const NATIVE: Status = 3;
pub const POISONED: Status = 4;
pub const ALREADY_RUNNING: Status = 5;
pub const SESSIONS_ACTIVE: Status = 6;
pub const RESOURCE: Status = 7;
pub const CONFIGURATION: Status = 8;
pub const IO: Status = 9;
pub const STALE_SNAPSHOT: Status = 10;
pub const INVALID_CANDIDATE: Status = 11;
pub const ENGINE_ACTIVE: Status = 12;
pub const INCOMPATIBLE: Status = 13;
pub const UNKNOWN_FIELDS: Status = 14;
pub const SETTINGS: Status = 15;
pub const PHRASES: Status = 16;
pub const SNAPSHOT: Status = 17;
pub const RECOVERY_REQUIRED: Status = 18;

pub struct Failure {
    status: Status,
    message: String,
}
impl Failure {
    fn new(status: Status, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
    fn argument(message: &str) -> Self {
        Self::new(INVALID_ARGUMENT, message)
    }
}
impl From<Error> for Failure {
    fn from(error: Error) -> Self {
        let status = match error {
            Error::AlreadyRunning => ALREADY_RUNNING,
            Error::SessionsActive => SESSIONS_ACTIVE,
            Error::InvalidString => INVALID_ARGUMENT,
            Error::InvalidUtf8 | Error::InvalidOffsets | Error::Native(_) => NATIVE,
            Error::StaleSnapshot => STALE_SNAPSHOT,
            Error::InvalidCandidate => INVALID_CANDIDATE,
            Error::Poisoned => POISONED,
            Error::Configuration(_) => CONFIGURATION,
        };
        Self::new(status, error.to_string())
    }
}
impl From<EngineError> for Failure {
    fn from(error: EngineError) -> Self {
        let message = error.to_string();
        let status = match error {
            EngineError::Native(error) => return Failure::from(error),
            EngineError::MissingResource(_) | EngineError::ContextIndex(_) => RESOURCE,
            EngineError::Configuration(_) => CONFIGURATION,
            EngineError::Io(_) => IO,
        };
        Self::new(status, message)
    }
}

impl From<PersonalError> for Failure {
    fn from(error: PersonalError) -> Self {
        let status = match error {
            PersonalError::Incompatible => INCOMPATIBLE,
            PersonalError::UnknownFields => UNKNOWN_FIELDS,
            PersonalError::Settings => SETTINGS,
            PersonalError::Phrases(_) => PHRASES,
            PersonalError::Snapshot => SNAPSHOT,
            PersonalError::NativeSnapshot => NATIVE,
            PersonalError::RecoveryRequired => RECOVERY_REQUIRED,
            PersonalError::EngineActive => ENGINE_ACTIVE,
            PersonalError::Io(_) => IO,
        };
        Self::new(status, error.to_string())
    }
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

/// Run one export body: panics and failures become a status and a thread-local message.
fn guard(work: impl FnOnce() -> Result<(), Failure>) -> Status {
    let failure = match catch_unwind(AssertUnwindSafe(work)) {
        Ok(Ok(())) => return OK,
        Ok(Err(failure)) => failure,
        Err(_) => Failure::new(PANIC, "panic"),
    };
    LAST_ERROR.with(|last| {
        *last.borrow_mut() = CString::new(failure.message.replace('\0', "?")).unwrap();
    });
    failure.status
}

unsafe fn text<'a>(pointer: *const c_char, name: &str) -> Result<&'a str, Failure> {
    if pointer.is_null() {
        return Err(Failure::argument(&format!("{name} is NULL")));
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|_| Failure::argument(&format!("{name} is not UTF-8")))
}

unsafe fn optional_path(pointer: *const c_char, name: &str) -> Result<Option<PathBuf>, Failure> {
    if pointer.is_null() {
        return Ok(None);
    }
    Ok(Some(PathBuf::from(unsafe { text(pointer, name) }?)))
}

unsafe fn reference<'a, T>(pointer: *const T, name: &str) -> Result<&'a T, Failure> {
    // Handles come from this module's boxes; the caller keeps them alive for the call.
    unsafe { pointer.as_ref() }.ok_or_else(|| Failure::argument(&format!("{name} is NULL")))
}

unsafe fn write<T>(pointer: *mut T, value: T) {
    if !pointer.is_null() {
        unsafe { ptr::write(pointer, value) };
    }
}

fn c_string(value: &str) -> Result<CString, Failure> {
    CString::new(value).map_err(|_| Failure::new(NATIVE, "embedded NUL in engine text"))
}

/// Input options as a bitmask in `InputOption::ALL` order.
fn options_from_mask(mask: u32) -> InputPreferences {
    InputOption::ALL
        .iter()
        .enumerate()
        .fold(InputPreferences::default(), |prefs, (bit, option)| {
            prefs.with(*option, mask & (1 << bit) != 0)
        })
}

fn mask_from_options(input: &InputPreferences) -> u32 {
    InputOption::ALL
        .iter()
        .enumerate()
        .fold(0, |mask, (bit, option)| {
            mask | (u32::from(input.get(*option)) << bit)
        })
}

fn configuration_code(error: ConfigurationError) -> &'static CStr {
    use crate::phrases::PhraseError;
    match error {
        ConfigurationError::Phrases(PhraseError::InvalidCode) => c"invalid-code",
        ConfigurationError::Phrases(PhraseError::ControlCharacter) => c"control-character",
        ConfigurationError::Phrases(PhraseError::EmptyText) => c"empty-text",
        ConfigurationError::Phrases(PhraseError::InvalidData) => c"invalid-data",
        ConfigurationError::Phrases(PhraseError::Duplicate) => c"duplicate",
        ConfigurationError::PhraseWrite => c"phrase-write",
        ConfigurationError::SessionReload => c"session-reload",
        ConfigurationError::MissingPrism => c"missing-prism",
        ConfigurationError::SchemaOpen => c"schema-open",
        ConfigurationError::PatchInit => c"patch-init",
        ConfigurationError::PatchLoad => c"patch-load",
        ConfigurationError::SchemaRestore => c"schema-restore",
        ConfigurationError::SchemaApply => c"schema-apply",
    }
}

#[repr(C)]
pub struct EngineConfig {
    pub shared: *const c_char,
    pub user: *const c_char,
    pub cache: *const c_char,
    pub context_index: *const c_char,
}

#[repr(C)]
pub struct Phrase {
    pub id: *const c_char,
    pub code: *const c_char,
    pub text: *const c_char,
}

/// An immutable display snapshot with NUL-terminated copies of every string.
pub struct SnapshotHandle {
    snapshot: Snapshot,
    input: CString,
    preedit: CString,
    candidates: Vec<(CString, CString)>,
}

impl SnapshotHandle {
    fn new(snapshot: Snapshot) -> Result<Self, Failure> {
        let input = c_string(&snapshot.input)?;
        let preedit = c_string(&snapshot.preedit)?;
        let candidates = snapshot
            .candidates
            .iter()
            .map(|c| Ok((c_string(&c.text)?, c_string(&c.comment)?)))
            .collect::<Result<Vec<_>, Failure>>()?;
        Ok(Self {
            snapshot,
            input,
            preedit,
            candidates,
        })
    }
}

pub const ACTION_KEY: c_int = 0;
pub const ACTION_SELECT: c_int = 1;
pub const ACTION_HIGHLIGHT: c_int = 2;
pub const ACTION_COMMIT: c_int = 3;
pub const ACTION_CLEAR: c_int = 4;
pub const ACTION_TOGGLE_ASCII: c_int = 5;

#[repr(C)]
pub struct MutationRecord {
    pub session: u64,
    pub action: c_int,
    pub key: i32,
    pub modifiers: i32,
    pub index: usize,
    pub handled: c_int,
    pub before: *const SnapshotHandle,
    pub after: *const SnapshotHandle,
}

pub type ObserverCallback =
    unsafe extern "C" fn(user_data: *mut c_void, mutation: *const MutationRecord);

struct Observer {
    callback: ObserverCallback,
    user_data: *mut c_void,
}
// The caller promises the callback and its data may be used from any mutating thread.
unsafe impl Send for Observer {}
unsafe impl Sync for Observer {}

impl Observer {
    fn deliver(&self, mutation: &Mutation) {
        let (Ok(before), Ok(after)) = (
            SnapshotHandle::new(mutation.before.clone()),
            SnapshotHandle::new(mutation.after.clone()),
        ) else {
            return;
        };
        let (action, key, modifiers, index) = match mutation.action {
            Action::Key { key, modifiers } => (ACTION_KEY, key, modifiers, 0),
            Action::Select(index) => (ACTION_SELECT, 0, 0, index),
            Action::Highlight(index) => (ACTION_HIGHLIGHT, 0, 0, index),
            Action::Commit => (ACTION_COMMIT, 0, 0, 0),
            Action::Clear => (ACTION_CLEAR, 0, 0, 0),
            Action::ToggleAscii => (ACTION_TOGGLE_ASCII, 0, 0, 0),
        };
        let record = MutationRecord {
            session: mutation.session,
            action,
            key,
            modifiers,
            index,
            handled: c_int::from(mutation.handled),
            before: &before,
            after: &after,
        };
        unsafe { (self.callback)(self.user_data, &record) };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn ifr_abi_version() -> u32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn ifr_last_error() -> *const c_char {
    LAST_ERROR.with(|last| last.borrow().as_ptr())
}

#[unsafe(no_mangle)]
pub extern "C" fn ifr_input_options_default() -> u32 {
    mask_from_options(&InputPreferences::default())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_engine_create(
    config: *const EngineConfig,
    engine: *mut *mut Arc<Engine>,
) -> Status {
    guard(|| {
        let config = unsafe { reference(config, "config") }?;
        if engine.is_null() {
            return Err(Failure::argument("engine is NULL"));
        }
        let configuration = Configuration {
            shared: PathBuf::from(unsafe { text(config.shared, "shared") }?),
            user: PathBuf::from(unsafe { text(config.user, "user") }?),
            cache: unsafe { optional_path(config.cache, "cache") }?,
            context_index: unsafe { optional_path(config.context_index, "context_index") }?,
        };
        let created = Engine::new(configuration)?;
        unsafe { write(engine, Box::into_raw(Box::new(created))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_engine_destroy(engine: *mut Arc<Engine>) {
    if !engine.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(engine) })));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_engine_context_ranking_ready(engine: *const Arc<Engine>) -> c_int {
    let mut ready = 0;
    guard(|| {
        ready = c_int::from(unsafe { reference(engine, "engine") }?.context_ranking_ready());
        Ok(())
    });
    ready
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_engine_set_observer(
    engine: *const Arc<Engine>,
    callback: Option<ObserverCallback>,
    user_data: *mut c_void,
) -> Status {
    guard(|| {
        let engine = unsafe { reference(engine, "engine") }?;
        engine.set_observer(callback.map(|callback| {
            let observer = Observer {
                callback,
                user_data,
            };
            Arc::new(move |mutation: &Mutation| observer.deliver(mutation))
                as Arc<crate::engine::Observer>
        }));
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_create(
    engine: *const Arc<Engine>,
    session: *mut *mut InputSession,
) -> Status {
    guard(|| {
        let engine = unsafe { reference(engine, "engine") }?;
        if session.is_null() {
            return Err(Failure::argument("session is NULL"));
        }
        let created = engine.session()?;
        unsafe { write(session, Box::into_raw(Box::new(created))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_destroy(session: *mut InputSession) {
    if !session.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(session) })));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_id(session: *const InputSession) -> u64 {
    let mut id = 0;
    guard(|| {
        id = unsafe { reference(session, "session") }?.id();
        Ok(())
    });
    id
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_available(session: *const InputSession) -> c_int {
    let mut available = 0;
    guard(|| {
        available = c_int::from(unsafe { reference(session, "session") }?.available());
        Ok(())
    });
    available
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_key(
    session: *const InputSession,
    key: i32,
    modifiers: i32,
    handled: *mut c_int,
) -> Status {
    guard(|| {
        let result = unsafe { reference(session, "session") }?.key(key, modifiers)?;
        unsafe { write(handled, c_int::from(result)) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_snapshot(
    session: *const InputSession,
    snapshot: *mut *mut SnapshotHandle,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        if snapshot.is_null() {
            return Err(Failure::argument("snapshot is NULL"));
        }
        let handle = SnapshotHandle::new(session.snapshot()?)?;
        unsafe { write(snapshot, Box::into_raw(Box::new(handle))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_free(snapshot: *mut SnapshotHandle) {
    if !snapshot.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            drop(unsafe { Box::from_raw(snapshot) })
        }));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_input(snapshot: *const SnapshotHandle) -> *const c_char {
    unsafe { snapshot.as_ref() }.map_or(ptr::null(), |s| s.input.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_preedit(snapshot: *const SnapshotHandle) -> *const c_char {
    unsafe { snapshot.as_ref() }.map_or(ptr::null(), |s| s.preedit.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_caret(snapshot: *const SnapshotHandle) -> usize {
    unsafe { snapshot.as_ref() }.map_or(0, |s| s.snapshot.caret_bytes)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_selection_start(snapshot: *const SnapshotHandle) -> usize {
    unsafe { snapshot.as_ref() }.map_or(0, |s| s.snapshot.selection_bytes.start)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_selection_end(snapshot: *const SnapshotHandle) -> usize {
    unsafe { snapshot.as_ref() }.map_or(0, |s| s.snapshot.selection_bytes.end)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_candidate_count(snapshot: *const SnapshotHandle) -> usize {
    unsafe { snapshot.as_ref() }.map_or(0, |s| s.candidates.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_candidate_text(
    snapshot: *const SnapshotHandle,
    index: usize,
) -> *const c_char {
    unsafe { snapshot.as_ref() }
        .and_then(|s| s.candidates.get(index))
        .map_or(ptr::null(), |(text, _)| text.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_candidate_comment(
    snapshot: *const SnapshotHandle,
    index: usize,
) -> *const c_char {
    unsafe { snapshot.as_ref() }
        .and_then(|s| s.candidates.get(index))
        .map_or(ptr::null(), |(_, comment)| comment.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_page(snapshot: *const SnapshotHandle) -> i32 {
    unsafe { snapshot.as_ref() }.map_or(0, |s| s.snapshot.page)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_highlighted(snapshot: *const SnapshotHandle) -> usize {
    unsafe { snapshot.as_ref() }.map_or(0, |s| s.snapshot.highlighted)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_last_page(snapshot: *const SnapshotHandle) -> c_int {
    unsafe { snapshot.as_ref() }.map_or(1, |s| c_int::from(s.snapshot.last_page))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_select(
    session: *const InputSession,
    snapshot: *const SnapshotHandle,
    index: usize,
    handled: *mut c_int,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        let snapshot = unsafe { reference(snapshot, "snapshot") }?;
        let result = session.select(&snapshot.snapshot, index)?;
        unsafe { write(handled, c_int::from(result)) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_highlight(
    session: *const InputSession,
    snapshot: *const SnapshotHandle,
    index: usize,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        let snapshot = unsafe { reference(snapshot, "snapshot") }?;
        Ok(session.highlight(&snapshot.snapshot, index)?)
    })
}

/// Paging is Rime's Page_Up/Page_Down through the same key policy as a frontend key.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_change_page(
    session: *const InputSession,
    backward: c_int,
    handled: *mut c_int,
) -> Status {
    let key = if backward != 0 { 0xff55 } else { 0xff56 };
    unsafe { ifr_session_key(session, key, 0, handled) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_commit(
    session: *const InputSession,
    handled: *mut c_int,
) -> Status {
    guard(|| {
        let result = unsafe { reference(session, "session") }?.commit()?;
        unsafe { write(handled, c_int::from(result)) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_clear(session: *const InputSession) -> Status {
    guard(|| Ok(unsafe { reference(session, "session") }?.clear()?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_take_commit(
    session: *const InputSession,
    commit: *mut *mut c_char,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        if commit.is_null() {
            return Err(Failure::argument("commit is NULL"));
        }
        let text = session.take_commit()?;
        let owned = if text.is_empty() {
            ptr::null_mut()
        } else {
            c_string(&text)?.into_raw()
        };
        unsafe { write(commit, owned) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_set_preceding_text(
    session: *const InputSession,
    text: *const c_char,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        let text = unsafe { self::text(text, "text") }?;
        Ok(session.set_preceding_text(text)?)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_set_configuration(
    session: *const InputSession,
    candidate_count: usize,
    phrases: *const Phrase,
    phrase_count: usize,
    options: *const u32,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        if phrase_count != 0 && phrases.is_null() {
            return Err(Failure::argument("phrases is NULL"));
        }
        if phrase_count > 65_536 {
            return Err(Failure::argument("too many phrases"));
        }
        let mut owned = Vec::with_capacity(phrase_count);
        for index in 0..phrase_count {
            let phrase = unsafe { &*phrases.add(index) };
            owned.push(CustomPhrase {
                id: unsafe { text(phrase.id, "phrase id") }?.to_owned(),
                code: unsafe { text(phrase.code, "phrase code") }?.to_owned(),
                text: unsafe { text(phrase.text, "phrase text") }?.to_owned(),
            });
        }
        let input = unsafe { options.as_ref() }.map(|mask| options_from_mask(*mask));
        Ok(session.set_configuration(candidate_count, &owned, input.as_ref())?)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_configuration_error(
    session: *const InputSession,
) -> *const c_char {
    let mut code = ptr::null();
    guard(|| {
        if let Some(error) = unsafe { reference(session, "session") }?.configuration_error() {
            code = configuration_code(error).as_ptr();
        }
        Ok(())
    });
    code
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_candidate_count(session: *const InputSession) -> usize {
    let mut count = 5;
    guard(|| {
        count = unsafe { reference(session, "session") }?.candidate_count();
        Ok(())
    });
    count
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_input_options(
    session: *const InputSession,
    options: *mut u32,
) -> c_int {
    let mut applied = 0;
    guard(|| {
        if let Some(input) = unsafe { reference(session, "session") }?.input_preferences() {
            unsafe { write(options, mask_from_options(&input)) };
            applied = 1;
        }
        Ok(())
    });
    applied
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_set_ascii_mode(
    session: *const InputSession,
    value: c_int,
) -> Status {
    guard(|| Ok(unsafe { reference(session, "session") }?.set_ascii_mode(value != 0)?))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_ascii_mode(
    session: *const InputSession,
    value: *mut c_int,
) -> Status {
    guard(|| {
        let result = unsafe { reference(session, "session") }?.ascii_mode()?;
        unsafe { write(value, c_int::from(result)) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_toggle_ascii_mode(
    session: *const InputSession,
    handled: *mut c_int,
) -> Status {
    guard(|| {
        let result = unsafe { reference(session, "session") }?.toggle_ascii_mode()?;
        unsafe { write(handled, c_int::from(result)) };
        Ok(())
    })
}

/// A parsed macOS backup with NUL-terminated copies of its portable settings.
pub struct BackupHandle {
    backup: Backup,
    phrases: Vec<(CString, CString, CString)>,
    unsupported: Vec<CString>,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_parse(
    bytes: *const u8,
    length: usize,
    backup: *mut *mut BackupHandle,
) -> Status {
    guard(|| {
        if backup.is_null() || (length != 0 && bytes.is_null()) {
            return Err(Failure::argument("backup or bytes is NULL"));
        }
        if length > personal::MAXIMUM_DOCUMENT_BYTES {
            return Err(Failure::new(INCOMPATIBLE, "document too large"));
        }
        let document = if length == 0 {
            &[][..]
        } else {
            unsafe { slice::from_raw_parts(bytes, length) }
        };
        let parsed = Backup::from_json(document)?;
        let phrases = parsed
            .phrases
            .iter()
            .map(|p| Ok((c_string(&p.id)?, c_string(&p.code)?, c_string(&p.text)?)))
            .collect::<Result<Vec<_>, Failure>>()?;
        let unsupported = parsed
            .unsupported
            .iter()
            .map(|key| c_string(key))
            .collect::<Result<Vec<_>, Failure>>()?;
        let handle = BackupHandle {
            backup: parsed,
            phrases,
            unsupported,
        };
        unsafe { write(backup, Box::into_raw(Box::new(handle))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_free(backup: *mut BackupHandle) {
    if !backup.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(backup) })));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_candidate_count(backup: *const BackupHandle) -> usize {
    unsafe { backup.as_ref() }.map_or(5, |b| b.backup.candidate_count)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_input_options(backup: *const BackupHandle) -> u32 {
    unsafe { backup.as_ref() }.map_or_else(
        || ifr_input_options_default(),
        |b| mask_from_options(&b.backup.input),
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_phrase_count(backup: *const BackupHandle) -> usize {
    unsafe { backup.as_ref() }.map_or(0, |b| b.phrases.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_phrase(
    backup: *const BackupHandle,
    index: usize,
    phrase: *mut Phrase,
) -> c_int {
    let Some((id, code, text)) = unsafe { backup.as_ref() }.and_then(|b| b.phrases.get(index))
    else {
        return 0;
    };
    unsafe {
        write(
            phrase,
            Phrase {
                id: id.as_ptr(),
                code: code.as_ptr(),
                text: text.as_ptr(),
            },
        )
    };
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_unsupported_count(backup: *const BackupHandle) -> usize {
    unsafe { backup.as_ref() }.map_or(0, |b| b.unsupported.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_unsupported(
    backup: *const BackupHandle,
    index: usize,
) -> *const c_char {
    unsafe { backup.as_ref() }
        .and_then(|b| b.unsupported.get(index))
        .map_or(ptr::null(), |key| key.as_ptr())
}

/// Replace the user directory's dictionaries with the backup's. Rejected while any engine
/// is initialized in this process; settings are applied by the frontend afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_backup_import(
    backup: *const BackupHandle,
    user: *const c_char,
) -> Status {
    guard(|| {
        let backup = unsafe { reference(backup, "backup") }?;
        let user = PathBuf::from(unsafe { text(user, "user") }?);
        if crate::engine_active() {
            return Err(Failure::new(ENGINE_ACTIVE, "an engine is initialized"));
        }
        Ok(personal::import(&user, &backup.backup.dictionaries)?)
    })
}

/// Finish an interrupted import; a no-op without a pending transaction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_personal_recover(user: *const c_char) -> Status {
    guard(|| {
        let user = PathBuf::from(unsafe { text(user, "user") }?);
        if crate::engine_active() {
            return Err(Failure::new(ENGINE_ACTIVE, "an engine is initialized"));
        }
        Ok(personal::recover(Path::new(&user))?)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn option_masks_round_trip() {
        let defaults = InputPreferences::default();
        assert_eq!(options_from_mask(ifr_input_options_default()), defaults);
        let traditional = defaults.with(InputOption::Traditional, true);
        let mask = mask_from_options(&traditional);
        assert_eq!(mask, ifr_input_options_default() | (1 << 13));
        assert_eq!(options_from_mask(mask), traditional);
        assert_eq!(
            configuration_code(ConfigurationError::PhraseWrite),
            c"phrase-write"
        );
    }
}
