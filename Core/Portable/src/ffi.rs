use std::ffi::{c_char, c_int, c_void};

#[repr(C)]
pub struct Candidate {
    pub text: *const c_char,
    pub comment: *const c_char,
}

#[repr(C)]
pub struct Snapshot {
    pub preedit: *const c_char,
    pub caret: usize,
    pub selection_start: usize,
    pub selection_end: usize,
    pub candidates: *const Candidate,
    pub candidate_count: usize,
    pub page: c_int,
    pub highlighted: c_int,
    pub last_page: c_int,
    pub owner: *mut c_void,
}

impl Default for Snapshot {
    fn default() -> Self {
        // All fields are integers or nullable pointers, matching the C contract.
        unsafe { std::mem::zeroed() }
    }
}

impl Drop for Snapshot {
    fn drop(&mut self) {
        // The native owner holds all pointers, including on conversion failure.
        unsafe { ifp_snapshot_free(self) }
    }
}

unsafe extern "C" {
    pub fn ifp_initialize(
        shared: *const c_char,
        user: *const c_char,
        cache: *const c_char,
    ) -> c_int;
    pub fn ifp_prepare() -> c_int;
    pub fn ifp_finalize() -> c_int;
    pub fn ifp_deploy(schema: *const c_char) -> c_int;
    pub fn ifp_session_create(schema: *const c_char, session: *mut usize) -> c_int;
    pub fn ifp_session_destroy(session: usize) -> c_int;
    pub fn ifp_process_key(
        session: usize,
        key: c_int,
        modifiers: c_int,
        handled: *mut c_int,
    ) -> c_int;
    pub fn ifp_clear(session: usize) -> c_int;
    pub fn ifp_select_candidate(session: usize, index: usize) -> c_int;
    pub fn ifp_change_page(session: usize, backward: c_int, changed: *mut c_int) -> c_int;
    pub fn ifp_snapshot(session: usize, snapshot: *mut Snapshot) -> c_int;
    pub fn ifp_snapshot_free(snapshot: *mut Snapshot);
    pub fn ifp_take_commit(session: usize, commit: *mut *mut c_char) -> c_int;
    pub fn ifp_string_free(string: *mut c_char);
    pub fn ifp_get_input(session: usize, input: *mut *mut c_char) -> c_int;
    pub fn ifp_highlight_candidate(session: usize, index: usize, handled: *mut c_int) -> c_int;
    pub fn ifp_commit_composition(session: usize, handled: *mut c_int) -> c_int;
    pub fn ifp_set_option(session: usize, option: *const c_char, value: c_int) -> c_int;
    pub fn ifp_get_option(session: usize, option: *const c_char, value: *mut c_int) -> c_int;
    pub fn ifp_call(
        session: usize,
        request: *const c_char,
        capacity: usize,
        result: *mut *mut c_char,
    ) -> c_int;
    pub fn ifp_apply_schema_patch(
        session: usize,
        schema: *const c_char,
        yaml: *const c_char,
        paths: *const *const c_char,
        count: usize,
        outcome: *mut c_int,
    ) -> c_int;
}
