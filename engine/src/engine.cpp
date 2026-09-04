#include "engine_internal.hpp"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdlib>
#include <mutex>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace {

enum class RuntimePhase {
  kNeverInitialized,
  kRunning,
  kFinalized,
};

struct ProcessState {
  ~ProcessState() {
    if (runtime != nullptr && runtime->active) {
      runtime->backend.finalize();
      runtime->active = false;
    }
  }

  std::mutex mutex;
  RuntimePhase phase = RuntimePhase::kNeverInitialized;
  std::unique_ptr<InkFlowRuntime> runtime;
};

ProcessState& process_state() {
  static ProcessState state;
  return state;
}

bool has_text(const char* value) {
  return value != nullptr && value[0] != '\0';
}

bool is_valid_schema_id(const char* schema_id) {
  if (!has_text(schema_id)) {
    return false;
  }
  const std::string_view value(schema_id);
  if (value.size() >= 256) {
    return false;
  }
  return std::all_of(value.begin(), value.end(), [](unsigned char character) {
    return (character >= 'a' && character <= 'z') ||
           (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9') || character == '_' ||
           character == '-' || character == '.';
  });
}

InkFlowStatus validate_config(const InkFlowRuntimeConfig* config) {
  if (config == nullptr || config->struct_size < sizeof(*config) ||
      !has_text(config->shared_data_dir) ||
      !has_text(config->user_data_dir) ||
      !has_text(config->prebuilt_data_dir) ||
      !has_text(config->staging_data_dir) ||
      !has_text(config->distribution_name) ||
      !has_text(config->distribution_code_name) ||
      !has_text(config->distribution_version) ||
      !has_text(config->application_name) || config->minimum_log_level < 0 ||
      config->minimum_log_level > 3) {
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  const std::string_view application_name(config->application_name);
  if (application_name.size() <= 5 ||
      application_name.substr(0, 5) != "rime.") {
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  return INKFLOW_STATUS_OK;
}

bool is_directory(const char* path) {
  struct stat metadata {};
  return stat(path, &metadata) == 0 && S_ISDIR(metadata.st_mode);
}

InkFlowStatus create_directory_tree(const char* path) {
  if (is_directory(path)) {
    return INKFLOW_STATUS_OK;
  }
  if (errno != ENOENT) {
    return INKFLOW_STATUS_FILESYSTEM_ERROR;
  }

  const std::string input(path);
  std::string current;
  size_t cursor = 0;
  if (input.front() == '/') {
    current = "/";
    cursor = 1;
  }
  while (cursor <= input.size()) {
    const size_t separator = input.find('/', cursor);
    const size_t end = separator == std::string::npos ? input.size() : separator;
    const std::string component = input.substr(cursor, end - cursor);
    if (!component.empty()) {
      if (!current.empty() && current.back() != '/') {
        current.push_back('/');
      }
      current.append(component);
      if (mkdir(current.c_str(), 0700) != 0 && errno != EEXIST) {
        return INKFLOW_STATUS_FILESYSTEM_ERROR;
      }
      if (!is_directory(current.c_str())) {
        return INKFLOW_STATUS_FILESYSTEM_ERROR;
      }
    }
    if (separator == std::string::npos) {
      break;
    }
    cursor = separator + 1;
  }
  return INKFLOW_STATUS_OK;
}

bool canonical_path(const char* path, std::string* result) {
  char resolved[PATH_MAX];
  if (realpath(path, resolved) == nullptr) {
    return false;
  }
  *result = resolved;
  return true;
}

InkFlowStatus prepare_directories(const InkFlowRuntimeConfig& config) {
  if (!is_directory(config.shared_data_dir) ||
      access(config.shared_data_dir, R_OK | X_OK) != 0) {
    return INKFLOW_STATUS_FILESYSTEM_ERROR;
  }
  if (!is_directory(config.prebuilt_data_dir) ||
      access(config.prebuilt_data_dir, R_OK | X_OK) != 0) {
    return INKFLOW_STATUS_FILESYSTEM_ERROR;
  }
  InkFlowStatus status = create_directory_tree(config.user_data_dir);
  if (status != INKFLOW_STATUS_OK) {
    return INKFLOW_STATUS_FILESYSTEM_ERROR;
  }
  status = create_directory_tree(config.staging_data_dir);
  if (status != INKFLOW_STATUS_OK) {
    return INKFLOW_STATUS_FILESYSTEM_ERROR;
  }
  if (access(config.user_data_dir, W_OK | X_OK) != 0 ||
      access(config.staging_data_dir, W_OK | X_OK) != 0) {
    return INKFLOW_STATUS_FILESYSTEM_ERROR;
  }

  std::string shared;
  std::string prebuilt;
  std::string user;
  std::string staging;
  if (!canonical_path(config.shared_data_dir, &shared) ||
      !canonical_path(config.prebuilt_data_dir, &prebuilt) ||
      !canonical_path(config.user_data_dir, &user) ||
      !canonical_path(config.staging_data_dir, &staging)) {
    return INKFLOW_STATUS_FILESYSTEM_ERROR;
  }
  if (user == shared || user == prebuilt || staging == shared ||
      staging == prebuilt || user == staging) {
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  return INKFLOW_STATUS_OK;
}

void copy_config(const InkFlowRuntimeConfig& source, InkFlowRuntime* target) {
  target->shared_data_dir = source.shared_data_dir;
  target->user_data_dir = source.user_data_dir;
  target->prebuilt_data_dir = source.prebuilt_data_dir;
  target->staging_data_dir = source.staging_data_dir;
  target->distribution_name = source.distribution_name;
  target->distribution_code_name = source.distribution_code_name;
  target->distribution_version = source.distribution_version;
  target->application_name = source.application_name;
  target->minimum_log_level = source.minimum_log_level;
}

bool is_known_runtime(const ProcessState& state, const InkFlowRuntime* runtime) {
  return runtime != nullptr && state.runtime.get() == runtime;
}

bool is_known_session(const ProcessState& state,
                      const InkFlowSession* session) {
  if (session == nullptr || state.runtime == nullptr) {
    return false;
  }
  return std::any_of(
      state.runtime->sessions.begin(), state.runtime->sessions.end(),
      [session](const std::unique_ptr<InkFlowSession>& known) {
        return known.get() == session;
      });
}

bool has_open_sessions(const InkFlowRuntime& runtime) {
  return std::any_of(
      runtime.sessions.begin(), runtime.sessions.end(),
      [](const std::unique_ptr<InkFlowSession>& session) {
        return session->open;
      });
}

InkFlowStatus validate_open_session(const ProcessState& state,
                                    const InkFlowSession* session) {
  if (!is_known_session(state, session)) {
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  if (!session->open || state.phase != RuntimePhase::kRunning ||
      session->runtime != state.runtime.get() || !state.runtime->active) {
    return INKFLOW_STATUS_SESSION_CLOSED;
  }
  return INKFLOW_STATUS_OK;
}

template <typename Operation>
InkFlowStatus run_session_operation(InkFlowSession* session,
                                    InkFlowSnapshot** out_snapshot,
                                    Operation&& operation) {
  if (out_snapshot == nullptr) {
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  *out_snapshot = nullptr;
  return inkflow::protect([&] {
    ProcessState& state = process_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    const InkFlowStatus validation = validate_open_session(state, session);
    if (validation != INKFLOW_STATUS_OK) {
      return validation;
    }

    bool handled = false;
    const InkFlowStatus operation_status = operation(
        state.runtime->backend, session->backend_id, &handled);
    if (operation_status != INKFLOW_STATUS_OK) {
      return operation_status;
    }
    std::unique_ptr<InkFlowSnapshot> snapshot;
    const InkFlowStatus snapshot_status = state.runtime->backend.snapshot(
        session->backend_id, handled, &snapshot);
    if (snapshot_status != INKFLOW_STATUS_OK) {
      return snapshot_status;
    }
    *out_snapshot = snapshot.release();
    return INKFLOW_STATUS_OK;
  });
}

}  // namespace

extern "C" InkFlowStatus inkflow_runtime_create(
    const InkFlowRuntimeConfig* config,
    InkFlowRuntime** out_runtime) {
  if (out_runtime == nullptr) {
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  *out_runtime = nullptr;
  return inkflow::protect([&] {
    const InkFlowStatus config_status = validate_config(config);
    if (config_status != INKFLOW_STATUS_OK) {
      return config_status;
    }

    ProcessState& state = process_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.phase == RuntimePhase::kRunning) {
      return INKFLOW_STATUS_RUNTIME_ALREADY_EXISTS;
    }
    if (state.phase == RuntimePhase::kFinalized) {
      return INKFLOW_STATUS_RUNTIME_FINALIZED;
    }
    const InkFlowStatus directory_status = prepare_directories(*config);
    if (directory_status != INKFLOW_STATUS_OK) {
      return directory_status;
    }

    auto runtime = std::make_unique<InkFlowRuntime>();
    copy_config(*config, runtime.get());
    const InkFlowStatus backend_status = runtime->backend.initialize(*runtime);
    if (backend_status != INKFLOW_STATUS_OK) {
      return backend_status;
    }
    runtime->active = true;
    state.runtime = std::move(runtime);
    state.phase = RuntimePhase::kRunning;
    *out_runtime = state.runtime.get();
    return INKFLOW_STATUS_OK;
  });
}

extern "C" InkFlowStatus inkflow_runtime_destroy(InkFlowRuntime* runtime) {
  return inkflow::protect([&] {
    ProcessState& state = process_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!is_known_runtime(state, runtime)) {
      return INKFLOW_STATUS_INVALID_ARGUMENT;
    }
    if (state.phase == RuntimePhase::kFinalized || !runtime->active) {
      return INKFLOW_STATUS_RUNTIME_FINALIZED;
    }

    InkFlowStatus result = INKFLOW_STATUS_OK;
    for (const auto& session : runtime->sessions) {
      if (!session->open) {
        continue;
      }
      const InkFlowStatus status = inkflow::protect([&] {
        return runtime->backend.destroy_session(session->backend_id);
      });
      if (result == INKFLOW_STATUS_OK && status != INKFLOW_STATUS_OK) {
        result = status;
      }
      session->open = false;
      session->backend_id = 0;
    }
    runtime->backend.finalize();
    runtime->active = false;
    state.phase = RuntimePhase::kFinalized;
    return result;
  });
}

extern "C" InkFlowStatus inkflow_runtime_prepare(InkFlowRuntime* runtime) {
  return inkflow::protect([&] {
    ProcessState& state = process_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!is_known_runtime(state, runtime)) {
      return INKFLOW_STATUS_INVALID_ARGUMENT;
    }
    if (state.phase != RuntimePhase::kRunning || !runtime->active) {
      return INKFLOW_STATUS_RUNTIME_FINALIZED;
    }
    if (has_open_sessions(*runtime)) {
      return INKFLOW_STATUS_RUNTIME_IN_USE;
    }
    return runtime->backend.prepare(*runtime);
  });
}

extern "C" InkFlowStatus inkflow_session_create(InkFlowRuntime* runtime,
                                                 const char* schema_id,
                                                 InkFlowSession** out_session) {
  if (out_session == nullptr) {
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  *out_session = nullptr;
  return inkflow::protect([&] {
    ProcessState& state = process_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!is_known_runtime(state, runtime)) {
      return INKFLOW_STATUS_INVALID_ARGUMENT;
    }
    if (state.phase != RuntimePhase::kRunning || !runtime->active) {
      return INKFLOW_STATUS_RUNTIME_FINALIZED;
    }
    if (!is_valid_schema_id(schema_id)) {
      return INKFLOW_STATUS_INVALID_ARGUMENT;
    }

    auto session = std::make_unique<InkFlowSession>();
    InkFlowSession* session_handle = session.get();
    runtime->sessions.push_back(std::move(session));

    RimeSessionId backend_id = 0;
    const InkFlowStatus status =
        runtime->backend.create_session(schema_id, &backend_id);
    if (status != INKFLOW_STATUS_OK) {
      runtime->sessions.pop_back();
      return status;
    }
    session_handle->runtime = runtime;
    session_handle->backend_id = backend_id;
    session_handle->open = true;
    *out_session = session_handle;
    return INKFLOW_STATUS_OK;
  });
}

extern "C" InkFlowStatus inkflow_session_destroy(InkFlowSession* session) {
  return inkflow::protect([&] {
    ProcessState& state = process_state();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (!is_known_session(state, session)) {
      return INKFLOW_STATUS_INVALID_ARGUMENT;
    }
    if (!session->open || state.phase != RuntimePhase::kRunning) {
      return INKFLOW_STATUS_SESSION_CLOSED;
    }
    const InkFlowStatus status = inkflow::protect([&] {
      return state.runtime->backend.destroy_session(session->backend_id);
    });
    session->open = false;
    session->backend_id = 0;
    return status;
  });
}

extern "C" InkFlowStatus inkflow_session_process_key(
    InkFlowSession* session,
    InkFlowKeyEvent event,
    InkFlowSnapshot** out_snapshot) {
  if (out_snapshot == nullptr) {
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  *out_snapshot = nullptr;
  int backend_keycode = 0;
  int backend_modifiers = 0;
  const InkFlowStatus mapping_status =
      inkflow::map_key_event(event, &backend_keycode, &backend_modifiers);
  if (mapping_status != INKFLOW_STATUS_OK) {
    return mapping_status;
  }
  return run_session_operation(
      session, out_snapshot,
      [backend_keycode, backend_modifiers](inkflow::RimeBackend& backend,
                                           RimeSessionId id,
                                           bool* handled) {
        return backend.process_key(id, backend_keycode, backend_modifiers,
                                   handled);
      });
}

extern "C" InkFlowStatus inkflow_session_commit(
    InkFlowSession* session,
    InkFlowSnapshot** out_snapshot) {
  return run_session_operation(
      session, out_snapshot,
      [](inkflow::RimeBackend& backend, RimeSessionId id, bool* handled) {
        return backend.commit_composition(id, handled);
      });
}

extern "C" InkFlowStatus inkflow_session_select_candidate(
    InkFlowSession* session,
    size_t index_on_current_page,
    InkFlowSnapshot** out_snapshot) {
  return run_session_operation(
      session, out_snapshot,
      [index_on_current_page](inkflow::RimeBackend& backend, RimeSessionId id,
                              bool* handled) {
        return backend.select_candidate(id, index_on_current_page, handled);
      });
}

extern "C" InkFlowStatus inkflow_session_delete_candidate(
    InkFlowSession* session,
    size_t index_on_current_page,
    InkFlowSnapshot** out_snapshot) {
  return run_session_operation(
      session, out_snapshot,
      [index_on_current_page](inkflow::RimeBackend& backend, RimeSessionId id,
                              bool* handled) {
        return backend.delete_candidate(id, index_on_current_page, handled);
      });
}

extern "C" InkFlowStatus inkflow_session_change_page(
    InkFlowSession* session,
    int backward,
    InkFlowSnapshot** out_snapshot) {
  if (backward != 0 && backward != 1) {
    if (out_snapshot != nullptr) {
      *out_snapshot = nullptr;
    }
    return INKFLOW_STATUS_INVALID_ARGUMENT;
  }
  return run_session_operation(
      session, out_snapshot,
      [backward](inkflow::RimeBackend& backend, RimeSessionId id,
                 bool* handled) {
        return backend.change_page(id, backward != 0, handled);
      });
}

extern "C" InkFlowStatus inkflow_session_reset(
    InkFlowSession* session,
    InkFlowSnapshot** out_snapshot) {
  return run_session_operation(
      session, out_snapshot,
      [](inkflow::RimeBackend& backend, RimeSessionId id, bool* handled) {
        const InkFlowStatus status = backend.clear_composition(id);
        *handled = status == INKFLOW_STATUS_OK;
        return status;
      });
}

extern "C" InkFlowStatus inkflow_session_snapshot(
    InkFlowSession* session,
    InkFlowSnapshot** out_snapshot) {
  return run_session_operation(
      session, out_snapshot,
      [](inkflow::RimeBackend&, RimeSessionId, bool* handled) {
        *handled = false;
        return INKFLOW_STATUS_OK;
      });
}
