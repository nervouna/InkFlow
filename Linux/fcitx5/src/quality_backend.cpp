// Loaded only by the optional recording worker. SQLite never runs on the input thread.
#include "quality.h"

#include <sqlite3.h>
#include <unicode/uchar.h>
#include <unicode/utf8.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <filesystem>

namespace inkflow {
namespace {
class Backend final : public QualityBackend {
public:
  ~Backend() override {
    sqlite3_finalize(upsert_);
    sqlite3_close(db_);
  }

  bool open(const std::filesystem::path& directory) {
    // Warm ICU property data here too: classification of an eligible selection
    // on the Fcitx event loop must only consult already initialized tables.
    volatile auto emoji = u_hasBinaryProperty(0x1f600, UCHAR_EMOJI_PRESENTATION);
    (void)emoji;
    std::filesystem::create_directories(directory.parent_path());
    if (mkdir(directory.c_str(), 0700) != 0 && errno != EEXIST) return false;
    auto file = directory / "counts.sqlite3";
    int fd = ::open(file.c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    close(fd);
    if (sqlite3_open_v2(file.c_str(), &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nullptr) != SQLITE_OK) {
      return false;
    }
    sqlite3_busy_timeout(db_, 500);
    if (!exec("CREATE TABLE IF NOT EXISTS counts_v1 (day TEXT NOT NULL, length INTEGER NOT NULL,"
              " context INTEGER NOT NULL, page_size INTEGER NOT NULL, rank_bin INTEGER NOT NULL,"
              " n INTEGER NOT NULL, PRIMARY KEY(day,length,context,page_size,rank_bin)) WITHOUT ROWID")) return false;
    const char* sql = "INSERT INTO counts_v1 VALUES(date(?1,'unixepoch','localtime'),?2,?3,?4,?5,1)"
                      " ON CONFLICT(day,length,context,page_size,rank_bin) DO UPDATE SET n=n+1";
    if (!exec("DELETE FROM counts_v1 WHERE day < date('now','localtime','-27 days')")) return false;
    return sqlite3_prepare_v2(db_, sql, -1, &upsert_, nullptr) == SQLITE_OK;
  }

  // Same Unicode scalar ranges and Emoji_Presentation precedence as QualityTextKind.classify.
  uint8_t chineseLength(std::string_view candidate) const noexcept override {
    bool han = false;
    uint8_t length = 0;
    const auto size = static_cast<int32_t>(candidate.size());
    for (int32_t index = 0; index < size;) {
      UChar32 scalar;
      U8_NEXT(reinterpret_cast<const uint8_t*>(candidate.data()), index, size, scalar);
      if (scalar < 0 || (scalar >= 'A' && scalar <= 'Z') || (scalar >= 'a' && scalar <= 'z') ||
          scalar == 0xfe0f || scalar == 0x20e3 || u_hasBinaryProperty(scalar, UCHAR_EMOJI_PRESENTATION)) return 0;
      han |= (scalar >= 0x3400 && scalar <= 0x9fff) || (scalar >= 0x20000 && scalar <= 0x323af);
      if (length < 3) ++length;
    }
    return han ? length : 0;
  }

  bool symbol(std::string_view text) const noexcept override {
    for (int32_t index = 0; index < static_cast<int32_t>(text.size());) {
      UChar32 scalar;
      U8_NEXT(reinterpret_cast<const uint8_t*>(text.data()), index, static_cast<int32_t>(text.size()), scalar);
      if (scalar < 0 || (!(U_GET_GC_MASK(scalar) & (U_GC_P_MASK | U_GC_S_MASK)) && !u_isUWhiteSpace(scalar))) {
        return false;
      }
      if (scalar == 0xfe0f || scalar == 0x20e3 || u_hasBinaryProperty(scalar, UCHAR_EMOJI_PRESENTATION)) return false;
    }
    return !text.empty();
  }

  bool write(std::span<const QualityDecision> batch) override {
    if (!exec("BEGIN IMMEDIATE")) return false;
    for (const auto& decision : batch) {
      sqlite3_bind_int64(upsert_, 1, decision.started);
      sqlite3_bind_int(upsert_, 2, decision.length);
      sqlite3_bind_int(upsert_, 3, decision.context);
      sqlite3_bind_int(upsert_, 4, decision.pageSize);
      sqlite3_bind_int(upsert_, 5, static_cast<int>(decision.bin));
      int result = sqlite3_step(upsert_);
      sqlite3_reset(upsert_);
      if (result != SQLITE_DONE) {
        exec("ROLLBACK");
        return false;
      }
    }
    if (exec("DELETE FROM counts_v1 WHERE day < date('now','localtime','-27 days')") && exec("COMMIT")) return true;
    exec("ROLLBACK");
    return false;
  }

private:
  bool exec(const char* sql) { return sqlite3_exec(db_, sql, nullptr, nullptr, nullptr) == SQLITE_OK; }
  sqlite3* db_ = nullptr;
  sqlite3_stmt* upsert_ = nullptr;
};
}  // namespace

extern "C" __attribute__((visibility("default"))) QualityBackend* inkflow_quality_open(const char* directory) {
  auto backend = std::make_unique<Backend>();
  return backend->open(directory) ? backend.release() : nullptr;
}
}  // namespace inkflow
