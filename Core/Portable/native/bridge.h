#ifndef INKFLOW_PORTABLE_BRIDGE_H
#define INKFLOW_PORTABLE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Internal Rust/native ABI. Calls require the process-wide Rust engine lock.
 * Strings are NUL-terminated UTF-8. Offsets are UTF-8 bytes, not characters.
 * 0 means success; -1 native failure; -2 invalid session/schema; -3 exception.
 * Outputs must be zero-initialized. Nonzero status leaves outputs empty.
 * No C++ exception crosses this interface. */
typedef struct {
  const char* text;
  const char* comment;
} IFPCandidate;
typedef struct {
  const char* preedit;
  size_t caret;
  size_t selection_start;
  size_t selection_end;
  const IFPCandidate* candidates;
  size_t candidate_count;
  int page;
  int highlighted;
  int last_page;
  void* owner;
} IFPSnapshot;
int ifp_initialize(const char* shared, const char* user, const char* cache);
int ifp_prepare(void);
int ifp_finalize(void);
/* Preparation is explicit and must run before interactive sessions. */
int ifp_deploy(const char* schema_path);
int ifp_session_create(const char* schema, uintptr_t* session);
int ifp_session_destroy(uintptr_t session);
int ifp_process_key(uintptr_t session, int key, int modifiers, int* handled);
int ifp_clear(uintptr_t session);
int ifp_select_candidate(uintptr_t session, size_t index);
int ifp_change_page(uintptr_t session, int backward, int* changed);
int ifp_snapshot(uintptr_t session, IFPSnapshot* snapshot);
void ifp_snapshot_free(IFPSnapshot* snapshot);
/* A successful empty read returns NULL. A non-NULL commit is consumed once. */
int ifp_take_commit(uintptr_t session, char** commit);
void ifp_string_free(char* string);
/* Raw composition input; an empty composition yields an empty string. */
int ifp_get_input(uintptr_t session, char** input);
int ifp_highlight_candidate(uintptr_t session, size_t index, int* handled);
int ifp_commit_composition(uintptr_t session, int* handled);
int ifp_set_option(uintptr_t session, const char* option, int value);
int ifp_get_option(uintptr_t session, const char* option, int* value);
/* One synchronous property-channel round trip. NULL result: unanswered or a reply
 * that would not fit in capacity bytes. Properties never retain request or reply. */
int ifp_call(uintptr_t session, const char* request, size_t capacity, char** result);
/* Replace whole configuration nodes of the schema with the patch's, reselect the
 * schema in this session, then restore the originals. outcome: bit 0 patched,
 * bit 1 selected, bit 2 restored. -1 with outcome 1/2/3: schema open, patch
 * init or patch load failed before any change. */
int ifp_apply_schema_patch(uintptr_t session, const char* schema, const char* yaml,
                           const char* const* paths, size_t count, int* outcome);
/* Back up (restore == 0) or restore a closed user dictionary `root/<name>.userdb` to/from the
 * TSV snapshot `file`. Runs its own Rime instance: only while no runtime is initialized.
 * -1: the snapshot or database was rejected; nothing is reported about why. */
int ifp_personal_data_snapshot(const char* root, const char* name, const char* file, int restore);
#ifdef __cplusplus
}
#endif
#endif
