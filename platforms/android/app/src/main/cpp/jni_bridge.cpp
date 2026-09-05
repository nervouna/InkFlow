#include <jni.h>

#include <inkflow/engine.h>

#include <cstdint>
#include <limits>
#include <mutex>
#include <new>
#include <string>
#include <vector>

namespace {

constexpr char kBridgeClassName[] = "io/damao/inkflow/engine/NativeBridge";
constexpr char kCandidateClassName[] =
    "io/damao/inkflow/engine/EngineCandidate";
constexpr char kUpdateClassName[] =
    "io/damao/inkflow/engine/NativeEngineUpdate";
constexpr char kUpdateSignature[] =
    "(ZLjava/lang/String;Ljava/lang/String;JJJLjava/util/List;JZZ)V";
constexpr char kProcessKeySignature[] =
    "(JII)Lio/damao/inkflow/engine/NativeEngineUpdate;";
constexpr char kNoArgumentUpdateSignature[] =
    "(J)Lio/damao/inkflow/engine/NativeEngineUpdate;";
constexpr char kIndexUpdateSignature[] =
    "(JI)Lio/damao/inkflow/engine/NativeEngineUpdate;";
constexpr char kBooleanUpdateSignature[] =
    "(JZ)Lio/damao/inkflow/engine/NativeEngineUpdate;";

std::mutex g_mutex;
InkFlowRuntime* g_runtime = nullptr;
InkFlowSession* g_session = nullptr;
jlong g_session_owner = 0;
jlong g_next_session_owner = 0;
bool g_prepared = false;

jclass g_candidate_class = nullptr;
jmethodID g_candidate_constructor = nullptr;
jclass g_update_class = nullptr;
jmethodID g_update_constructor = nullptr;
jclass g_array_list_class = nullptr;
jmethodID g_array_list_constructor = nullptr;
jmethodID g_array_list_add = nullptr;

class SnapshotOwner {
 public:
  explicit SnapshotOwner(InkFlowSnapshot* snapshot) : snapshot_(snapshot) {}
  ~SnapshotOwner() { inkflow_snapshot_destroy(snapshot_); }

  SnapshotOwner(const SnapshotOwner&) = delete;
  SnapshotOwner& operator=(const SnapshotOwner&) = delete;

 private:
  InkFlowSnapshot* snapshot_;
};

class StringCharsOwner {
 public:
  StringCharsOwner(JNIEnv* environment,
                   jstring value,
                   const jchar* characters)
      : environment_(environment), value_(value), characters_(characters) {}
  ~StringCharsOwner() {
    environment_->ReleaseStringChars(value_, characters_);
  }

  StringCharsOwner(const StringCharsOwner&) = delete;
  StringCharsOwner& operator=(const StringCharsOwner&) = delete;

 private:
  JNIEnv* environment_;
  jstring value_;
  const jchar* characters_;
};

void throw_fixed(JNIEnv* environment,
                 const char* class_name,
                 const char* message) {
  if (environment->ExceptionCheck()) {
    return;
  }
  jclass exception_class = environment->FindClass(class_name);
  if (exception_class == nullptr) {
    return;
  }
  environment->ThrowNew(exception_class, message);
  environment->DeleteLocalRef(exception_class);
}

void throw_status(JNIEnv* environment,
                  const char* operation,
                  InkFlowStatus status) {
  std::string message("InkFlow ");
  message.append(operation);
  message.append(" failed with status ");
  message.append(std::to_string(static_cast<unsigned int>(status)));
  throw_fixed(environment, "java/lang/IllegalStateException", message.c_str());
}

void translate_cpp_exception(JNIEnv* environment) {
  try {
    throw;
  } catch (const std::bad_alloc&) {
    throw_fixed(environment, "java/lang/OutOfMemoryError",
                "InkFlow native allocation failed");
  } catch (...) {
    throw_fixed(environment, "java/lang/IllegalStateException",
                "InkFlow native bridge failed");
  }
}

bool jstring_to_utf8(JNIEnv* environment,
                     jstring value,
                     std::string* result) {
  if (value == nullptr || result == nullptr) {
    throw_fixed(environment, "java/lang/IllegalArgumentException",
                "InkFlow path must not be null");
    return false;
  }

  const jsize length = environment->GetStringLength(value);
  const jchar* characters = environment->GetStringChars(value, nullptr);
  if (characters == nullptr) {
    return false;
  }
  const StringCharsOwner owner(environment, value, characters);

  result->clear();
  result->reserve(static_cast<size_t>(length));
  bool valid = true;
  for (jsize index = 0; index < length && valid; ++index) {
    uint32_t scalar = characters[index];
    if (scalar == 0) {
      valid = false;
      break;
    }
    if (scalar >= 0xd800u && scalar <= 0xdbffu) {
      if (++index >= length) {
        valid = false;
        break;
      }
      const uint32_t low = characters[index];
      if (low < 0xdc00u || low > 0xdfffu) {
        valid = false;
        break;
      }
      scalar = 0x10000u + ((scalar - 0xd800u) << 10u) + (low - 0xdc00u);
    } else if (scalar >= 0xdc00u && scalar <= 0xdfffu) {
      valid = false;
      break;
    }

    if (scalar <= 0x7fu) {
      result->push_back(static_cast<char>(scalar));
    } else if (scalar <= 0x7ffu) {
      result->push_back(static_cast<char>(0xc0u | (scalar >> 6u)));
      result->push_back(static_cast<char>(0x80u | (scalar & 0x3fu)));
    } else if (scalar <= 0xffffu) {
      result->push_back(static_cast<char>(0xe0u | (scalar >> 12u)));
      result->push_back(
          static_cast<char>(0x80u | ((scalar >> 6u) & 0x3fu)));
      result->push_back(static_cast<char>(0x80u | (scalar & 0x3fu)));
    } else {
      result->push_back(static_cast<char>(0xf0u | (scalar >> 18u)));
      result->push_back(
          static_cast<char>(0x80u | ((scalar >> 12u) & 0x3fu)));
      result->push_back(
          static_cast<char>(0x80u | ((scalar >> 6u) & 0x3fu)));
      result->push_back(static_cast<char>(0x80u | (scalar & 0x3fu)));
    }
  }
  if (!valid) {
    throw_fixed(environment, "java/lang/IllegalArgumentException",
                "InkFlow path is not valid Unicode");
  }
  return valid;
}

bool utf8_to_utf16(const char* value, std::vector<jchar>* result) {
  if (value == nullptr || result == nullptr) {
    return false;
  }
  result->clear();

  const auto* bytes = reinterpret_cast<const unsigned char*>(value);
  size_t index = 0;
  while (bytes[index] != 0) {
    const unsigned char first = bytes[index];
    uint32_t scalar = 0;
    size_t count = 0;
    if (first <= 0x7fu) {
      scalar = first;
      count = 1;
    } else if (first >= 0xc2u && first <= 0xdfu) {
      scalar = first & 0x1fu;
      count = 2;
    } else if (first >= 0xe0u && first <= 0xefu) {
      scalar = first & 0x0fu;
      count = 3;
    } else if (first >= 0xf0u && first <= 0xf4u) {
      scalar = first & 0x07u;
      count = 4;
    } else {
      return false;
    }

    for (size_t continuation = 1; continuation < count; ++continuation) {
      const unsigned char byte = bytes[index + continuation];
      if (byte == 0 || (byte & 0xc0u) != 0x80u) {
        return false;
      }
      scalar = (scalar << 6u) | (byte & 0x3fu);
    }

    if ((count == 3 && first == 0xe0u && bytes[index + 1] < 0xa0u) ||
        (count == 3 && first == 0xedu && bytes[index + 1] >= 0xa0u) ||
        (count == 4 && first == 0xf0u && bytes[index + 1] < 0x90u) ||
        (count == 4 && first == 0xf4u && bytes[index + 1] > 0x8fu) ||
        scalar > 0x10ffffu || (scalar >= 0xd800u && scalar <= 0xdfffu)) {
      return false;
    }

    if (scalar <= 0xffffu) {
      result->push_back(static_cast<jchar>(scalar));
    } else {
      scalar -= 0x10000u;
      result->push_back(static_cast<jchar>(0xd800u + (scalar >> 10u)));
      result->push_back(static_cast<jchar>(0xdc00u + (scalar & 0x3ffu)));
    }
    index += count;
  }
  return true;
}

jstring new_utf8_string(JNIEnv* environment, const char* value) {
  if (value == nullptr) {
    return nullptr;
  }
  std::vector<jchar> characters;
  if (!utf8_to_utf16(value, &characters)) {
    throw_fixed(environment, "java/lang/IllegalStateException",
                "InkFlow engine returned invalid UTF-8");
    return nullptr;
  }
  if (characters.size() >
      static_cast<size_t>(std::numeric_limits<jsize>::max())) {
    throw_fixed(environment, "java/lang/IllegalStateException",
                "InkFlow engine text is too long");
    return nullptr;
  }
  const jchar empty = 0;
  const jchar* data = characters.empty() ? &empty : characters.data();
  return environment->NewString(
      data, static_cast<jsize>(characters.size()));
}

bool size_to_jlong(JNIEnv* environment, size_t value, jlong* result) {
  if (value > static_cast<size_t>(std::numeric_limits<jlong>::max())) {
    throw_fixed(environment, "java/lang/IllegalStateException",
                "InkFlow engine offset is too large");
    return false;
  }
  *result = static_cast<jlong>(value);
  return true;
}

jobject make_update(JNIEnv* environment, InkFlowSnapshot* snapshot) {
  if (snapshot == nullptr) {
    throw_fixed(environment, "java/lang/IllegalStateException",
                "InkFlow engine returned no snapshot");
    return nullptr;
  }

  const size_t count = inkflow_snapshot_candidate_count(snapshot);
  if (count > static_cast<size_t>(std::numeric_limits<jint>::max())) {
    throw_fixed(environment, "java/lang/IllegalStateException",
                "InkFlow engine returned too many candidates");
    return nullptr;
  }

  jlong cursor = 0;
  jlong selection_start = 0;
  jlong selection_end = 0;
  if (!size_to_jlong(environment,
                     inkflow_snapshot_preedit_cursor_byte_offset(snapshot),
                     &cursor) ||
      !size_to_jlong(
          environment,
          inkflow_snapshot_preedit_selection_start_byte_offset(snapshot),
          &selection_start) ||
      !size_to_jlong(
          environment,
          inkflow_snapshot_preedit_selection_end_byte_offset(snapshot),
          &selection_end)) {
    return nullptr;
  }

  jstring commit = new_utf8_string(
      environment, inkflow_snapshot_commit_text(snapshot));
  if (environment->ExceptionCheck()) {
    return nullptr;
  }
  jstring preedit = new_utf8_string(
      environment, inkflow_snapshot_preedit(snapshot));
  if (environment->ExceptionCheck() || preedit == nullptr) {
    environment->DeleteLocalRef(commit);
    return nullptr;
  }

  jobject candidates = environment->NewObject(
      g_array_list_class, g_array_list_constructor, static_cast<jint>(count));
  if (candidates == nullptr) {
    environment->DeleteLocalRef(commit);
    environment->DeleteLocalRef(preedit);
    return nullptr;
  }

  for (size_t index = 0; index < count; ++index) {
    jstring text = new_utf8_string(
        environment, inkflow_snapshot_candidate_text(snapshot, index));
    if (environment->ExceptionCheck() || text == nullptr) {
      if (!environment->ExceptionCheck()) {
        throw_fixed(environment, "java/lang/IllegalStateException",
                    "InkFlow candidate text is missing");
      }
      environment->DeleteLocalRef(candidates);
      environment->DeleteLocalRef(commit);
      environment->DeleteLocalRef(preedit);
      return nullptr;
    }
    jstring comment = new_utf8_string(
        environment, inkflow_snapshot_candidate_comment(snapshot, index));
    if (environment->ExceptionCheck()) {
      environment->DeleteLocalRef(text);
      environment->DeleteLocalRef(candidates);
      environment->DeleteLocalRef(commit);
      environment->DeleteLocalRef(preedit);
      return nullptr;
    }
    jobject candidate = environment->NewObject(
        g_candidate_class, g_candidate_constructor, text, comment);
    environment->DeleteLocalRef(text);
    environment->DeleteLocalRef(comment);
    if (candidate == nullptr) {
      environment->DeleteLocalRef(candidates);
      environment->DeleteLocalRef(commit);
      environment->DeleteLocalRef(preedit);
      return nullptr;
    }
    environment->CallBooleanMethod(candidates, g_array_list_add, candidate);
    environment->DeleteLocalRef(candidate);
    if (environment->ExceptionCheck()) {
      environment->DeleteLocalRef(candidates);
      environment->DeleteLocalRef(commit);
      environment->DeleteLocalRef(preedit);
      return nullptr;
    }
  }

  const size_t raw_highlight =
      inkflow_snapshot_highlighted_candidate_index(snapshot);
  jlong highlight = -1;
  if (raw_highlight != INKFLOW_NO_CANDIDATE) {
    if (raw_highlight >= count ||
        !size_to_jlong(environment, raw_highlight, &highlight)) {
      if (!environment->ExceptionCheck()) {
        throw_fixed(environment, "java/lang/IllegalStateException",
                    "InkFlow candidate highlight is invalid");
      }
      environment->DeleteLocalRef(candidates);
      environment->DeleteLocalRef(commit);
      environment->DeleteLocalRef(preedit);
      return nullptr;
    }
  }

  jobject update = environment->NewObject(
      g_update_class, g_update_constructor,
      static_cast<jboolean>(inkflow_snapshot_handled(snapshot) != 0), commit,
      preedit, cursor, selection_start, selection_end, candidates, highlight,
      static_cast<jboolean>(
          inkflow_snapshot_has_previous_page(snapshot) != 0),
      static_cast<jboolean>(inkflow_snapshot_has_next_page(snapshot) != 0));
  environment->DeleteLocalRef(candidates);
  environment->DeleteLocalRef(commit);
  environment->DeleteLocalRef(preedit);
  return update;
}

template <typename Operation>
jobject run_session_operation(JNIEnv* environment,
                              jlong owner_token,
                              const char* operation_name,
                              Operation operation) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (owner_token <= 0 || g_session == nullptr ||
      owner_token != g_session_owner) {
    throw_fixed(environment, "java/lang/IllegalStateException",
                "InkFlow session owner is stale");
    return nullptr;
  }

  InkFlowSnapshot* snapshot = nullptr;
  const InkFlowStatus status = operation(g_session, &snapshot);
  if (status != INKFLOW_STATUS_OK) {
    throw_status(environment, operation_name, status);
    return nullptr;
  }
  SnapshotOwner owner(snapshot);
  return make_update(environment, snapshot);
}

jint native_api_version(JNIEnv*, jclass) {
  return static_cast<jint>(inkflow_engine_api_version());
}

void native_initialize(JNIEnv* environment,
                       jclass,
                       jstring shared_data_directory,
                       jstring user_data_directory,
                       jstring prebuilt_data_directory,
                       jstring staging_data_directory) {
  try {
    std::string shared_data;
    std::string user_data;
    std::string prebuilt_data;
    std::string staging_data;
    if (!jstring_to_utf8(environment, shared_data_directory, &shared_data) ||
        !jstring_to_utf8(environment, user_data_directory, &user_data) ||
        !jstring_to_utf8(environment, prebuilt_data_directory,
                         &prebuilt_data) ||
        !jstring_to_utf8(environment, staging_data_directory, &staging_data)) {
      return;
    }

    std::lock_guard<std::mutex> lock(g_mutex);
    if (inkflow_engine_api_version() != INKFLOW_ENGINE_API_VERSION) {
      throw_fixed(environment, "java/lang/IllegalStateException",
                  "InkFlow engine API version mismatch");
      return;
    }

    if (g_runtime == nullptr) {
      InkFlowRuntimeConfig config{};
      config.struct_size = sizeof(config);
      config.shared_data_dir = shared_data.c_str();
      config.user_data_dir = user_data.c_str();
      config.prebuilt_data_dir = prebuilt_data.c_str();
      config.staging_data_dir = staging_data.c_str();
      config.distribution_name = "InkFlow";
      config.distribution_code_name = "android";
      config.distribution_version = "0.1.0";
      config.application_name = "rime.inkflow.android";
      config.minimum_log_level = 3;

      InkFlowRuntime* runtime = nullptr;
      const InkFlowStatus create_status =
          inkflow_runtime_create(&config, &runtime);
      if (create_status != INKFLOW_STATUS_OK) {
        throw_status(environment, "runtime initialization", create_status);
        return;
      }
      g_runtime = runtime;
    }

    if (!g_prepared) {
      const InkFlowStatus prepare_status = inkflow_runtime_prepare(g_runtime);
      if (prepare_status != INKFLOW_STATUS_OK) {
        throw_status(environment, "schema deployment", prepare_status);
        return;
      }
      g_prepared = true;
    }
  } catch (...) {
    translate_cpp_exception(environment);
  }
}

jlong native_open_session(JNIEnv* environment, jclass) {
  try {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_runtime == nullptr || !g_prepared) {
      throw_fixed(environment, "java/lang/IllegalStateException",
                  "InkFlow runtime is not ready");
      return 0;
    }
    if (g_next_session_owner == std::numeric_limits<jlong>::max()) {
      throw_fixed(environment, "java/lang/IllegalStateException",
                  "InkFlow session owner space is exhausted");
      return 0;
    }
    if (g_session != nullptr) {
      InkFlowSession* previous = g_session;
      g_session = nullptr;
      g_session_owner = 0;
      const InkFlowStatus close_status = inkflow_session_destroy(previous);
      if (close_status != INKFLOW_STATUS_OK) {
        throw_status(environment, "session close", close_status);
        return 0;
      }
    }

    InkFlowSession* session = nullptr;
    const InkFlowStatus status =
        inkflow_session_create(g_runtime, "inkflow", &session);
    if (status != INKFLOW_STATUS_OK) {
      throw_status(environment, "session open", status);
      return 0;
    }
    g_session = session;
    g_session_owner = ++g_next_session_owner;
    return g_session_owner;
  } catch (...) {
    translate_cpp_exception(environment);
    return 0;
  }
}

jboolean native_close_session(JNIEnv* environment,
                              jclass,
                              jlong owner_token) {
  try {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (owner_token <= 0 || g_session == nullptr ||
        owner_token != g_session_owner) {
      return JNI_FALSE;
    }
    InkFlowSession* session = g_session;
    g_session = nullptr;
    g_session_owner = 0;
    const InkFlowStatus status = inkflow_session_destroy(session);
    if (status != INKFLOW_STATUS_OK) {
      throw_status(environment, "session close", status);
      return JNI_FALSE;
    }
    return JNI_TRUE;
  } catch (...) {
    translate_cpp_exception(environment);
    return JNI_FALSE;
  }
}

jobject native_process_key(JNIEnv* environment,
                           jclass,
                           jlong owner_token,
                           jint key_code,
                           jint modifiers) {
  try {
    const InkFlowKeyEvent event{
        static_cast<InkFlowKeyCode>(static_cast<uint32_t>(key_code)),
        static_cast<InkFlowKeyModifiers>(static_cast<uint32_t>(modifiers)),
    };
    return run_session_operation(
        environment, owner_token, "key processing",
        [event](InkFlowSession* session, InkFlowSnapshot** snapshot) {
          return inkflow_session_process_key(session, event, snapshot);
        });
  } catch (...) {
    translate_cpp_exception(environment);
    return nullptr;
  }
}

jobject native_commit(JNIEnv* environment, jclass, jlong owner_token) {
  try {
    return run_session_operation(environment, owner_token, "commit",
                                 inkflow_session_commit);
  } catch (...) {
    translate_cpp_exception(environment);
    return nullptr;
  }
}

jobject native_select_candidate(JNIEnv* environment,
                                jclass,
                                jlong owner_token,
                                jint index) {
  try {
    if (index < 0) {
      throw_fixed(environment, "java/lang/IllegalArgumentException",
                  "Candidate index must be nonnegative");
      return nullptr;
    }
    return run_session_operation(
        environment, owner_token, "candidate selection",
        [index](InkFlowSession* session, InkFlowSnapshot** snapshot) {
          return inkflow_session_select_candidate(
              session, static_cast<size_t>(index), snapshot);
        });
  } catch (...) {
    translate_cpp_exception(environment);
    return nullptr;
  }
}

jobject native_change_page(JNIEnv* environment,
                           jclass,
                           jlong owner_token,
                           jboolean backward) {
  try {
    return run_session_operation(
        environment, owner_token, "page change",
        [backward](InkFlowSession* session, InkFlowSnapshot** snapshot) {
          return inkflow_session_change_page(session, backward ? 1 : 0,
                                              snapshot);
        });
  } catch (...) {
    translate_cpp_exception(environment);
    return nullptr;
  }
}

jobject native_reset(JNIEnv* environment, jclass, jlong owner_token) {
  try {
    return run_session_operation(environment, owner_token, "reset",
                                 inkflow_session_reset);
  } catch (...) {
    translate_cpp_exception(environment);
    return nullptr;
  }
}

jclass make_global_class(JNIEnv* environment, const char* class_name) {
  jclass local = environment->FindClass(class_name);
  if (local == nullptr) {
    return nullptr;
  }
  auto* global = static_cast<jclass>(environment->NewGlobalRef(local));
  environment->DeleteLocalRef(local);
  return global;
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* virtual_machine, void*) {
  JNIEnv* environment = nullptr;
  if (virtual_machine->GetEnv(reinterpret_cast<void**>(&environment),
                              JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }

  jclass bridge_class = environment->FindClass(kBridgeClassName);
  if (bridge_class == nullptr) {
    return JNI_ERR;
  }

  JNINativeMethod methods[] = {
      {const_cast<char*>("apiVersion"), const_cast<char*>("()I"),
       reinterpret_cast<void*>(native_api_version)},
      {const_cast<char*>("initialize"),
       const_cast<char*>(
           "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V"),
       reinterpret_cast<void*>(native_initialize)},
      {const_cast<char*>("openSession"), const_cast<char*>("()J"),
       reinterpret_cast<void*>(native_open_session)},
      {const_cast<char*>("closeSession"), const_cast<char*>("(J)Z"),
       reinterpret_cast<void*>(native_close_session)},
      {const_cast<char*>("processKey"),
       const_cast<char*>(kProcessKeySignature),
       reinterpret_cast<void*>(native_process_key)},
      {const_cast<char*>("commit"),
       const_cast<char*>(kNoArgumentUpdateSignature),
       reinterpret_cast<void*>(native_commit)},
      {const_cast<char*>("selectCandidate"),
       const_cast<char*>(kIndexUpdateSignature),
       reinterpret_cast<void*>(native_select_candidate)},
      {const_cast<char*>("changePage"),
       const_cast<char*>(kBooleanUpdateSignature),
       reinterpret_cast<void*>(native_change_page)},
      {const_cast<char*>("reset"),
       const_cast<char*>(kNoArgumentUpdateSignature),
       reinterpret_cast<void*>(native_reset)},
  };

  const jint register_status = environment->RegisterNatives(
      bridge_class, methods,
      static_cast<jint>(sizeof(methods) / sizeof(methods[0])));
  environment->DeleteLocalRef(bridge_class);
  if (register_status != JNI_OK) {
    return JNI_ERR;
  }

  g_candidate_class = make_global_class(environment, kCandidateClassName);
  g_update_class = make_global_class(environment, kUpdateClassName);
  g_array_list_class = make_global_class(environment, "java/util/ArrayList");
  if (g_candidate_class == nullptr || g_update_class == nullptr ||
      g_array_list_class == nullptr) {
    return JNI_ERR;
  }

  g_candidate_constructor = environment->GetMethodID(
      g_candidate_class, "<init>",
      "(Ljava/lang/String;Ljava/lang/String;)V");
  g_update_constructor = environment->GetMethodID(
      g_update_class, "<init>", kUpdateSignature);
  g_array_list_constructor =
      environment->GetMethodID(g_array_list_class, "<init>", "(I)V");
  g_array_list_add = environment->GetMethodID(
      g_array_list_class, "add", "(Ljava/lang/Object;)Z");
  if (g_candidate_constructor == nullptr || g_update_constructor == nullptr ||
      g_array_list_constructor == nullptr || g_array_list_add == nullptr) {
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}
