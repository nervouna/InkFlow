#ifndef INKFLOW_RIME_H
#define INKFLOW_RIME_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Frontend-facing ABI of the InkFlow Rust/Rime engine (ABI version 1).
 *
 * Handles: IFREngine, IFRSession and IFRSnapshot are opaque. Each is created by one
 * function and released by its matching destroy or free function, which accepts NULL. Owned
 * strings from ifr_session_take_commit are released with ifr_string_free. Borrowed
 * strings (snapshot accessors, ifr_last_error, configuration errors) stay valid while
 * their owner lives; ifr_last_error is valid on the calling thread until its next
 * failing call. Every string crossing the ABI is NUL-terminated UTF-8; embedded NUL
 * and non-UTF-8 input are rejected with IFR_INVALID_ARGUMENT.
 *
 * Status: functions returning IFRStatus write their outputs only on IFR_OK and set
 * ifr_last_error otherwise. Accessors that cannot fail return neutral values for NULL
 * or out-of-range arguments. No Rust panic unwinds across the ABI: a caught panic is
 * IFR_PANIC and the engine should be destroyed. Invalid pointers remain undefined.
 *
 * Threads: there is no thread affinity. One process-wide lock serializes every Rime
 * call and one policy lock serializes every session of an engine, so all handles may
 * be used from any thread, one call at a time per handle. Rime is process-global: a
 * second live engine returns IFR_ALREADY_RUNNING. Sessions keep their engine alive;
 * ifr_engine_destroy only drops the caller's reference, and Rime finalizes when the
 * last session or engine reference goes.
 *
 * Offsets: ifr_snapshot_caret/selection_* count bytes of the returned UTF-8 preedit
 * and always fall on character boundaries. Frontends convert to their own units.
 *
 * Keys: Rime/X11 keysyms with Rime modifier masks (Shift 1<<0, Control 1<<2,
 * Alt 1<<3, Super 1<<26, Release 1<<30). Digits select displayed candidates, Up/Down
 * move the highlight, Page_Up/Page_Down page; everything else goes to Rime.
 *
 * Candidate selection and highlight take the snapshot they were decided on. A
 * snapshot superseded by any mutation returns IFR_STALE_SNAPSHOT; an index outside its
 * page returns IFR_INVALID_CANDIDATE. Snapshots are copies and outlive the session.
 *
 * Commits: ifr_session_take_commit drains completed text exactly once. Call it after
 * every key, selection, commit or configuration change before the next action.
 *
 * Nothing here touches the network or telemetry. Engine creation, configuration
 * changes and the custom-phrase reload at a shared idle are the only disk work;
 * keys never read storage. The observer runs on the mutating thread after the engine
 * lock is released; it must not call back into the same session and cannot block
 * input on storage without blocking that thread. */

typedef int32_t IFRStatus;
enum {
  IFR_OK = 0,
  IFR_PANIC = 1,
  IFR_INVALID_ARGUMENT = 2,
  IFR_NATIVE = 3,             /* librime failed; stop using the engine and recreate it. */
  IFR_POISONED = 4,           /* An earlier panic poisoned a lock; recreate the engine. */
  IFR_ALREADY_RUNNING = 5,    /* Another engine (or its sessions) is still alive. */
  IFR_SESSIONS_ACTIVE = 6,
  IFR_RESOURCE = 7,           /* A prepared resource or the context index is missing/invalid. */
  IFR_CONFIGURATION = 8,      /* A session could not apply its configuration. */
  IFR_IO = 9,
  IFR_STALE_SNAPSHOT = 10,
  IFR_INVALID_CANDIDATE = 11,
  IFR_ENGINE_ACTIVE = 12,     /* Personal-data work needs every engine destroyed first. */
  IFR_INCOMPATIBLE = 13,      /* Another backup format, Rime version or dictionary set. */
  IFR_UNKNOWN_FIELDS = 14,
  IFR_SETTINGS = 15,
  IFR_PHRASES = 16,
  IFR_SNAPSHOT = 17,          /* A dictionary snapshot breaks the TSV contract. */
  IFR_RECOVERY_REQUIRED = 18  /* An earlier import was interrupted; call ifr_personal_recover. */
};

typedef struct IFREngine IFREngine;
typedef struct IFRSession IFRSession;
typedef struct IFRSnapshot IFRSnapshot;
typedef struct IFRBackup IFRBackup;

typedef struct {
  const char* shared;        /* Prepared shared resources. */
  const char* user;          /* Isolated writable user directory; created if missing. */
  const char* cache;         /* Target-native compiled cache, or NULL to compile into user/build. */
  const char* context_index; /* Prepared pinyin_simp.context.bin, or NULL for Rime's order. */
} IFREngineConfig;

typedef struct {
  const char* id;   /* Opaque frontend identity, unique within one configuration. */
  const char* code;
  const char* text;
} IFRPhrase;

/* Input options as a bitmask; ifr_input_options_default() gives the product defaults. */
enum {
  IFR_OPTION_ABBREVIATION = 1u << 0,
  IFR_OPTION_TYPO_TOLERANCE = 1u << 1,
  IFR_OPTION_FUZZY_Z = 1u << 2,
  IFR_OPTION_FUZZY_C = 1u << 3,
  IFR_OPTION_FUZZY_S = 1u << 4,
  IFR_OPTION_EMOJI = 1u << 5,
  IFR_OPTION_BRACKET_PAGING = 1u << 6,
  IFR_OPTION_MINUS_EQUAL_PAGING = 1u << 7,
  IFR_OPTION_ENGLISH_PUNCTUATION = 1u << 8,
  IFR_OPTION_CORNER_QUOTES = 1u << 9,
  IFR_OPTION_MIDDLE_DOT = 1u << 10,
  IFR_OPTION_FULLWIDTH_PIPE = 1u << 11,
  IFR_OPTION_IDEOGRAPHIC_COMMA = 1u << 12,
  IFR_OPTION_TRADITIONAL = 1u << 13
};

enum {
  IFR_ACTION_KEY = 0,
  IFR_ACTION_SELECT = 1,
  IFR_ACTION_HIGHLIGHT = 2,
  IFR_ACTION_COMMIT = 3,
  IFR_ACTION_CLEAR = 4,
  IFR_ACTION_TOGGLE_ASCII = 5
};

/* One completed mutation. Snapshots are borrowed for the callback only. */
typedef struct {
  uint64_t session;
  int action;
  int32_t key;        /* IFR_ACTION_KEY */
  int32_t modifiers;  /* IFR_ACTION_KEY */
  size_t index;       /* IFR_ACTION_SELECT / IFR_ACTION_HIGHLIGHT */
  int handled;
  const IFRSnapshot* before;
  const IFRSnapshot* after;
} IFRMutation;

typedef void (*IFRObserver)(void* user_data, const IFRMutation* mutation);

uint32_t ifr_abi_version(void);
const char* ifr_last_error(void);
uint32_t ifr_input_options_default(void);

/* Engine creation initializes Rime, checks the prepared cache and loads the context
 * index: setup work, never on the key path. */
IFRStatus ifr_engine_create(const IFREngineConfig* config, IFREngine** engine);
void ifr_engine_destroy(IFREngine* engine);
int ifr_engine_context_ranking_ready(const IFREngine* engine);
/* NULL removes the observer. The callback and user_data must be usable from any
 * thread that mutates a session of this engine. */
IFRStatus ifr_engine_set_observer(const IFREngine* engine, IFRObserver callback, void* user_data);

IFRStatus ifr_session_create(const IFREngine* engine, IFRSession** session);
void ifr_session_destroy(IFRSession* session);
uint64_t ifr_session_id(const IFRSession* session);
int ifr_session_available(const IFRSession* session);

/* handled is 1 when the engine consumed the key. Output pointers may be NULL. */
IFRStatus ifr_session_key(const IFRSession* session, int32_t key, int32_t modifiers, int* handled);
IFRStatus ifr_session_snapshot(const IFRSession* session, IFRSnapshot** snapshot);
void ifr_snapshot_free(IFRSnapshot* snapshot);
const char* ifr_snapshot_input(const IFRSnapshot* snapshot);   /* Rime's raw input. */
const char* ifr_snapshot_preedit(const IFRSnapshot* snapshot);
size_t ifr_snapshot_caret(const IFRSnapshot* snapshot);
size_t ifr_snapshot_selection_start(const IFRSnapshot* snapshot);
size_t ifr_snapshot_selection_end(const IFRSnapshot* snapshot);
size_t ifr_snapshot_candidate_count(const IFRSnapshot* snapshot);
const char* ifr_snapshot_candidate_text(const IFRSnapshot* snapshot, size_t index);
const char* ifr_snapshot_candidate_comment(const IFRSnapshot* snapshot, size_t index);
int32_t ifr_snapshot_page(const IFRSnapshot* snapshot);
size_t ifr_snapshot_highlighted(const IFRSnapshot* snapshot);  /* Display index. */
int ifr_snapshot_last_page(const IFRSnapshot* snapshot);

IFRStatus ifr_session_select(const IFRSession* session, const IFRSnapshot* snapshot,
                             size_t index, int* handled);
IFRStatus ifr_session_highlight(const IFRSession* session, const IFRSnapshot* snapshot,
                                size_t index);
IFRStatus ifr_session_change_page(const IFRSession* session, int backward, int* handled);
IFRStatus ifr_session_commit(const IFRSession* session, int* handled);
IFRStatus ifr_session_clear(const IFRSession* session);
/* *commit receives an owned string, or NULL when nothing completed. */
IFRStatus ifr_session_take_commit(const IFRSession* session, char** commit);
void ifr_string_free(char* string);

/* Bounded document text before the caret; only its last graphemes are kept. */
IFRStatus ifr_session_set_preceding_text(const IFRSession* session, const char* text);
/* candidate_count outside 3..9 falls back to 5. options NULL keeps the current
 * preferences. Phrases are validated; failures are reported by
 * ifr_session_configuration_error, not by the status. Settings apply at this
 * session's next composition boundary; phrases apply to every idle session. */
IFRStatus ifr_session_set_configuration(const IFRSession* session, size_t candidate_count,
                                        const IFRPhrase* phrases, size_t phrase_count,
                                        const uint32_t* options);
/* A stable code (invalid-code, duplicate, phrase-write, missing-prism, ...) or NULL. */
const char* ifr_session_configuration_error(const IFRSession* session);
size_t ifr_session_candidate_count(const IFRSession* session);
/* Returns 1 and writes the applied options once a composition boundary accepted them. */
int ifr_session_input_options(const IFRSession* session, uint32_t* options);

IFRStatus ifr_session_set_ascii_mode(const IFRSession* session, int value);
IFRStatus ifr_session_ascii_mode(const IFRSession* session, int* value);
IFRStatus ifr_session_toggle_ascii_mode(const IFRSession* session, int* handled);

/* Portable personal data: the macOS format-1 backup document. Parsing validates the
 * document and keeps its portable settings; macOS-only preferences are listed as
 * unsupported. Importing replaces the user directory's three Rime dictionaries with
 * the backup's (absence removes the local one) with rollback on failure, and is
 * rejected with IFR_ENGINE_ACTIVE while any engine is initialized in the process:
 * destroy every session and engine first, import, then recreate the engine and apply
 * the backup's settings through ifr_session_set_configuration. Phrase strings are
 * borrowed from the backup. Never call these from the key path. */
IFRStatus ifr_backup_parse(const uint8_t* bytes, size_t length, IFRBackup** backup);
void ifr_backup_free(IFRBackup* backup);
size_t ifr_backup_candidate_count(const IFRBackup* backup);
uint32_t ifr_backup_input_options(const IFRBackup* backup);
size_t ifr_backup_phrase_count(const IFRBackup* backup);
/* Returns 1 and fills phrase, or 0 when index is out of range. */
int ifr_backup_phrase(const IFRBackup* backup, size_t index, IFRPhrase* phrase);
size_t ifr_backup_unsupported_count(const IFRBackup* backup);
const char* ifr_backup_unsupported(const IFRBackup* backup, size_t index);
IFRStatus ifr_backup_import(const IFRBackup* backup, const char* user);
/* Finish an interrupted import in `user`; a no-op without a pending transaction. */
IFRStatus ifr_personal_recover(const char* user);

#ifdef __cplusplus
}
#endif
#endif
