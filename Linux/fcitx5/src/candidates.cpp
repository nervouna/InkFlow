#include "candidates.h"

#include "engine.h"

namespace inkflow {

Candidate::Candidate(Engine* engine, SnapshotRef snapshot, std::size_t index)
    : fcitx::CandidateWord(fcitx::Text(ifr_snapshot_candidate_text(snapshot.get(), index))),
      engine_(engine), snapshot_(std::move(snapshot)), index_(index) {
  const char* comment = ifr_snapshot_candidate_comment(snapshot_.get(), index_);
  if (comment && *comment) setComment(fcitx::Text(comment));
}

void Candidate::select(fcitx::InputContext* ic) const {
  engine_->selectCandidate(ic, snapshot_, index_);
}

CandidateList::CandidateList(Engine* engine, fcitx::InputContext* ic, SnapshotRef snapshot)
    : engine_(engine), ic_(ic), snapshot_(std::move(snapshot)) {
  setPageable(this);
  setCursorMovable(this);
  std::size_t count = ifr_snapshot_candidate_count(snapshot_.get());
  for (std::size_t index = 0; index < count; ++index) {
    labels_.emplace_back(std::to_string(index + 1) + ". ");
    words_.push_back(std::make_unique<Candidate>(engine_, snapshot_, index));
  }
}

const fcitx::Text& CandidateList::label(int index) const { return labels_.at(index); }
const fcitx::CandidateWord& CandidateList::candidate(int index) const { return *words_.at(index); }
int CandidateList::size() const { return static_cast<int>(words_.size()); }
int CandidateList::cursorIndex() const {
  return static_cast<int>(ifr_snapshot_highlighted(snapshot_.get()));
}
fcitx::CandidateLayoutHint CandidateList::layoutHint() const {
  return fcitx::CandidateLayoutHint::Horizontal;
}
bool CandidateList::hasPrev() const { return ifr_snapshot_page(snapshot_.get()) > 0; }
bool CandidateList::hasNext() const { return !ifr_snapshot_last_page(snapshot_.get()); }
bool CandidateList::usedNextBefore() const { return false; }

// Each navigation call ends by asking the engine to rebuild the panel, which destroys
// this list; nothing of it is touched afterwards.
void CandidateList::prev() {
  Engine* engine = engine_;
  fcitx::InputContext* ic = ic_;
  engine->changePage(ic, true);
}
void CandidateList::next() {
  Engine* engine = engine_;
  fcitx::InputContext* ic = ic_;
  engine->changePage(ic, false);
}
void CandidateList::prevCandidate() {
  Engine* engine = engine_;
  fcitx::InputContext* ic = ic_;
  engine->moveHighlight(ic, true);
}
void CandidateList::nextCandidate() {
  Engine* engine = engine_;
  fcitx::InputContext* ic = ic_;
  engine->moveHighlight(ic, false);
}

}  // namespace inkflow
