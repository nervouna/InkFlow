#include "engine_internal.hpp"

#include <array>
#include <cstring>
#include <limits>
#include <utility>

namespace {

class CommitRelease {
 public:
  CommitRelease(RimeApi* api, RimeCommit* commit) : api_(api), commit_(commit) {}
  ~CommitRelease() {
    if (owned_) {
      try {
        (void)api_->free_commit(commit_);
      } catch (...) {
      }
    }
  }

  bool release() {
    owned_ = false;
    return api_->free_commit(commit_) != 0;
  }

 private:
  RimeApi* api_;
  RimeCommit* commit_;
  bool owned_ = true;
};

class ContextRelease {
 public:
  ContextRelease(RimeApi* api, RimeContext* context)
      : api_(api), context_(context) {}
  ~ContextRelease() {
    if (owned_) {
      try {
        (void)api_->free_context(context_);
      } catch (...) {
      }
    }
  }

  bool release() {
    owned_ = false;
    return api_->free_context(context_) != 0;
  }

 private:
  RimeApi* api_;
  RimeContext* context_;
  bool owned_ = true;
};

class ConfigRelease {
 public:
  ConfigRelease(RimeApi* api, RimeConfig* config)
      : api_(api), config_(config) {}
  ~ConfigRelease() {
    if (owned_) {
      try {
        (void)api_->config_close(config_);
      } catch (...) {
      }
    }
  }

  bool close() {
    if (!api_->config_close(config_)) {
      return false;
    }
    owned_ = false;
    return true;
  }

 private:
  RimeApi* api_;
  RimeConfig* config_;
  bool owned_ = true;
};

class BackendSessionRelease {
 public:
  BackendSessionRelease(RimeApi* api, RimeSessionId id) : api_(api), id_(id) {}
  ~BackendSessionRelease() {
    if (owned_) {
      try {
        (void)api_->destroy_session(id_);
      } catch (...) {
      }
    }
  }

  void disarm() { owned_ = false; }

 private:
  RimeApi* api_;
  RimeSessionId id_;
  bool owned_ = true;
};

bool has_required_api(RimeApi* api) {
  return api != nullptr && RIME_API_AVAILABLE(api, setup) &&
         RIME_API_AVAILABLE(api, initialize) &&
         RIME_API_AVAILABLE(api, finalize) && RIME_API_AVAILABLE(api, deploy) &&
         RIME_API_AVAILABLE(api, deployer_initialize) &&
         RIME_API_AVAILABLE(api, create_session) &&
         RIME_API_AVAILABLE(api, find_session) &&
         RIME_API_AVAILABLE(api, destroy_session) &&
         RIME_API_AVAILABLE(api, cleanup_all_sessions) &&
         RIME_API_AVAILABLE(api, process_key) &&
         RIME_API_AVAILABLE(api, commit_composition) &&
         RIME_API_AVAILABLE(api, clear_composition) &&
         RIME_API_AVAILABLE(api, get_commit) &&
         RIME_API_AVAILABLE(api, free_commit) &&
         RIME_API_AVAILABLE(api, get_context) &&
         RIME_API_AVAILABLE(api, free_context) &&
         RIME_API_AVAILABLE(api, get_current_schema) &&
         RIME_API_AVAILABLE(api, select_schema) &&
         RIME_API_AVAILABLE(api, schema_open) &&
         RIME_API_AVAILABLE(api, config_close) &&
         RIME_API_AVAILABLE(api, config_get_cstring) &&
         RIME_API_AVAILABLE(api, select_candidate_on_current_page) &&
         RIME_API_AVAILABLE(api, delete_candidate_on_current_page) &&
         RIME_API_AVAILABLE(api, change_page);
}

RimeTraits make_traits(const InkFlowRuntime& runtime) {
  RimeTraits traits{};
  RIME_STRUCT_INIT(RimeTraits, traits);
  traits.shared_data_dir = runtime.shared_data_dir.c_str();
  traits.user_data_dir = runtime.user_data_dir.c_str();
  traits.prebuilt_data_dir = runtime.prebuilt_data_dir.c_str();
  traits.staging_dir = runtime.staging_data_dir.c_str();
  traits.distribution_name = runtime.distribution_name.c_str();
  traits.distribution_code_name = runtime.distribution_code_name.c_str();
  traits.distribution_version = runtime.distribution_version.c_str();
  traits.app_name = runtime.application_name.c_str();
  traits.min_log_level = runtime.minimum_log_level;
  traits.log_dir = "";
  return traits;
}

}  // namespace

namespace inkflow {

RimeBackend::~RimeBackend() {
  finalize();
}

InkFlowStatus RimeBackend::initialize(const InkFlowRuntime& runtime) {
  api_ = rime_get_api();
  if (!has_required_api(api_)) {
    api_ = nullptr;
    return INKFLOW_STATUS_BACKEND_UNAVAILABLE;
  }

  RimeTraits traits = make_traits(runtime);

  api_->setup(&traits);
  api_->initialize(&traits);
  initialized_ = true;
  return INKFLOW_STATUS_OK;
}

InkFlowStatus RimeBackend::prepare(const InkFlowRuntime& runtime) {
  if (!initialized_ || api_ == nullptr) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  RimeTraits traits = make_traits(runtime);
  api_->deployer_initialize(&traits);
  if (!api_->deploy()) {
    return INKFLOW_STATUS_DEPLOYMENT_FAILED;
  }
  return INKFLOW_STATUS_OK;
}

void RimeBackend::finalize() noexcept {
  if (!initialized_ || api_ == nullptr) {
    return;
  }
  initialized_ = false;
  try {
    api_->cleanup_all_sessions();
    api_->finalize();
  } catch (...) {
    // Destructors and the C ABI must never propagate an upstream exception.
  }
}

InkFlowStatus RimeBackend::create_session(const char* schema_id,
                                          RimeSessionId* out_id) {
  if (!initialized_ || out_id == nullptr) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  *out_id = 0;

  // select_schema() accepts any syntactically valid identifier and
  // get_current_schema() merely echoes it. Verify that the deployed schema can
  // actually be loaded and identifies itself before allocating a session.
  RimeConfig schema{};
  if (!api_->schema_open(schema_id, &schema)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  ConfigRelease schema_release(api_, &schema);
  const char* configured_schema_id =
      api_->config_get_cstring(&schema, "schema/schema_id");
  if (configured_schema_id == nullptr ||
      std::strcmp(configured_schema_id, schema_id) != 0) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }

  const RimeSessionId id = api_->create_session();
  if (id == 0) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  BackendSessionRelease release(api_, id);
  if (!api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  if (!api_->select_schema(id, schema_id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }

  std::array<char, 256> selected_schema{};
  if (!api_->get_current_schema(id, selected_schema.data(),
                                selected_schema.size()) ||
      std::strcmp(selected_schema.data(), schema_id) != 0) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  if (!schema_release.close()) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  release.disarm();
  *out_id = id;
  return INKFLOW_STATUS_OK;
}

InkFlowStatus RimeBackend::destroy_session(RimeSessionId id) {
  if (!initialized_ || id == 0 || !api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  return api_->destroy_session(id) ? INKFLOW_STATUS_OK
                                   : INKFLOW_STATUS_BACKEND_ERROR;
}

InkFlowStatus RimeBackend::process_key(RimeSessionId id,
                                       int keycode,
                                       int modifiers,
                                       bool* handled) {
  if (!initialized_ || handled == nullptr || !api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  *handled = api_->process_key(id, keycode, modifiers) != 0;
  return INKFLOW_STATUS_OK;
}

InkFlowStatus RimeBackend::commit_composition(RimeSessionId id,
                                              bool* handled) {
  if (!initialized_ || handled == nullptr || !api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  *handled = api_->commit_composition(id) != 0;
  return INKFLOW_STATUS_OK;
}

InkFlowStatus RimeBackend::clear_composition(RimeSessionId id) {
  if (!initialized_ || !api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  api_->clear_composition(id);
  return INKFLOW_STATUS_OK;
}

InkFlowStatus RimeBackend::validate_candidate_index(RimeSessionId id,
                                                    size_t index) {
  RimeContext context{};
  RIME_STRUCT_INIT(RimeContext, context);
  if (!api_->get_context(id, &context)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  ContextRelease release(api_, &context);
  if (context.menu.num_candidates < 0) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  const bool valid =
      index < static_cast<size_t>(context.menu.num_candidates);
  if (!release.release()) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  return valid ? INKFLOW_STATUS_OK
               : INKFLOW_STATUS_INVALID_CANDIDATE_INDEX;
}

InkFlowStatus RimeBackend::select_candidate(RimeSessionId id,
                                            size_t index,
                                            bool* handled) {
  if (!initialized_ || handled == nullptr || !api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  const InkFlowStatus validation = validate_candidate_index(id, index);
  if (validation != INKFLOW_STATUS_OK) {
    return validation;
  }
  *handled = api_->select_candidate_on_current_page(id, index) != 0;
  return *handled ? INKFLOW_STATUS_OK : INKFLOW_STATUS_BACKEND_ERROR;
}

InkFlowStatus RimeBackend::delete_candidate(RimeSessionId id,
                                            size_t index,
                                            bool* handled) {
  if (!initialized_ || handled == nullptr || !api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  const InkFlowStatus validation = validate_candidate_index(id, index);
  if (validation != INKFLOW_STATUS_OK) {
    return validation;
  }
  *handled = api_->delete_candidate_on_current_page(id, index) != 0;
  return INKFLOW_STATUS_OK;
}

InkFlowStatus RimeBackend::change_page(RimeSessionId id,
                                       bool backward,
                                       bool* handled) {
  if (!initialized_ || handled == nullptr || !api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  *handled = api_->change_page(id, backward ? True : False) != 0;
  return INKFLOW_STATUS_OK;
}

InkFlowStatus RimeBackend::snapshot(
    RimeSessionId id,
    bool handled,
    std::unique_ptr<InkFlowSnapshot>* out_snapshot) {
  if (!initialized_ || out_snapshot == nullptr || !api_->find_session(id)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  out_snapshot->reset();
  auto result = std::make_unique<InkFlowSnapshot>();
  result->handled = handled;

  RimeCommit commit{};
  RIME_STRUCT_INIT(RimeCommit, commit);
  if (api_->get_commit(id, &commit)) {
    CommitRelease release(api_, &commit);
    if (commit.text == nullptr) {
      return INKFLOW_STATUS_BACKEND_ERROR;
    }
    result->commit_text = commit.text;
    if (!release.release()) {
      return INKFLOW_STATUS_BACKEND_ERROR;
    }
  }

  RimeContext context{};
  RIME_STRUCT_INIT(RimeContext, context);
  if (!api_->get_context(id, &context)) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  ContextRelease release(api_, &context);

  if (context.composition.length < 0 || context.composition.cursor_pos < 0 ||
      context.composition.sel_start < 0 || context.composition.sel_end < 0 ||
      context.menu.num_candidates < 0 || context.menu.page_no < 0) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  if (context.composition.preedit != nullptr) {
    result->preedit = context.composition.preedit;
  } else if (context.composition.length != 0) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }

  result->cursor_byte_offset =
      static_cast<size_t>(context.composition.cursor_pos);
  result->selection_start_byte_offset =
      static_cast<size_t>(context.composition.sel_start);
  result->selection_end_byte_offset =
      static_cast<size_t>(context.composition.sel_end);
  if (result->cursor_byte_offset > result->preedit.size() ||
      result->selection_start_byte_offset > result->preedit.size() ||
      result->selection_end_byte_offset > result->preedit.size()) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }

  const size_t candidate_count =
      static_cast<size_t>(context.menu.num_candidates);
  if (candidate_count > 0 && context.menu.candidates == nullptr) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  result->candidates.reserve(candidate_count);
  for (size_t index = 0; index < candidate_count; ++index) {
    const RimeCandidate& candidate = context.menu.candidates[index];
    if (candidate.text == nullptr) {
      return INKFLOW_STATUS_BACKEND_ERROR;
    }
    InkFlowCandidate owned_candidate;
    owned_candidate.text = candidate.text;
    if (candidate.comment != nullptr) {
      owned_candidate.comment = candidate.comment;
    }
    result->candidates.push_back(std::move(owned_candidate));
  }

  if (candidate_count > 0) {
    if (context.menu.highlighted_candidate_index < 0 ||
        static_cast<size_t>(context.menu.highlighted_candidate_index) >=
            candidate_count) {
      return INKFLOW_STATUS_BACKEND_ERROR;
    }
    result->highlighted_candidate_index =
        static_cast<size_t>(context.menu.highlighted_candidate_index);
    result->has_previous_page = context.menu.page_no > 0;
    result->has_next_page = context.menu.is_last_page == False;
  }

  if (!release.release()) {
    return INKFLOW_STATUS_BACKEND_ERROR;
  }
  *out_snapshot = std::move(result);
  return INKFLOW_STATUS_OK;
}

}  // namespace inkflow
