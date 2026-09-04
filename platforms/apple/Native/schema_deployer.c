#include "inkflow/engine.h"

#include <stdio.h>

static int fail(InkFlowStatus status, const char* operation) {
  fprintf(stderr, "%s failed: %s (%d)\n", operation,
          inkflow_status_message(status), (int)status);
  return 1;
}

int main(int argc, char* argv[]) {
  if (argc != 5) {
    fprintf(stderr,
            "usage: %s <shared> <prebuilt> <user> <staging>\n",
            argv[0]);
    return 64;
  }

  InkFlowRuntimeConfig config = {
      .struct_size = sizeof(InkFlowRuntimeConfig),
      .shared_data_dir = argv[1],
      .user_data_dir = argv[3],
      .prebuilt_data_dir = argv[2],
      .staging_data_dir = argv[4],
      .distribution_name = "InkFlow",
      .distribution_code_name = "inkflow-apple-resource-builder",
      .distribution_version = "0.1.0",
      .application_name = "rime.inkflow.apple.resource-builder",
      .minimum_log_level = 3,
  };
  InkFlowRuntime* runtime = NULL;
  InkFlowStatus status = inkflow_runtime_create(&config, &runtime);
  if (status != INKFLOW_STATUS_OK) {
    return fail(status, "runtime creation");
  }
  status = inkflow_runtime_prepare(runtime);
  if (status != INKFLOW_STATUS_OK) {
    (void)inkflow_runtime_destroy(runtime);
    return fail(status, "schema deployment");
  }
  status = inkflow_runtime_destroy(runtime);
  return status == INKFLOW_STATUS_OK ? 0 : fail(status, "runtime shutdown");
}
