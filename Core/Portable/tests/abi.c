/* C consumer of the frontend ABI. Arguments: FIXTURE_ROOT SCRATCH [RESOURCES].
 * FIXTURE_ROOT holds shared/ with the tiny probe schema; RESOURCES holds prepared
 * production resources (shared/ and prepared/cache/). */
#include "inkflow_rime.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char buffer[8][4096];
static const char* path(int slot, const char* root, const char* tail) {
  snprintf(buffer[slot], sizeof(buffer[slot]), "%s/%s", root, tail);
  return buffer[slot];
}

static void expect(IFRStatus status, IFRStatus wanted, const char* what) {
  if (status != wanted) {
    fprintf(stderr, "%s: status %d (wanted %d): %s\n", what, status, wanted, ifr_last_error());
    exit(1);
  }
}

static void type_text(const IFRSession* session, const char* text) {
  for (const char* p = text; *p; ++p) {
    int handled = 0;
    expect(ifr_session_key(session, *p, 0, &handled), IFR_OK, "key");
    assert(handled == 1);
  }
}

static char* take(const IFRSession* session) {
  char* commit = (char*)1;
  expect(ifr_session_take_commit(session, &commit), IFR_OK, "take_commit");
  return commit;
}

typedef struct {
  int count;
  uint64_t session;
  int bad;
} Observed;

static void observe(void* user_data, const IFRMutation* mutation) {
  Observed* observed = (Observed*)user_data;
  observed->count++;
  if (mutation->session != observed->session || !mutation->before || !mutation->after ||
      !ifr_snapshot_preedit(mutation->before) || !ifr_snapshot_preedit(mutation->after)) {
    observed->bad++;
  }
}

static const char* backup_json =
    "{\"format\":1,\"rime\":\"1.17.0\",\"settings\":{\"integers\":{\"candidateCount\":7,\"fontSize\":18,"
    "\"input.abbreviation\":1,\"input.typoTolerance\":1,\"input.fuzzyZ\":0,\"input.fuzzyC\":0,"
    "\"input.fuzzyS\":0,\"input.emoji\":1,\"input.bracketPaging\":1,\"input.minusEqualPaging\":1,"
    "\"input.englishPunctuation\":0,\"input.cornerQuotes\":1,\"input.middleDot\":1,"
    "\"input.fullwidthPipe\":1,\"input.ideographicComma\":1,\"input.traditional\":1},"
    "\"phrases\":[{\"id\":\"p1\",\"code\":\"dz\",\"text\":\"地址\"}]},"
    "\"dictionaries\":{\"pinyin_simp\":null,\"inkflow_shared_english\":null,\"inkflow_voice_alias\":null}}";

static IFRBackup* parsed_backup(void) {
  IFRBackup* backup = NULL;
  expect(ifr_backup_parse((const uint8_t*)backup_json, strlen(backup_json), &backup), IFR_OK, "backup parse");
  assert(backup && ifr_backup_candidate_count(backup) == 7);
  assert(ifr_backup_input_options(backup) == (ifr_input_options_default() | IFR_OPTION_TRADITIONAL));
  assert(ifr_backup_phrase_count(backup) == 1);
  IFRPhrase phrase = {NULL, NULL, NULL};
  assert(ifr_backup_phrase(backup, 0, &phrase) == 1 && strcmp(phrase.code, "dz") == 0 &&
         strcmp(phrase.text, "地址") == 0 && strcmp(phrase.id, "p1") == 0);
  assert(ifr_backup_phrase(backup, 1, &phrase) == 0);
  assert(ifr_backup_unsupported_count(backup) == 1 &&
         strcmp(ifr_backup_unsupported(backup, 0), "settings.integers.fontSize") == 0);
  assert(ifr_backup_unsupported(backup, 1) == NULL);
  return backup;
}

static void backup_checks(const char* scratch) {
  IFRBackup* backup = NULL;
  expect(ifr_backup_parse(NULL, 1, &backup), IFR_INVALID_ARGUMENT, "null bytes");
  expect(ifr_backup_parse((const uint8_t*)"{}", 2, &backup), IFR_INCOMPATIBLE, "empty document");
  const char* unknown = "{\"format\":1,\"rime\":\"1.17.0\",\"settings\":{},\"dictionaries\":{},\"x\":1}";
  expect(ifr_backup_parse((const uint8_t*)unknown, strlen(unknown), &backup), IFR_UNKNOWN_FIELDS, "unknown field");
  backup = parsed_backup();
  /* No engine is live: importing absent dictionaries into a fresh directory succeeds. */
  const char* user = path(7, scratch, "import-user");
  expect(ifr_backup_import(backup, user), IFR_OK, "import");
  expect(ifr_personal_recover(user), IFR_OK, "recover");
  expect(ifr_backup_import(backup, "bad\xff"), IFR_INVALID_ARGUMENT, "bad user");
  ifr_backup_free(backup);
  ifr_backup_free(NULL);
  assert(ifr_backup_candidate_count(NULL) == 5 && ifr_backup_phrase_count(NULL) == 0);
  puts("PASS C ABI: backup parsing, disclosure, import and recovery on an isolated directory");
}

static void fixture_checks(const char* fixture, const char* scratch) {
  IFREngine* engine = NULL;
  IFREngineConfig config = {path(0, fixture, "shared"), path(1, scratch, "fixture-user"), NULL, NULL};
  assert(ifr_abi_version() == 1);
  expect(ifr_engine_create(NULL, &engine), IFR_INVALID_ARGUMENT, "null config");
  expect(ifr_engine_create(&config, NULL), IFR_INVALID_ARGUMENT, "null out");
  /* The probe schema compiles through the real runtime; the engine then rejects the
   * missing production dictionary and finalizes Rime before returning. */
  expect(ifr_engine_create(&config, &engine), IFR_RESOURCE, "fixture engine");
  assert(engine == NULL && strstr(ifr_last_error(), "pinyin_simp") != NULL);
  expect(ifr_engine_create(&config, &engine), IFR_RESOURCE, "fixture engine again");
  config.context_index = path(2, scratch, "missing.context.bin");
  expect(ifr_engine_create(&config, &engine), IFR_IO, "missing context index");
  config.shared = "bad\xff";
  expect(ifr_engine_create(&config, &engine), IFR_INVALID_ARGUMENT, "non-UTF-8 path");
  expect(ifr_session_key(NULL, 97, 0, NULL), IFR_INVALID_ARGUMENT, "null session");
  assert(ifr_session_id(NULL) == 0 && ifr_snapshot_candidate_count(NULL) == 0);
  assert(ifr_snapshot_candidate_text(NULL, 0) == NULL);
  ifr_engine_destroy(NULL);
  ifr_session_destroy(NULL);
  ifr_snapshot_free(NULL);
  ifr_string_free(NULL);
  puts("PASS C ABI: argument validation, fixture runtime lifetime and resource checks");
}

static IFREngine* production(const char* resources, const char* user) {
  IFREngine* engine = NULL;
  IFREngineConfig config = {path(3, resources, "shared"), user, path(4, resources, "prepared/cache"),
                            path(5, resources, "shared/pinyin_simp.context.bin")};
  expect(ifr_engine_create(&config, &engine), IFR_OK, "engine");
  assert(engine != NULL && ifr_engine_context_ranking_ready(engine) == 1);
  return engine;
}

static void resource_checks(const char* resources, const char* scratch) {
  const char* user = path(6, scratch, "user");
  IFREngine* engine = production(resources, user);
  IFREngine* second = NULL;
  IFREngineConfig duplicate = {path(3, resources, "shared"), user, NULL, NULL};
  expect(ifr_engine_create(&duplicate, &second), IFR_ALREADY_RUNNING, "second engine");

  IFRSession* session = NULL;
  expect(ifr_session_create(engine, &session), IFR_OK, "session");
  Observed observed = {0, ifr_session_id(session), 0};
  assert(observed.session != 0 && ifr_session_available(session) == 1);
  expect(ifr_engine_set_observer(engine, observe, &observed), IFR_OK, "observer");

  IFRPhrase phrases[] = {{"a", "dz", "地址"}};
  uint32_t options = ifr_input_options_default();
  expect(ifr_session_set_configuration(session, 9, phrases, 1, &options), IFR_OK, "configure");
  assert(ifr_session_configuration_error(session) == NULL);
  assert(ifr_session_candidate_count(session) == 9);
  uint32_t applied = 0;
  assert(ifr_session_input_options(session, &applied) == 1 && applied == options);
  IFRPhrase invalid[] = {{"b", "", "x"}};
  expect(ifr_session_set_configuration(session, 9, invalid, 1, NULL), IFR_OK, "invalid phrases");
  assert(strcmp(ifr_session_configuration_error(session), "invalid-data") == 0);
  expect(ifr_session_set_configuration(session, 9, phrases, 1, NULL), IFR_OK, "reconfigure");
  assert(ifr_session_configuration_error(session) == NULL);

  /* Composition, UTF-8 byte offsets, token-identified selection and commit draining. */
  assert(take(session) == NULL);
  type_text(session, "nihao");
  IFRSnapshot* shown = NULL;
  expect(ifr_session_snapshot(session, &shown), IFR_OK, "snapshot");
  assert(strcmp(ifr_snapshot_input(shown), "nihao") == 0);
  assert(strcmp(ifr_snapshot_preedit(shown), "ni hao") == 0);
  assert(ifr_snapshot_caret(shown) == strlen("ni hao"));
  assert(ifr_snapshot_selection_start(shown) == 0 && ifr_snapshot_selection_end(shown) == strlen("ni hao"));
  assert(ifr_snapshot_candidate_count(shown) == 9 && ifr_snapshot_page(shown) == 0);
  assert(strcmp(ifr_snapshot_candidate_text(shown, 0), "你好") == 0);
  assert(ifr_snapshot_candidate_comment(shown, 0) != NULL);
  assert(ifr_snapshot_candidate_text(shown, 9) == NULL && ifr_snapshot_highlighted(shown) == 0);
  int handled = 0;
  expect(ifr_session_select(session, shown, 9, &handled), IFR_INVALID_CANDIDATE, "out of range");
  expect(ifr_session_select(session, shown, 0, &handled), IFR_OK, "select");
  assert(handled == 1);
  char* commit = take(session);
  assert(commit && strcmp(commit, "你好") == 0);
  ifr_string_free(commit);
  assert(take(session) == NULL);
  expect(ifr_session_select(session, shown, 0, &handled), IFR_STALE_SNAPSHOT, "stale select");
  expect(ifr_session_highlight(session, shown, 0), IFR_STALE_SNAPSHOT, "stale highlight");
  ifr_snapshot_free(shown);

  /* Paging, digit selection and highlight through the policy layer. */
  type_text(session, "shi");
  IFRSnapshot* first = NULL;
  expect(ifr_session_snapshot(session, &first), IFR_OK, "first page");
  assert(ifr_snapshot_last_page(first) == 0);
  expect(ifr_session_change_page(session, 0, &handled), IFR_OK, "page down");
  IFRSnapshot* next = NULL;
  expect(ifr_session_snapshot(session, &next), IFR_OK, "second page");
  assert(handled == 1 && ifr_snapshot_page(next) == 1);
  assert(strcmp(ifr_snapshot_candidate_text(next, 0), ifr_snapshot_candidate_text(first, 0)) != 0);
  ifr_snapshot_free(next);
  expect(ifr_session_change_page(session, 1, &handled), IFR_OK, "page up");
  expect(ifr_session_snapshot(session, &next), IFR_OK, "back on first page");
  assert(ifr_snapshot_page(next) == 0);
  expect(ifr_session_highlight(session, next, 2), IFR_OK, "highlight");
  ifr_snapshot_free(next);
  expect(ifr_session_snapshot(session, &next), IFR_OK, "highlighted");
  assert(ifr_snapshot_highlighted(next) == 2);
  expect(ifr_session_key(session, 0xff54, 0, &handled), IFR_OK, "Down");
  ifr_snapshot_free(next);
  expect(ifr_session_snapshot(session, &next), IFR_OK, "moved");
  assert(handled == 1 && ifr_snapshot_highlighted(next) == 3);
  ifr_snapshot_free(next);
  expect(ifr_session_key(session, '2', 0, &handled), IFR_OK, "digit");
  commit = take(session);
  assert(handled == 1 && commit && strcmp(commit, ifr_snapshot_candidate_text(first, 1)) == 0);
  ifr_string_free(commit);
  ifr_snapshot_free(first);

  /* Custom phrases, preceding text, commit, clear and ASCII mode. */
  type_text(session, "dz");
  expect(ifr_session_snapshot(session, &shown), IFR_OK, "phrase page");
  assert(strcmp(ifr_snapshot_candidate_text(shown, 0), "地址") == 0);
  ifr_snapshot_free(shown);
  expect(ifr_session_clear(session), IFR_OK, "clear");
  expect(ifr_session_snapshot(session, &shown), IFR_OK, "cleared");
  assert(ifr_snapshot_preedit(shown)[0] == 0 && ifr_snapshot_candidate_count(shown) == 0);
  ifr_snapshot_free(shown);
  expect(ifr_session_set_preceding_text(session, "中国"), IFR_OK, "preceding");
  expect(ifr_session_set_preceding_text(session, "bad\xff"), IFR_INVALID_ARGUMENT, "bad preceding");
  type_text(session, "nihao");
  expect(ifr_session_commit(session, &handled), IFR_OK, "commit");
  commit = take(session);
  assert(handled == 1 && commit && strcmp(commit, "你好") == 0);
  ifr_string_free(commit);
  int ascii = 1;
  expect(ifr_session_ascii_mode(session, &ascii), IFR_OK, "ascii read");
  assert(ascii == 0);
  expect(ifr_session_set_ascii_mode(session, 1), IFR_OK, "ascii on");
  expect(ifr_session_key(session, 'a', 0, &handled), IFR_OK, "ascii key");
  assert(handled == 0);
  expect(ifr_session_ascii_mode(session, &ascii), IFR_OK, "ascii read");
  assert(ascii == 1);
  expect(ifr_session_toggle_ascii_mode(session, &handled), IFR_OK, "toggle");
  expect(ifr_session_ascii_mode(session, &ascii), IFR_OK, "ascii read");
  assert(handled == 1 && ascii == 0);
  assert(observed.count > 10 && observed.bad == 0);
  expect(ifr_engine_set_observer(engine, NULL, NULL), IFR_OK, "remove observer");
  int before = observed.count;
  type_text(session, "ni");
  assert(observed.count == before);
  expect(ifr_session_clear(session), IFR_OK, "clear");

  /* Personal-data import waits for every engine reference, including live sessions. */
  IFRBackup* backup = parsed_backup();
  expect(ifr_backup_import(backup, user), IFR_ENGINE_ACTIVE, "import while live");

  /* The session keeps the engine alive after the caller drops its reference. */
  ifr_engine_destroy(engine);
  type_text(session, "nihao");
  expect(ifr_session_snapshot(session, &shown), IFR_OK, "after engine release");
  assert(strcmp(ifr_snapshot_candidate_text(shown, 0), "你好") == 0);
  ifr_snapshot_free(shown);
  expect(ifr_engine_create(&duplicate, &second), IFR_ALREADY_RUNNING, "still running");
  expect(ifr_backup_import(backup, user), IFR_ENGINE_ACTIVE, "import with a live session");
  ifr_session_destroy(session);
  expect(ifr_backup_import(backup, user), IFR_OK, "import after teardown");
  ifr_backup_free(backup);
  engine = production(resources, user);
  ifr_engine_destroy(engine);
  puts("PASS C ABI: engine/session lifetime, keys, snapshots, selection, paging, commits, configuration");
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fputs("usage: abi-test FIXTURE_ROOT SCRATCH [RESOURCES]\n", stderr);
    return 2;
  }
  fixture_checks(argv[1], argv[2]);
  backup_checks(argv[2]);
  if (argc > 3) {
    resource_checks(argv[3], argv[2]);
  } else {
    puts("SKIP C ABI production checks: no resources directory");
  }
  return 0;
}
