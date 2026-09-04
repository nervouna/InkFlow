#ifndef INKFLOW_ENGINE_INTERNAL_HPP_
#define INKFLOW_ENGINE_INTERNAL_HPP_

#include <inkflow/engine.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "librime_backend.hpp"

struct InkFlowCandidate {
  std::string text;
  std::optional<std::string> comment;
};

struct InkFlowSnapshot {
  bool handled = false;
  std::optional<std::string> commit_text;
  std::string preedit;
  size_t cursor_byte_offset = 0;
  size_t selection_start_byte_offset = 0;
  size_t selection_end_byte_offset = 0;
  size_t highlighted_candidate_index = INKFLOW_NO_CANDIDATE;
  bool has_previous_page = false;
  bool has_next_page = false;
  std::vector<InkFlowCandidate> candidates;
};

struct InkFlowRuntime;

struct InkFlowSession {
  InkFlowRuntime* runtime = nullptr;
  RimeSessionId backend_id = 0;
  bool open = false;
};

struct InkFlowRuntime {
  std::string shared_data_dir;
  std::string user_data_dir;
  std::string prebuilt_data_dir;
  std::string staging_data_dir;
  std::string distribution_name;
  std::string distribution_code_name;
  std::string distribution_version;
  std::string application_name;
  int minimum_log_level = 0;
  bool active = false;
  inkflow::RimeBackend backend;
  std::vector<std::unique_ptr<InkFlowSession>> sessions;
};

namespace inkflow {

InkFlowStatus map_key_event(InkFlowKeyEvent event,
                            int* backend_keycode,
                            int* backend_modifiers);

template <typename Operation>
InkFlowStatus protect(Operation&& operation) {
  try {
    return operation();
  } catch (const std::bad_alloc&) {
    return INKFLOW_STATUS_OUT_OF_MEMORY;
  } catch (...) {
    return INKFLOW_STATUS_INTERNAL_ERROR;
  }
}

}  // namespace inkflow

#endif  // INKFLOW_ENGINE_INTERNAL_HPP_
