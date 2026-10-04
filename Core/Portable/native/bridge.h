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
int ifp_initialize(const char* shared, const char* user);
int ifp_finalize(void);
/* Preparation is explicit and must run before interactive sessions. */
int ifp_deploy(const char* schema_path);
int ifp_session_create(const char* schema, uintptr_t* session);
int ifp_session_destroy(uintptr_t session);
int ifp_process_key(uintptr_t session, int key, int modifiers, int* handled);
int ifp_clear(uintptr_t session);
int ifp_snapshot(uintptr_t session, IFPSnapshot* snapshot);
void ifp_snapshot_free(IFPSnapshot* snapshot);
/* A successful empty read returns NULL. A non-NULL commit is consumed once. */
int ifp_take_commit(uintptr_t session, char** commit);
void ifp_string_free(char* string);
#ifdef __cplusplus
}
#endif
#endif
