# Keep the project compatible with the Android SDK CMake pinned in
# toolchains.lock.json. Host presets may require a newer CMake to parse them.
cmake_minimum_required(VERSION 3.22.1)

project(
  InkFlow
  VERSION 0.1.0
  DESCRIPTION "Cross-platform Chinese input method"
  LANGUAGES C CXX
)

if(ANDROID)
  if(NOT CMAKE_C_COMPILER_ID STREQUAL "Clang" OR
     NOT CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    message(FATAL_ERROR "Android native builds require Clang prefix-map support")
  endif()

  # This directory property is intentionally established before the engine and
  # its pinned third-party closure create any targets. It keeps __FILE__ and
  # debug metadata independent of the developer's checkout location.
  set(
    INKFLOW_ANDROID_PREFIX_MAPS
    "${PROJECT_SOURCE_DIR}=inkflow/source"
    "${CMAKE_ANDROID_NDK}=android/ndk"
  )
  foreach(inkflow_android_prefix_map IN LISTS INKFLOW_ANDROID_PREFIX_MAPS)
    add_compile_options(
      "-ffile-prefix-map=${inkflow_android_prefix_map}"
      "-fmacro-prefix-map=${inkflow_android_prefix_map}"
      "-fdebug-prefix-map=${inkflow_android_prefix_map}"
    )
  endforeach()
endif()

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(InkFlowPaths)

include(CTest)

option(INKFLOW_BUILD_ENGINE "Build the shared InkFlow engine when present" ON)

if(INKFLOW_BUILD_ENGINE AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/engine/CMakeLists.txt")
  add_subdirectory(engine)
elseif(INKFLOW_BUILD_ENGINE)
  message(STATUS "InkFlow engine is not present yet; configuring foundation only")
endif()

if(ANDROID)
  if(NOT TARGET InkFlow::Engine)
    message(FATAL_ERROR "The Android JNI library requires InkFlow::Engine")
  endif()
  add_subdirectory(platforms/android/app/src/main/cpp)
endif()
