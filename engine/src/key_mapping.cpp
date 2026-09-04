#include "engine_internal.hpp"

namespace {

constexpr uint32_t kSupportedModifiers =
    INKFLOW_MODIFIER_SHIFT | INKFLOW_MODIFIER_CAPS_LOCK |
    INKFLOW_MODIFIER_CONTROL | INKFLOW_MODIFIER_ALT |
    INKFLOW_MODIFIER_SUPER | INKFLOW_MODIFIER_RELEASE;

constexpr int kBackendShiftMask = 1 << 0;
constexpr int kBackendLockMask = 1 << 1;
constexpr int kBackendControlMask = 1 << 2;
constexpr int kBackendAltMask = 1 << 3;
constexpr int kBackendSuperMask = 1 << 26;
constexpr int kBackendReleaseMask = 1 << 30;

constexpr int kX11Backspace = 0xff08;
constexpr int kX11Tab = 0xff09;
constexpr int kX11Return = 0xff0d;
constexpr int kX11Escape = 0xff1b;
constexpr int kX11Home = 0xff50;
constexpr int kX11Left = 0xff51;
constexpr int kX11Up = 0xff52;
constexpr int kX11Right = 0xff53;
constexpr int kX11Down = 0xff54;
constexpr int kX11PageUp = 0xff55;
constexpr int kX11PageDown = 0xff56;
constexpr int kX11End = 0xff57;
constexpr int kX11Delete = 0xffff;
constexpr int kX11UnicodePrefix = 0x01000000;

bool is_unicode_scalar(uint32_t value) {
  return value <= 0x10ffffu && !(value >= 0xd800u && value <= 0xdfffu);
}

}  // namespace

namespace inkflow {

InkFlowStatus map_key_event(InkFlowKeyEvent event,
                            int* backend_keycode,
                            int* backend_modifiers) {
  if (backend_keycode == nullptr || backend_modifiers == nullptr ||
      (event.modifiers & ~kSupportedModifiers) != 0) {
    return INKFLOW_STATUS_UNSUPPORTED_KEY;
  }

  int mapped_key = 0;
  switch (event.key) {
    case INKFLOW_KEY_BACKSPACE:
      mapped_key = kX11Backspace;
      break;
    case INKFLOW_KEY_DELETE_FORWARD:
      mapped_key = kX11Delete;
      break;
    case INKFLOW_KEY_RETURN:
      mapped_key = kX11Return;
      break;
    case INKFLOW_KEY_ESCAPE:
      mapped_key = kX11Escape;
      break;
    case INKFLOW_KEY_TAB:
      mapped_key = kX11Tab;
      break;
    case INKFLOW_KEY_LEFT:
      mapped_key = kX11Left;
      break;
    case INKFLOW_KEY_RIGHT:
      mapped_key = kX11Right;
      break;
    case INKFLOW_KEY_UP:
      mapped_key = kX11Up;
      break;
    case INKFLOW_KEY_DOWN:
      mapped_key = kX11Down;
      break;
    case INKFLOW_KEY_PAGE_UP:
      mapped_key = kX11PageUp;
      break;
    case INKFLOW_KEY_PAGE_DOWN:
      mapped_key = kX11PageDown;
      break;
    case INKFLOW_KEY_HOME:
      mapped_key = kX11Home;
      break;
    case INKFLOW_KEY_END:
      mapped_key = kX11End;
      break;
    default:
      if (!is_unicode_scalar(event.key) || event.key < 0x20u ||
          event.key == 0x7fu) {
        return INKFLOW_STATUS_UNSUPPORTED_KEY;
      }
      mapped_key = event.key <= 0x7eu
                       ? static_cast<int>(event.key)
                       : kX11UnicodePrefix | static_cast<int>(event.key);
      break;
  }

  int mapped_modifiers = 0;
  if ((event.modifiers & INKFLOW_MODIFIER_SHIFT) != 0) {
    mapped_modifiers |= kBackendShiftMask;
  }
  if ((event.modifiers & INKFLOW_MODIFIER_CAPS_LOCK) != 0) {
    mapped_modifiers |= kBackendLockMask;
  }
  if ((event.modifiers & INKFLOW_MODIFIER_CONTROL) != 0) {
    mapped_modifiers |= kBackendControlMask;
  }
  if ((event.modifiers & INKFLOW_MODIFIER_ALT) != 0) {
    mapped_modifiers |= kBackendAltMask;
  }
  if ((event.modifiers & INKFLOW_MODIFIER_SUPER) != 0) {
    mapped_modifiers |= kBackendSuperMask;
  }
  if ((event.modifiers & INKFLOW_MODIFIER_RELEASE) != 0) {
    mapped_modifiers |= kBackendReleaseMask;
  }

  *backend_keycode = mapped_key;
  *backend_modifiers = mapped_modifiers;
  return INKFLOW_STATUS_OK;
}

}  // namespace inkflow
