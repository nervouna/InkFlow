#include "engine_internal.hpp"

extern "C" void inkflow_snapshot_destroy(InkFlowSnapshot* snapshot) {
  delete snapshot;
}

extern "C" int inkflow_snapshot_handled(const InkFlowSnapshot* snapshot) {
  return snapshot != nullptr && snapshot->handled;
}

extern "C" const char* inkflow_snapshot_commit_text(
    const InkFlowSnapshot* snapshot) {
  if (snapshot == nullptr || !snapshot->commit_text.has_value()) {
    return nullptr;
  }
  return snapshot->commit_text->c_str();
}

extern "C" const char* inkflow_snapshot_preedit(
    const InkFlowSnapshot* snapshot) {
  return snapshot == nullptr ? "" : snapshot->preedit.c_str();
}

extern "C" size_t inkflow_snapshot_preedit_cursor_byte_offset(
    const InkFlowSnapshot* snapshot) {
  return snapshot == nullptr ? 0 : snapshot->cursor_byte_offset;
}

extern "C" size_t inkflow_snapshot_preedit_selection_start_byte_offset(
    const InkFlowSnapshot* snapshot) {
  return snapshot == nullptr ? 0 : snapshot->selection_start_byte_offset;
}

extern "C" size_t inkflow_snapshot_preedit_selection_end_byte_offset(
    const InkFlowSnapshot* snapshot) {
  return snapshot == nullptr ? 0 : snapshot->selection_end_byte_offset;
}

extern "C" size_t inkflow_snapshot_candidate_count(
    const InkFlowSnapshot* snapshot) {
  return snapshot == nullptr ? 0 : snapshot->candidates.size();
}

extern "C" size_t inkflow_snapshot_highlighted_candidate_index(
    const InkFlowSnapshot* snapshot) {
  return snapshot == nullptr ? INKFLOW_NO_CANDIDATE
                             : snapshot->highlighted_candidate_index;
}

extern "C" int inkflow_snapshot_has_previous_page(
    const InkFlowSnapshot* snapshot) {
  return snapshot != nullptr && snapshot->has_previous_page;
}

extern "C" int inkflow_snapshot_has_next_page(
    const InkFlowSnapshot* snapshot) {
  return snapshot != nullptr && snapshot->has_next_page;
}

extern "C" const char* inkflow_snapshot_candidate_text(
    const InkFlowSnapshot* snapshot,
    size_t index) {
  if (snapshot == nullptr || index >= snapshot->candidates.size()) {
    return nullptr;
  }
  return snapshot->candidates[index].text.c_str();
}

extern "C" const char* inkflow_snapshot_candidate_comment(
    const InkFlowSnapshot* snapshot,
    size_t index) {
  if (snapshot == nullptr || index >= snapshot->candidates.size() ||
      !snapshot->candidates[index].comment.has_value()) {
    return nullptr;
  }
  return snapshot->candidates[index].comment->c_str();
}
