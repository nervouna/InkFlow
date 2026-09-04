include_guard(GLOBAL)

set(
  INKFLOW_SCHEMA_SOURCE_DIR
  "${PROJECT_SOURCE_DIR}/schemas/source"
  CACHE INTERNAL
  "Canonical editable InkFlow schema source"
)
set(
  INKFLOW_SCHEMA_TEST_DIR
  "${PROJECT_SOURCE_DIR}/schemas/test"
  CACHE INTERNAL
  "Deterministic InkFlow schema fixtures"
)
set(
  INKFLOW_TRANSCRIPT_DIR
  "${PROJECT_SOURCE_DIR}/testdata/transcripts"
  CACHE INTERNAL
  "Versioned deterministic engine transcripts"
)

foreach(required_directory IN ITEMS
    "${INKFLOW_SCHEMA_SOURCE_DIR}"
    "${INKFLOW_SCHEMA_TEST_DIR}"
    "${INKFLOW_TRANSCRIPT_DIR}")
  if(NOT IS_DIRECTORY "${required_directory}")
    message(FATAL_ERROR "Required InkFlow directory is missing: ${required_directory}")
  endif()
endforeach()
