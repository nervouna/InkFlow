#include <inkflow/engine.h>

extern "C" uint32_t inkflow_engine_api_version(void) {
  return INKFLOW_ENGINE_API_VERSION;
}

extern "C" const char* inkflow_status_message(InkFlowStatus status) {
  switch (status) {
    case INKFLOW_STATUS_OK:
      return "ok";
    case INKFLOW_STATUS_INVALID_ARGUMENT:
      return "invalid argument";
    case INKFLOW_STATUS_OUT_OF_MEMORY:
      return "out of memory";
    case INKFLOW_STATUS_RUNTIME_ALREADY_EXISTS:
      return "runtime already exists";
    case INKFLOW_STATUS_RUNTIME_FINALIZED:
      return "runtime finalized";
    case INKFLOW_STATUS_DEPLOYMENT_FAILED:
      return "Rime deployment failed";
    case INKFLOW_STATUS_BACKEND_UNAVAILABLE:
      return "Rime backend unavailable";
    case INKFLOW_STATUS_SESSION_CLOSED:
      return "session closed";
    case INKFLOW_STATUS_INVALID_CANDIDATE_INDEX:
      return "invalid candidate index";
    case INKFLOW_STATUS_UNSUPPORTED_KEY:
      return "unsupported key";
    case INKFLOW_STATUS_BACKEND_ERROR:
      return "Rime backend error";
    case INKFLOW_STATUS_FILESYSTEM_ERROR:
      return "filesystem error";
    case INKFLOW_STATUS_INTERNAL_ERROR:
      return "internal error";
    case INKFLOW_STATUS_RUNTIME_IN_USE:
      return "runtime in use";
  }
  return "unknown status";
}
