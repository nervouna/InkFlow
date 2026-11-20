#ifndef INKFLOW_PORTABLE_BRIDGE_H
#define INKFLOW_PORTABLE_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

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
const char* ifp_version(void);
int ifp_initialize(const char* shared, const char* user, const char* cache);
int ifp_prepare(void);
int ifp_finalize(void);
int ifp_deploy(const char* schema_path);
int ifp_session_create(const char* schema, uintptr_t* session);
int ifp_session_destroy(uintptr_t session);
int ifp_process_key(uintptr_t session, int key, int modifiers, int* handled);
int ifp_clear(uintptr_t session);
int ifp_select_candidate(uintptr_t session, size_t index);
int ifp_change_page(uintptr_t session, int backward, int* changed);
int ifp_snapshot(uintptr_t session, IFPSnapshot* snapshot);
int ifp_context_window(uintptr_t session, IFPSnapshot* snapshot);
int ifp_promote_context_candidate(uintptr_t session, size_t source, size_t destination);
void ifp_snapshot_free(IFPSnapshot* snapshot);
int ifp_take_commit(uintptr_t session, char** commit);
void ifp_string_free(char* string);
int ifp_get_input(uintptr_t session, char** input);
int ifp_get_caret_pos(uintptr_t session, size_t* caret);
int ifp_highlight_candidate(uintptr_t session, size_t index, int* handled);
int ifp_commit_composition(uintptr_t session, int* handled);
int ifp_set_option(uintptr_t session, const char* option, int value);
int ifp_get_option(uintptr_t session, const char* option, int* value);
int ifp_call(uintptr_t session, const char* request, size_t capacity, char** result);
int ifp_apply_schema_patch(uintptr_t session, const char* schema, const char* yaml,
                           const char* const* paths, size_t count, int* outcome);
int ifp_personal_data_snapshot(const char* root, const char* name, const char* file, int restore);
#ifdef __cplusplus
}
#endif
#endif
