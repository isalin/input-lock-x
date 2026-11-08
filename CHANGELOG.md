# Changelog

## Unreleased

- Updating: the installer asks GNOME Shell what it has loaded and says when to
  log out: when the extension is `OUT OF DATE`, in `ERROR`, not loaded yet, or
  older than the installed copy. It also says when a logout cannot help,
  because the installed GNOME Shell is not supported, and when user extensions
  are switched off. It no longer says no logout is needed for an extension it
  cannot see running, and reports the extension as enabled only once GNOME
  shows it running. The README's update instructions match.

## 1.0.1 — 2026-11-08

- GNOME Shell 51 support.

## 1.0.0 — 2026-08-30

Initial public release of Input Lock X:

- GNOME Shell panel toggle and configurable engage shortcut.
- Companion root daemon that grabs selected evdev devices.
- Auto device classification that leaves the touchscreen and external input
  alone by default.
- Ctrl+Esc emergency release path, including the lock screen.
- Installer, systemd service, polkit policy, SSH recovery, tests, and
  extension packaging.
- GNOME Shell 45–50 support on Wayland and X11.
