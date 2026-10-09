#include "bridge.h"
#include <cassert>
#include <cstdio>
#include <map>
#include <set>

using namespace inkflow;

int main() {
  std::map<std::string, std::string> env = {{"HOME", "/home/u"}};
  auto getenv = [&](const char* name) -> const char* {
    auto it = env.find(name);
    return it == env.end() ? nullptr : it->second.c_str();
  };
  std::set<std::string> present = {"/usr/share/inkflow/rime/shared", "/usr/share/inkflow/rime/prepared/complete"};
  auto exists = [&](const std::string& path) { return present.count(path) > 0; };
  Paths paths = resolve_paths(getenv, exists);
  assert(paths.user == "/home/u/.local/share/inkflow/rime");
  assert(paths.shared == "/usr/share/inkflow/rime/shared");
  assert(paths.cache == "/usr/share/inkflow/rime/prepared/cache");
  assert(paths.context_index == "/usr/share/inkflow/rime/shared/pinyin_simp.context.bin");
  env["XDG_DATA_HOME"] = "/data";
  env["XDG_DATA_DIRS"] = "/opt/share:/usr/share";
  present.insert("/opt/share/inkflow/rime/shared");
  paths = resolve_paths(getenv, exists);
  assert(paths.user == "/data/inkflow/rime" && paths.shared == "/usr/share/inkflow/rime/shared");
  present.insert("/opt/share/inkflow/rime/prepared/complete");
  assert(resolve_paths(getenv, exists).shared == "/opt/share/inkflow/rime/shared");
  present.insert("/data/inkflow/current/share/inkflow/rime/shared");
  present.insert("/data/inkflow/current/share/inkflow/rime/prepared/complete");
  assert(resolve_paths(getenv, exists).shared == "/data/inkflow/current/share/inkflow/rime/shared");
  assert(resolve_paths(getenv, exists).user == "/data/inkflow/rime");
  env["INKFLOW_RESOURCES"] = "/tmp/res";
  present.insert("/tmp/res/shared");
  present.insert("/tmp/res/prepared/complete");
  assert(resolve_paths(getenv, exists).cache == "/tmp/res/prepared/cache");
  present.clear();
  assert(resolve_paths(getenv, exists).shared.empty());

  PreeditLayout layout = preedit_layout("ni hao", 6, 0, 6);
  assert(layout.cursor == 6 && layout.segments.size() == 1 && layout.segments[0].highlighted);
  layout = preedit_layout("你好 ma", 6, 7, 9);
  assert(layout.segments.size() == 2 && layout.segments[0].text == "你好 " &&
         layout.segments[1].text == "ma" && layout.segments[1].highlighted && !layout.segments[0].highlighted);
  layout = preedit_layout("abc", 1, 1, 2);
  assert(layout.segments.size() == 3 && layout.segments[2].text == "c" && layout.cursor == 1);
  layout = preedit_layout("abc", 9, 0, 0);
  assert(layout.segments.size() == 1 && !layout.segments[0].highlighted && layout.cursor == 3);
  assert(preedit_layout("", 0, 0, 0).segments.empty());

  assert(rime_modifiers(0, false) == 0);
  assert(rime_modifiers(1u << 0 | 1u << 2, false) == ((1u << 0) | (1u << 2)));
  assert(rime_modifiers(1u << 6, false) == (1u << 26));
  assert(rime_modifiers(1u << 26, true) == ((1u << 26) | (1u << 30)));
  assert(rime_modifiers(1u << 4 | 1u << 31, false) == 0);

  assert(preceding_text("中文abc", 5, 16) == "中文abc");
  assert(preceding_text("中文abc", 5, 2) == "bc");
  assert(preceding_text("中文abc", 2, 16) == "中文");
  assert(preceding_text("中文abc", 0, 16) == "");
  assert(preceding_text("中文abc", 6, 16) == "");
  assert(preceding_text("\xff\xfe", 1, 16) == "");
  assert(preceding_text("a\xe4\xb8", 2, 16) == "");
  std::string code, text;
  assert(parse_phrase("dz=地址", code, text) && code == "dz" && text == "地址");
  assert(parse_phrase("a=b=c", code, text) && code == "a" && text == "b=c");
  assert(!parse_phrase("nothing", code, text) && !parse_phrase("=x", code, text) && !parse_phrase("x=", code, text));
  std::puts("PASS fcitx5 bridge helpers: XDG paths, preedit layout, key states, preceding text, phrases");
  return 0;
}
