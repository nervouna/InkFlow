#include "engine.h"

#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/surroundingtext.h>
#include <fcitx/userinterface.h>
#include <sys/stat.h>

#include <cstdlib>

#include "bridge.h"

namespace inkflow {

FCITX_DEFINE_LOG_CATEGORY(inkflow_log, "inkflow");

namespace {
// The engine keeps 16 graphemes; a few more code points cover combining sequences.
constexpr std::size_t kPrecedingCodePoints = 32;

bool directory_exists(const std::string& path) {
  struct stat info{};
  return ::stat(path.c_str(), &info) == 0;
}
}  // namespace

Engine::Engine(fcitx::Instance* instance)
    : instance_(instance), factory_([this](fcitx::InputContext&) {
        auto* state = new State;
        if (!engine_) return state;
        IFRStatus status = ifr_session_create(engine_, &state->session);
        if (status != IFR_OK) {
          INKFLOW_WARN() << "session create failed: " << status << " " << ifr_last_error();
          state->session = nullptr;
          return state;
        }
        uint32_t options = ifr_input_options_default();
        ifr_session_set_configuration(state->session, 5, nullptr, 0, &options);
        if (const char* error = ifr_session_configuration_error(state->session)) {
          INKFLOW_WARN() << "configuration error: " << error;
        }
        return state;
      }) {
  Paths paths = resolve_paths([](const char* name) { return std::getenv(name); }, directory_exists);
  if (paths.shared.empty()) {
    INKFLOW_WARN() << "no prepared resources under XDG data directories; keys pass through";
  } else {
    IFREngineConfig config = {paths.shared.c_str(), paths.user.c_str(), paths.cache.c_str(),
                              paths.context_index.c_str()};
    IFRStatus status = ifr_engine_create(&config, &engine_);
    if (status != IFR_OK) {
      INKFLOW_WARN() << "engine create failed: " << status << " " << ifr_last_error();
      engine_ = nullptr;
    } else {
      INKFLOW_INFO() << "engine ready: " << paths.shared << " user " << paths.user;
    }
  }
  instance_->inputContextManager().registerProperty("inkflowState", &factory_);
}

Engine::~Engine() {
  // The factory unregisters itself and destroys every session after this body; the
  // last of those references finalizes Rime.
  ifr_engine_destroy(engine_);
}

State* Engine::state(fcitx::InputContext* ic) { return ic->propertyFor(&factory_); }

bool Engine::sensitive(const fcitx::InputContext* ic) const {
  return ic->capabilityFlags().testAny(
      fcitx::CapabilityFlags{fcitx::CapabilityFlag::Password, fcitx::CapabilityFlag::Sensitive});
}

void Engine::failed(fcitx::InputContext* ic, State* state, const char* what, IFRStatus status) {
  INKFLOW_WARN() << what << " failed: " << status << " " << ifr_last_error();
  clear(ic, state);
}

// Document context is captured only when a composition starts and only through the
// client's declared surrounding-text capability; anything else leaves native order.
void Engine::refreshContext(fcitx::InputContext* ic, State* state) {
  std::string preceding;
  if (!sensitive(ic) && ic->capabilityFlags().test(fcitx::CapabilityFlag::SurroundingText)) {
    const auto& surrounding = ic->surroundingText();
    if (surrounding.isValid()) {
      preceding = preceding_text(surrounding.text(), surrounding.cursor(), kPrecedingCodePoints);
    }
  }
  ifr_session_set_preceding_text(state->session, preceding.c_str());
}

void Engine::keyEvent(const fcitx::InputMethodEntry&, fcitx::KeyEvent& event) {
  auto* ic = event.inputContext();
  State* st = state(ic);
  if (!st->session) return;
  if (sensitive(ic)) {
    // Never compose or learn in password and sensitive fields; the client gets raw keys.
    if (st->composing()) clear(ic, st);
    return;
  }
  const fcitx::Key& key = event.rawKey();
  if (!st->composing()) refreshContext(ic, st);
  int handled = 0;
  IFRStatus status = ifr_session_key(st->session, static_cast<int32_t>(key.sym()),
                                     static_cast<int32_t>(rime_modifiers(key.states(), event.isRelease())),
                                     &handled);
  if (status != IFR_OK) {
    failed(ic, st, "key", status);
    return;
  }
  refresh(ic, st);
  if (handled) event.filterAndAccept();
}

void Engine::activate(const fcitx::InputMethodEntry&, fcitx::InputContextEvent& event) {
  State* st = state(event.inputContext());
  if (st->session) refresh(event.inputContext(), st);
}

void Engine::deactivate(const fcitx::InputMethodEntry& entry, fcitx::InputContextEvent& event) {
  auto* ic = event.inputContext();
  State* st = state(ic);
  // Switching input methods keeps what was typed, as the macOS frontend does on
  // deactivation; focus changes drop the composition because the target is gone.
  if (st->session && st->composing() &&
      event.type() == fcitx::EventType::InputContextSwitchInputMethod) {
    int handled = 0;
    IFRStatus status = ifr_session_commit(st->session, &handled);
    if (status != IFR_OK) {
      failed(ic, st, "commit", status);
      return;
    }
    refresh(ic, st);
  }
  reset(entry, event);
}

void Engine::reset(const fcitx::InputMethodEntry&, fcitx::InputContextEvent& event) {
  State* st = state(event.inputContext());
  if (st->session) clear(event.inputContext(), st);
}

void Engine::selectCandidate(fcitx::InputContext* ic, const SnapshotRef& snapshot, std::size_t index) {
  State* st = state(ic);
  if (!st->session) return;
  int handled = 0;
  IFRStatus status = ifr_session_select(st->session, snapshot.get(), index, &handled);
  if (status == IFR_STALE_SNAPSHOT || status == IFR_INVALID_CANDIDATE) {
    INKFLOW_INFO() << "ignored late candidate action: " << status;
    refresh(ic, st);
    return;
  }
  if (status != IFR_OK) {
    failed(ic, st, "select", status);
    return;
  }
  refresh(ic, st);
}

void Engine::changePage(fcitx::InputContext* ic, bool backward) {
  State* st = state(ic);
  if (!st->session) return;
  IFRStatus status = ifr_session_change_page(st->session, backward ? 1 : 0, nullptr);
  if (status != IFR_OK) {
    failed(ic, st, "page", status);
    return;
  }
  refresh(ic, st);
}

void Engine::moveHighlight(fcitx::InputContext* ic, bool backward) {
  State* st = state(ic);
  if (!st->session) return;
  IFRStatus status = ifr_session_key(st->session, backward ? 0xff52 : 0xff54, 0, nullptr);
  if (status != IFR_OK) {
    failed(ic, st, "highlight", status);
    return;
  }
  refresh(ic, st);
}

void Engine::refresh(fcitx::InputContext* ic, State* st) {
  char* commit = nullptr;
  IFRStatus status = ifr_session_take_commit(st->session, &commit);
  if (status != IFR_OK) {
    INKFLOW_WARN() << "take_commit failed: " << status << " " << ifr_last_error();
  } else if (commit) {
    ic->commitString(commit);
    ifr_string_free(commit);
  }
  IFRSnapshot* raw = nullptr;
  status = ifr_session_snapshot(st->session, &raw);
  auto& panel = ic->inputPanel();
  panel.reset();
  if (status != IFR_OK) {
    INKFLOW_WARN() << "snapshot failed: " << status << " " << ifr_last_error();
    st->snapshot.reset();
  } else {
    st->snapshot = SnapshotRef(raw, ifr_snapshot_free);
    const char* preedit = ifr_snapshot_preedit(raw);
    if (preedit && *preedit) {
      PreeditLayout layout = preedit_layout(preedit, ifr_snapshot_caret(raw),
                                            ifr_snapshot_selection_start(raw),
                                            ifr_snapshot_selection_end(raw));
      fcitx::Text text;
      for (const auto& segment : layout.segments) {
        fcitx::TextFormatFlags flags = fcitx::TextFormatFlag::Underline;
        if (segment.highlighted) flags |= fcitx::TextFormatFlag::HighLight;
        text.append(segment.text, flags);
      }
      text.setCursor(static_cast<int>(layout.cursor));
      if (ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit)) {
        panel.setClientPreedit(text);
      } else {
        panel.setPreedit(text);
      }
    }
    if (ifr_snapshot_candidate_count(raw) > 0) {
      panel.setCandidateList(std::make_unique<CandidateList>(this, ic, st->snapshot));
    }
  }
  ic->updatePreedit();
  ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void Engine::clear(fcitx::InputContext* ic, State* st) {
  IFRStatus status = ifr_session_clear(st->session);
  if (status != IFR_OK) {
    INKFLOW_WARN() << "clear failed: " << status << " " << ifr_last_error();
  }
  refresh(ic, st);
}

}  // namespace inkflow

#ifdef FCITX_ADDON_FACTORY_V2
FCITX_ADDON_FACTORY_V2(inkflow, inkflow::Factory);
#else
FCITX_ADDON_FACTORY(inkflow::Factory);
#endif
