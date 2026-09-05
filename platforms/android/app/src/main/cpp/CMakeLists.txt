add_library(inkflow_android_jni SHARED jni_bridge.cpp)

target_compile_features(inkflow_android_jni PRIVATE cxx_std_17)
target_compile_options(
  inkflow_android_jni
  PRIVATE -Wall -Wextra -Wpedantic -Werror
)
target_link_libraries(inkflow_android_jni PRIVATE InkFlow::Engine)
set_target_properties(
  inkflow_android_jni
  PROPERTIES
    CXX_EXTENSIONS NO
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN YES
    OUTPUT_NAME inkflow_android
)

inkflow_apply_engine_export_boundary(inkflow_android_jni JNI_OnLoad)
