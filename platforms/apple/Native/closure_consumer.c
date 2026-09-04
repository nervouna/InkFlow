#include "engine.h"

int main(void) {
  return inkflow_engine_api_version() == INKFLOW_ENGINE_API_VERSION ? 0 : 1;
}
