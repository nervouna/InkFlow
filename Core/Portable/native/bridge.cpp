#include "bridge.h"
#include "InkFlowRimeNative.h"
#include <rime_api.h>
#include <rime/registry.h>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {
RimeApi* api() { return rime_get_api(); }
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
struct Commit {
  RimeCommit value{};
  Commit() { RIME_STRUCT_INIT(RimeCommit, value); }
  ~Commit() { api()->free_commit(&value); }
};
const char* text(const char* value) { return value ? value : ""; }
}

extern "C" int ifp_initialize(const char* shared, const char* user) {
  try {
    RimeTraits traits{};
    RIME_STRUCT_INIT(RimeTraits, traits);
    traits.shared_data_dir = shared;
    traits.user_data_dir = user;
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
    const char* value = text(commit.value.text);
    char* copy = static_cast<char*>(std::malloc(std::strlen(value) + 1));
    if (!copy) return -1;
    std::strcpy(copy, value);
    *result = copy;
    return 0;
  } catch (...) { return -3; }
}
extern "C" void ifp_string_free(char* value) { std::free(value); }
