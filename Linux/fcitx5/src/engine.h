// Fcitx5 input-method engine over the InkFlow C ABI. One engine per addon, one engine
// session per input context, created on first use. Keys are processed synchronously on
// Fcitx5's thread with no event-loop dependency; the engine never touches network,
// SQLite or telemetry.
#ifndef INKFLOW_FCITX5_ENGINE_H
#define INKFLOW_FCITX5_ENGINE_H
#include <fcitx-utils/log.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>

#include <string>

#include "bridge.h"
#include "candidates.h"
#include "config.h"
#include "inkflow_rime.h"

namespace inkflow {

FCITX_DECLARE_LOG_CATEGORY(inkflow_log);
#define INKFLOW_WARN() FCITX_LOGC(::inkflow::inkflow_log, Warn)
#define INKFLOW_INFO() FCITX_LOGC(::inkflow::inkflow_log, Info)

class State final : public fcitx::InputContextProperty {
public:
  ~State() override { release(); }
  void release() {
    snapshot.reset();
    ifr_session_destroy(session);
    session = nullptr;
  }
  bool composing() const {
    return snapshot && ifr_snapshot_preedit(snapshot.get()) && *ifr_snapshot_preedit(snapshot.get());
  }
  IFRSession* session = nullptr;
  SnapshotRef snapshot;
};

class Engine final : public fcitx::InputMethodEngineV2 {
public:
  explicit Engine(fcitx::Instance* instance);
  ~Engine() override;

  void keyEvent(const fcitx::InputMethodEntry& entry, fcitx::KeyEvent& event) override;
  void activate(const fcitx::InputMethodEntry& entry, fcitx::InputContextEvent& event) override;
  void deactivate(const fcitx::InputMethodEntry& entry, fcitx::InputContextEvent& event) override;
  void reset(const fcitx::InputMethodEntry& entry, fcitx::InputContextEvent& event) override;
  void reloadConfig() override;
  const fcitx::Configuration* getConfig() const override { return &config_; }
  void setConfig(const fcitx::RawConfig& raw) override;

  // Called by the candidate list; each rebuilds the panel.
  void selectCandidate(fcitx::InputContext* ic, const SnapshotRef& snapshot, std::size_t index);
  void changePage(fcitx::InputContext* ic, bool backward);
  void moveHighlight(fcitx::InputContext* ic, bool backward);

private:
  State* state(fcitx::InputContext* ic);
  // The input context's engine session, created and configured on first use.
  IFRSession* session(State* state);
  bool sensitive(const fcitx::InputContext* ic) const;
  void refreshContext(fcitx::InputContext* ic, State* state);
  // Drain the commit exactly once, then rebuild preedit and candidates from a fresh snapshot.
  void refresh(fcitx::InputContext* ic, State* state);
  void clear(fcitx::InputContext* ic, State* state);
  void failed(fcitx::InputContext* ic, State* state, const char* what, IFRStatus status);
  void createEngine();
  void destroyEngine();
  uint32_t inputOptions() const;
  void applyConfiguration(IFRSession* session);
  void applyConfigurationToSessions();
  void saveConfig();
  // The explicit personal-data entry point: stops the engine, imports, restarts, and
  // writes the backup's settings into the configuration. Never runs on the key path.
  void importBackup(std::string file);

  fcitx::Instance* instance_;
  Paths paths_;
  Config config_;
  IFREngine* engine_ = nullptr;
  fcitx::FactoryFor<State> factory_;
};

class Factory final : public fcitx::AddonFactory {
public:
  fcitx::AddonInstance* create(fcitx::AddonManager* manager) override {
    return new Engine(manager->instance());
  }
};

}  // namespace inkflow
#endif
