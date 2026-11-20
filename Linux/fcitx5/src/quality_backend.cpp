// Loaded only by the optional recording worker. SQLite never runs on the input thread.
#include "quality.h"

#include <sqlite3.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <filesystem>

namespace inkflow {
namespace {
class Backend final : public QualityBackend {
public:
  explicit Backend(const char* directory) : directory_(directory) {}

  ~Backend() override {
    sqlite3_finalize(upsert_);
    sqlite3_close(db_);
  }

  bool open() {
    std::filesystem::create_directories(directory_.parent_path());
    if (mkdir(directory_.c_str(), 0700) != 0 && errno != EEXIST) return false;
    auto file = directory_ / "counts.sqlite3";
    int fd = ::open(file.c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    struct stat info{};
    const bool privateFile = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && fchmod(fd, 0600) == 0;
    close(fd);
    if (!privateFile) return false;
    if (sqlite3_open_v2(file.c_str(), &db_, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nullptr) != SQLITE_OK) {
      return false;
    }
    sqlite3_busy_timeout(db_, 500);
    if (!exec("CREATE TABLE IF NOT EXISTS counts_v1 (day TEXT NOT NULL, length INTEGER NOT NULL,"
              " context INTEGER NOT NULL, page_size INTEGER NOT NULL, rank_bin INTEGER NOT NULL,"
              " n INTEGER NOT NULL, PRIMARY KEY(day,length,context,page_size,rank_bin)) WITHOUT ROWID")) return false;
    const char* sql = "INSERT INTO counts_v1 VALUES(date(?1,'unixepoch','localtime'),?2,?3,?4,?5,1)"
                      " ON CONFLICT(day,length,context,page_size,rank_bin) DO UPDATE SET n=n+1";
    return sqlite3_prepare_v2(db_, sql, -1, &upsert_, nullptr) == SQLITE_OK;
  }

  bool write(std::span<const QualityDecision> batch) override {
    if (!db_ && !open()) return false;
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
  std::filesystem::path directory_;
  sqlite3* db_ = nullptr;
  sqlite3_stmt* upsert_ = nullptr;
};
}  // namespace

extern "C" __attribute__((visibility("default"))) QualityBackend* inkflow_quality_open(const char* directory) {
  return new Backend(directory);
}
}  // namespace inkflow
