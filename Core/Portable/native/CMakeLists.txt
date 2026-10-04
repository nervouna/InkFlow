cmake_minimum_required(VERSION 3.20)
project(inkflow_rime_bridge LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
find_library(RIME_LIBRARY rime REQUIRED PATHS "${CMAKE_INSTALL_PREFIX}/lib" NO_DEFAULT_PATH)
find_path(RIME_INCLUDE rime_api.h REQUIRED PATHS "${CMAKE_INSTALL_PREFIX}/include" NO_DEFAULT_PATH)
add_library(inkflow_rime_bridge STATIC bridge.cpp
  ../../Sources/InkFlowRimeNative/InkFlowRimeNative.cpp
  ../../Sources/InkFlowRimeNative/PersonalData.cpp)
target_include_directories(inkflow_rime_bridge PRIVATE ../../Sources/InkFlowRimeNative/include)
target_include_directories(inkflow_rime_bridge SYSTEM PRIVATE "${RIME_INCLUDE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../build/portable/sources/rime/include")
target_compile_definitions(inkflow_rime_bridge PRIVATE BOOST_DLL_USE_STD_FS
  GLOG_EXPORT= GLOG_NO_EXPORT= "GLOG_DEPRECATED=__attribute__((deprecated))")
target_compile_options(inkflow_rime_bridge PRIVATE -Wall -Wextra -Werror)
target_link_libraries(inkflow_rime_bridge PRIVATE "${RIME_LIBRARY}")
install(TARGETS inkflow_rime_bridge ARCHIVE DESTINATION lib)
install(FILES bridge.h DESTINATION include)
