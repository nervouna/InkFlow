#include "test_support.hpp"

#include <rapidjson/document.h>
#include <rapidjson/error/en.h>

#include <fstream>
#include <iterator>
#include <memory>
#include <string>

#ifndef INKFLOW_TEST_SHARED_DATA_DIR
#error "INKFLOW_TEST_SHARED_DATA_DIR must be defined"
#endif
#ifndef INKFLOW_TEST_TRANSCRIPT_PATH
#error "INKFLOW_TEST_TRANSCRIPT_PATH must be defined"
#endif
#ifndef INKFLOW_TEST_TRANSCRIPT_USER_DATA_DIR
#error "INKFLOW_TEST_TRANSCRIPT_USER_DATA_DIR must be defined"
#endif
#ifndef INKFLOW_TEST_TRANSCRIPT_STAGING_DATA_DIR
#error "INKFLOW_TEST_TRANSCRIPT_STAGING_DATA_DIR must be defined"
#endif

namespace {

using Snapshot = std::unique_ptr<InkFlowSnapshot, decltype(&inkflow_snapshot_destroy)>;

bool check_expectation(const rapidjson::Value& expectation,
                       const InkFlowSnapshot* snapshot,
                       size_t action_index) {
  auto fail = [action_index](const char* field) {
    std::cerr << "Transcript action " << action_index
              << " failed expectation: " << field << '\n';
    return false;
  };

  if (expectation.HasMember("handled") &&
      inkflow_snapshot_handled(snapshot) !=
          static_cast<int>(expectation["handled"].GetBool())) {
    return fail("handled");
  }
  if (expectation.HasMember("preedit") &&
      expectation["preedit"].GetString() !=
          std::string(inkflow_snapshot_preedit(snapshot))) {
    return fail("preedit");
  }
  if (expectation.HasMember("commit")) {
    const char* commit = inkflow_snapshot_commit_text(snapshot);
    if (expectation["commit"].IsNull()) {
      if (commit != nullptr) {
        return fail("commit");
      }
    } else if (commit == nullptr ||
               expectation["commit"].GetString() != std::string(commit)) {
      return fail("commit");
    }
  }
  if (expectation.HasMember("candidates")) {
    const auto& candidates = expectation["candidates"].GetArray();
    if (inkflow_snapshot_candidate_count(snapshot) != candidates.Size()) {
      return fail("candidates.count");
    }
    for (rapidjson::SizeType index = 0; index < candidates.Size(); ++index) {
      const char* actual = inkflow_snapshot_candidate_text(snapshot, index);
      if (actual == nullptr || candidates[index].GetString() !=
                                   std::string(actual)) {
        return fail("candidates.text");
      }
    }
  }
  if (expectation.HasMember("highlightedCandidate") &&
      inkflow_snapshot_highlighted_candidate_index(snapshot) !=
          expectation["highlightedCandidate"].GetUint64()) {
    return fail("highlightedCandidate");
  }
  if (expectation.HasMember("hasPreviousPage") &&
      inkflow_snapshot_has_previous_page(snapshot) !=
          static_cast<int>(expectation["hasPreviousPage"].GetBool())) {
    return fail("hasPreviousPage");
  }
  if (expectation.HasMember("hasNextPage") &&
      inkflow_snapshot_has_next_page(snapshot) !=
          static_cast<int>(expectation["hasNextPage"].GetBool())) {
    return fail("hasNextPage");
  }
  return true;
}

}  // namespace

int main() {
  std::ifstream stream(INKFLOW_TEST_TRANSCRIPT_PATH);
  const std::string json((std::istreambuf_iterator<char>(stream)),
                         std::istreambuf_iterator<char>());
  rapidjson::Document transcript;
  transcript.Parse(json.c_str(), json.size());
  if (transcript.HasParseError()) {
    std::cerr << "Could not parse transcript: "
              << rapidjson::GetParseError_En(transcript.GetParseError()) << '\n';
    return 1;
  }
  if (!transcript.IsObject() || !transcript.HasMember("schemaId") ||
      !transcript.HasMember("actions") || !transcript["actions"].IsArray()) {
    fputs("Transcript has an invalid shape\n", stderr);
    return 1;
  }
  if (!inkflow::test::make_test_directories(
          INKFLOW_TEST_TRANSCRIPT_USER_DATA_DIR,
          INKFLOW_TEST_TRANSCRIPT_STAGING_DATA_DIR)) {
    return 1;
  }

  InkFlowRuntimeConfig config = inkflow::test::make_config(
      INKFLOW_TEST_SHARED_DATA_DIR, INKFLOW_TEST_TRANSCRIPT_USER_DATA_DIR,
      INKFLOW_TEST_TRANSCRIPT_STAGING_DATA_DIR, "rime.inkflow.transcript");
  InkFlowRuntime* runtime = nullptr;
  InkFlowSession* session = nullptr;
  if (!inkflow::test::expect_status(
          "create runtime", inkflow_runtime_create(&config, &runtime),
          INKFLOW_STATUS_OK) ||
      !inkflow::test::expect_status(
          "prepare raw schema", inkflow_runtime_prepare(runtime),
          INKFLOW_STATUS_OK) ||
      !inkflow::test::expect_status(
          "create session",
          inkflow_session_create(runtime, transcript["schemaId"].GetString(),
                                 &session),
          INKFLOW_STATUS_OK)) {
    return 1;
  }

  size_t action_index = 0;
  for (const auto& action : transcript["actions"].GetArray()) {
    InkFlowSnapshot* raw_snapshot = nullptr;
    InkFlowStatus status = INKFLOW_STATUS_INTERNAL_ERROR;
    const std::string type = action["type"].GetString();
    if (type == "key") {
      const std::string key = action["key"].GetString();
      if (key.size() != 1) {
        fputs("This transcript runner expects one-byte portable keys\n", stderr);
        return 1;
      }
      status = inkflow_session_process_key(
          session,
          InkFlowKeyEvent{static_cast<unsigned char>(key[0]),
                          INKFLOW_MODIFIER_NONE},
          &raw_snapshot);
    } else if (type == "selectCandidate") {
      status = inkflow_session_select_candidate(
          session, action["index"].GetUint64(), &raw_snapshot);
    } else {
      std::cerr << "Unsupported transcript action: " << type << '\n';
      return 1;
    }
    Snapshot snapshot(raw_snapshot, &inkflow_snapshot_destroy);
    if (!inkflow::test::expect_status("transcript action", status,
                                     INKFLOW_STATUS_OK) ||
        snapshot == nullptr ||
        !check_expectation(action["expect"], snapshot.get(), action_index)) {
      return 1;
    }
    ++action_index;
  }

  if (!inkflow::test::expect_status("destroy session",
                                    inkflow_session_destroy(session),
                                    INKFLOW_STATUS_OK) ||
      !inkflow::test::expect_status("destroy runtime",
                                    inkflow_runtime_destroy(runtime),
                                    INKFLOW_STATUS_OK)) {
    return 1;
  }
  return 0;
}
