if(NOT DEFINED INKFLOW_TEST_CMAKE_COMMAND OR
   NOT DEFINED INKFLOW_TEST_SOURCE_DIR OR
   NOT DEFINED INKFLOW_TEST_BINARY_DIR)
  message(FATAL_ERROR "fake-backend test inputs are missing")
endif()

execute_process(
  COMMAND
    "${INKFLOW_TEST_CMAKE_COMMAND}"
    -S "${INKFLOW_TEST_SOURCE_DIR}"
    -B "${INKFLOW_TEST_BINARY_DIR}"
    -DBUILD_TESTING=OFF
    -DINKFLOW_ENGINE_BACKEND=fake
  RESULT_VARIABLE INKFLOW_FAKE_RESULT
  OUTPUT_VARIABLE INKFLOW_FAKE_OUTPUT
  ERROR_VARIABLE INKFLOW_FAKE_ERROR
)

if(INKFLOW_FAKE_RESULT EQUAL 0)
  message(FATAL_ERROR "configuration unexpectedly accepted a fake backend")
endif()

set(INKFLOW_FAKE_LOG "${INKFLOW_FAKE_OUTPUT}\n${INKFLOW_FAKE_ERROR}")
if(NOT INKFLOW_FAKE_LOG MATCHES
   "intentionally unavailable to production targets")
  message(FATAL_ERROR
    "configuration failed for an unexpected reason:\n${INKFLOW_FAKE_LOG}")
endif()

message(STATUS "Fake production backend was rejected by the expected gate")
