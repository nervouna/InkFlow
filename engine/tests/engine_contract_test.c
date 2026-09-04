#include <inkflow/engine.h>

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

#ifndef INKFLOW_TEST_SHARED_DATA_DIR
#error "INKFLOW_TEST_SHARED_DATA_DIR must be defined"
#endif

#ifndef INKFLOW_TEST_C_USER_DATA_DIR
#error "INKFLOW_TEST_C_USER_DATA_DIR must be defined"
#endif

#ifndef INKFLOW_TEST_C_STAGING_DATA_DIR
#error "INKFLOW_TEST_C_STAGING_DATA_DIR must be defined"
#endif

static int make_directory_tree(const char* path) {
  char buffer[PATH_MAX];
  size_t index;
  size_t length = strlen(path);

  if (length == 0 || length >= sizeof(buffer)) {
    return 0;
  }
  memcpy(buffer, path, length + 1);
  for (index = 1; index <= length; ++index) {
    if (buffer[index] != '/' && buffer[index] != '\0') {
      continue;
    }
    {
      char saved = buffer[index];
      buffer[index] = '\0';
      if (mkdir(buffer, 0700) != 0 && errno != EEXIST) {
        return 0;
      }
      buffer[index] = saved;
    }
  }
  return 1;
}

static int expect_status(const char* operation,
                         InkFlowStatus actual,
                         InkFlowStatus expected) {
  if (actual == expected) {
    return 1;
  }
  fprintf(stderr, "%s: expected %s, got %s\n", operation,
          inkflow_status_message(expected), inkflow_status_message(actual));
  return 0;
}

int main(void) {
  InkFlowRuntimeConfig config = {0};
  InkFlowRuntime* runtime = NULL;
  InkFlowSession* session = NULL;
  InkFlowSnapshot* first = NULL;
  InkFlowSnapshot* second = NULL;

  if (inkflow_engine_api_version() != INKFLOW_ENGINE_API_VERSION) {
    fputs("unexpected engine API version\n", stderr);
    return 1;
  }
  if (!expect_status("invalid runtime arguments",
                     inkflow_runtime_create(NULL, NULL),
                     INKFLOW_STATUS_INVALID_ARGUMENT)) {
    return 1;
  }
  if (!make_directory_tree(INKFLOW_TEST_C_USER_DATA_DIR) ||
      !make_directory_tree(INKFLOW_TEST_C_STAGING_DATA_DIR)) {
    fputs("could not create isolated test data directories\n", stderr);
    return 1;
  }

  config.struct_size = sizeof(config);
  config.shared_data_dir = INKFLOW_TEST_SHARED_DATA_DIR;
  config.user_data_dir = INKFLOW_TEST_C_USER_DATA_DIR;
  config.prebuilt_data_dir = INKFLOW_TEST_SHARED_DATA_DIR;
  config.staging_data_dir = INKFLOW_TEST_C_STAGING_DATA_DIR;
  config.distribution_name = "InkFlow Tests";
  config.distribution_code_name = "inkflow-tests";
  config.distribution_version = "1";
  config.application_name = "rime.inkflow.c-contract";
  config.minimum_log_level = 3;

  if (!expect_status("create runtime",
                     inkflow_runtime_create(&config, &runtime),
                     INKFLOW_STATUS_OK) ||
      runtime == NULL) {
    return 1;
  }
  if (!expect_status("prepare raw schema",
                     inkflow_runtime_prepare(runtime), INKFLOW_STATUS_OK)) {
    return 1;
  }
  if (!expect_status("create session",
                     inkflow_session_create(runtime, "inkflow_test", &session),
                     INKFLOW_STATUS_OK) ||
      session == NULL) {
    return 1;
  }

  if (!expect_status("commit empty composition",
                     inkflow_session_commit(session, &first),
                     INKFLOW_STATUS_OK) ||
      first == NULL || inkflow_snapshot_handled(first) ||
      inkflow_snapshot_commit_text(first) != NULL ||
      strcmp(inkflow_snapshot_preedit(first), "") != 0) {
    fputs("unexpected snapshot after committing an empty composition\n",
          stderr);
    return 1;
  }
  inkflow_snapshot_destroy(first);
  first = NULL;

  if (!expect_status("type n",
                     inkflow_session_process_key(
                         session, (InkFlowKeyEvent){'n', INKFLOW_MODIFIER_NONE},
                         &first),
                     INKFLOW_STATUS_OK) ||
      first == NULL || !inkflow_snapshot_handled(first) ||
      strcmp(inkflow_snapshot_preedit(first), "n") != 0 ||
      inkflow_snapshot_commit_text(first) != NULL ||
      inkflow_snapshot_preedit_cursor_byte_offset(first) >
          strlen(inkflow_snapshot_preedit(first)) ||
      inkflow_snapshot_preedit_selection_start_byte_offset(first) >
          strlen(inkflow_snapshot_preedit(first)) ||
      inkflow_snapshot_preedit_selection_end_byte_offset(first) >
          strlen(inkflow_snapshot_preedit(first))) {
    fputs("unexpected snapshot after typing n\n", stderr);
    return 1;
  }
  if (!expect_status("type i",
                     inkflow_session_process_key(
                         session, (InkFlowKeyEvent){'i', INKFLOW_MODIFIER_NONE},
                         &second),
                     INKFLOW_STATUS_OK) ||
      second == NULL || strcmp(inkflow_snapshot_preedit(second), "ni") != 0) {
    fputs("unexpected snapshot after typing i\n", stderr);
    return 1;
  }
  if (strcmp(inkflow_snapshot_preedit(first), "n") != 0) {
    fputs("an older snapshot changed after a later operation\n", stderr);
    return 1;
  }
  inkflow_snapshot_destroy(first);
  inkflow_snapshot_destroy(second);
  first = NULL;
  second = NULL;

  if (!expect_status("reset", inkflow_session_reset(session, &first),
                     INKFLOW_STATUS_OK) ||
      strcmp(inkflow_snapshot_preedit(first), "") != 0 ||
      inkflow_snapshot_candidate_count(first) != 0) {
    fputs("reset did not clear composition\n", stderr);
    return 1;
  }
  inkflow_snapshot_destroy(first);

  if (!expect_status("destroy session", inkflow_session_destroy(session),
                     INKFLOW_STATUS_OK) ||
      !expect_status("use closed session",
                     inkflow_session_snapshot(session, &first),
                     INKFLOW_STATUS_SESSION_CLOSED) ||
      first != NULL ||
      !expect_status("destroy runtime", inkflow_runtime_destroy(runtime),
                     INKFLOW_STATUS_OK)) {
    return 1;
  }
  return 0;
}
