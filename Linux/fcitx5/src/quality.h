// Local quality capture. Only bounded numeric decisions cross the writer queue.
#pragma once

#include "inkflow_rime.h"

#include <array>
#include <atomic>
#include <cstdint>
#include <ctime>
#include <memory>
#include <optional>
#include <semaphore>
#include <span>
#include <string>
#include <string_view>
#include <thread>

namespace inkflow {

enum class RankBin : uint8_t { First, TopThreeOther, FirstPageOther, Paged };

struct QualityDecision {
  std::time_t started;
  uint8_t length;
  uint8_t pageSize;
  bool context;
  RankBin bin;
};

// Loaded by the worker from the same installation as the addon. ICU and SQLite
// are optional at runtime; an unavailable writer leaves the offline engine alone.
class QualityBackend {
public:
  virtual ~QualityBackend() = default;
  virtual uint8_t chineseLength(std::string_view candidate) const noexcept = 0;
  virtual bool symbol(std::string_view text) const noexcept = 0;
  virtual bool write(std::span<const QualityDecision> decisions) = 0;
};

class QualityWriter {
public:
  explicit QualityWriter(std::string directory);
  ~QualityWriter();
  uint8_t chineseLength(std::string_view candidate) const;
  bool symbol(std::string_view text) const;
  void submit(std::span<const QualityDecision> decisions);

private:
  void run(const std::string& directory);
  static constexpr unsigned capacity = 1024;
  std::array<QualityDecision, capacity> queue_{};
  std::atomic<unsigned> read_{0};
  std::atomic<unsigned> written_{0};
  std::atomic<bool> stopping_{false};
  std::counting_semaphore<capacity + 1> wake_{0};
  std::atomic<const QualityBackend*> classifier_{nullptr};
  std::thread worker_;
};

struct QualityChoice {
  std::size_t index;
  std::size_t pageSize;
  bool punctuation = false;
};

class QualityComposition {
public:
  void begin(bool context);
  void reset();
  void observe(QualityWriter& writer, const IFRSnapshot* before, const IFRSnapshot* after, const char* commit,
               std::optional<QualityChoice> choice);

private:
  struct Segment {
    QualityDecision decision;
    std::size_t prefixBytes;
  };
  static constexpr std::size_t maxSegments = 64;
  std::array<Segment, maxSegments> segments_{};
  std::size_t count_ = 0;
  std::time_t started_ = 0;
  bool context_ = false;
};

}  // namespace inkflow
