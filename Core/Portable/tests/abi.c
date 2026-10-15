/* C consumer of the frontend ABI. Arguments: FIXTURE_ROOT SCRATCH [RESOURCES].
 * FIXTURE_ROOT holds shared/ with the tiny probe schema; RESOURCES holds prepared
 * production resources (shared/ and prepared/cache/). */
#include "inkflow_rime.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char buffer[12][4096];
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

/* A format-1 document carrying the given snapshot texts, NULL for an absent dictionary. */
static const char* dictionary_names[3] = {"pinyin_simp", "inkflow_shared_english", "inkflow_voice_alias"};

static char* append_json_string(char* out, const char* text) {
  *out++ = '"';
  for (const char* p = text; *p; ++p) {
    if (*p == '"' || *p == '\\') {
      *out++ = '\\';
      *out++ = *p;
    } else if (*p == '\n') {
      *out++ = '\\';
      *out++ = 'n';
    } else if (*p == '\t') {
      *out++ = '\\';
      *out++ = 't';
    } else {
      *out++ = *p;
    }
  }
  *out++ = '"';
  return out;
}

static void backup_document(char* out, size_t size, const char* const texts[3]) {
  char* end = out + size;
  out += snprintf(out, size,
                 "{\"format\":1,\"rime\":\"1.17.0\",\"settings\":{\"integers\":{\"candidateCount\":5,"
                 "\"input.abbreviation\":1,\"input.typoTolerance\":1,\"input.fuzzyZ\":0,\"input.fuzzyC\":0,"
                 "\"input.fuzzyS\":0,\"input.emoji\":1,\"input.bracketPaging\":1,\"input.minusEqualPaging\":0,"
                 "\"input.englishPunctuation\":0,\"input.cornerQuotes\":1,\"input.middleDot\":1,"
                 "\"input.fullwidthPipe\":1,\"input.ideographicComma\":1,\"input.traditional\":0},"
                 "\"phrases\":[]},\"dictionaries\":{");
  for (int n = 0; n < 3; ++n) {
    out += snprintf(out, (size_t)(end - out), "%s\"%s\":", n ? "," : "", dictionary_names[n]);
    if (texts[n]) {
      out = append_json_string(out, texts[n]);
    } else {
      out += snprintf(out, (size_t)(end - out), "null");
    }
  }
  strcpy(out, "}}");
}

/* The macOS personal-data worker test's synthetic dictionaries. */
static void synthetic(char* out, size_t size, const char* name, const char* row) {
  snprintf(out, size,
           "# Rime user dictionary\n#@/db_name\t%s\n#@/db_type\tuserdb\n#@/rime_version\t1.17.0\n"
           "#@/user_id\tsynthetic-source\n#@/tick\t99\n%s\tc=7 d=0.123456789 t=42\n"
           "ce shi \t测试\tc=-3 d=0.0000123 t=17\n",
           name, row);
}

static size_t line_count(const char* text) {
  size_t count = 0;
  for (; *text; ++text) count += *text == '\n';
  return count;
}

/* Same lines, ignoring order: Rime writes a snapshot in key order. */
static int same_lines(const char* a, const char* b) {
  if (line_count(a) != line_count(b)) return 0;
  char* padded = malloc(strlen(b) + 2);
  padded[0] = '\n';
  strcpy(padded + 1, b);
  const char* start = a;
  int same = 1;
  for (const char* p = a; *p && same; ++p) {
    if (*p != '\n') continue;
    char needle[512];
    size_t length = (size_t)(p - start);
    assert(length + 3 < sizeof(needle));
    needle[0] = '\n';
    memcpy(needle + 1, start, length);
    memcpy(needle + 1 + length, "\n", 2);
    same = strstr(padded, needle) != NULL;
    start = p + 1;
  }
  free(padded);
  return same;
}

static IFRBackup* parse_document(const char* json) {
  IFRBackup* backup = NULL;
  expect(ifr_backup_parse((const uint8_t*)json, strlen(json), &backup), IFR_OK, "document parse");
  assert(backup != NULL);
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

static char* read_text(const char* file) {
  FILE* stream = fopen(file, "rb");
  assert(stream != NULL);
  char* text = malloc(1 << 16);
  size_t length = fread(text, 1, (1 << 16) - 1, stream);
  assert(feof(stream));
  text[length] = 0;
  fclose(stream);
  return text;
}

/* Snapshot export on isolated user directories; no engine is live. */
static void export_checks(const char* fixture, const char* scratch) {
  IFRPersonalExport* exported = (IFRPersonalExport*)1;
  expect(ifr_personal_export(NULL, &exported), IFR_INVALID_ARGUMENT, "null user");
  expect(ifr_personal_export("bad\xff", &exported), IFR_INVALID_ARGUMENT, "bad user");
  expect(ifr_personal_export(path(7, scratch, "export-user"), NULL), IFR_INVALID_ARGUMENT, "null out");
  assert(ifr_personal_export_text(NULL, "pinyin_simp") == NULL);
  ifr_personal_export_free(NULL);

  /* Directories without dictionaries export as explicit absence. */
  const char* user = path(7, scratch, "export-user");
  exported = NULL;
  expect(ifr_personal_export(user, &exported), IFR_OK, "export of an empty directory");
  assert(exported != NULL);
  for (int n = 0; n < 3; ++n) assert(ifr_personal_export_text(exported, dictionary_names[n]) == NULL);
  ifr_personal_export_free(exported);

  /* Restore the synthetic dictionaries, export them and take the export through a document. */
  char texts[3][1024], json[8192], again[8192];
  synthetic(texts[0], sizeof(texts[0]), "pinyin_simp", "ni hao \t你好");
  synthetic(texts[1], sizeof(texts[1]), "inkflow_shared_english", "backupword \tBackupWord");
  synthetic(texts[2], sizeof(texts[2]), "inkflow_voice_alias", "beifen \t备份别名");
  const char* incoming[3] = {texts[0], texts[1], NULL};
  backup_document(json, sizeof(json), incoming);
  IFRBackup* backup = parse_document(json);
  expect(ifr_backup_import(backup, user), IFR_OK, "import for export");
  ifr_backup_free(backup);
  expect(ifr_personal_export(user, &exported), IFR_OK, "export");
  const char* text[3];
  for (int n = 0; n < 3; ++n) text[n] = ifr_personal_export_text(exported, dictionary_names[n]);
  assert(text[0] && same_lines(text[0], texts[0]) && text[1] && same_lines(text[1], texts[1]));
  assert(text[2] == NULL && "an absent dictionary stays absent");
  assert(ifr_personal_export_text(exported, "unknown") == NULL && ifr_personal_export_text(exported, NULL) == NULL);
  backup_document(again, sizeof(again), text);
  /* The exported snapshots form a document that parses and restores into another directory,
   * where they export unchanged. */
  backup = parse_document(again);
  const char* other = path(8, scratch, "export-again");
  expect(ifr_backup_import(backup, other), IFR_OK, "import of the export");
  ifr_backup_free(backup);
  IFRPersonalExport* second = NULL;
  expect(ifr_personal_export(other, &second), IFR_OK, "export again");
  for (int n = 0; n < 3; ++n) {
    const char* b = ifr_personal_export_text(second, dictionary_names[n]);
    assert((text[n] == NULL) == (b == NULL) && (!b || strcmp(text[n], b) == 0));
  }
  ifr_personal_export_free(second);
  ifr_personal_export_free(exported);

  /* The Swift personal-data worker restored fixture/swift-user from the same synthetic
   * snapshots and wrote the .userdb.txt files from it: the same bytes come out here. */
  expect(ifr_personal_export(path(8, fixture, "swift-user"), &exported), IFR_OK, "export of the Swift directory");
  for (int n = 0; n < 3; ++n) {
    char recorded[4096];
    snprintf(recorded, sizeof(recorded), "%s/swift-user/%s.userdb.txt", fixture, dictionary_names[n]);
    char* swift = read_text(recorded);
    const char* actual = ifr_personal_export_text(exported, dictionary_names[n]);
    assert(actual != NULL && strcmp(actual, swift) == 0);
    free(swift);
  }
  ifr_personal_export_free(exported);
  puts("PASS C ABI: snapshot export, absence, round trip through a backup document, Swift writer bytes");
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

  /* Rime version: the linked librime's, with no engine. */
  assert(strcmp(ifr_rime_version(), "1.17.0") == 0);

  /* Compile deploys the fixture's probe schema, then rejects the missing production files;
   * probe needs the production schema. Neither keeps Rime initialized. */
  const char* compiler = path(9, scratch, "fixture-compile-user");
  const char* cache = path(10, scratch, "fixture-compile-cache");
  expect(ifr_resources_compile(path(0, fixture, "shared"), compiler, cache), IFR_RESOURCE, "fixture compile");
  assert(strstr(ifr_last_error(), "inkflow_pinyin") != NULL);
  expect(ifr_resources_probe(path(0, fixture, "shared"), compiler, cache), IFR_RESOURCE, "fixture probe");
  expect(ifr_resources_compile(NULL, compiler, cache), IFR_INVALID_ARGUMENT, "null shared");
  expect(ifr_resources_compile(path(0, fixture, "shared"), NULL, cache), IFR_INVALID_ARGUMENT, "null user");
  expect(ifr_resources_probe(path(0, fixture, "shared"), compiler, "bad\xff"), IFR_INVALID_ARGUMENT, "bad cache");

  /* Engine-bound maintenance rejects a missing engine and answers neutrally. */
  IFRLearning* learning = (IFRLearning*)1;
  IFRLearningUndo* undo = (IFRLearningUndo*)1;
  expect(ifr_personal_learning_entries(NULL, &learning), IFR_INVALID_ARGUMENT, "entries without an engine");
  expect(ifr_personal_learning_delete(NULL, NULL, 0, &undo), IFR_INVALID_ARGUMENT, "delete without an engine");
  expect(ifr_personal_learning_undo(NULL, NULL), IFR_INVALID_ARGUMENT, "undo without an engine");
  expect(ifr_personal_learning_invalidate(NULL), IFR_INVALID_ARGUMENT, "invalidate without an engine");
  assert(ifr_learning_count(NULL) == 0 && ifr_learning_source(NULL, 0) == -1);
  assert(ifr_learning_code(NULL, 0) == NULL && ifr_learning_text(NULL, 0) == NULL);
  assert(ifr_learning_commits(NULL, 0) == 0);
  ifr_learning_free(NULL);
  ifr_learning_undo_free(NULL);
  assert(ifr_session_requested_ascii_mode(NULL) == 0);
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

/* Type `input` and choose the candidate `target`; the commit must be exactly `target`. */
static void choose(const IFRSession* session, const char* input, const char* target) {
  type_text(session, input);
  IFRSnapshot* shown = NULL;
  expect(ifr_session_snapshot(session, &shown), IFR_OK, "choose snapshot");
  size_t index = ifr_snapshot_candidate_count(shown);
  for (size_t n = 0; n < ifr_snapshot_candidate_count(shown); ++n) {
    if (strcmp(ifr_snapshot_candidate_text(shown, n), target) == 0) {
      index = n;
      break;
    }
  }
  assert(index < ifr_snapshot_candidate_count(shown));
  int handled = 0;
  expect(ifr_session_select(session, shown, index, &handled), IFR_OK, "choose");
  ifr_snapshot_free(shown);
  char* commit = take(session);
  assert(commit && strcmp(commit, target) == 0);
  ifr_string_free(commit);
}

static IFRLearning* learning_entries(const IFREngine* engine) {
  IFRLearning* learning = NULL;
  expect(ifr_personal_learning_entries(engine, &learning), IFR_OK, "entries");
  assert(learning != NULL);
  return learning;
}

static size_t entry_index(const IFRLearning* learning, int source, const char* text) {
  for (size_t n = 0; n < ifr_learning_count(learning); ++n) {
    if (ifr_learning_source(learning, n) == source && strcmp(ifr_learning_text(learning, n), text) == 0) return n;
  }
  return (size_t)-1;
}

/* Maintenance operations on production resources: personal learning, requested ASCII,
 * probe and compile. The seeded dictionaries are the macOS worker test's synthetic ones. */
static void maintenance_checks(const char* resources, const char* scratch) {
  const char* user = path(9, scratch, "maintenance-user");
  char texts[3][1024], json[8192];
  synthetic(texts[0], sizeof(texts[0]), "pinyin_simp", "ni hao \t你好");
  synthetic(texts[1], sizeof(texts[1]), "inkflow_shared_english", "backupword \tBackupWord");
  synthetic(texts[2], sizeof(texts[2]), "inkflow_voice_alias", "beifen \t备份别名");
  const char* seed[3] = {texts[0], texts[1], texts[2]};
  backup_document(json, sizeof(json), seed);
  IFRBackup* backup = parse_document(json);
  expect(ifr_backup_import(backup, user), IFR_OK, "seed import");
  ifr_backup_free(backup);

  IFREngine* engine = production(resources, user);
  IFRSession* session = NULL;
  expect(ifr_session_create(engine, &session), IFR_OK, "maintenance session");
  uint32_t options = ifr_input_options_default();
  expect(ifr_session_set_configuration(session, 9, NULL, 0, &options), IFR_OK, "configure");

  /* Entries: both namespaces, sorted by source then code, with the seeded counts. */
  IFRLearning* learning = learning_entries(engine);
  assert(ifr_learning_count(learning) == 2);
  assert(ifr_learning_source(learning, 0) == IFR_LEARNING_ENGLISH &&
         strcmp(ifr_learning_code(learning, 0), "backupword") == 0 &&
         strcmp(ifr_learning_text(learning, 0), "BackupWord") == 0 && ifr_learning_commits(learning, 0) == 7);
  assert(ifr_learning_source(learning, 1) == IFR_LEARNING_VOICE &&
         strcmp(ifr_learning_code(learning, 1), "beifen") == 0 &&
         strcmp(ifr_learning_text(learning, 1), "备份别名") == 0 && ifr_learning_commits(learning, 1) == 7);
  assert(ifr_learning_source(learning, 2) == -1 && ifr_learning_code(learning, 2) == NULL);
  assert(ifr_learning_text(learning, 2) == NULL && ifr_learning_commits(learning, 2) == 0);

  /* Delete returns an undo token; the listing it came from is then stale. */
  IFRLearningUndo* undo = (IFRLearningUndo*)1;
  expect(ifr_personal_learning_delete(engine, learning, 2, &undo), IFR_INVALID_ARGUMENT, "index out of range");
  expect(ifr_personal_learning_delete(engine, NULL, 0, &undo), IFR_INVALID_ARGUMENT, "no listing");
  undo = NULL;
  expect(ifr_personal_learning_delete(engine, learning, 1, &undo), IFR_OK, "delete");
  assert(undo != NULL);
  IFRLearningUndo* stale = NULL;
  expect(ifr_personal_learning_delete(engine, learning, 1, &stale), IFR_CONFLICT, "stale listing");
  assert(stale == NULL);
  ifr_learning_free(learning);
  learning = learning_entries(engine);
  assert(ifr_learning_count(learning) == 1 && entry_index(learning, IFR_LEARNING_VOICE, "备份别名") == (size_t)-1);

  /* Undo restores with one more confirmation, once. */
  expect(ifr_personal_learning_undo(engine, undo), IFR_OK, "undo");
  expect(ifr_personal_learning_undo(engine, undo), IFR_CONFLICT, "undo twice");
  expect(ifr_personal_learning_undo(engine, NULL), IFR_INVALID_ARGUMENT, "no undo token");
  ifr_learning_free(learning);
  learning = learning_entries(engine);
  size_t voice = entry_index(learning, IFR_LEARNING_VOICE, "备份别名");
  assert(ifr_learning_count(learning) == 2 && voice != (size_t)-1 && ifr_learning_commits(learning, voice) == 8);
  ifr_learning_undo_free(undo);

  /* Invalidation supersedes every captured listing. */
  expect(ifr_personal_learning_invalidate(engine), IFR_OK, "invalidate");
  expect(ifr_personal_learning_delete(engine, learning, 0, &stale), IFR_CONFLICT, "invalidated listing");
  ifr_learning_free(learning);

  /* Management waits for an idle engine: composition, then Rime's native undo window. */
  type_text(session, "ni");
  learning = NULL;
  expect(ifr_personal_learning_entries(engine, &learning), IFR_BUSY, "composition");
  assert(learning == NULL);
  expect(ifr_session_clear(session), IFR_OK, "clear");
  choose(session, "nihao", "你好");
  expect(ifr_personal_learning_entries(engine, &learning), IFR_BUSY, "undo window");
  sleep(4);
  learning = learning_entries(engine);
  ifr_learning_free(learning);

  /* Requested ASCII mode is the caller's request, ahead of Rime's live switch. */
  assert(ifr_session_requested_ascii_mode(session) == 0);
  type_text(session, "ni");
  expect(ifr_session_set_ascii_mode(session, 1), IFR_OK, "ascii request");
  int live = 1;
  assert(ifr_session_requested_ascii_mode(session) == 1);
  expect(ifr_session_ascii_mode(session, &live), IFR_OK, "ascii live");
  assert(live == 0 && "the request starts after the composition");
  expect(ifr_session_clear(session), IFR_OK, "clear");
  expect(ifr_session_set_ascii_mode(session, 0), IFR_OK, "ascii release");
  assert(ifr_session_requested_ascii_mode(session) == 0);
  int handled = 0;
  expect(ifr_session_toggle_ascii_mode(session, &handled), IFR_OK, "toggle");
  assert(handled == 1 && ifr_session_requested_ascii_mode(session) == 1);
  expect(ifr_session_toggle_ascii_mode(session, &handled), IFR_OK, "toggle back");
  assert(ifr_session_requested_ascii_mode(session) == 0);

  /* Resource maintenance and personal export stay out of a live engine's way. */
  const char* probe_user = path(10, scratch, "maintenance-probe-user");
  expect(ifr_resources_probe(path(3, resources, "shared"), probe_user, path(4, resources, "prepared/cache")),
         IFR_ALREADY_RUNNING, "probe beside a live engine");
  expect(ifr_resources_compile(path(3, resources, "shared"), probe_user, path(11, scratch, "maintenance-cache")),
         IFR_ALREADY_RUNNING, "compile beside a live engine");
  IFRPersonalExport* exported = NULL;
  expect(ifr_personal_export(user, &exported), IFR_ENGINE_ACTIVE, "export beside a live engine");
  assert(exported == NULL);
  ifr_session_destroy(session);
  ifr_engine_destroy(engine);

  /* Probe the prepared cache with a clean user directory, compile the production sources
   * into a fresh one and probe that too, then export what the engine kept. */
  expect(ifr_resources_probe(path(3, resources, "shared"), probe_user, path(4, resources, "prepared/cache")),
         IFR_OK, "probe");
  const char* fresh = path(11, scratch, "maintenance-cache");
  expect(ifr_resources_compile(path(3, resources, "shared"), path(5, scratch, "maintenance-compile-user"), fresh),
         IFR_OK, "compile");
  expect(ifr_resources_probe(path(3, resources, "shared"), probe_user, fresh), IFR_OK, "probe the compiled cache");
  expect(ifr_personal_export(user, &exported), IFR_OK, "export after the engine");
  const char* english = ifr_personal_export_text(exported, "inkflow_shared_english");
  const char* alias = ifr_personal_export_text(exported, "inkflow_voice_alias");
  assert(english && strstr(english, "backupword \tBackupWord\tc=7") != NULL);
  assert(alias && strstr(alias, "beifen \t备份别名\tc=8") != NULL);
  assert(ifr_personal_export_text(exported, "pinyin_simp") != NULL);
  ifr_personal_export_free(exported);
  puts("PASS C ABI: personal learning, requested ASCII mode, probe and export beside a live engine");
}

int main(int argc, char** argv) {
  if (argc < 3) {
    fputs("usage: abi-test FIXTURE_ROOT SCRATCH [RESOURCES]\n", stderr);
    return 2;
  }
  fixture_checks(argv[1], argv[2]);
  backup_checks(argv[2]);
  export_checks(argv[1], argv[2]);
  if (argc > 3) {
    resource_checks(argv[3], argv[2]);
    maintenance_checks(argv[3], argv[2]);
  } else {
    puts("SKIP C ABI production checks: no resources directory");
  }
  return 0;
}
