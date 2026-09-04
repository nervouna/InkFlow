#ifndef INKFLOW_LIBRIME_BACKEND_HPP_
#define INKFLOW_LIBRIME_BACKEND_HPP_

#include <inkflow/engine.h>

#include <rime_api.h>

#include <memory>

struct InkFlowRuntime;
struct InkFlowSnapshot;

namespace inkflow {

class RimeBackend {
 public:
  RimeBackend() = default;
  ~RimeBackend();

  RimeBackend(const RimeBackend&) = delete;
  RimeBackend& operator=(const RimeBackend&) = delete;

  InkFlowStatus initialize(const InkFlowRuntime& runtime);
  InkFlowStatus prepare(const InkFlowRuntime& runtime);
  void finalize() noexcept;

  InkFlowStatus create_session(const char* schema_id, RimeSessionId* out_id);
  InkFlowStatus destroy_session(RimeSessionId id);
  InkFlowStatus process_key(RimeSessionId id,
                            int keycode,
                            int modifiers,
                            bool* handled);
  InkFlowStatus commit_composition(RimeSessionId id, bool* handled);
  InkFlowStatus clear_composition(RimeSessionId id);
  InkFlowStatus select_candidate(RimeSessionId id,
                                 size_t index,
                                 bool* handled);
  InkFlowStatus delete_candidate(RimeSessionId id,
                                 size_t index,
                                 bool* handled);
  InkFlowStatus change_page(RimeSessionId id, bool backward, bool* handled);
  InkFlowStatus snapshot(RimeSessionId id,
                         bool handled,
                         std::unique_ptr<InkFlowSnapshot>* out_snapshot);

 private:
  InkFlowStatus validate_candidate_index(RimeSessionId id, size_t index);

  RimeApi* api_ = nullptr;
  bool initialized_ = false;
};

}  // namespace inkflow

#endif  // INKFLOW_LIBRIME_BACKEND_HPP_
