// Fcitx5 candidate list over one engine snapshot. Navigation goes back through the
// engine, which rebuilds the panel; every selection carries the snapshot it was shown
// from so a late click on a superseded page is rejected by the engine.
#ifndef INKFLOW_FCITX5_CANDIDATES_H
#define INKFLOW_FCITX5_CANDIDATES_H
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/text.h>
#include <memory>
#include <vector>

#include "inkflow_rime.h"

namespace inkflow {

class Engine;
using SnapshotRef = std::shared_ptr<IFRSnapshot>;

class Candidate final : public fcitx::CandidateWord {
public:
  Candidate(Engine* engine, SnapshotRef snapshot, std::size_t index);
  void select(fcitx::InputContext* ic) const override;

private:
  Engine* engine_;
  SnapshotRef snapshot_;
  std::size_t index_;
};

class CandidateList final : public fcitx::CandidateList,
                            public fcitx::PageableCandidateList,
                            public fcitx::CursorMovableCandidateList {
public:
  CandidateList(Engine* engine, fcitx::InputContext* ic, SnapshotRef snapshot);
  const fcitx::Text& label(int index) const override;
  const fcitx::CandidateWord& candidate(int index) const override;
  int size() const override;
  int cursorIndex() const override;
  fcitx::CandidateLayoutHint layoutHint() const override;
  bool hasPrev() const override;
  bool hasNext() const override;
  void prev() override;
  void next() override;
  bool usedNextBefore() const override;
  void prevCandidate() override;
  void nextCandidate() override;

private:
  Engine* engine_;
  fcitx::InputContext* ic_;
  SnapshotRef snapshot_;
  std::vector<fcitx::Text> labels_;
  std::vector<std::unique_ptr<Candidate>> words_;
};

}  // namespace inkflow
#endif
