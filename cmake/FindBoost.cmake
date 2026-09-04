# InkFlow builds against the Boost release pinned by librime's own release
# tooling. The assembled Boost release tree is header-only for the Regex C++
# API used by librime 1.17.0, so no machine-local Boost library is permitted.
if(DEFINED INKFLOW_BOOST_SOURCE_DIR AND
   EXISTS "${INKFLOW_BOOST_SOURCE_DIR}/boost/version.hpp")
  if(NOT TARGET Boost::headers)
    add_library(Boost::headers INTERFACE IMPORTED GLOBAL)
    set_target_properties(
      Boost::headers
      PROPERTIES INTERFACE_INCLUDE_DIRECTORIES "${INKFLOW_BOOST_SOURCE_DIR}"
    )
  endif()
  if(NOT TARGET Boost::regex)
    add_library(Boost::regex INTERFACE IMPORTED GLOBAL)
    set_target_properties(
      Boost::regex
      PROPERTIES
        INTERFACE_LINK_LIBRARIES Boost::headers
        INTERFACE_COMPILE_DEFINITIONS BOOST_REGEX_NO_LIB
    )
  endif()

  set(Boost_FOUND TRUE)
  set(Boost_VERSION 108900)
  set(Boost_VERSION_STRING "1.89.0")
  set(Boost_INCLUDE_DIR "${INKFLOW_BOOST_SOURCE_DIR}")
  set(Boost_INCLUDE_DIRS "${INKFLOW_BOOST_SOURCE_DIR}")
  set(Boost_LIBRARIES Boost::regex)
  foreach(component IN LISTS Boost_FIND_COMPONENTS)
    if(component STREQUAL "regex")
      set(Boost_regex_FOUND TRUE)
    else()
      set(Boost_${component}_FOUND FALSE)
      set(Boost_FOUND FALSE)
    endif()
  endforeach()

  include(FindPackageHandleStandardArgs)
  find_package_handle_standard_args(
    Boost
    REQUIRED_VARS Boost_INCLUDE_DIR
    VERSION_VAR Boost_VERSION_STRING
    HANDLE_COMPONENTS
  )
else()
  include("${CMAKE_ROOT}/Modules/FindBoost.cmake")
endif()
