#ifndef INKFLOW_ENGINE_H_
#define INKFLOW_ENGINE_H_

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(INKFLOW_ENGINE_BUILDING)
#define INKFLOW_ENGINE_API __declspec(dllexport)
#elif defined(INKFLOW_ENGINE_SHARED)
#define INKFLOW_ENGINE_API __declspec(dllimport)
#else
#define INKFLOW_ENGINE_API
#endif
#elif defined(__GNUC__) || defined(__clang__)
#define INKFLOW_ENGINE_API __attribute__((visibility("default")))
#else
#define INKFLOW_ENGINE_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define INKFLOW_ENGINE_API_VERSION 1u
#define INKFLOW_NO_CANDIDATE ((size_t)-1)

typedef struct InkFlowRuntime InkFlowRuntime;
typedef struct InkFlowSession InkFlowSession;
typedef struct InkFlowSnapshot InkFlowSnapshot;

typedef enum InkFlowStatus {
  INKFLOW_STATUS_OK = 0,
  INKFLOW_STATUS_INVALID_ARGUMENT = 1,
  INKFLOW_STATUS_OUT_OF_MEMORY = 2,
  INKFLOW_STATUS_RUNTIME_ALREADY_EXISTS = 3,
  INKFLOW_STATUS_RUNTIME_FINALIZED = 4,
  INKFLOW_STATUS_DEPLOYMENT_FAILED = 5,
  INKFLOW_STATUS_BACKEND_UNAVAILABLE = 6,
  INKFLOW_STATUS_SESSION_CLOSED = 7,
  INKFLOW_STATUS_INVALID_CANDIDATE_INDEX = 8,
  INKFLOW_STATUS_UNSUPPORTED_KEY = 9,
  INKFLOW_STATUS_BACKEND_ERROR = 10,
  INKFLOW_STATUS_FILESYSTEM_ERROR = 11,
  INKFLOW_STATUS_INTERNAL_ERROR = 12,
  INKFLOW_STATUS_RUNTIME_IN_USE = 13
} InkFlowStatus;

typedef struct InkFlowRuntimeConfig {
  size_t struct_size;
  const char* shared_data_dir;
  const char* user_data_dir;
  const char* prebuilt_data_dir;
  const char* staging_data_dir;
  const char* distribution_name;
  const char* distribution_code_name;
  const char* distribution_version;
  const char* application_name;
  int32_t minimum_log_level;
} InkFlowRuntimeConfig;

typedef uint32_t InkFlowKeyCode;

/*
 * A key is either a named constant below or a printable Unicode scalar value.
 * Platform adapters should pass the unmodified scalar plus separate modifier
 * bits; control characters must use their named key constant.
 */
enum {
  INKFLOW_KEY_BACKSPACE = 0x00110000u,
  INKFLOW_KEY_DELETE_FORWARD = 0x00110001u,
  INKFLOW_KEY_RETURN = 0x00110002u,
  INKFLOW_KEY_ESCAPE = 0x00110003u,
  INKFLOW_KEY_TAB = 0x00110004u,
  INKFLOW_KEY_LEFT = 0x00110005u,
  INKFLOW_KEY_RIGHT = 0x00110006u,
  INKFLOW_KEY_UP = 0x00110007u,
  INKFLOW_KEY_DOWN = 0x00110008u,
  INKFLOW_KEY_PAGE_UP = 0x00110009u,
  INKFLOW_KEY_PAGE_DOWN = 0x0011000au,
  INKFLOW_KEY_HOME = 0x0011000bu,
  INKFLOW_KEY_END = 0x0011000cu
};

typedef uint32_t InkFlowKeyModifiers;

/* Modifier values are portable InkFlow bits, not native platform masks. */
enum {
  INKFLOW_MODIFIER_NONE = 0u,
  INKFLOW_MODIFIER_SHIFT = 1u << 0,
  INKFLOW_MODIFIER_CAPS_LOCK = 1u << 1,
  INKFLOW_MODIFIER_CONTROL = 1u << 2,
  INKFLOW_MODIFIER_ALT = 1u << 3,
  INKFLOW_MODIFIER_SUPER = 1u << 4,
  INKFLOW_MODIFIER_RELEASE = 1u << 5
};

typedef struct InkFlowKeyEvent {
  InkFlowKeyCode key;
  InkFlowKeyModifiers modifiers;
} InkFlowKeyEvent;

INKFLOW_ENGINE_API uint32_t inkflow_engine_api_version(void);
INKFLOW_ENGINE_API const char* inkflow_status_message(InkFlowStatus status);

/*
 * A process can own one runtime generation. Creating a runtime only sets up
 * and initializes librime; it never deploys schema data. Destroying it
 * finalizes librime, and creating another runtime in that process is
 * intentionally rejected. All paths and strings are copied before this call
 * returns.
 */
INKFLOW_ENGINE_API InkFlowStatus inkflow_runtime_create(
    const InkFlowRuntimeConfig* config,
    InkFlowRuntime** out_runtime);

/*
 * Explicitly deploy raw schema data for development or schema updates. This
 * operation is rejected while any session is active. Production clients that
 * bundle compatible prebuilt data can skip it during cold start.
 */
INKFLOW_ENGINE_API InkFlowStatus inkflow_runtime_prepare(
    InkFlowRuntime* runtime);
INKFLOW_ENGINE_API InkFlowStatus inkflow_runtime_destroy(
    InkFlowRuntime* runtime);

/*
 * A syntactically valid schema ID whose deployed config cannot be loaded or
 * does not identify itself exactly returns INKFLOW_STATUS_BACKEND_ERROR.
 */
INKFLOW_ENGINE_API InkFlowStatus inkflow_session_create(
    InkFlowRuntime* runtime,
    const char* schema_id,
    InkFlowSession** out_session);
INKFLOW_ENGINE_API InkFlowStatus inkflow_session_destroy(
    InkFlowSession* session);

INKFLOW_ENGINE_API InkFlowStatus inkflow_session_process_key(
    InkFlowSession* session,
    InkFlowKeyEvent event,
    InkFlowSnapshot** out_snapshot);
INKFLOW_ENGINE_API InkFlowStatus inkflow_session_commit(
    InkFlowSession* session,
    InkFlowSnapshot** out_snapshot);
INKFLOW_ENGINE_API InkFlowStatus inkflow_session_select_candidate(
    InkFlowSession* session,
    size_t index_on_current_page,
    InkFlowSnapshot** out_snapshot);
INKFLOW_ENGINE_API InkFlowStatus inkflow_session_delete_candidate(
    InkFlowSession* session,
    size_t index_on_current_page,
    InkFlowSnapshot** out_snapshot);
INKFLOW_ENGINE_API InkFlowStatus inkflow_session_change_page(
    InkFlowSession* session,
    int backward,
    InkFlowSnapshot** out_snapshot);
INKFLOW_ENGINE_API InkFlowStatus inkflow_session_reset(
    InkFlowSession* session,
    InkFlowSnapshot** out_snapshot);
INKFLOW_ENGINE_API InkFlowStatus inkflow_session_snapshot(
    InkFlowSession* session,
    InkFlowSnapshot** out_snapshot);

/*
 * Snapshots own deep copies of all text. Their views remain valid until the
 * matching snapshot is destroyed, regardless of later session operations.
 * Passing a snapshot to destroy more than once is undefined behavior.
 */
INKFLOW_ENGINE_API void inkflow_snapshot_destroy(InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API int inkflow_snapshot_handled(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API const char* inkflow_snapshot_commit_text(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API const char* inkflow_snapshot_preedit(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API size_t inkflow_snapshot_preedit_cursor_byte_offset(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API size_t inkflow_snapshot_preedit_selection_start_byte_offset(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API size_t inkflow_snapshot_preedit_selection_end_byte_offset(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API size_t inkflow_snapshot_candidate_count(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API size_t inkflow_snapshot_highlighted_candidate_index(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API int inkflow_snapshot_has_previous_page(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API int inkflow_snapshot_has_next_page(
    const InkFlowSnapshot* snapshot);
INKFLOW_ENGINE_API const char* inkflow_snapshot_candidate_text(
    const InkFlowSnapshot* snapshot,
    size_t index);
INKFLOW_ENGINE_API const char* inkflow_snapshot_candidate_comment(
    const InkFlowSnapshot* snapshot,
    size_t index);

#ifdef __cplusplus
}
#endif

#endif  /* INKFLOW_ENGINE_H_ */
