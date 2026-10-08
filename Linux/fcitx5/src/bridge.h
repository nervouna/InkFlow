// Pure helpers between Fcitx5 and the engine ABI: XDG paths, preedit layout from UTF-8
// byte offsets, key-state translation and bounded surrounding text. No Fcitx5 or GLib
// dependency, so tests/bridge_test.cpp runs on any platform.
#ifndef INKFLOW_FCITX5_BRIDGE_H
#define INKFLOW_FCITX5_BRIDGE_H
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace inkflow {

struct Paths {
  std::string shared;
  std::string cache;
  std::string context_index;
  std::string user;
};

using Env = std::function<const char*(const char*)>;
using Exists = std::function<bool(const std::string&)>;

inline std::string env_or(const Env& env, const char* name, const std::string& fallback) {
  const char* value = env(name);
  return value && *value ? value : fallback;
}

inline std::vector<std::string> split(const std::string& text, char separator) {
  std::vector<std::string> parts;
  std::string::size_type start = 0;
  while (start <= text.size()) {
    auto end = text.find(separator, start);
    if (end == std::string::npos) end = text.size();
    if (end > start) parts.push_back(text.substr(start, end - start));
    start = end + 1;
  }
  return parts;
}

// Resources: INKFLOW_RESOURCES (a prepared directory holding shared/ and prepared/cache/),
// otherwise the first <dir>/inkflow/rime of XDG_DATA_HOME then XDG_DATA_DIRS that holds
// shared/. User data: XDG_DATA_HOME/inkflow/rime. Empty strings mean "not found".
inline Paths resolve_paths(const Env& env, const Exists& exists) {
  Paths paths;
  std::string home = env_or(env, "HOME", "");
  std::string data_home = env_or(env, "XDG_DATA_HOME", home + "/.local/share");
  paths.user = data_home + "/inkflow/rime";
  std::vector<std::string> roots;
  std::string override = env_or(env, "INKFLOW_RESOURCES", "");
  if (!override.empty()) roots.push_back(override);
  roots.push_back(data_home + "/inkflow/rime");
  for (const auto& dir : split(env_or(env, "XDG_DATA_DIRS", "/usr/local/share:/usr/share"), ':')) {
    roots.push_back(dir + "/inkflow/rime");
  }
  for (const auto& root : roots) {
    if (!exists(root + "/shared") || !exists(root + "/prepared/complete")) continue;
    paths.shared = root + "/shared";
    paths.cache = root + "/prepared/cache";
    paths.context_index = paths.shared + "/pinyin_simp.context.bin";
    break;
  }
  return paths;
}

struct PreeditSegment {
  std::string text;
  bool highlighted;
};

struct PreeditLayout {
  std::vector<PreeditSegment> segments;
  std::size_t cursor;
};

// Offsets are UTF-8 bytes of `preedit` on character boundaries (the ABI guarantees it);
// anything inconsistent collapses to an unhighlighted preedit with the caret at its end.
inline PreeditLayout preedit_layout(const std::string& preedit, std::size_t caret,
                                    std::size_t selection_start, std::size_t selection_end) {
  PreeditLayout layout{{}, preedit.size()};
  bool valid = caret <= preedit.size() && selection_start <= selection_end &&
               selection_end <= preedit.size();
  if (!valid) {
    if (!preedit.empty()) layout.segments.push_back({preedit, false});
    return layout;
  }
  layout.cursor = caret;
  if (selection_start > 0) layout.segments.push_back({preedit.substr(0, selection_start), false});
  if (selection_end > selection_start) {
    layout.segments.push_back({preedit.substr(selection_start, selection_end - selection_start), true});
  }
  if (selection_end < preedit.size()) layout.segments.push_back({preedit.substr(selection_end), false});
  return layout;
}

// Fcitx5 KeyState bits that Rime understands, as Rime masks. Super (Mod4) and GTK's
// virtual Super both become Rime's Super mask; a release adds Rime's release mask.
inline std::uint32_t rime_modifiers(std::uint32_t fcitx_states, bool release) {
  const std::uint32_t shift = 1u << 0, lock = 1u << 1, control = 1u << 2, alt = 1u << 3;
  const std::uint32_t super = 1u << 6, super2 = 1u << 26;
  std::uint32_t mask = fcitx_states & (shift | lock | control | alt);
  if (fcitx_states & (super | super2)) mask |= 1u << 26;
  if (release) mask |= 1u << 30;
  return mask;
}

inline std::size_t utf8_sequence_length(unsigned char lead) {
  if (lead < 0x80) return 1;
  if ((lead & 0xE0) == 0xC0) return 2;
  if ((lead & 0xF0) == 0xE0) return 3;
  if ((lead & 0xF8) == 0xF0) return 4;
  return 0;
}

// Byte offsets of each code point start plus the end; empty when the text is not UTF-8.
inline std::vector<std::size_t> code_point_offsets(const std::string& text) {
  std::vector<std::size_t> offsets;
  std::size_t index = 0;
  while (index < text.size()) {
    offsets.push_back(index);
    std::size_t length = utf8_sequence_length(static_cast<unsigned char>(text[index]));
    if (length == 0 || index + length > text.size()) return {};
    for (std::size_t i = 1; i < length; ++i) {
      if ((static_cast<unsigned char>(text[index + i]) & 0xC0) != 0x80) return {};
    }
    index += length;
  }
  offsets.push_back(text.size());
  return offsets;
}

// The last `limit` code points before `cursor` (a code-point index, as Fcitx5 reports it).
// Invalid UTF-8 or an out-of-range cursor yields no context rather than wrong context.
inline std::string preceding_text(const std::string& text, std::size_t cursor, std::size_t limit) {
  auto offsets = code_point_offsets(text);
  if (offsets.empty() || cursor + 1 > offsets.size()) return "";
  std::size_t first = cursor > limit ? cursor - limit : 0;
  return text.substr(offsets[first], offsets[cursor] - offsets[first]);
}

}  // namespace inkflow
#endif
