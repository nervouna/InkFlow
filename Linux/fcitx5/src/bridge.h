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

inline Paths resolve_paths(const Env& env, const Exists& exists) {
  Paths paths;
  std::string home = env_or(env, "HOME", "");
  std::string data_home = env_or(env, "XDG_DATA_HOME", home + "/.local/share");
  paths.user = data_home + "/inkflow/rime";
  std::vector<std::string> roots;
  std::string override = env_or(env, "INKFLOW_RESOURCES", "");
  if (!override.empty()) roots.push_back(override);
  roots.push_back(data_home + "/inkflow/current/share/inkflow/rime");
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

inline std::uint32_t rime_modifiers(std::uint32_t fcitx_states, bool release) {
  const std::uint32_t shift = 1u << 0, lock = 1u << 1, control = 1u << 2, alt = 1u << 3;
  const std::uint32_t super = 1u << 6, super2 = 1u << 26;
  std::uint32_t mask = fcitx_states & (shift | lock | control | alt);
  if (fcitx_states & (super | super2)) mask |= 1u << 26;
  if (release) mask |= 1u << 30;
  return mask;
}

struct ShiftToggle {
  bool armed = false;
  bool key(std::uint32_t keysym, std::uint32_t fcitx_states, bool release) {
    const std::uint32_t shift_l = 0xffe1;
    const std::uint32_t others = 1u << 2 | 1u << 3 | 1u << 6 | 1u << 26;
    if (keysym != shift_l || (fcitx_states & others)) {
      armed = false;
      return false;
    }
    if (!release) {
      armed = true;
      return false;
    }
    bool toggle = armed;
    armed = false;
    return toggle;
  }
};

inline std::size_t utf8_sequence_length(unsigned char lead) {
  if (lead < 0x80) return 1;
  if ((lead & 0xE0) == 0xC0) return 2;
  if ((lead & 0xF0) == 0xE0) return 3;
  if ((lead & 0xF8) == 0xF0) return 4;
  return 0;
}

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

inline std::string preceding_text(const std::string& text, std::size_t cursor, std::size_t limit) {
  auto offsets = code_point_offsets(text);
  if (offsets.empty() || cursor + 1 > offsets.size()) return "";
  std::size_t first = cursor > limit ? cursor - limit : 0;
  return text.substr(offsets[first], offsets[cursor] - offsets[first]);
}

inline bool parse_phrase(const std::string& entry, std::string& code, std::string& text) {
  auto separator = entry.find('=');
  if (separator == std::string::npos) return false;
  code = entry.substr(0, separator);
  text = entry.substr(separator + 1);
  return !code.empty() && !text.empty();
}

}
#endif
