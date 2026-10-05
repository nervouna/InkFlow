#!/bin/bash
# Read-only target inspection. Run as the desktop user, including over SSH.
set -euo pipefail
printf 'Architecture: '; uname -m
printf 'OS:\n'
awk -F= '$1 ~ /^(ID|VERSION_ID|PRETTY_NAME|BUILD_ID)$/ { print }' /etc/os-release
printf 'C library: '; getconf GNU_LIBC_VERSION || true
printf 'Current shell session: %s / %s\n' "${XDG_SESSION_TYPE:-unknown}" "${XDG_CURRENT_DESKTOP:-unknown}"
if command -v loginctl >/dev/null; then
  sessions=$(loginctl show-user "$(id -u)" -p Sessions --value 2>/dev/null || true)
  for session in $sessions; do
    printf 'User session:\n'
    loginctl show-session "$session" -p Type -p Desktop -p Remote -p State || true
  done
fi
for process in Hyprland kwin_wayland kwin_x11 fcitx5; do
  if pgrep -u "$(id -u)" -x "$process" >/dev/null; then printf 'Running: %s\n' "$process"; fi
done
if command -v fcitx5 >/dev/null; then fcitx5 -v; else printf 'Fcitx5: not on PATH\n'; fi
if command -v findmnt >/dev/null; then
  printf 'Root/home mount types and VFS flags:\n'
  findmnt -n -o TARGET,FSTYPE,VFS-OPTIONS --target /
  findmnt -n -o TARGET,FSTYPE,VFS-OPTIONS --target "$HOME"
fi
if command -v flatpak >/dev/null; then
  flatpak --version
  printf 'Flatpak platforms:\n'
  flatpak list --runtime --columns=application,branch | grep -E '^org\.(gnome|kde|freedesktop)\.Platform[[:space:]]' || true
else
  printf 'Flatpak: not on PATH\n'
fi
printf 'No installation, activation, or configuration changes performed.\n'
