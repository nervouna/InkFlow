use crate::{
    Error,
    engine::{
        Configuration, Engine, EngineError, InputSession, LearningEntry, LearningError,
        LearningSource, LearningUndo, Snapshot,
    },
    personal::{self, Backup, PersonalError},
    phrases::{CustomPhrase, PhraseError},
    preferences::{InputOption, InputPreferences},
    ranking::PersonalSource,
    resources::{self, ResourceError},
};
use std::{
    cell::RefCell,
    collections::BTreeMap,
    ffi::{CStr, CString, c_char, c_int, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    path::{Path, PathBuf},
    ptr, slice,
    sync::{Arc, OnceLock},
};

pub const ABI_VERSION: u32 = 4;

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
pub const BUSY: Status = 19;
pub const UNAVAILABLE: Status = 20;
pub const CONFLICT: Status = 21;
pub const TOO_LARGE: Status = 22;
pub const NO_REPLY: Status = 23;

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

impl From<LearningError> for Failure {
    fn from(error: LearningError) -> Self {
        let (status, message) = match error {
            LearningError::Busy => (
                BUSY,
                "an input session is busy or Rime's undo window is open",
            ),
            LearningError::Unavailable => {
                (UNAVAILABLE, "personal learning management is unavailable")
            }
            LearningError::Conflict => (CONFLICT, "personal learning changed since it was listed"),
            LearningError::TooLarge => {
                (TOO_LARGE, "too many entries or too large a learning count")
            }
            LearningError::Native(error) => return Failure::from(error),
        };
        Self::new(status, message)
    }
}

impl From<ResourceError> for Failure {
    fn from(error: ResourceError) -> Self {
        let message = error.to_string();
        let status = match error {
            ResourceError::Native(error) => return Failure::from(error),
            ResourceError::Io(_) => IO,
            ResourceError::Missing(_) | ResourceError::Probe(_) => RESOURCE,
        };
        Self::new(status, message)
    }
}

thread_local! {
    static LAST_ERROR: RefCell<CString> = RefCell::new(CString::default());
}

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
    unsafe { pointer.as_ref() }.ok_or_else(|| Failure::argument(&format!("{name} is NULL")))
}

unsafe fn write<T>(pointer: *mut T, value: T) {
    if !pointer.is_null() {
        unsafe { ptr::write(pointer, value) };
    }
}

unsafe fn query<T, R>(pointer: *const T, name: &str, neutral: R, read: impl FnOnce(&T) -> R) -> R {
    let mut value = neutral;
    guard(|| {
        value = read(unsafe { reference(pointer, name) }?);
        Ok(())
    });
    value
}

unsafe fn release<T>(pointer: *mut T) {
    if !pointer.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(pointer) })));
    }
}

fn c_string(value: &str) -> Result<CString, Failure> {
    CString::new(value).map_err(|_| Failure::new(NATIVE, "embedded NUL in engine text"))
}

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

pub struct SnapshotHandle {
    snapshot: Snapshot,
    input: CString,
    preedit: CString,
    candidates: Vec<(CString, CString)>,
    evidence: Vec<Option<CString>>,
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
        let evidence = snapshot
            .candidates
            .iter()
            .map(|c| c.evidence.as_ref().map(|e| c_string(&e.row())).transpose())
            .collect::<Result<Vec<_>, Failure>>()?;
        Ok(Self {
            snapshot,
            input,
            preedit,
            candidates,
            evidence,
        })
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
    unsafe { release(engine) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_engine_context_ranking_ready(engine: *const Arc<Engine>) -> c_int {
    unsafe { query(engine, "engine", 0, |e| c_int::from(e.context_ranking_ready())) }
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
    unsafe { release(session) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_id(session: *const InputSession) -> u64 {
    unsafe { query(session, "session", 0, InputSession::id) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_available(session: *const InputSession) -> c_int {
    unsafe { query(session, "session", 0, |s| c_int::from(s.available())) }
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
    unsafe { ifr_session_snapshot_if_changed(session, ptr::null(), snapshot) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_snapshot_if_changed(
    session: *const InputSession,
    previous: *const SnapshotHandle,
    snapshot: *mut *mut SnapshotHandle,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        if snapshot.is_null() {
            return Err(Failure::argument("snapshot is NULL"));
        }
        let current = session.snapshot()?;
        if unsafe { previous.as_ref() }.is_some_and(|old| old.snapshot.reusable_as(&current)) {
            unsafe { write(snapshot, ptr::null_mut()) };
            return Ok(());
        }
        let handle = SnapshotHandle::new(current)?;
        unsafe { write(snapshot, Box::into_raw(Box::new(handle))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_free(snapshot: *mut SnapshotHandle) {
    unsafe { release(snapshot) }
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
pub unsafe extern "C" fn ifr_snapshot_raw_caret(snapshot: *const SnapshotHandle) -> usize {
    unsafe { snapshot.as_ref() }.map_or(0, |s| s.snapshot.raw_caret_bytes)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_candidate_native_index(
    snapshot: *const SnapshotHandle,
    index: usize,
) -> usize {
    unsafe { snapshot.as_ref() }
        .and_then(|s| s.snapshot.candidates.get(index))
        .map_or(0, |c| c.native_index)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_candidate_native_rank(
    snapshot: *const SnapshotHandle,
    index: usize,
) -> usize {
    unsafe { snapshot.as_ref() }
        .and_then(|s| s.snapshot.candidates.get(index))
        .map_or(0, |c| c.native_rank)
}

pub const PERSONAL_NONE: c_int = 0;
pub const PERSONAL_EXACT_ENGLISH: c_int = 1;
pub const PERSONAL_EXACT_MIXED: c_int = 2;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_candidate_personal_source(
    snapshot: *const SnapshotHandle,
    index: usize,
) -> c_int {
    unsafe { snapshot.as_ref() }
        .and_then(|s| s.snapshot.candidates.get(index))
        .and_then(|c| c.personal_source())
        .map_or(PERSONAL_NONE, |source| match source {
            PersonalSource::ExactEnglish => PERSONAL_EXACT_ENGLISH,
            PersonalSource::ExactMixed => PERSONAL_EXACT_MIXED,
        })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_candidate_evidence(
    snapshot: *const SnapshotHandle,
    index: usize,
) -> *const c_char {
    unsafe { snapshot.as_ref() }
        .and_then(|s| s.evidence.get(index))
        .and_then(Option::as_ref)
        .map_or(ptr::null(), |row| row.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_snapshot_candidate_consumed_input(
    snapshot: *const SnapshotHandle,
    index: usize,
    start: *mut usize,
    end: *mut usize,
) -> c_int {
    let Some(range) = unsafe { snapshot.as_ref() }
        .and_then(|s| s.snapshot.candidates.get(index))
        .and_then(|c| c.consumed_input())
    else {
        return 0;
    };
    unsafe {
        write(start, range.start);
        write(end, range.end);
    }
    1
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
pub unsafe extern "C" fn ifr_session_start_document_context(
    session: *const InputSession,
    text: *const c_char,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        let text = unsafe { self::text(text, "text") }?;
        Ok(session.start_document_context(text)?)
    })
}

unsafe fn owned_phrases(
    phrases: *const Phrase,
    phrase_count: usize,
) -> Result<Vec<CustomPhrase>, Failure> {
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
    Ok(owned)
}

fn phrase_failure(error: PhraseError) -> Failure {
    Failure::new(PHRASES, error.code().to_string_lossy())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_phrase_normalize(
    code: *const c_char,
    text_in: *const c_char,
    normalized_code: *mut *mut c_char,
    normalized_text: *mut *mut c_char,
) -> Status {
    guard(|| {
        let code = unsafe { text(code, "code") }?;
        let text_in = unsafe { text(text_in, "text") }?;
        if normalized_code.is_null() || normalized_text.is_null() {
            return Err(Failure::argument("output is NULL"));
        }
        let phrase = CustomPhrase::validated("", code, text_in).map_err(phrase_failure)?;
        let code = c_string(&phrase.code)?.into_raw();
        let text = match c_string(&phrase.text) {
            Ok(text) => text.into_raw(),
            Err(error) => {
                drop(unsafe { CString::from_raw(code) });
                return Err(error);
            }
        };
        unsafe {
            write(normalized_code, code);
            write(normalized_text, text);
        }
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_phrases_validate(
    phrases: *const Phrase,
    phrase_count: usize,
) -> Status {
    guard(|| {
        let owned = unsafe { owned_phrases(phrases, phrase_count) }?;
        CustomPhrase::validate(&owned).map_err(phrase_failure)
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
        let owned = unsafe { owned_phrases(phrases, phrase_count) }?;
        let input = unsafe { options.as_ref() }.map(|mask| options_from_mask(*mask));
        Ok(session.set_configuration(candidate_count, &owned, input.as_ref())?)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_configuration_error(
    session: *const InputSession,
) -> *const c_char {
    let code = |s: &InputSession| s.configuration_error().map_or(ptr::null(), |e| e.code().as_ptr());
    unsafe { query(session, "session", ptr::null(), code) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_candidate_count(session: *const InputSession) -> usize {
    unsafe { query(session, "session", 5, InputSession::candidate_count) }
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
pub unsafe extern "C" fn ifr_session_requested_ascii_mode(session: *const InputSession) -> c_int {
    unsafe { query(session, "session", 0, |s| c_int::from(s.requested_ascii_mode())) }
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

#[unsafe(no_mangle)]
pub extern "C" fn ifr_compiled_file_count() -> usize {
    crate::resources::compiled_files().len()
}

#[unsafe(no_mangle)]
pub extern "C" fn ifr_compiled_file_name(index: usize) -> *const c_char {
    static NAMES: OnceLock<Vec<CString>> = OnceLock::new();
    let names = NAMES.get_or_init(|| {
        crate::resources::compiled_files()
            .into_iter()
            .filter_map(|name| CString::new(name).ok())
            .collect()
    });
    names.get(index).map_or(ptr::null(), |name| name.as_ptr())
}

#[unsafe(no_mangle)]
pub extern "C" fn ifr_rime_version() -> *const c_char {
    static VERSION: OnceLock<CString> = OnceLock::new();
    let mut version = ptr::null();
    guard(|| {
        if VERSION.get().is_none() {
            let _ = VERSION.set(c_string(&crate::rime_version()?)?);
        }
        version = VERSION.get().map_or(ptr::null(), |v| v.as_ptr());
        Ok(())
    });
    version
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_resources_compile(
    shared: *const c_char,
    user: *const c_char,
    cache: *const c_char,
) -> Status {
    guard(|| {
        let shared = PathBuf::from(unsafe { text(shared, "shared") }?);
        let user = PathBuf::from(unsafe { text(user, "user") }?);
        let cache = PathBuf::from(unsafe { text(cache, "cache") }?);
        Ok(resources::compile(&shared, &user, &cache)?)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_resources_probe(
    shared: *const c_char,
    user: *const c_char,
    cache: *const c_char,
) -> Status {
    guard(|| {
        let shared = PathBuf::from(unsafe { text(shared, "shared") }?);
        let user = PathBuf::from(unsafe { text(user, "user") }?);
        let cache = PathBuf::from(unsafe { text(cache, "cache") }?);
        Ok(resources::probe(&shared, &user, &cache)?)
    })
}

pub struct ReplyHandle {
    status: CString,
    body: CString,
}

const MAXIMUM_REPLY_BYTES: usize = 4 * 1024 * 1024;
const MAXIMUM_FIELDS: usize = 64;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_session_call(
    session: *const InputSession,
    op: *const c_char,
    fields: *const *const c_char,
    field_count: usize,
    capacity: usize,
    reply: *mut *mut ReplyHandle,
) -> Status {
    guard(|| {
        let session = unsafe { reference(session, "session") }?;
        let op = unsafe { text(op, "op") }?;
        if reply.is_null() {
            return Err(Failure::argument("reply is NULL"));
        }
        if capacity > MAXIMUM_REPLY_BYTES {
            return Err(Failure::argument("capacity is too large"));
        }
        if field_count > MAXIMUM_FIELDS || (field_count != 0 && fields.is_null()) {
            return Err(Failure::argument("fields is NULL or too long"));
        }
        let fields = (0..field_count)
            .map(|n| unsafe { text(*fields.add(n), "field") })
            .collect::<Result<Vec<_>, Failure>>()?;
        let answer = session
            .call(op, &fields, capacity)?
            .ok_or_else(|| Failure::new(NO_REPLY, "no reply"))?;
        let handle = ReplyHandle {
            status: c_string(&answer.status)?,
            body: c_string(&answer.body)?,
        };
        unsafe { write(reply, Box::into_raw(Box::new(handle))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_reply_status(reply: *const ReplyHandle) -> *const c_char {
    unsafe { reply.as_ref() }.map_or(ptr::null(), |r| r.status.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_reply_body(reply: *const ReplyHandle) -> *const c_char {
    unsafe { reply.as_ref() }.map_or(ptr::null(), |r| r.body.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_reply_free(reply: *mut ReplyHandle) {
    unsafe { release(reply) }
}

pub struct LearningHandle {
    entries: Vec<LearningEntry>,
    strings: Vec<(CString, CString)>,
}

pub struct LearningUndoHandle(LearningUndo);

pub const LEARNING_ENGLISH: c_int = 0;
pub const LEARNING_VOICE: c_int = 1;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_personal_learning_entries(
    engine: *const Arc<Engine>,
    learning: *mut *mut LearningHandle,
) -> Status {
    guard(|| {
        let engine = unsafe { reference(engine, "engine") }?;
        if learning.is_null() {
            return Err(Failure::argument("learning is NULL"));
        }
        let entries = engine.personal_learning_entries()?;
        let strings = entries
            .iter()
            .map(|e| Ok((c_string(&e.code)?, c_string(&e.text)?)))
            .collect::<Result<Vec<_>, Failure>>()?;
        let handle = LearningHandle { entries, strings };
        unsafe { write(learning, Box::into_raw(Box::new(handle))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_learning_free(learning: *mut LearningHandle) {
    unsafe { release(learning) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_learning_count(learning: *const LearningHandle) -> usize {
    unsafe { learning.as_ref() }.map_or(0, |l| l.entries.len())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_learning_source(
    learning: *const LearningHandle,
    index: usize,
) -> c_int {
    unsafe { learning.as_ref() }
        .and_then(|l| l.entries.get(index))
        .map_or(-1, |e| match e.source {
            LearningSource::English => LEARNING_ENGLISH,
            LearningSource::Voice => LEARNING_VOICE,
        })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_learning_code(
    learning: *const LearningHandle,
    index: usize,
) -> *const c_char {
    unsafe { learning.as_ref() }
        .and_then(|l| l.strings.get(index))
        .map_or(ptr::null(), |(code, _)| code.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_learning_text(
    learning: *const LearningHandle,
    index: usize,
) -> *const c_char {
    unsafe { learning.as_ref() }
        .and_then(|l| l.strings.get(index))
        .map_or(ptr::null(), |(_, text)| text.as_ptr())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_learning_commits(
    learning: *const LearningHandle,
    index: usize,
) -> u32 {
    unsafe { learning.as_ref() }
        .and_then(|l| l.entries.get(index))
        .map_or(0, |e| e.commits)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_personal_learning_delete(
    engine: *const Arc<Engine>,
    learning: *const LearningHandle,
    index: usize,
    undo: *mut *mut LearningUndoHandle,
) -> Status {
    guard(|| {
        let engine = unsafe { reference(engine, "engine") }?;
        let learning = unsafe { reference(learning, "learning") }?;
        if undo.is_null() {
            return Err(Failure::argument("undo is NULL"));
        }
        let entry = learning
            .entries
            .get(index)
            .ok_or_else(|| Failure::argument("index is out of range"))?;
        let token = engine.delete_personal_learning(entry)?;
        unsafe { write(undo, Box::into_raw(Box::new(LearningUndoHandle(token)))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_personal_learning_undo(
    engine: *const Arc<Engine>,
    undo: *const LearningUndoHandle,
) -> Status {
    guard(|| {
        let engine = unsafe { reference(engine, "engine") }?;
        let undo = unsafe { reference(undo, "undo") }?;
        Ok(engine.undo_personal_learning(&undo.0)?)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_learning_undo_free(undo: *mut LearningUndoHandle) {
    unsafe { release(undo) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_personal_learning_invalidate(engine: *const Arc<Engine>) -> Status {
    guard(|| Ok(unsafe { reference(engine, "engine") }?.invalidate_personal_learning()?))
}

pub struct ExportHandle(BTreeMap<String, CString>);

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_personal_export(
    user: *const c_char,
    exported: *mut *mut ExportHandle,
) -> Status {
    guard(|| {
        let user = PathBuf::from(unsafe { text(user, "user") }?);
        if exported.is_null() {
            return Err(Failure::argument("exported is NULL"));
        }
        if crate::engine_active() {
            return Err(Failure::new(ENGINE_ACTIVE, "an engine is initialized"));
        }
        let mut snapshots = BTreeMap::new();
        for (name, snapshot) in personal::export(&user)? {
            if let Some(snapshot) = snapshot {
                snapshots.insert(name, c_string(&snapshot)?);
            }
        }
        unsafe { write(exported, Box::into_raw(Box::new(ExportHandle(snapshots)))) };
        Ok(())
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_personal_export_free(exported: *mut ExportHandle) {
    unsafe { release(exported) }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ifr_personal_export_text(
    exported: *const ExportHandle,
    name: *const c_char,
) -> *const c_char {
    let Some(exported) = (unsafe { exported.as_ref() }) else {
        return ptr::null();
    };
    if name.is_null() {
        return ptr::null();
    }
    unsafe { CStr::from_ptr(name) }
        .to_str()
        .ok()
        .and_then(|name| exported.0.get(name))
        .map_or(ptr::null(), |snapshot| snapshot.as_ptr())
}

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
    unsafe { release(backup) }
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
    }

    #[test]
    fn maintenance_failures_keep_distinct_statuses() {
        for (error, status) in [
            (LearningError::Busy, BUSY),
            (LearningError::Unavailable, UNAVAILABLE),
            (LearningError::Conflict, CONFLICT),
            (LearningError::TooLarge, TOO_LARGE),
            (LearningError::Native(Error::Poisoned), POISONED),
        ] {
            assert_eq!(Failure::from(error).status, status);
        }
        for (error, status) in [
            (
                ResourceError::Native(Error::AlreadyRunning),
                ALREADY_RUNNING,
            ),
            (ResourceError::Io(std::io::ErrorKind::NotFound.into()), IO),
            (ResourceError::Missing("default.yaml".into()), RESOURCE),
            (ResourceError::Probe("candidate nihao".into()), RESOURCE),
        ] {
            assert_eq!(Failure::from(error).status, status);
        }
        let statuses = [BUSY, UNAVAILABLE, CONFLICT, TOO_LARGE, NO_REPLY];
        assert!(statuses.iter().all(|s| *s > RECOVERY_REQUIRED));
        assert_eq!(
            statuses,
            [19, 20, 21, 22, 23],
            "appended in order, never renumbered"
        );
    }
}
