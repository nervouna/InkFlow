#include "engine.h"

#include <fcitx-config/iniparser.h>
#include <fcitx-utils/capabilityflags.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/surroundingtext.h>
#include <fcitx/userinterface.h>
#include <sys/stat.h>

#include <cstdlib>
#include <fstream>
#include <iterator>
#include <utility>
#include <vector>

namespace inkflow {

FCITX_DEFINE_LOG_CATEGORY(inkflow_log, "inkflow");

namespace {
constexpr const char* kConfigFile = "conf/inkflow.conf";
// The engine keeps 16 graphemes; a few more code points cover combining sequences.
constexpr std::size_t kPrecedingCodePoints = 32;

bool directory_exists(const std::string& path) {
  struct stat info{};
  return ::stat(path.c_str(), &info) == 0;
}
}  // namespace

Engine::Engine(fcitx::Instance* instance)
    : instance_(instance),
      paths_(resolve_paths([](const char* name) { return std::getenv(name); }, directory_exists)),
      factory_([](fcitx::InputContext&) { return new State; }) {
  createEngine();
  instance_->inputContextManager().registerProperty("inkflowState", &factory_);
  reloadConfig();
}

Engine::~Engine() {
  // The factory unregisters itself and destroys every session after this body; the
  // last of those references finalizes Rime.
  ifr_engine_destroy(engine_);
}

void Engine::createEngine() {
  if (engine_) return;
  if (paths_.shared.empty()) {
    INKFLOW_WARN() << "no prepared resources under XDG data directories; keys pass through";
    return;
  }
  IFREngineConfig config = {paths_.shared.c_str(), paths_.user.c_str(), paths_.cache.c_str(),
                            paths_.context_index.c_str()};
  IFRStatus status = ifr_engine_create(&config, &engine_);
  if (status != IFR_OK) {
    INKFLOW_WARN() << "engine create failed: " << status << " " << ifr_last_error();
    engine_ = nullptr;
    return;
  }
  INKFLOW_INFO() << "engine ready: " << paths_.shared << " user " << paths_.user;
}

// Every session and the engine reference go, so Rime finalizes before this returns.
void Engine::destroyEngine() {
  instance_->inputContextManager().foreach([this](fcitx::InputContext* ic) {
    State* st = state(ic);
    if (st->session) {
      st->release();
      ic->inputPanel().reset();
      if (ic->hasFocus()) {
        ic->updatePreedit();
        ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
      }
    }
    return true;
  });
  ifr_engine_destroy(engine_);
  engine_ = nullptr;
}

State* Engine::state(fcitx::InputContext* ic) { return ic->propertyFor(&factory_); }

IFRSession* Engine::session(State* st) {
  if (st->session || !engine_) return st->session;
  IFRStatus status = ifr_session_create(engine_, &st->session);
  if (status != IFR_OK) {
    INKFLOW_WARN() << "session create failed: " << status << " " << ifr_last_error();
    st->session = nullptr;
    return nullptr;
  }
  applyConfiguration(st->session);
  return st->session;
}

uint32_t Engine::inputOptions() const {
  struct Bit {
    const fcitx::Option<bool>& option;
    uint32_t mask;
  };
  const Bit bits[] = {
      {config_.abbreviation, IFR_OPTION_ABBREVIATION},
      {config_.typoTolerance, IFR_OPTION_TYPO_TOLERANCE},
      {config_.fuzzyZ, IFR_OPTION_FUZZY_Z},
      {config_.fuzzyC, IFR_OPTION_FUZZY_C},
      {config_.fuzzyS, IFR_OPTION_FUZZY_S},
      {config_.emoji, IFR_OPTION_EMOJI},
      {config_.bracketPaging, IFR_OPTION_BRACKET_PAGING},
      {config_.minusEqualPaging, IFR_OPTION_MINUS_EQUAL_PAGING},
      {config_.englishPunctuation, IFR_OPTION_ENGLISH_PUNCTUATION},
      {config_.cornerQuotes, IFR_OPTION_CORNER_QUOTES},
      {config_.middleDot, IFR_OPTION_MIDDLE_DOT},
      {config_.fullwidthPipe, IFR_OPTION_FULLWIDTH_PIPE},
      {config_.ideographicComma, IFR_OPTION_IDEOGRAPHIC_COMMA},
      {config_.traditional, IFR_OPTION_TRADITIONAL},
  };
  uint32_t mask = 0;
  for (const Bit& bit : bits) {
    if (*bit.option) mask |= bit.mask;
  }
  return mask;
}

void Engine::applyConfiguration(IFRSession* session) {
  std::vector<std::string> strings;
  const auto& entries = *config_.customPhrases;
  strings.reserve(entries.size() * 3);
  std::vector<IFRPhrase> phrases;
  for (std::size_t index = 0; index < entries.size(); ++index) {
    std::string code, text;
    if (!parse_phrase(entries[index], code, text)) {
      INKFLOW_WARN() << "skipping custom phrase without code=text at index " << index;
      continue;
    }
    strings.push_back(std::to_string(index));
    strings.push_back(std::move(code));
    strings.push_back(std::move(text));
  }
  for (std::size_t i = 0; i + 2 < strings.size(); i += 3) {
    phrases.push_back({strings[i].c_str(), strings[i + 1].c_str(), strings[i + 2].c_str()});
  }
  uint32_t options = inputOptions();
  IFRStatus status = ifr_session_set_configuration(session, static_cast<std::size_t>(*config_.candidateCount),
                                                   phrases.data(), phrases.size(), &options);
  if (status != IFR_OK) {
    INKFLOW_WARN() << "set_configuration failed: " << status << " " << ifr_last_error();
  } else if (const char* error = ifr_session_configuration_error(session)) {
    INKFLOW_WARN() << "configuration not applied: " << error;
  }
}

void Engine::applyConfigurationToSessions() {
  instance_->inputContextManager().foreach([this](fcitx::InputContext* ic) {
    State* st = state(ic);
    if (st->session) applyConfiguration(st->session);
    return true;
  });
}

void Engine::saveConfig() { fcitx::safeSaveAsIni(config_, kConfigFile); }

void Engine::reloadConfig() {
  fcitx::readAsIni(config_, kConfigFile);
  if (!config_.importBackup->empty()) {
    importBackup(*config_.importBackup);
  }
  applyConfigurationToSessions();
}

void Engine::setConfig(const fcitx::RawConfig& raw) {
  config_.load(raw, true);
  saveConfig();
  if (!config_.importBackup->empty()) {
    importBackup(*config_.importBackup);
  }
  applyConfigurationToSessions();
}

void Engine::importBackup(std::string file) {
  // The request is consumed whatever happens, so a bad file cannot repeat on every reload.
  config_.importBackup.setValue(std::string());
  saveConfig();
  std::ifstream input(file, std::ios::binary);
  if (!input) {
    INKFLOW_WARN() << "backup not readable: " << file;
    return;
  }
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
  IFRBackup* backup = nullptr;
  IFRStatus status = ifr_backup_parse(bytes.data(), bytes.size(), &backup);
  if (status != IFR_OK) {
    INKFLOW_WARN() << "backup rejected: " << status << " " << ifr_last_error();
    return;
  }
  for (std::size_t i = 0; i < ifr_backup_unsupported_count(backup); ++i) {
    INKFLOW_INFO() << "backup preference not portable, skipped: " << ifr_backup_unsupported(backup, i);
  }
  destroyEngine();
  status = ifr_backup_import(backup, paths_.user.c_str());
  if (status == IFR_RECOVERY_REQUIRED) {
    INKFLOW_WARN() << "finishing an interrupted import first";
    if (ifr_personal_recover(paths_.user.c_str()) == IFR_OK) {
      status = ifr_backup_import(backup, paths_.user.c_str());
    }
  }
  if (status != IFR_OK) {
    INKFLOW_WARN() << "import failed, user data unchanged: " << status << " " << ifr_last_error();
  } else {
    config_.candidateCount.setValue(static_cast<int>(ifr_backup_candidate_count(backup)));
    uint32_t options = ifr_backup_input_options(backup);
    config_.abbreviation.setValue((options & IFR_OPTION_ABBREVIATION) != 0);
    config_.typoTolerance.setValue((options & IFR_OPTION_TYPO_TOLERANCE) != 0);
    config_.fuzzyZ.setValue((options & IFR_OPTION_FUZZY_Z) != 0);
    config_.fuzzyC.setValue((options & IFR_OPTION_FUZZY_C) != 0);
    config_.fuzzyS.setValue((options & IFR_OPTION_FUZZY_S) != 0);
    config_.emoji.setValue((options & IFR_OPTION_EMOJI) != 0);
    config_.bracketPaging.setValue((options & IFR_OPTION_BRACKET_PAGING) != 0);
    config_.minusEqualPaging.setValue((options & IFR_OPTION_MINUS_EQUAL_PAGING) != 0);
    config_.englishPunctuation.setValue((options & IFR_OPTION_ENGLISH_PUNCTUATION) != 0);
    config_.cornerQuotes.setValue((options & IFR_OPTION_CORNER_QUOTES) != 0);
    config_.middleDot.setValue((options & IFR_OPTION_MIDDLE_DOT) != 0);
    config_.fullwidthPipe.setValue((options & IFR_OPTION_FULLWIDTH_PIPE) != 0);
    config_.ideographicComma.setValue((options & IFR_OPTION_IDEOGRAPHIC_COMMA) != 0);
    config_.traditional.setValue((options & IFR_OPTION_TRADITIONAL) != 0);
    std::vector<std::string> entries;
    for (std::size_t i = 0; i < ifr_backup_phrase_count(backup); ++i) {
      IFRPhrase phrase = {nullptr, nullptr, nullptr};
      if (ifr_backup_phrase(backup, i, &phrase)) {
        entries.push_back(std::string(phrase.code) + "=" + phrase.text);
      }
    }
    config_.customPhrases.setValue(entries);
    saveConfig();
    INKFLOW_INFO() << "imported personal data from " << file;
  }
  ifr_backup_free(backup);
  createEngine();
}

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
  if (sensitive(ic)) {
    // Never compose or learn in password and sensitive fields; the client gets raw keys.
    if (st->session && st->composing()) clear(ic, st);
    return;
  }
  if (!session(st)) return;
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
  if (session(st)) refresh(event.inputContext(), st);
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
        fcitx::TextFormatFlags flags{fcitx::TextFormatFlag::Underline,
                                     fcitx::TextFormatFlag::DontCommit};
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
