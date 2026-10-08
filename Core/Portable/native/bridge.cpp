#include "bridge.h"
#include "InkFlowRimeNative.h"
#include <rime_api.h>
#include <rime/registry.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
RimeApi* api() { return rime_get_api(); }
std::atomic<int> deployment_status{0};
void deployment(void*, RimeSessionId, const char* type, const char* value) {
  if (std::strcmp(type, "deploy")) return;
  if (!std::strcmp(value, "success")) deployment_status.store(1);
  if (!std::strcmp(value, "failure")) deployment_status.store(-1);
}
struct Snapshot {
  std::string preedit;
  std::vector<std::string> texts;
  std::vector<std::string> comments;
  std::vector<IFPCandidate> candidates;
};
struct Context {
  RimeContext value{};
  Context() { RIME_STRUCT_INIT(RimeContext, value); }
  ~Context() { api()->free_context(&value); }
};
struct Config {
  RimeConfig value{};
  ~Config() { if (value.ptr) api()->config_close(&value); }
};
char* duplicate(const char* value) {
  char* copy = static_cast<char*>(std::malloc(std::strlen(value) + 1));
  if (copy) std::strcpy(copy, value);
  return copy;
}
struct Commit {
  RimeCommit value{};
  Commit() { RIME_STRUCT_INIT(RimeCommit, value); }
  ~Commit() { api()->free_commit(&value); }
};
const char* text(const char* value) { return value ? value : ""; }
}

extern "C" int ifp_initialize(const char* shared, const char* user, const char* cache) {
  try {
    RimeTraits traits{};
    RIME_STRUCT_INIT(RimeTraits, traits);
    traits.shared_data_dir = shared;
    traits.user_data_dir = user;
    traits.staging_dir = cache;
    traits.prebuilt_data_dir = cache;
    traits.distribution_name = "InkFlow portable probe";
    traits.distribution_code_name = "inkflow-portable";
    traits.distribution_version = "0";
    traits.app_name = "inkflow.portable";
    traits.min_log_level = 2;
    traits.log_dir = user;
    static const char* modules[] = {"default", "deployer", "lua", nullptr};
    traits.modules = modules;
    api()->setup(&traits);
    api()->initialize(&traits);
    IFRegisterRimeNativeComponents();
    if (!api()->find_module("lua") ||
        !rime::Registry::instance().Find("inkflow_mixed_personal")) {
      api()->finalize();
      return -1;
    }
    return 0;
  } catch (...) {
    // Initialization may have installed modules before failing.
    try { api()->finalize(); } catch (...) {}
    return -3;
  }
}
extern "C" int ifp_finalize(void) {
  try { api()->finalize(); return 0; } catch (...) { return -3; }
}
extern "C" int ifp_prepare(void) {
  try {
    deployment_status.store(0);
    api()->set_notification_handler(deployment, nullptr);
    if (api()->start_maintenance(1)) api()->join_maintenance_thread();
    api()->set_notification_handler(nullptr, nullptr);
    return deployment_status.load() == 1 ? 0 : -1;
  } catch (...) {
    try { api()->set_notification_handler(nullptr, nullptr); } catch (...) {}
    return -3;
  }
}
extern "C" int ifp_deploy(const char* schema_path) {
  try { return api()->deploy_schema(schema_path) ? 0 : -1; }
  catch (...) { return -3; }
}
extern "C" int ifp_session_create(const char* schema, uintptr_t* session) {
  RimeSessionId id = 0;
  try {
    Config config;
    if (!api()->schema_open(schema, &config.value)) return -2;
    const char* configured_id = api()->config_get_cstring(&config.value, "schema/schema_id");
    if (!configured_id || std::strcmp(configured_id, schema) != 0) return -2;
    id = api()->create_session();
    if (!id) return -1;
    if (!api()->select_schema(id, schema)) {
      api()->destroy_session(id);
      return -2;
    }
    *session = id;
    return 0;
  } catch (...) {
    if (id) { try { api()->destroy_session(id); } catch (...) {} }
    return -3;
  }
}
extern "C" int ifp_session_destroy(uintptr_t session) {
  try { return api()->destroy_session(session) ? 0 : -2; }
  catch (...) { return -3; }
}
extern "C" int ifp_process_key(uintptr_t session, int key, int modifiers, int* handled) {
  try {
    if (!api()->find_session(session)) return -2;
    *handled = api()->process_key(session, key, modifiers) ? 1 : 0;
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_clear(uintptr_t session) {
  try {
    if (!api()->find_session(session)) return -2;
    api()->clear_composition(session);
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_select_candidate(uintptr_t session, size_t index) {
  try {
    if (!api()->find_session(session)) return -2;
    return api()->select_candidate_on_current_page(session, index) ? 0 : -1;
  } catch (...) { return -3; }
}
extern "C" int ifp_change_page(uintptr_t session, int backward, int* changed) {
  try {
    if (!api()->find_session(session)) return -2;
    *changed = api()->change_page(session, backward != 0) ? 1 : 0;
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_snapshot(uintptr_t session, IFPSnapshot* result) {
  try {
    if (!api()->find_session(session)) return -2;
    Context context;
    if (!api()->get_context(session, &context.value)) return -1;
    const auto& c = context.value;
    auto owned = std::make_unique<Snapshot>();
    owned->preedit = text(c.composition.preedit);
    for (int i = 0; i < c.menu.num_candidates; ++i) {
      owned->texts.emplace_back(text(c.menu.candidates[i].text));
      owned->comments.emplace_back(text(c.menu.candidates[i].comment));
    }
    for (size_t i = 0; i < owned->texts.size(); ++i)
      owned->candidates.push_back({owned->texts[i].c_str(), owned->comments[i].c_str()});
    *result = {owned->preedit.c_str(), static_cast<size_t>(c.composition.cursor_pos),
               static_cast<size_t>(c.composition.sel_start), static_cast<size_t>(c.composition.sel_end),
               owned->candidates.data(), owned->candidates.size(), c.menu.page_no,
               c.menu.highlighted_candidate_index, c.menu.is_last_page, owned.get()};
    owned.release();
    return 0;
  } catch (...) { return -3; }
}
extern "C" void ifp_snapshot_free(IFPSnapshot* snapshot) {
  delete static_cast<Snapshot*>(snapshot->owner);
  *snapshot = {};
}
extern "C" int ifp_take_commit(uintptr_t session, char** result) {
  try {
    if (!api()->find_session(session)) return -2;
    Commit commit;
    if (!api()->get_commit(session, &commit.value)) return 0;
    char* copy = duplicate(text(commit.value.text));
    if (!copy) return -1;
    *result = copy;
    return 0;
  } catch (...) { return -3; }
}
extern "C" void ifp_string_free(char* value) { std::free(value); }
extern "C" int ifp_get_input(uintptr_t session, char** result) {
  try {
    if (!api()->find_session(session)) return -2;
    char* copy = duplicate(text(api()->get_input(session)));
    if (!copy) return -1;
    *result = copy;
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_highlight_candidate(uintptr_t session, size_t index, int* handled) {
  try {
    if (!api()->find_session(session)) return -2;
    *handled = api()->highlight_candidate_on_current_page(session, index) ? 1 : 0;
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_commit_composition(uintptr_t session, int* handled) {
  try {
    if (!api()->find_session(session)) return -2;
    *handled = api()->commit_composition(session) ? 1 : 0;
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_set_option(uintptr_t session, const char* option, int value) {
  try {
    if (!api()->find_session(session)) return -2;
    api()->set_option(session, option, value != 0);
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_get_option(uintptr_t session, const char* option, int* value) {
  try {
    if (!api()->find_session(session)) return -2;
    *value = api()->get_option(session, option) ? 1 : 0;
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_call(uintptr_t session, const char* request, size_t capacity, char** result) {
  try {
    if (!api()->find_session(session)) return -2;
    api()->set_property(session, "inkflow_result", "");
    api()->set_property(session, "inkflow_request", request);
    api()->set_property(session, "inkflow_request", "");
    std::string buffer(capacity + 1, '\0');
    const bool read = api()->get_property(session, "inkflow_result", buffer.data(), buffer.size() - 1);
    api()->set_property(session, "inkflow_result", "");
    if (!read) return 0;
    // A reply that fills the buffer may be truncated; fail closed.
    const size_t end = buffer.find('\0');
    if (end >= buffer.size() - 1) return 0;
    char* copy = duplicate(buffer.c_str());
    if (!copy) return -1;
    *result = copy;
    return 0;
  } catch (...) { return -3; }
}
extern "C" int ifp_apply_schema_patch(uintptr_t session, const char* schema, const char* yaml,
                                      const char* const* paths, size_t count, int* outcome) {
  try {
    if (!api()->find_session(session)) return -2;
    Config config;
    if (!api()->schema_open(schema, &config.value)) { *outcome = 1; return -1; }
    Config patch;
    if (!api()->config_init(&patch.value)) { *outcome = 2; return -1; }
    if (!api()->config_load_string(&patch.value, yaml)) { *outcome = 3; return -1; }
    // Replace whole nodes and restore them synchronously. Other sessions retain their
    // component configuration, while this idle session loads one coherent snapshot.
    std::vector<std::pair<const char*, RimeConfig>> originals;
    bool patched = true;
    for (size_t i = 0; i < count; ++i) {
      RimeConfig original{}, replacement{};
      if (!api()->config_get_item(&config.value, paths[i], &original)) { patched = false; break; }
      originals.emplace_back(paths[i], original);
      if (!api()->config_get_item(&patch.value, paths[i], &replacement)) { patched = false; break; }
      const bool changed = api()->config_set_item(&config.value, paths[i], &replacement);
      api()->config_close(&replacement);
      if (!changed) { patched = false; break; }
    }
    const bool selected = patched && api()->select_schema(session, schema);
    bool restored = true;
    for (auto it = originals.rbegin(); it != originals.rend(); ++it) {
      if (!api()->config_set_item(&config.value, it->first, &it->second)) restored = false;
      api()->config_close(&it->second);
    }
    *outcome = (patched ? 1 : 0) | (selected ? 2 : 0) | (restored ? 4 : 0);
    return 0;
  } catch (...) { return -3; }
}
