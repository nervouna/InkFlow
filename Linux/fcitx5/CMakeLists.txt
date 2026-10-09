cmake_minimum_required(VERSION 3.20)
project(inkflow-fcitx5 VERSION 0.1.0 LANGUAGES C CXX)
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  message(FATAL_ERROR "The Fcitx5 addon builds on Linux only")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)

find_package(Fcitx5Core REQUIRED)
# Package staging uses relative paths regardless of the host Fcitx installation.
set(INKFLOW_ADDONDIR "${FCITX_INSTALL_ADDONDIR}" CACHE STRING "Fcitx addon install directory")
set(INKFLOW_PKGDATADIR "${FCITX_INSTALL_PKGDATADIR}" CACHE STRING "Fcitx data install directory")

# The Rust engine is built first: cargo build --release in Core/Portable (see README).
get_filename_component(INKFLOW_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
set(INKFLOW_CARGO_DIR "${INKFLOW_ROOT}/build/portable/cargo/release" CACHE PATH "Cargo release output of Core/Portable")
set(INKFLOW_NATIVE_PREFIX "${INKFLOW_ROOT}/build/portable/prefix" CACHE PATH "Native prefix from build-native.py")
set(INKFLOW_RESOURCES "" CACHE PATH "Prepared resources (shared/ and prepared/cache/) to install; empty skips")
foreach(file "${INKFLOW_CARGO_DIR}/libinkflow_rime.a" "${INKFLOW_NATIVE_PREFIX}/lib/librime.so")
  if(NOT EXISTS "${file}")
    message(FATAL_ERROR "Missing ${file}; build the Rust engine first")
  endif()
endforeach()

add_library(inkflow MODULE src/engine.cpp src/candidates.cpp)
target_include_directories(inkflow PRIVATE "${INKFLOW_ROOT}/Core/Portable/include" src)
target_compile_options(inkflow PRIVATE -Wall -Wextra -Werror)
# The staticlib bundles the Rust crate and the C++ bridge; librime stays shared.
target_link_libraries(inkflow PRIVATE Fcitx5::Core
  "${INKFLOW_CARGO_DIR}/libinkflow_rime.a" "${INKFLOW_NATIVE_PREFIX}/lib/librime.so"
  stdc++ dl pthread m)
set(INKFLOW_LIBDIR "lib/inkflow")
set_target_properties(inkflow PROPERTIES INSTALL_RPATH "$ORIGIN/../inkflow" BUILD_WITH_INSTALL_RPATH OFF)

configure_file(inkflow.conf.in inkflow.conf @ONLY)
install(TARGETS inkflow DESTINATION "${INKFLOW_ADDONDIR}")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/inkflow.conf" DESTINATION "${INKFLOW_PKGDATADIR}/addon")
install(FILES inkflow-pinyin.conf DESTINATION "${INKFLOW_PKGDATADIR}/inputmethod")
file(GLOB INKFLOW_RIME_LIBS "${INKFLOW_NATIVE_PREFIX}/lib/librime.so*")
install(FILES ${INKFLOW_RIME_LIBS} DESTINATION "${INKFLOW_LIBDIR}")
if(INKFLOW_RESOURCES)
  install(DIRECTORY "${INKFLOW_RESOURCES}/shared" "${INKFLOW_RESOURCES}/prepared"
          DESTINATION "share/inkflow/rime")
endif()

enable_testing()
add_executable(bridge_test tests/bridge_test.cpp)
target_include_directories(bridge_test PRIVATE src)
# Release builds must still execute the assert-based helper checks.
target_compile_options(bridge_test PRIVATE -UNDEBUG)
add_test(NAME bridge_test COMMAND bridge_test)
