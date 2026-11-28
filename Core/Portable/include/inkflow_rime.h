#ifndef INKFLOW_RIME_H
#define INKFLOW_RIME_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif


typedef int32_t IFRStatus;
enum {
  IFR_OK = 0,
  IFR_PANIC = 1,
  IFR_INVALID_ARGUMENT = 2,
  IFR_NATIVE = 3,
  IFR_POISONED = 4,
  IFR_ALREADY_RUNNING = 5,
  IFR_SESSIONS_ACTIVE = 6,
  IFR_RESOURCE = 7,
  IFR_CONFIGURATION = 8,
  IFR_IO = 9,
  IFR_STALE_SNAPSHOT = 10,
  IFR_INVALID_CANDIDATE = 11,
  IFR_ENGINE_ACTIVE = 12,
  IFR_INCOMPATIBLE = 13,
  IFR_UNKNOWN_FIELDS = 14,
  IFR_SETTINGS = 15,
  IFR_PHRASES = 16,
  IFR_SNAPSHOT = 17,
  IFR_RECOVERY_REQUIRED = 18
  ,
  IFR_BUSY = 19,
  IFR_UNAVAILABLE = 20,
  IFR_CONFLICT = 21,
  IFR_TOO_LARGE = 22
  ,
  IFR_NO_REPLY = 23
};

typedef struct IFREngine IFREngine;
typedef struct IFRSession IFRSession;
typedef struct IFRSnapshot IFRSnapshot;
typedef struct IFRBackup IFRBackup;
typedef struct IFRLearning IFRLearning;
typedef struct IFRLearningUndo IFRLearningUndo;
typedef struct IFRPersonalExport IFRPersonalExport;
typedef struct IFRReply IFRReply;

typedef struct {
  const char* shared;
  const char* user;
  const char* cache;
  const char* context_index;
} IFREngineConfig;

typedef struct {
  const char* id;
  const char* code;
  const char* text;
} IFRPhrase;

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

uint32_t ifr_abi_version(void);
const char* ifr_last_error(void);
uint32_t ifr_input_options_default(void);
const char* ifr_rime_version(void);
size_t ifr_compiled_file_count(void);
const char* ifr_compiled_file_name(size_t index);

IFRStatus ifr_engine_create(const IFREngineConfig* config, IFREngine** engine);
void ifr_engine_destroy(IFREngine* engine);
int ifr_engine_context_ranking_ready(const IFREngine* engine);

IFRStatus ifr_session_create(const IFREngine* engine, IFRSession** session);
void ifr_session_destroy(IFRSession* session);
uint64_t ifr_session_id(const IFRSession* session);
int ifr_session_available(const IFRSession* session);

IFRStatus ifr_session_key(const IFRSession* session, int32_t key, int32_t modifiers, int* handled);
IFRStatus ifr_session_snapshot(const IFRSession* session, IFRSnapshot** snapshot);
IFRStatus ifr_session_snapshot_if_changed(const IFRSession* session, const IFRSnapshot* previous,
                                          IFRSnapshot** snapshot);
void ifr_snapshot_free(IFRSnapshot* snapshot);
const char* ifr_snapshot_input(const IFRSnapshot* snapshot);
const char* ifr_snapshot_preedit(const IFRSnapshot* snapshot);
size_t ifr_snapshot_caret(const IFRSnapshot* snapshot);
size_t ifr_snapshot_selection_start(const IFRSnapshot* snapshot);
size_t ifr_snapshot_selection_end(const IFRSnapshot* snapshot);
size_t ifr_snapshot_candidate_count(const IFRSnapshot* snapshot);
const char* ifr_snapshot_candidate_text(const IFRSnapshot* snapshot, size_t index);
const char* ifr_snapshot_candidate_comment(const IFRSnapshot* snapshot, size_t index);
int32_t ifr_snapshot_page(const IFRSnapshot* snapshot);
size_t ifr_snapshot_highlighted(const IFRSnapshot* snapshot);
int ifr_snapshot_last_page(const IFRSnapshot* snapshot);

size_t ifr_snapshot_raw_caret(const IFRSnapshot* snapshot);

size_t ifr_snapshot_candidate_native_index(const IFRSnapshot* snapshot, size_t index);
size_t ifr_snapshot_candidate_native_rank(const IFRSnapshot* snapshot, size_t index);
enum { IFR_PERSONAL_NONE = 0, IFR_PERSONAL_EXACT_ENGLISH = 1, IFR_PERSONAL_EXACT_MIXED = 2 };
int ifr_snapshot_candidate_personal_source(const IFRSnapshot* snapshot, size_t index);
int ifr_snapshot_candidate_consumed_input(const IFRSnapshot* snapshot, size_t index,
                                          size_t* start, size_t* end);

const char* ifr_snapshot_candidate_evidence(const IFRSnapshot* snapshot, size_t index);

IFRStatus ifr_session_select(const IFRSession* session, const IFRSnapshot* snapshot,
                             size_t index, int* handled);
IFRStatus ifr_session_highlight(const IFRSession* session, const IFRSnapshot* snapshot,
                                size_t index);
IFRStatus ifr_session_change_page(const IFRSession* session, int backward, int* handled);
IFRStatus ifr_session_commit(const IFRSession* session, int* handled);
IFRStatus ifr_session_clear(const IFRSession* session);
IFRStatus ifr_session_take_commit(const IFRSession* session, char** commit);
void ifr_string_free(char* string);

IFRStatus ifr_session_set_preceding_text(const IFRSession* session, const char* text);
IFRStatus ifr_session_start_document_context(const IFRSession* session, const char* text);
IFRStatus ifr_session_set_configuration(const IFRSession* session, size_t candidate_count,
                                        const IFRPhrase* phrases, size_t phrase_count,
                                        const uint32_t* options);
const char* ifr_session_configuration_error(const IFRSession* session);
size_t ifr_session_candidate_count(const IFRSession* session);
int ifr_session_input_options(const IFRSession* session, uint32_t* options);

IFRStatus ifr_session_set_ascii_mode(const IFRSession* session, int value);
IFRStatus ifr_session_ascii_mode(const IFRSession* session, int* value);
int ifr_session_requested_ascii_mode(const IFRSession* session);
IFRStatus ifr_session_toggle_ascii_mode(const IFRSession* session, int* handled);

IFRStatus ifr_backup_parse(const uint8_t* bytes, size_t length, IFRBackup** backup);
void ifr_backup_free(IFRBackup* backup);
size_t ifr_backup_candidate_count(const IFRBackup* backup);
uint32_t ifr_backup_input_options(const IFRBackup* backup);
size_t ifr_backup_phrase_count(const IFRBackup* backup);
int ifr_backup_phrase(const IFRBackup* backup, size_t index, IFRPhrase* phrase);
size_t ifr_backup_unsupported_count(const IFRBackup* backup);
const char* ifr_backup_unsupported(const IFRBackup* backup, size_t index);
IFRStatus ifr_backup_import(const IFRBackup* backup, const char* user);
IFRStatus ifr_personal_recover(const char* user);

enum { IFR_LEARNING_ENGLISH = 0, IFR_LEARNING_VOICE = 1 };
IFRStatus ifr_personal_learning_entries(const IFREngine* engine, IFRLearning** learning);
void ifr_learning_free(IFRLearning* learning);
size_t ifr_learning_count(const IFRLearning* learning);
int ifr_learning_source(const IFRLearning* learning, size_t index);
const char* ifr_learning_code(const IFRLearning* learning, size_t index);
const char* ifr_learning_text(const IFRLearning* learning, size_t index);
uint32_t ifr_learning_commits(const IFRLearning* learning, size_t index);
IFRStatus ifr_personal_learning_delete(const IFREngine* engine, const IFRLearning* learning,
                                       size_t index, IFRLearningUndo** undo);
IFRStatus ifr_personal_learning_undo(const IFREngine* engine, const IFRLearningUndo* undo);
void ifr_learning_undo_free(IFRLearningUndo* undo);
IFRStatus ifr_personal_learning_invalidate(const IFREngine* engine);

IFRStatus ifr_resources_compile(const char* shared, const char* user, const char* cache);
IFRStatus ifr_resources_probe(const char* shared, const char* user, const char* cache);

IFRStatus ifr_personal_export(const char* user, IFRPersonalExport** exported);
void ifr_personal_export_free(IFRPersonalExport* exported);
const char* ifr_personal_export_text(const IFRPersonalExport* exported, const char* name);

IFRStatus ifr_session_call(const IFRSession* session, const char* op, const char* const* fields,
                           size_t field_count, size_t capacity, IFRReply** reply);
const char* ifr_reply_status(const IFRReply* reply);
const char* ifr_reply_body(const IFRReply* reply);
void ifr_reply_free(IFRReply* reply);

#ifdef __cplusplus
}
#endif
#endif
