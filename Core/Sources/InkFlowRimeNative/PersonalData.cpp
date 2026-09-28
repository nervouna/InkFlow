#include "InkFlowRimeNative.h"
#include <rime_api.h>
#include <rime/dict/user_db.h>
#include <filesystem>
#include <fstream>
#include <map>
#include <regex>
#include <cmath>
#include <stdexcept>

namespace {
using Rows = std::map<std::string, std::string>;
void check(bool value) { if (!value) throw std::runtime_error("personal-data-invalid"); }
Rows readRows(rime::Db* db, bool metadata) {
  Rows rows;
  auto cursor = metadata ? db->QueryMetadata() : db->QueryAll();
  check(bool(cursor));
  std::string key, value;
  size_t bytes = 0;
  while (cursor->GetNextRecord(&key, &value)) {
    bytes += key.size() + value.size() + 4;
    check(bytes <= 32 * 1024 * 1024 && key.size() + value.size() <= 65536 && rows.size() < 250000);
    check(rows.emplace(key, value).second);
  }
  return rows;
}
std::pair<Rows, Rows> parse(const std::string& file, const std::string& name) {
  check(std::filesystem::file_size(file) <= 32 * 1024 * 1024);
  std::ifstream stream(file, std::ios::binary);
  std::string bytes((std::istreambuf_iterator<char>(stream)), {});
  check(!stream.bad() && !bytes.empty() && bytes.back() == '\n');
  check(bytes.find('\0') == std::string::npos && bytes.find('\r') == std::string::npos);
  const std::string header = "# Rime user dictionary\n";
  check(bytes.compare(0, header.size(), header) == 0);
  Rows data, metadata;
  const std::regex packed("c=-?[0-9]+ d=-?[0-9]+(\\.[0-9]+)?([eE][+-]?[0-9]+)? t=[0-9]+");
  size_t offset = header.size(), count = 0;
  while (offset < bytes.size()) {
    auto end = bytes.find('\n', offset);
    auto line = bytes.substr(offset, end - offset);
    offset = end + 1;
    check(++count <= 250000 && line.size() <= 65536 && !line.empty());
    for (unsigned char c : line) check(c >= 32 || c == '\t');
    auto tab = line.find('\t');
    check(tab != std::string::npos);
    if (line.compare(0, 2, "#@") == 0) {
      check(tab > 2 && line.find('\t', tab + 1) == std::string::npos);
      auto key = line.substr(2, tab - 2), value = line.substr(tab + 1);
      check(value.empty() || value.back() != ' ');
      check(metadata.emplace(key, value).second);
    } else {
      check(line[0] != '#');
      auto next = line.find('\t', tab + 1);
      check(tab > 0 && line[tab - 1] == ' ' && next != std::string::npos && next > tab + 1);
      check(line.find('\t', next + 1) == std::string::npos);
      auto value = line.substr(next + 1);
      check(std::regex_match(value, packed));
      auto d = value.find(" d="), t = value.find(" t=");
      (void)std::stoi(value.substr(2, d - 2));
      check(std::isfinite(std::stod(value.substr(d + 3, t - d - 3))));
      (void)std::stoul(value.substr(t + 3));
      check(data.emplace(line.substr(0, next), value).second);
    }
  }
  check(metadata["/db_type"] == "userdb");
  auto identity = metadata["/db_name"];
  check(identity.find('/') == std::string::npos && identity.find('\\') == std::string::npos);
  auto extension = identity.rfind(".userdb");
  if (extension != std::string::npos) identity.erase(extension);
  check(identity == name && metadata.count("/rime_version") == 1);
  if (metadata.count("/tick")) {
    check(std::regex_match(metadata.at("/tick"), std::regex("[0-9]+")));
    (void)std::stoul(metadata.at("/tick"));
  }
  return {data, metadata};
}
}

// Called only by the isolated personal-data worker, with closed staged databases.
extern "C" int IFPersonalDataSnapshot(const char* root, const char* name, const char* file, int restore) {
  bool initialized = false;
  try {
    const std::string dictionary(name);
    check(dictionary == "pinyin_simp" || dictionary == "inkflow_shared_english" || dictionary == "inkflow_voice_alias");
    std::pair<Rows, Rows> expected;
    if (restore) expected = parse(file, dictionary);
    RimeTraits traits{}; traits.data_size = sizeof(RimeTraits) - sizeof(traits.data_size);
    traits.shared_data_dir = root; traits.user_data_dir = root;
    traits.staging_dir = root; traits.prebuilt_data_dir = root; traits.log_dir = root;
    traits.min_log_level = 4;
    auto api = rime_get_api(); api->setup(&traits); api->initialize(&traits); initialized = true;
    auto component = rime::UserDb::Require("userdb"); check(component != nullptr);
    {
      std::unique_ptr<rime::Db> db(component->Create(dictionary)); check(db->Open());
      if (restore) {
        check(rime::UserDbHelper(db.get()).UniformRestore(rime::path(file)));
        // TsvReader trims an empty metadata value's delimiter. The independently
        // validated map retains it; restore it explicitly before comparing all keys.
        for (const auto& entry : expected.second)
          if (entry.second.empty()) check(db->MetaUpdate(entry.first, entry.second));
      }
      else {
        expected = {readRows(db.get(), false), readRows(db.get(), true)};
        check(rime::UserDbHelper(db.get()).UniformBackup(rime::path(file)));
        check(parse(file, dictionary) == expected);
      }
      check(readRows(db.get(), false) == expected.first && readRows(db.get(), true) == expected.second);
      check(db->Close());
    }
    api->finalize(); return 0;
  } catch (...) { if (initialized) rime_get_api()->finalize(); return 1; }
}
