#include "quality.h"

#include <fcitx-utils/log.h>
#include <fcitx-utils/utf8.h>
#include <dlfcn.h>

#include <algorithm>
#include <chrono>
#include <filesystem>

namespace inkflow {
namespace {
#include "quality_unicode.inc"

ScalarKind kind(uint32_t scalar) {
  auto range = std::lower_bound(std::begin(scalarRanges), std::end(scalarRanges), scalar,
                                [](const auto& entry, uint32_t value) { return entry.last < value; });
  return range == std::end(scalarRanges) ? ScalarKind::Other : range->kind;
}

// Matches QualityTextKind.classify; the input snapshot contains validated UTF-8.
uint8_t chineseLength(std::string_view candidate) {
  bool han = false;
  uint8_t length = 0;
  for (uint32_t c : fcitx::utf8::MakeUTF8CharRange(candidate)) {
    if ((c >= 0x3400 && c <= 0x9fff) || (c >= 0x20000 && c <= 0x323af)) {
      han = true;
    } else if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || kind(c) == ScalarKind::Emoji) {
      return 0;
    }
    if (length < 3) ++length;
  }
  return han ? length : 0;
}

bool symbol(std::string_view text) {
  for (uint32_t c : fcitx::utf8::MakeUTF8CharRange(text)) {
    if (kind(c) != ScalarKind::Symbol) return false;
  }
  return !text.empty();
}

std::string_view view(const char* value) {
  return value ? std::string_view(value) : std::string_view();
}

std::string_view prefix(const IFRSnapshot* snapshot) {
  return view(ifr_snapshot_preedit(snapshot)).substr(0, ifr_snapshot_selection_start(snapshot));
}

bool equalsParts(std::string_view whole, std::string_view left, std::string_view right) {
  return whole.size() == left.size() + right.size() && whole.starts_with(left) && whole.ends_with(right);
}
}  // namespace

QualityWriter::QualityWriter(std::string directory)
    : worker_([this, directory = std::move(directory)] {
        try {
          run(directory);
        } catch (const std::exception&) {
          FCITX_WARN() << "InkFlow local quality writer unavailable";
        }
        accepting_.store(false, std::memory_order_release);
      }) {}

QualityWriter::~QualityWriter() {
  stopping_.store(true, std::memory_order_release);
  wake_.release();
  worker_.join();
}

void QualityWriter::submit(std::span<const QualityDecision> decisions) {
  // Fcitx5's event loop is the only producer. It never waits for the writer.
  if (decisions.empty() || !accepting_.load(std::memory_order_acquire)) return;
  const unsigned end = written_.load(std::memory_order_relaxed);
  if (decisions.size() > capacity - (end - read_.load(std::memory_order_acquire))) return;
  unsigned next = end;
  for (const auto& decision : decisions) {
    queue_[next++ % capacity] = decision;
  }
  written_.store(next, std::memory_order_release);
  wake_.release(decisions.size());
}

void QualityWriter::run(const std::string& directory) {
  // No dlopen, SQLite or timezone setup competes with the first candidate.
  wake_.acquire();
  if (!written_.load(std::memory_order_acquire)) return;
  Dl_info info{};
  if (!dladdr(reinterpret_cast<const void*>(&view), &info)) return;
  auto library = std::filesystem::path(info.dli_fname).parent_path() / "libinkflow-quality.so";
  auto closeModule = [](void* handle) { dlclose(handle); };
  std::unique_ptr<void, decltype(closeModule)> module(dlopen(library.c_str(), RTLD_NOW | RTLD_LOCAL), closeModule);
  using Open = QualityBackend* (*)(const char*);
  auto open = module ? reinterpret_cast<Open>(dlsym(module.get(), "inkflow_quality_open")) : nullptr;
  std::unique_ptr<QualityBackend> backend(open ? open(directory.c_str()) : nullptr);
  if (!backend) {
    FCITX_WARN() << "InkFlow local quality storage unavailable";
    return;
  }
  unsigned head = 0;
  for (;;) {
    std::array<QualityDecision, 64> batch;
    std::size_t n = 0;
    // Coalesce bursts of selections into one transaction. A pause/shutdown
    // posts an extra wake so queued decisions drain without waiting out the timer.
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(40);
    do {
      if (head == written_.load(std::memory_order_acquire)) break;
      batch[n++] = queue_[head++ % capacity];
    } while (n < batch.size() && wake_.try_acquire_until(deadline));
    read_.store(head, std::memory_order_release);
    if (n && !backend->write(std::span(batch).first(n))) {
      FCITX_WARN() << "InkFlow local quality storage write failed";
      return;
    }
    if (stopping_.load(std::memory_order_acquire) && head == written_.load(std::memory_order_acquire)) return;
    wake_.acquire();
  }
}

void QualityComposition::begin(bool context) {
  count_ = 0;
  started_ = std::time(nullptr);
  context_ = context;
}

void QualityComposition::reset() {
  started_ = 0;
  count_ = 0;
}

void QualityComposition::observe(QualityWriter& writer, const IFRSnapshot* before, const IFRSnapshot* after,
                                 const char* commit, std::optional<QualityChoice> choice) {
  if (!started_) return;
  if (!after) {
    reset();
    return;
  }
  const auto nextInput = view(ifr_snapshot_input(after));
  if (!before || (!choice && !count_)) {
    if (nextInput.empty()) reset();
    return;
  }
  const auto oldPrefix = prefix(before);
  const auto nextPrefix = prefix(after);
  const auto oldInput = view(ifr_snapshot_input(before));
  std::string_view chosen;
  const int page = ifr_snapshot_page(before);
  if (choice && choice->pageSize >= 3 && choice->pageSize <= 9 && page >= 0 &&
      choice->index < ifr_snapshot_candidate_count(before) && choice->index < choice->pageSize) {
    chosen = view(ifr_snapshot_candidate_text(before, choice->index));
  }
  if (!chosen.empty()) {
    const bool punctuation = choice->punctuation;
    const auto length = punctuation ? 0 : chineseLength(chosen);
    if (length && count_ == maxSegments) {
      reset();
      return;
    }
    if (length) {
      const auto bin = page > 0 ? RankBin::Paged : choice->index == 0 ? RankBin::First :
                       choice->index < 3 ? RankBin::TopThreeOther : RankBin::FirstPageOther;
      QualityDecision decision{started_, static_cast<uint8_t>(length), static_cast<uint8_t>(choice->pageSize),
                               context_, bin};
      segments_[count_++] = {decision, oldPrefix.size() + chosen.size()};
    }
    if (!nextInput.empty() && oldInput == nextInput && equalsParts(nextPrefix, oldPrefix, chosen) && !punctuation) {
      return;
    }
    auto delivered = view(commit);
    // The punctuation itself is excluded. Earlier segment choices are proven only
    // if the commit consists of the exact selected prefix, candidate and optional punctuation.
    if (punctuation && delivered.starts_with(oldPrefix)) {
      auto tail = delivered.substr(oldPrefix.size());
      if (tail.starts_with(chosen)) {
        auto suffix = tail.substr(chosen.size());
        if (symbol(suffix)) delivered = delivered.substr(0, oldPrefix.size() + chosen.size());
      }
    }
    if (nextInput.empty() && equalsParts(delivered, oldPrefix, chosen)) {
      std::array<QualityDecision, maxSegments> decisions;
      for (std::size_t i = 0; i < count_; ++i) decisions[i] = segments_[i].decision;
      writer.submit(std::span(decisions).first(count_));
    }
    if (!nextInput.empty() && punctuation && oldInput == nextInput && oldPrefix == nextPrefix) return;
    count_ = 0;
  } else if (!nextInput.empty() && count_) {
    if (oldInput == nextInput && oldPrefix.starts_with(nextPrefix)) {
      while (count_ && segments_[count_ - 1].prefixBytes > nextPrefix.size()) --count_;
      if (nextPrefix != oldPrefix || ifr_snapshot_raw_caret(before) == ifr_snapshot_raw_caret(after)) return;
    }
    count_ = 0;
  }
  if (nextInput.empty()) reset();
}

}  // namespace inkflow
