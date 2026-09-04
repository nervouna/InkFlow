#include "test_support.hpp"

#include <cstring>
#include <filesystem>
#include <thread>

#ifndef INKFLOW_TEST_SHARED_DATA_DIR
#error "INKFLOW_TEST_SHARED_DATA_DIR must be defined"
#endif
#ifndef INKFLOW_TEST_CPP_USER_DATA_DIR
#error "INKFLOW_TEST_CPP_USER_DATA_DIR must be defined"
#endif
#ifndef INKFLOW_TEST_CPP_STAGING_DATA_DIR
#error "INKFLOW_TEST_CPP_STAGING_DATA_DIR must be defined"
#endif

namespace {

bool expect_preedit(InkFlowSession* session, const char* expected) {
  InkFlowSnapshot* snapshot = nullptr;
  if (!inkflow::test::expect_status(
          "get snapshot", inkflow_session_snapshot(session, &snapshot),
          INKFLOW_STATUS_OK) ||
      snapshot == nullptr) {
    return false;
  }
  const bool matches =
      std::strcmp(inkflow_snapshot_preedit(snapshot), expected) == 0;
  if (!matches) {
    std::cerr << "Expected preedit '" << expected << "', got '"
              << inkflow_snapshot_preedit(snapshot) << "'\n";
  }
  inkflow_snapshot_destroy(snapshot);
  return matches;
}

}  // namespace

int main() {
  using inkflow::test::expect_status;

  if (!inkflow::test::reset_test_directories(
          INKFLOW_TEST_CPP_USER_DATA_DIR,
          INKFLOW_TEST_CPP_STAGING_DATA_DIR)) {
    return 1;
  }
  InkFlowRuntimeConfig config = inkflow::test::make_config(
      INKFLOW_TEST_SHARED_DATA_DIR, INKFLOW_TEST_CPP_USER_DATA_DIR,
      INKFLOW_TEST_CPP_STAGING_DATA_DIR, "rime.inkflow.lifecycle");

  InkFlowRuntime* runtime = nullptr;
  if (!expect_status("prepare null runtime", inkflow_runtime_prepare(nullptr),
                     INKFLOW_STATUS_INVALID_ARGUMENT)) {
    return 1;
  }
  InkFlowRuntimeConfig overlapping_paths = config;
  overlapping_paths.user_data_dir = INKFLOW_TEST_SHARED_DATA_DIR;
  if (!expect_status("overlapping read-only and writable paths",
                     inkflow_runtime_create(&overlapping_paths, &runtime),
                     INKFLOW_STATUS_INVALID_ARGUMENT) ||
      runtime != nullptr) {
    return 1;
  }
  InkFlowRuntimeConfig invalid_application = config;
  invalid_application.application_name = "inkflow.lifecycle";
  if (!expect_status("invalid application name",
                     inkflow_runtime_create(&invalid_application, &runtime),
                     INKFLOW_STATUS_INVALID_ARGUMENT) ||
      runtime != nullptr) {
    return 1;
  }
  InkFlowRuntimeConfig short_config = config;
  short_config.struct_size = offsetof(InkFlowRuntimeConfig, application_name);
  if (!expect_status("short config",
                     inkflow_runtime_create(&short_config, &runtime),
                     INKFLOW_STATUS_INVALID_ARGUMENT) ||
      runtime != nullptr ||
      !expect_status("forged runtime",
                     inkflow_session_create(
                         reinterpret_cast<InkFlowRuntime*>(1), "inkflow_test",
                         reinterpret_cast<InkFlowSession**>(&runtime)),
                     INKFLOW_STATUS_INVALID_ARGUMENT)) {
    return 1;
  }

  if (!expect_status("create runtime", inkflow_runtime_create(&config, &runtime),
                     INKFLOW_STATUS_OK) ||
      runtime == nullptr) {
    return 1;
  }
  const std::filesystem::path deployed_table =
      std::filesystem::path(INKFLOW_TEST_CPP_STAGING_DATA_DIR) /
      "inkflow_test.table.bin";
  if (std::filesystem::exists(deployed_table)) {
    fputs("runtime creation unexpectedly deployed schema data\n", stderr);
    return 1;
  }
  if (!expect_status("prepare raw schema", inkflow_runtime_prepare(runtime),
                     INKFLOW_STATUS_OK) ||
      !std::filesystem::is_regular_file(deployed_table)) {
    fputs("explicit runtime preparation did not deploy schema data\n", stderr);
    return 1;
  }
  InkFlowRuntime* duplicate = nullptr;
  if (!expect_status("duplicate runtime",
                     inkflow_runtime_create(&config, &duplicate),
                     INKFLOW_STATUS_RUNTIME_ALREADY_EXISTS) ||
      duplicate != nullptr) {
    return 1;
  }

  InkFlowSession* first = nullptr;
  InkFlowSession* second = nullptr;
  if (!expect_status("invalid schema id",
                     inkflow_session_create(runtime, "invalid/schema", &first),
                     INKFLOW_STATUS_INVALID_ARGUMENT) ||
      first != nullptr ||
      !expect_status("nonexistent schema",
                     inkflow_session_create(runtime, "does_not_exist", &first),
                     INKFLOW_STATUS_BACKEND_ERROR) ||
      first != nullptr ||
      !expect_status("missing session output",
                     inkflow_session_create(runtime, "inkflow_test", nullptr),
                     INKFLOW_STATUS_INVALID_ARGUMENT) ||
      !expect_status("create first session",
                     inkflow_session_create(runtime, "inkflow_test", &first),
                     INKFLOW_STATUS_OK) ||
      !expect_status("create second session",
                     inkflow_session_create(runtime, "inkflow_test", &second),
                     INKFLOW_STATUS_OK)) {
    return 1;
  }

  if (!expect_status("prepare while sessions are active",
                     inkflow_runtime_prepare(runtime),
                     INKFLOW_STATUS_RUNTIME_IN_USE)) {
    return 1;
  }

  InkFlowSnapshot* snapshot = reinterpret_cast<InkFlowSnapshot*>(1);
  if (!expect_status("commit empty composition",
                     inkflow_session_commit(first, &snapshot),
                     INKFLOW_STATUS_OK) ||
      snapshot == nullptr || inkflow_snapshot_handled(snapshot) ||
      inkflow_snapshot_commit_text(snapshot) != nullptr ||
      std::strcmp(inkflow_snapshot_preedit(snapshot), "") != 0) {
    return 1;
  }
  inkflow_snapshot_destroy(snapshot);
  snapshot = nullptr;
  if (!expect_status("commit without output",
                     inkflow_session_commit(first, nullptr),
                     INKFLOW_STATUS_INVALID_ARGUMENT)) {
    return 1;
  }

  bool first_result = false;
  bool second_result = false;
  std::thread first_thread([&] {
    first_result = inkflow::test::type_text(first, "ni");
  });
  std::thread second_thread([&] {
    second_result = inkflow::test::type_text(second, "ha");
  });
  first_thread.join();
  second_thread.join();
  if (!first_result || !second_result || !expect_preedit(first, "ni") ||
      !expect_preedit(second, "ha")) {
    fputs("sessions were not independent under concurrent calls\n", stderr);
    return 1;
  }

  snapshot = reinterpret_cast<InkFlowSnapshot*>(1);
  if (!expect_status("portable backspace",
                     inkflow_session_process_key(
                         first,
                         InkFlowKeyEvent{INKFLOW_KEY_BACKSPACE,
                                         INKFLOW_MODIFIER_NONE},
                         &snapshot),
                     INKFLOW_STATUS_OK) ||
      snapshot == nullptr || !inkflow_snapshot_handled(snapshot) ||
      std::strcmp(inkflow_snapshot_preedit(snapshot), "n") != 0) {
    return 1;
  }
  inkflow_snapshot_destroy(snapshot);
  snapshot = nullptr;
  if (!expect_status("valid Unicode scalar",
                     inkflow_session_process_key(
                         second,
                         InkFlowKeyEvent{0x4f60u, INKFLOW_MODIFIER_NONE},
                         &snapshot),
                     INKFLOW_STATUS_OK) ||
      snapshot == nullptr) {
    return 1;
  }
  inkflow_snapshot_destroy(snapshot);
  snapshot = reinterpret_cast<InkFlowSnapshot*>(1);
  if (!expect_status(
          "unsupported Unicode surrogate",
          inkflow_session_process_key(
              first, InkFlowKeyEvent{0xd800u, INKFLOW_MODIFIER_NONE}, &snapshot),
          INKFLOW_STATUS_UNSUPPORTED_KEY) ||
      snapshot != nullptr ||
      !expect_status(
          "unknown modifier",
          inkflow_session_process_key(
              first, InkFlowKeyEvent{'x', 1u << 20}, &snapshot),
          INKFLOW_STATUS_UNSUPPORTED_KEY) ||
      snapshot != nullptr) {
    return 1;
  }

  if (!expect_status("reset first", inkflow_session_reset(first, &snapshot),
                     INKFLOW_STATUS_OK)) {
    return 1;
  }
  inkflow_snapshot_destroy(snapshot);
  snapshot = nullptr;
  if (!inkflow::test::type_text(first, "nihao") ||
      !expect_status("snapshot candidates",
                     inkflow_session_snapshot(first, &snapshot),
                     INKFLOW_STATUS_OK) ||
      snapshot == nullptr || inkflow_snapshot_candidate_count(snapshot) != 1 ||
      std::strcmp(inkflow_snapshot_candidate_text(snapshot, 0), "你好") != 0 ||
      inkflow_snapshot_candidate_text(snapshot, 1) != nullptr ||
      inkflow_snapshot_candidate_comment(snapshot, 0) != nullptr ||
      inkflow_snapshot_highlighted_candidate_index(snapshot) != 0 ||
      inkflow_snapshot_has_previous_page(snapshot) ||
      inkflow_snapshot_has_next_page(snapshot)) {
    fputs("candidate snapshot did not match the isolated schema\n", stderr);
    return 1;
  }
  inkflow_snapshot_destroy(snapshot);
  snapshot = reinterpret_cast<InkFlowSnapshot*>(1);
  if (!expect_status("invalid candidate index",
                     inkflow_session_select_candidate(first, 1, &snapshot),
                     INKFLOW_STATUS_INVALID_CANDIDATE_INDEX) ||
      snapshot != nullptr || !expect_preedit(first, "nihao") ||
      !expect_status("invalid delete index",
                     inkflow_session_delete_candidate(first, 1, &snapshot),
                     INKFLOW_STATUS_INVALID_CANDIDATE_INDEX) ||
      snapshot != nullptr ||
      !expect_status("change unavailable page",
                     inkflow_session_change_page(first, 0, &snapshot),
                     INKFLOW_STATUS_OK) ||
      snapshot == nullptr || inkflow_snapshot_handled(snapshot)) {
    return 1;
  }
  inkflow_snapshot_destroy(snapshot);
  snapshot = reinterpret_cast<InkFlowSnapshot*>(1);
  if (!expect_status("invalid page direction",
                     inkflow_session_change_page(first, 2, &snapshot),
                     INKFLOW_STATUS_INVALID_ARGUMENT) ||
      snapshot != nullptr) {
    return 1;
  }

  if (!expect_status("commit composition",
                     inkflow_session_commit(first, &snapshot),
                     INKFLOW_STATUS_OK) ||
      snapshot == nullptr || !inkflow_snapshot_handled(snapshot) ||
      inkflow_snapshot_commit_text(snapshot) == nullptr ||
      std::strcmp(inkflow_snapshot_commit_text(snapshot), "你好") != 0 ||
      std::strcmp(inkflow_snapshot_preedit(snapshot), "") != 0 ||
      inkflow_snapshot_candidate_count(snapshot) != 0) {
    fputs("forced composition commit did not return the selected text\n",
          stderr);
    return 1;
  }
  inkflow_snapshot_destroy(snapshot);
  snapshot = nullptr;

  if (!expect_status("destroy first session", inkflow_session_destroy(first),
                     INKFLOW_STATUS_OK) ||
      !expect_status("destroy first session twice",
                     inkflow_session_destroy(first),
                     INKFLOW_STATUS_SESSION_CLOSED) ||
      !expect_status("commit closed session",
                     inkflow_session_commit(first, &snapshot),
                     INKFLOW_STATUS_SESSION_CLOSED) ||
      snapshot != nullptr ||
      !expect_status("forged session",
                     inkflow_session_snapshot(
                         reinterpret_cast<InkFlowSession*>(1), &snapshot),
                     INKFLOW_STATUS_INVALID_ARGUMENT) ||
      !expect_status("destroy runtime", inkflow_runtime_destroy(runtime),
                     INKFLOW_STATUS_OK) ||
      !expect_status("session closed by runtime",
                     inkflow_session_snapshot(second, &snapshot),
                     INKFLOW_STATUS_SESSION_CLOSED) ||
      !expect_status("destroy runtime twice", inkflow_runtime_destroy(runtime),
                     INKFLOW_STATUS_RUNTIME_FINALIZED)) {
    return 1;
  }

  if (!expect_status("prepare finalized runtime",
                     inkflow_runtime_prepare(runtime),
                     INKFLOW_STATUS_RUNTIME_FINALIZED)) {
    return 1;
  }

  duplicate = nullptr;
  if (!expect_status("runtime cannot be recreated",
                     inkflow_runtime_create(&config, &duplicate),
                     INKFLOW_STATUS_RUNTIME_FINALIZED) ||
      duplicate != nullptr) {
    return 1;
  }
  return 0;
}
