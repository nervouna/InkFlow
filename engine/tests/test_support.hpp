#ifndef INKFLOW_ENGINE_TEST_SUPPORT_HPP_
#define INKFLOW_ENGINE_TEST_SUPPORT_HPP_

#include <inkflow/engine.h>

#include <filesystem>
#include <iostream>
#include <string>

namespace inkflow::test {

inline bool make_test_directories(const char* user_data_dir,
                                  const char* staging_data_dir) {
  std::error_code error;
  std::filesystem::create_directories(user_data_dir, error);
  if (error) {
    std::cerr << "Could not create user data directory: " << error.message()
              << '\n';
    return false;
  }
  std::filesystem::create_directories(staging_data_dir, error);
  if (error) {
    std::cerr << "Could not create staging data directory: " << error.message()
              << '\n';
    return false;
  }
  return true;
}

inline bool reset_test_directories(const char* user_data_dir,
                                   const char* staging_data_dir) {
  std::error_code error;
  std::filesystem::remove_all(user_data_dir, error);
  if (error) {
    std::cerr << "Could not reset user data directory: " << error.message()
              << '\n';
    return false;
  }
  std::filesystem::remove_all(staging_data_dir, error);
  if (error) {
    std::cerr << "Could not reset staging data directory: " << error.message()
              << '\n';
    return false;
  }
  return make_test_directories(user_data_dir, staging_data_dir);
}

inline InkFlowRuntimeConfig make_config(const char* shared_data_dir,
                                        const char* user_data_dir,
                                        const char* staging_data_dir,
                                        const char* application_name) {
  InkFlowRuntimeConfig config{};
  config.struct_size = sizeof(config);
  config.shared_data_dir = shared_data_dir;
  config.user_data_dir = user_data_dir;
  config.prebuilt_data_dir = shared_data_dir;
  config.staging_data_dir = staging_data_dir;
  config.distribution_name = "InkFlow Tests";
  config.distribution_code_name = "inkflow-tests";
  config.distribution_version = "1";
  config.application_name = application_name;
  config.minimum_log_level = 3;
  return config;
}

inline bool expect_status(const char* operation,
                          InkFlowStatus actual,
                          InkFlowStatus expected) {
  if (actual == expected) {
    return true;
  }
  std::cerr << operation << ": expected " << inkflow_status_message(expected)
            << ", got " << inkflow_status_message(actual) << '\n';
  return false;
}

inline bool type_text(InkFlowSession* session, const std::string& text) {
  for (unsigned char character : text) {
    InkFlowSnapshot* snapshot = nullptr;
    InkFlowKeyEvent event{character, INKFLOW_MODIFIER_NONE};
    if (!expect_status("process key",
                       inkflow_session_process_key(session, event, &snapshot),
                       INKFLOW_STATUS_OK) ||
        snapshot == nullptr || !inkflow_snapshot_handled(snapshot)) {
      inkflow_snapshot_destroy(snapshot);
      return false;
    }
    inkflow_snapshot_destroy(snapshot);
  }
  return true;
}

}  // namespace inkflow::test

#endif  // INKFLOW_ENGINE_TEST_SUPPORT_HPP_
