set(INKFLOW_ENGINE_BACKEND "rime" CACHE STRING "Production engine backend")
option(INKFLOW_ENABLE_SANITIZERS
       "Instrument InkFlow engine and test code with ASan and UBSan" OFF)
set_property(CACHE INKFLOW_ENGINE_BACKEND PROPERTY STRINGS rime)
if(NOT INKFLOW_ENGINE_BACKEND STREQUAL "rime")
  message(FATAL_ERROR
    "Unsupported InkFlow production backend '${INKFLOW_ENGINE_BACKEND}'. "
    "Fake backends are intentionally unavailable to production targets."
  )
endif()

# This version and digest are copied from librime 1.17.0's install-boost.sh.
# Keeping the source under ignored build output avoids modifying the submodule.
set(
  INKFLOW_DEPENDENCY_CACHE_DIR
  "${PROJECT_SOURCE_DIR}/build/dependencies"
  CACHE PATH "Shared cache for pinned InkFlow build dependencies"
)
include(FetchContent)

function(inkflow_prepare_boost output_variable)
  set(INKFLOW_BOOST_VERSION "1.89.0")
  set(INKFLOW_BOOST_SHA256
      "9de758db755e8330a01d995b0a24d09798048400ac25c03fc5ea9be364b13c93")
  set(INKFLOW_BOOST_CACHE_KEY
      "boost-${INKFLOW_BOOST_VERSION}-${INKFLOW_BOOST_SHA256}")
  set(INKFLOW_BOOST_SOURCE_DIR
      "${INKFLOW_DEPENDENCY_CACHE_DIR}/sources/${INKFLOW_BOOST_CACHE_KEY}")
  set(INKFLOW_BOOST_READY_FILE
      "${INKFLOW_DEPENDENCY_CACHE_DIR}/ready/${INKFLOW_BOOST_CACHE_KEY}.sha256")

  # FetchContent's population sub-build embeds its generator in CMakeCache.txt.
  # A lock gives the shared, content-addressed archive/source one population
  # owner. Once its ready marker is published, other generators only read the
  # immutable source and never run a second extractor over an active build.
  file(MAKE_DIRECTORY
       "${INKFLOW_DEPENDENCY_CACHE_DIR}/locks"
       "${INKFLOW_DEPENDENCY_CACHE_DIR}/ready")
  file(
    LOCK "${INKFLOW_DEPENDENCY_CACHE_DIR}/locks/${INKFLOW_BOOST_CACHE_KEY}.lock"
    GUARD FUNCTION
    RESULT_VARIABLE INKFLOW_BOOST_LOCK_RESULT
    TIMEOUT 600
  )
  if(NOT INKFLOW_BOOST_LOCK_RESULT STREQUAL "0")
    message(FATAL_ERROR
      "Could not lock the pinned Boost cache: ${INKFLOW_BOOST_LOCK_RESULT}")
  endif()

  set(INKFLOW_BOOST_READY FALSE)
  if(EXISTS "${INKFLOW_BOOST_READY_FILE}")
    file(READ "${INKFLOW_BOOST_READY_FILE}" INKFLOW_BOOST_READY_SHA256)
    string(STRIP
           "${INKFLOW_BOOST_READY_SHA256}"
           INKFLOW_BOOST_READY_SHA256)
    if(NOT INKFLOW_BOOST_READY_SHA256 STREQUAL INKFLOW_BOOST_SHA256)
      message(FATAL_ERROR
        "Pinned Boost cache marker has an unexpected digest: "
        "${INKFLOW_BOOST_READY_FILE}")
    endif()
    if(NOT EXISTS "${INKFLOW_BOOST_SOURCE_DIR}/boost/version.hpp" OR
       NOT EXISTS "${INKFLOW_BOOST_SOURCE_DIR}/boost/regex.hpp")
      message(FATAL_ERROR
        "Pinned Boost cache is incomplete: ${INKFLOW_BOOST_SOURCE_DIR}")
    endif()
    set(INKFLOW_BOOST_READY TRUE)
  endif()

  if(NOT INKFLOW_BOOST_READY)
    string(SHA256
           INKFLOW_MAKE_PROGRAM_ID
           "${CMAKE_MAKE_PROGRAM}")
    set(INKFLOW_FETCHCONTENT_GENERATOR_ID
        "${INKFLOW_BOOST_CACHE_KEY}-${CMAKE_GENERATOR}-${CMAKE_GENERATOR_PLATFORM}-${CMAKE_GENERATOR_TOOLSET}-cmake-${CMAKE_VERSION}-make-${INKFLOW_MAKE_PROGRAM_ID}")
    string(MAKE_C_IDENTIFIER
           "${INKFLOW_FETCHCONTENT_GENERATOR_ID}"
           INKFLOW_FETCHCONTENT_GENERATOR_ID)
    string(TOLOWER
           "${INKFLOW_FETCHCONTENT_GENERATOR_ID}"
           INKFLOW_FETCHCONTENT_GENERATOR_ID)
    set(INKFLOW_BOOST_POPULATION_DIR
        "${INKFLOW_DEPENDENCY_CACHE_DIR}/subbuilds/${INKFLOW_FETCHCONTENT_GENERATOR_ID}")

    set(INKFLOW_BOOST_DOWNLOAD_OPTIONS)
    if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.24)
      list(APPEND INKFLOW_BOOST_DOWNLOAD_OPTIONS
           DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    endif()
    # This isolated form accepts an explicit sub-build directory and cannot be
    # redirected by a stale FETCHCONTENT_SOURCE_DIR_INKFLOW_BOOST cache entry.
    FetchContent_Populate(
      inkflow_boost
      SUBBUILD_DIR "${INKFLOW_BOOST_POPULATION_DIR}/inkflow_boost-subbuild"
      BINARY_DIR "${INKFLOW_BOOST_POPULATION_DIR}/inkflow_boost-build"
      URL
        "https://archives.boost.io/release/1.89.0/source/boost_1_89_0.tar.gz"
      URL_HASH "SHA256=${INKFLOW_BOOST_SHA256}"
      DOWNLOAD_DIR
        "${INKFLOW_DEPENDENCY_CACHE_DIR}/downloads/${INKFLOW_BOOST_CACHE_KEY}"
      SOURCE_DIR "${INKFLOW_BOOST_SOURCE_DIR}"
      ${INKFLOW_BOOST_DOWNLOAD_OPTIONS}
    )

    file(STRINGS
         "${INKFLOW_BOOST_SOURCE_DIR}/boost/version.hpp"
         INKFLOW_BOOST_VERSION_DEFINITION
         REGEX "^#define BOOST_VERSION 108900$")
    if(NOT EXISTS "${INKFLOW_BOOST_SOURCE_DIR}/boost/regex.hpp" OR
       NOT INKFLOW_BOOST_VERSION_DEFINITION)
      message(FATAL_ERROR
        "Pinned Boost population is incomplete: ${INKFLOW_BOOST_SOURCE_DIR}")
    endif()

    file(WRITE
         "${INKFLOW_BOOST_READY_FILE}.tmp"
         "${INKFLOW_BOOST_SHA256}\n")
    file(RENAME
         "${INKFLOW_BOOST_READY_FILE}.tmp"
         "${INKFLOW_BOOST_READY_FILE}")
  endif()

  set(${output_variable} "${INKFLOW_BOOST_SOURCE_DIR}" PARENT_SCOPE)
endfunction()

inkflow_prepare_boost(INKFLOW_BOOST_SOURCE_DIR)

set(INKFLOW_LIBRIME_DIR "${PROJECT_SOURCE_DIR}/third_party/librime")
foreach(required_path IN ITEMS
    "${INKFLOW_LIBRIME_DIR}/src/rime_api.h"
    "${INKFLOW_LIBRIME_DIR}/deps/yaml-cpp/CMakeLists.txt"
    "${INKFLOW_LIBRIME_DIR}/deps/leveldb/CMakeLists.txt"
    "${INKFLOW_LIBRIME_DIR}/deps/marisa-trie/CMakeLists.txt"
    "${INKFLOW_LIBRIME_DIR}/deps/opencc/CMakeLists.txt")
  if(NOT EXISTS "${required_path}")
    message(FATAL_ERROR
      "Pinned recursive librime sources are incomplete: ${required_path}")
  endif()
endforeach()

# Build librime's pinned recursive dependencies from source. The cache values
# suppress dependency tests, tools, shared libraries, and generated data.
set(INKFLOW_SAVED_BUILD_TESTING "${BUILD_TESTING}")
set(BUILD_TESTING OFF)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build only static native libraries" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# All bundled implementation symbols are private when the static closure is
# embedded in a platform library. engine.h explicitly restores default
# visibility for InkFlow's documented C entry points.
set(CMAKE_C_VISIBILITY_PRESET hidden)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

set(YAML_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_BUILD_CONTRIB OFF CACHE BOOL "" FORCE)
set(YAML_CPP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(YAML_CPP_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(
  "${INKFLOW_LIBRIME_DIR}/deps/yaml-cpp"
  "${CMAKE_CURRENT_BINARY_DIR}/third-party/yaml-cpp"
  EXCLUDE_FROM_ALL
)

set(LEVELDB_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(LEVELDB_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LEVELDB_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(
  "${INKFLOW_LIBRIME_DIR}/deps/leveldb"
  "${CMAKE_CURRENT_BINARY_DIR}/third-party/leveldb"
  EXCLUDE_FROM_ALL
)
# LevelDB publishes `-Werror` as a public usage requirement. Upstream librime
# normally consumes an installed LevelDB and therefore does not inherit those
# build diagnostics. Remove the warning-as-error flag from both the bundled
# target and its consumers so a newer platform SDK cannot turn an upstream
# warning (for example Xcode's 64-to-32 conversion warning) into a product
# build failure. Keep LevelDB's thread-safety analysis enabled for its sources.
get_target_property(INKFLOW_LEVELDB_COMPILE_OPTIONS leveldb COMPILE_OPTIONS)
if(INKFLOW_LEVELDB_COMPILE_OPTIONS)
  list(REMOVE_ITEM INKFLOW_LEVELDB_COMPILE_OPTIONS -Werror)
  set_property(
    TARGET leveldb PROPERTY COMPILE_OPTIONS
    "${INKFLOW_LEVELDB_COMPILE_OPTIONS}"
  )
endif()
set_property(TARGET leveldb PROPERTY INTERFACE_COMPILE_OPTIONS "")
unset(INKFLOW_LEVELDB_COMPILE_OPTIONS)

set(ENABLE_NATIVE_CODE OFF CACHE BOOL "" FORCE)
set(ENABLE_TOOLS OFF CACHE BOOL "" FORCE)
set(ENABLE_ASAN OFF CACHE BOOL "" FORCE)
set(ENABLE_UBSAN OFF CACHE BOOL "" FORCE)
add_subdirectory(
  "${INKFLOW_LIBRIME_DIR}/deps/marisa-trie"
  "${CMAKE_CURRENT_BINARY_DIR}/third-party/marisa"
  EXCLUDE_FROM_ALL
)

set(BUILD_DOCUMENTATION OFF CACHE BOOL "" FORCE)
set(ENABLE_GTEST OFF CACHE BOOL "" FORCE)
set(ENABLE_BENCHMARK OFF CACHE BOOL "" FORCE)
set(BUILD_PYTHON OFF CACHE BOOL "" FORCE)
set(USE_SYSTEM_MARISA ON CACHE BOOL "" FORCE)
set(LIBMARISA marisa CACHE STRING "Bundled marisa target" FORCE)
# OpenCC unconditionally declares host command-line tools. On iOS, CMake's
# bundle default turns those unused tools into app bundles whose upstream
# install rules lack a BUNDLE destination. Keep the override scoped to OpenCC;
# product targets retain the caller's original bundle policy.
if(DEFINED CMAKE_MACOSX_BUNDLE)
  set(INKFLOW_CMAKE_MACOSX_BUNDLE_WAS_DEFINED TRUE)
  set(INKFLOW_SAVED_CMAKE_MACOSX_BUNDLE "${CMAKE_MACOSX_BUNDLE}")
else()
  set(INKFLOW_CMAKE_MACOSX_BUNDLE_WAS_DEFINED FALSE)
endif()
set(CMAKE_MACOSX_BUNDLE OFF)
add_subdirectory(
  "${INKFLOW_LIBRIME_DIR}/deps/opencc"
  "${CMAKE_CURRENT_BINARY_DIR}/third-party/opencc"
  EXCLUDE_FROM_ALL
)
if(INKFLOW_CMAKE_MACOSX_BUNDLE_WAS_DEFINED)
  set(CMAKE_MACOSX_BUNDLE "${INKFLOW_SAVED_CMAKE_MACOSX_BUNDLE}")
else()
  unset(CMAKE_MACOSX_BUNDLE)
endif()
unset(INKFLOW_CMAKE_MACOSX_BUNDLE_WAS_DEFINED)
unset(INKFLOW_SAVED_CMAKE_MACOSX_BUNDLE)
set(INKFLOW_OPENCC_INCLUDE_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/third-party/opencc-include")
file(MAKE_DIRECTORY "${INKFLOW_OPENCC_INCLUDE_DIR}/opencc")
file(GLOB INKFLOW_OPENCC_PUBLIC_HEADERS CONFIGURE_DEPENDS
     "${INKFLOW_LIBRIME_DIR}/deps/opencc/src/*.h"
     "${INKFLOW_LIBRIME_DIR}/deps/opencc/src/*.hpp")
file(COPY ${INKFLOW_OPENCC_PUBLIC_HEADERS}
     DESTINATION "${INKFLOW_OPENCC_INCLUDE_DIR}/opencc")
configure_file(
  "${CMAKE_CURRENT_BINARY_DIR}/third-party/opencc/src/opencc_config.h"
  "${INKFLOW_OPENCC_INCLUDE_DIR}/opencc/opencc_config.h"
  COPYONLY
)

set(BUILD_TESTING "${INKFLOW_SAVED_BUILD_TESTING}")
set(BUILD_MERGED_PLUGINS ON CACHE BOOL "" FORCE)
set(BUILD_DATA OFF CACHE BOOL "" FORCE)
set(BUILD_SAMPLE OFF CACHE BOOL "" FORCE)
set(BUILD_TEST OFF CACHE BOOL "" FORCE)
set(BUILD_SEPARATE_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_STATIC ON CACHE BOOL "" FORCE)
set(ENABLE_LOGGING OFF CACHE BOOL "" FORCE)
set(ENABLE_EXTERNAL_PLUGINS OFF CACHE BOOL "" FORCE)
set(ENABLE_THREADING ON CACHE BOOL "" FORCE)
set(ENABLE_TIMESTAMP OFF CACHE BOOL "" FORCE)

# Satisfy librime's upstream Find modules with targets built above. These are
# target names rather than local install paths, keeping the product portable.
set(YamlCpp_INCLUDE_PATH "${INKFLOW_LIBRIME_DIR}/deps/yaml-cpp/include")
set(YamlCpp_NEW_API "${INKFLOW_LIBRIME_DIR}/deps/yaml-cpp/include")
set(YamlCpp_LIBRARY yaml-cpp)
set(LevelDb_INCLUDE_PATH "${INKFLOW_LIBRIME_DIR}/deps/leveldb/include")
set(LevelDb_LIBRARY leveldb)
set(Marisa_INCLUDE_PATH "${INKFLOW_LIBRIME_DIR}/deps/marisa-trie/include")
set(Marisa_LIBRARY marisa)
set(Opencc_INCLUDE_PATH "${INKFLOW_OPENCC_INCLUDE_DIR}")
set(Opencc_LIBRARY libopencc)
set(X11Keysym "${INKFLOW_LIBRIME_DIR}/include")

add_subdirectory(
  "${INKFLOW_LIBRIME_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}/third-party/librime"
  EXCLUDE_FROM_ALL
)

set(
  INKFLOW_ENGINE_SOURCES
  src/engine.cpp
  src/error.cpp
  src/key_mapping.cpp
  src/librime_backend.cpp
  src/snapshot.cpp
)

add_library(inkflow_engine STATIC ${INKFLOW_ENGINE_SOURCES})
add_library(InkFlow::Engine ALIAS inkflow_engine)

function(inkflow_configure_engine_library target)
  target_compile_features(${target} PUBLIC c_std_11 PRIVATE cxx_std_17)
  target_compile_definitions(${target} PRIVATE INKFLOW_ENGINE_BUILDING)
  target_include_directories(
    ${target}
    PUBLIC
      "$<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>"
    PRIVATE
      "${CMAKE_CURRENT_SOURCE_DIR}/src"
      "${INKFLOW_LIBRIME_DIR}/src"
  )
  target_link_libraries(${target} PRIVATE rime-static)
  set_target_properties(
    ${target}
    PROPERTIES
      C_EXTENSIONS NO
      C_VISIBILITY_PRESET hidden
      CXX_EXTENSIONS NO
      CXX_VISIBILITY_PRESET hidden
      VISIBILITY_INLINES_HIDDEN YES
  )
  if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    target_compile_options(
      ${target}
      PRIVATE -Wall -Wextra -Wpedantic -Werror
    )
  endif()
endfunction()

inkflow_configure_engine_library(inkflow_engine)

set(
  INKFLOW_ENGINE_SYMBOL_MANIFEST
  "${CMAKE_CURRENT_SOURCE_DIR}/exports/inkflow_engine.symbols"
)
set_property(
  DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${INKFLOW_ENGINE_SYMBOL_MANIFEST}"
)
file(STRINGS
     "${INKFLOW_ENGINE_SYMBOL_MANIFEST}"
     INKFLOW_ENGINE_PUBLIC_SYMBOLS)
list(FILTER INKFLOW_ENGINE_PUBLIC_SYMBOLS EXCLUDE REGEX "^[ \\t]*$")
list(LENGTH INKFLOW_ENGINE_PUBLIC_SYMBOLS INKFLOW_ENGINE_PUBLIC_SYMBOL_COUNT)
if(NOT INKFLOW_ENGINE_PUBLIC_SYMBOL_COUNT EQUAL 27)
  message(FATAL_ERROR
    "The InkFlow export manifest must contain exactly 27 C symbols")
endif()
foreach(symbol IN LISTS INKFLOW_ENGINE_PUBLIC_SYMBOLS)
  if(NOT symbol MATCHES "^inkflow_[a-z0-9_]+$")
    message(FATAL_ERROR "Invalid InkFlow export manifest entry: ${symbol}")
  endif()
endforeach()
set_property(
  GLOBAL PROPERTY INKFLOW_ENGINE_PUBLIC_SYMBOLS
  "${INKFLOW_ENGINE_PUBLIC_SYMBOLS}"
)

# Apply this to every final shared library that statically embeds InkFlow.
# Optional extra arguments allow a platform adapter to retain its own required
# entry points (for example JNI_OnLoad) without exposing librime or its deps.
function(inkflow_apply_engine_export_boundary target)
  if(NOT TARGET ${target})
    message(FATAL_ERROR "Unknown InkFlow shared-library target: ${target}")
  endif()
  get_target_property(INKFLOW_EXPORT_TARGET_TYPE ${target} TYPE)
  if(NOT INKFLOW_EXPORT_TARGET_TYPE MATCHES "^(MODULE|SHARED)_LIBRARY$")
    message(FATAL_ERROR
      "InkFlow export boundaries apply only to module or shared libraries")
  endif()

  get_property(
    INKFLOW_BOUNDARY_SYMBOLS
    GLOBAL PROPERTY INKFLOW_ENGINE_PUBLIC_SYMBOLS
  )
  list(APPEND INKFLOW_BOUNDARY_SYMBOLS ${ARGN})
  list(REMOVE_DUPLICATES INKFLOW_BOUNDARY_SYMBOLS)
  foreach(symbol IN LISTS INKFLOW_BOUNDARY_SYMBOLS)
    if(NOT symbol MATCHES "^[A-Za-z_][A-Za-z0-9_]*$")
      message(FATAL_ERROR "Invalid shared-library export: ${symbol}")
    endif()
  endforeach()

  # Xcode does not honor LINK_DEPENDS. Compile a tiny generated revision into
  # each boundary target so a manifest change also forces its final relink.
  string(JOIN ";" INKFLOW_BOUNDARY_REVISION_INPUT
         ${INKFLOW_BOUNDARY_SYMBOLS})
  string(SHA256
         INKFLOW_BOUNDARY_REVISION
         "${INKFLOW_BOUNDARY_REVISION_INPUT}")
  set(
    INKFLOW_BOUNDARY_ANCHOR
    "${CMAKE_CURRENT_BINARY_DIR}/${target}-export-boundary.c"
  )
  file(GENERATE
       OUTPUT "${INKFLOW_BOUNDARY_ANCHOR}"
       CONTENT
         "const char inkflow_export_boundary_revision_${INKFLOW_BOUNDARY_REVISION} = 0;\n")
  target_sources(${target} PRIVATE "${INKFLOW_BOUNDARY_ANCHOR}")

  if(APPLE)
    set(INKFLOW_BOUNDARY_CONTENT "")
    foreach(symbol IN LISTS INKFLOW_BOUNDARY_SYMBOLS)
      string(APPEND INKFLOW_BOUNDARY_CONTENT "_${symbol}\n")
    endforeach()
    set(
      INKFLOW_BOUNDARY_FILE
      "${CMAKE_CURRENT_BINARY_DIR}/${target}-exports.txt"
    )
    file(GENERATE
         OUTPUT "${INKFLOW_BOUNDARY_FILE}"
         CONTENT "${INKFLOW_BOUNDARY_CONTENT}")
    target_link_options(
      ${target}
      PRIVATE "LINKER:-exported_symbols_list,${INKFLOW_BOUNDARY_FILE}"
    )
    set_property(
      TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${INKFLOW_BOUNDARY_FILE}"
    )
  elseif(UNIX)
    set(INKFLOW_BOUNDARY_CONTENT "{\n  global:\n")
    foreach(symbol IN LISTS INKFLOW_BOUNDARY_SYMBOLS)
      string(APPEND INKFLOW_BOUNDARY_CONTENT "    ${symbol};\n")
    endforeach()
    string(APPEND INKFLOW_BOUNDARY_CONTENT "  local:\n    *;\n};\n")
    set(
      INKFLOW_BOUNDARY_FILE
      "${CMAKE_CURRENT_BINARY_DIR}/${target}-exports.map"
    )
    file(GENERATE
         OUTPUT "${INKFLOW_BOUNDARY_FILE}"
         CONTENT "${INKFLOW_BOUNDARY_CONTENT}")
    target_link_options(
      ${target}
      PRIVATE
        "LINKER:--version-script,${INKFLOW_BOUNDARY_FILE}"
        "LINKER:--no-undefined-version"
        "LINKER:--no-undefined"
    )
    set_property(
      TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${INKFLOW_BOUNDARY_FILE}"
    )
  else()
    message(FATAL_ERROR
      "InkFlow shared-library export boundaries are not implemented for "
      "${CMAKE_SYSTEM_NAME}")
  endif()
endfunction()

# This shared probe links the same sources and complete native dependency
# closure as a platform library. It is excluded from normal product builds and
# exists so release verification can audit the final dynamic export boundary.
add_library(
  inkflow_engine_link_closure
  SHARED EXCLUDE_FROM_ALL
  ${INKFLOW_ENGINE_SOURCES}
)
inkflow_configure_engine_library(inkflow_engine_link_closure)
inkflow_apply_engine_export_boundary(inkflow_engine_link_closure)

function(inkflow_enable_sanitizers target)
  if(NOT INKFLOW_ENABLE_SANITIZERS)
    return()
  endif()
  if(NOT CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    message(FATAL_ERROR
      "INKFLOW_ENABLE_SANITIZERS requires AppleClang, Clang, or GNU")
  endif()
  target_compile_options(
    ${target}
    PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer
  )
  get_target_property(INKFLOW_SANITIZER_TARGET_TYPE ${target} TYPE)
  if(INKFLOW_SANITIZER_TARGET_TYPE STREQUAL "EXECUTABLE")
    target_link_options(${target} PRIVATE -fsanitize=address,undefined)
  endif()
endfunction()

inkflow_enable_sanitizers(inkflow_engine)

if(BUILD_TESTING)
  set(INKFLOW_ENGINE_TEST_DATA_DIR "${CMAKE_CURRENT_BINARY_DIR}/test-data")
  file(MAKE_DIRECTORY "${INKFLOW_ENGINE_TEST_DATA_DIR}")

  function(inkflow_configure_engine_test target)
    target_link_libraries(${target} PRIVATE InkFlow::Engine)
    target_compile_features(${target} PRIVATE cxx_std_17)
    target_compile_definitions(
      ${target}
      PRIVATE
        INKFLOW_TEST_SHARED_DATA_DIR="${INKFLOW_SCHEMA_TEST_DIR}"
    )
    if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
      target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    inkflow_enable_sanitizers(${target})
  endfunction()

  add_executable(inkflow_engine_contract_test tests/engine_contract_test.c)
  inkflow_configure_engine_test(inkflow_engine_contract_test)
  set_target_properties(
    inkflow_engine_contract_test
    PROPERTIES
      C_EXTENSIONS NO
      C_STANDARD 11
      C_STANDARD_REQUIRED YES
  )
  target_compile_definitions(
    inkflow_engine_contract_test
    PRIVATE
      INKFLOW_TEST_C_USER_DATA_DIR="${INKFLOW_ENGINE_TEST_DATA_DIR}/c/user"
      INKFLOW_TEST_C_STAGING_DATA_DIR="${INKFLOW_ENGINE_TEST_DATA_DIR}/c/staging"
  )
  add_test(NAME inkflow_engine_contract COMMAND inkflow_engine_contract_test)

  add_executable(inkflow_engine_lifecycle_test tests/lifecycle_test.cpp)
  inkflow_configure_engine_test(inkflow_engine_lifecycle_test)
  target_compile_definitions(
    inkflow_engine_lifecycle_test
    PRIVATE
      INKFLOW_TEST_CPP_USER_DATA_DIR="${INKFLOW_ENGINE_TEST_DATA_DIR}/cpp/user"
      INKFLOW_TEST_CPP_STAGING_DATA_DIR="${INKFLOW_ENGINE_TEST_DATA_DIR}/cpp/staging"
  )
  add_test(NAME inkflow_engine_lifecycle COMMAND inkflow_engine_lifecycle_test)

  add_executable(inkflow_engine_transcript_test tests/transcript_test.cpp)
  inkflow_configure_engine_test(inkflow_engine_transcript_test)
  target_include_directories(
    inkflow_engine_transcript_test
    SYSTEM PRIVATE "${INKFLOW_LIBRIME_DIR}/deps/opencc/deps/rapidjson-1.1.0"
  )
  if(INKFLOW_ENABLE_SANITIZERS)
    # RapidJSON 1.1 performs intentional null-base pointer arithmetic that
    # trips current UBSan. Keep ASan on the transcript harness while the
    # separately compiled InkFlow engine remains instrumented by both.
    target_compile_options(
      inkflow_engine_transcript_test PRIVATE -fno-sanitize=undefined
    )
  endif()
  target_compile_definitions(
    inkflow_engine_transcript_test
    PRIVATE
      INKFLOW_TEST_TRANSCRIPT_PATH="${INKFLOW_TRANSCRIPT_DIR}/nihao.v1.json"
      INKFLOW_TEST_TRANSCRIPT_USER_DATA_DIR="${INKFLOW_ENGINE_TEST_DATA_DIR}/transcript/user"
      INKFLOW_TEST_TRANSCRIPT_STAGING_DATA_DIR="${INKFLOW_ENGINE_TEST_DATA_DIR}/transcript/staging"
  )
  add_test(NAME inkflow_engine_transcript COMMAND inkflow_engine_transcript_test)

  add_test(
    NAME inkflow_engine_rejects_fake_backend
    COMMAND
      "${CMAKE_COMMAND}"
      "-DINKFLOW_TEST_CMAKE_COMMAND=${CMAKE_COMMAND}"
      "-DINKFLOW_TEST_SOURCE_DIR=${PROJECT_SOURCE_DIR}"
      "-DINKFLOW_TEST_BINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}/negative-fake-backend"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/tests/reject_fake_backend.cmake"
  )
endif()
