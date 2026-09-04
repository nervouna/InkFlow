# Keep the project compatible with the Android SDK CMake pinned in
# toolchains.lock.json. Host presets may require a newer CMake to parse them.
cmake_minimum_required(VERSION 3.22.1)

project(
  InkFlow
  VERSION 0.1.0
  DESCRIPTION "Cross-platform Chinese input method"
  LANGUAGES C CXX
)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(InkFlowPaths)

include(CTest)

option(INKFLOW_BUILD_ENGINE "Build the shared InkFlow engine when present" ON)

if(INKFLOW_BUILD_ENGINE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/engine/CMakeLists.txt")
  add_subdirectory(engine)
elseif(INKFLOW_BUILD_ENGINE)
  message(STATUS "InkFlow engine is not present yet; configuring foundation only")
endif()
