//! Synchronous desktop Rime host: the native `Runtime`/`Session` layer plus the
//! InkFlow session policy in [`engine`].
pub mod abi;
pub mod channel;
pub mod engine;
mod ffi;
pub mod personal;
pub mod phrases;
pub mod preferences;
pub mod ranking;

use std::{
    ffi::{CStr, CString, c_char},
    path::Path,
    sync::{Arc, Mutex, MutexGuard},
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    AlreadyRunning,
    SessionsActive,
    InvalidString,
    InvalidUtf8,
    InvalidOffsets,
    StaleSnapshot,
    InvalidCandidate,
    Poisoned,
    Native(i32),
    /// A session could not apply its configuration; the code names the failure.
    Configuration(&'static str),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for Error {}
pub type Result<T> = std::result::Result<T, Error>;

// Rime's registry, modules and configuration are process-global.
static ENGINE: Mutex<bool> = Mutex::new(false);
fn lock() -> Result<MutexGuard<'static, bool>> {
    ENGINE.lock().map_err(|_| Error::Poisoned)
}
/// Whether a runtime is initialized in this process (personal-data work must wait).
pub(crate) fn engine_active() -> bool {
    ENGINE.lock().map(|active| *active).unwrap_or(true)
}
fn check(code: i32) -> Result<()> {
    if code == 0 {
        Ok(())
    } else {
        Err(Error::Native(code))
    }
}
fn string(value: &str) -> Result<CString> {
    CString::new(value).map_err(|_| Error::InvalidString)
}
fn path(value: &Path) -> Result<CString> {
    string(value.to_str().ok_or(Error::InvalidString)?)
}
unsafe fn copy(value: *const c_char) -> Result<String> {
    if value.is_null() {
        return Ok(String::new());
    }
    // Native output remains alive until the surrounding RAII owner is dropped.
    unsafe { CStr::from_ptr(value) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| Error::InvalidUtf8)
}

/// Back up or restore one closed user dictionary through the native helper, which runs its
/// own Rime instance; rejected while a runtime is initialized in this process.
pub(crate) fn personal_data_snapshot(
    root: &Path,
    name: &str,
    file: &Path,
    restore: bool,
) -> Result<bool> {
    let root = path(root)?;
    let name = string(name)?;
    let file = path(file)?;
    let active = lock()?;
    if *active {
        return Err(Error::AlreadyRunning);
    }
    Ok(unsafe {
        ffi::ifp_personal_data_snapshot(
            root.as_ptr(),
            name.as_ptr(),
            file.as_ptr(),
            i32::from(restore),
        )
    } == 0)
}

struct RuntimeOwner {
    // Keep traits' borrowed paths alive through native finalization.
    _shared: CString,
    _user: CString,
    _cache: CString,
}
impl Drop for RuntimeOwner {
    fn drop(&mut self) {
        let mut active = ENGINE.lock().unwrap_or_else(|e| e.into_inner());
        // On failed teardown, refuse a new runtime in the same process.
        if unsafe { ffi::ifp_finalize() } == 0 {
            *active = false;
        }
    }
}

pub struct Runtime {
    owner: Arc<RuntimeOwner>,
}
impl Runtime {
    /// Paths must name prepared shared resources and an isolated writable user directory.
    /// Initialization and deployment belong off the interactive key-event path.
    pub fn new(shared: &Path, user: &Path) -> Result<Self> {
        Self::with_cache(shared, user, &user.join("build"))
    }

    /// Use an explicit target-native cache, separate from writable personal data.
    pub fn with_cache(shared: &Path, user: &Path, cache: &Path) -> Result<Self> {
        let cache = path(cache)?;
        let shared = path(shared)?;
        let user = path(user)?;
        let mut active = lock()?;
        if *active {
            return Err(Error::AlreadyRunning);
        }
        check(unsafe { ffi::ifp_initialize(shared.as_ptr(), user.as_ptr(), cache.as_ptr()) })?;
        *active = true;
        Ok(Self {
            owner: Arc::new(RuntimeOwner {
                _shared: shared,
                _user: user,
                _cache: cache,
            }),
        })
    }

    /// Compile source resources for this target before opening any sessions.
    pub fn deploy(&mut self, schema: &Path) -> Result<()> {
        let schema = path(schema)?;
        let _lock = lock()?;
        if Arc::strong_count(&self.owner) != 1 {
            return Err(Error::SessionsActive);
        }
        check(unsafe { ffi::ifp_deploy(schema.as_ptr()) })
    }

    /// Compile the configured schema list and its dependencies through Rime maintenance.
    /// This is preparation work and is rejected while any sessions exist.
    pub fn prepare(&mut self) -> Result<()> {
        let _lock = lock()?;
        if Arc::strong_count(&self.owner) != 1 {
            return Err(Error::SessionsActive);
        }
        check(unsafe { ffi::ifp_prepare() })
    }

    pub fn session(&self, schema: &str) -> Result<Session> {
        let schema = string(schema)?;
        let _lock = lock()?;
        let mut id = 0;
        check(unsafe { ffi::ifp_session_create(schema.as_ptr(), &mut id) })?;
        Ok(Session {
            id,
            published: None,
            _runtime: self.owner.clone(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub text: String,
    pub comment: String,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    token: Arc<()>,
    pub preedit: String,
    pub caret_bytes: usize,
    pub selection_bytes: std::ops::Range<usize>,
    pub candidates: Vec<Candidate>,
    pub page: i32,
    pub highlighted: i32,
    pub last_page: bool,
}

pub struct Session {
    id: usize,
    published: Option<(Arc<()>, usize)>,
    _runtime: Arc<RuntimeOwner>,
}
impl Session {
    /// Keys and modifiers use Rime/X11 keysyms and masks, not platform key codes.
    pub fn process_key(&mut self, key: i32, modifiers: i32) -> Result<bool> {
        let _lock = lock()?;
        self.published = None;
        let mut handled = 0;
        check(unsafe { ffi::ifp_process_key(self.id, key, modifiers, &mut handled) })?;
        Ok(handled != 0)
    }

    pub fn clear(&mut self) -> Result<()> {
        let _lock = lock()?;
        self.published = None;
        check(unsafe { ffi::ifp_clear(self.id) })
    }

    /// Select a zero-based entry from the latest snapshot of this session.
    /// Any key, clear, native selection attempt or page change invalidates that snapshot.
    pub fn select_candidate(&mut self, snapshot: &Snapshot, index: usize) -> Result<()> {
        let _lock = lock()?;
        let Some((token, count)) = &self.published else {
            return Err(Error::StaleSnapshot);
        };
        if !Arc::ptr_eq(token, &snapshot.token) {
            return Err(Error::StaleSnapshot);
        }
        if index >= *count {
            return Err(Error::InvalidCandidate);
        }
        self.published = None;
        check(unsafe { ffi::ifp_select_candidate(self.id, index) })
    }

    pub fn change_page(&mut self, backward: bool) -> Result<bool> {
        let _lock = lock()?;
        self.published = None;
        let mut changed = 0;
        check(unsafe { ffi::ifp_change_page(self.id, i32::from(backward), &mut changed) })?;
        Ok(changed != 0)
    }

    pub fn snapshot(&mut self) -> Result<Snapshot> {
        let _lock = lock()?;
        self.published = None;
        let mut raw = ffi::Snapshot::default();
        check(unsafe { ffi::ifp_snapshot(self.id, &mut raw) })?;
        let preedit = unsafe { copy(raw.preedit) }?;
        if ![raw.caret, raw.selection_start, raw.selection_end]
            .iter()
            .all(|&offset| preedit.is_char_boundary(offset))
            || raw.selection_start > raw.selection_end
        {
            return Err(Error::InvalidOffsets);
        }
        let mut candidates = Vec::with_capacity(raw.candidate_count);
        for index in 0..raw.candidate_count {
            let candidate = unsafe { &*raw.candidates.add(index) };
            candidates.push(Candidate {
                text: unsafe { copy(candidate.text) }?,
                comment: unsafe { copy(candidate.comment) }?,
            });
        }
        let token = Arc::new(());
        self.published = Some((token.clone(), candidates.len()));
        Ok(Snapshot {
            token,
            preedit,
            caret_bytes: raw.caret,
            selection_bytes: raw.selection_start..raw.selection_end,
            candidates,
            page: raw.page,
            highlighted: raw.highlighted,
            last_page: raw.last_page != 0,
        })
    }

    pub fn take_commit(&mut self) -> Result<Option<String>> {
        let _lock = lock()?;
        let mut raw = std::ptr::null_mut();
        check(unsafe { ffi::ifp_take_commit(self.id, &mut raw) })?;
        if raw.is_null() {
            return Ok(None);
        }
        let value = unsafe { copy(raw) };
        unsafe { ffi::ifp_string_free(raw) };
        value.map(Some)
    }
}
/// Outcome of replacing schema nodes for one session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PatchOutcome {
    pub patched: bool,
    pub selected: bool,
    pub restored: bool,
}

/// Why a schema patch could not start; nothing was changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PatchFailure {
    SchemaOpen,
    PatchInit,
    PatchLoad,
}

impl Session {
    fn owned_string(raw: *mut c_char) -> Result<String> {
        if raw.is_null() {
            return Ok(String::new());
        }
        let value = unsafe { copy(raw) };
        unsafe { ffi::ifp_string_free(raw) };
        value
    }

    /// Rime's raw composition input.
    pub(crate) fn input(&mut self) -> Result<String> {
        let _lock = lock()?;
        let mut raw = std::ptr::null_mut();
        check(unsafe { ffi::ifp_get_input(self.id, &mut raw) })?;
        Self::owned_string(raw)
    }

    pub(crate) fn highlight(&mut self, index: usize) -> Result<bool> {
        let _lock = lock()?;
        self.published = None;
        let mut handled = 0;
        check(unsafe { ffi::ifp_highlight_candidate(self.id, index, &mut handled) })?;
        Ok(handled != 0)
    }

    /// Select a native index without snapshot identity; the policy layer validates its own.
    pub(crate) fn select_native(&mut self, index: usize) -> Result<bool> {
        let _lock = lock()?;
        self.published = None;
        Ok(unsafe { ffi::ifp_select_candidate(self.id, index) } == 0)
    }

    pub(crate) fn commit_composition(&mut self) -> Result<bool> {
        let _lock = lock()?;
        self.published = None;
        let mut handled = 0;
        check(unsafe { ffi::ifp_commit_composition(self.id, &mut handled) })?;
        Ok(handled != 0)
    }

    pub(crate) fn set_option(&mut self, option: &str, value: bool) -> Result<()> {
        let option = string(option)?;
        let _lock = lock()?;
        check(unsafe { ffi::ifp_set_option(self.id, option.as_ptr(), i32::from(value)) })
    }

    pub(crate) fn option(&mut self, option: &str) -> Result<bool> {
        let option = string(option)?;
        let _lock = lock()?;
        let mut value = 0;
        check(unsafe { ffi::ifp_get_option(self.id, option.as_ptr(), &mut value) })?;
        Ok(value != 0)
    }

    /// One synchronous round trip through this session's Lua modules. `None` when no module
    /// answers, the reply does not fit `capacity` bytes, or the request cannot be framed.
    pub(crate) fn call(
        &mut self,
        op: &str,
        fields: &[&str],
        capacity: usize,
    ) -> Result<Option<channel::Reply>> {
        let Some(request) = channel::request(op, fields) else {
            return Ok(None);
        };
        let request = string(&request)?;
        let _lock = lock()?;
        let mut raw = std::ptr::null_mut();
        check(unsafe { ffi::ifp_call(self.id, request.as_ptr(), capacity, &mut raw) })?;
        if raw.is_null() {
            return Ok(None);
        }
        Ok(channel::reply(&Self::owned_string(raw)?, op))
    }

    pub(crate) fn apply_schema_patch(
        &mut self,
        schema: &str,
        yaml: &str,
        paths: &[&str],
    ) -> Result<std::result::Result<PatchOutcome, PatchFailure>> {
        let schema = string(schema)?;
        let yaml = string(yaml)?;
        let paths = paths
            .iter()
            .map(|p| string(p))
            .collect::<Result<Vec<_>>>()?;
        let pointers: Vec<_> = paths.iter().map(|p| p.as_ptr()).collect();
        let _lock = lock()?;
        self.published = None;
        let mut outcome = 0;
        let status = unsafe {
            ffi::ifp_apply_schema_patch(
                self.id,
                schema.as_ptr(),
                yaml.as_ptr(),
                pointers.as_ptr(),
                pointers.len(),
                &mut outcome,
            )
        };
        if status == -1 {
            return Ok(Err(match outcome {
                1 => PatchFailure::SchemaOpen,
                2 => PatchFailure::PatchInit,
                _ => PatchFailure::PatchLoad,
            }));
        }
        check(status)?;
        Ok(Ok(PatchOutcome {
            patched: outcome & 1 != 0,
            selected: outcome & 2 != 0,
            restored: outcome & 4 != 0,
        }))
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _lock = ENGINE.lock().unwrap_or_else(|e| e.into_inner());
        unsafe { ffi::ifp_session_destroy(self.id) };
    }
}
