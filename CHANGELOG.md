# Changelog

## Unreleased

- Updating: the installer says whether you need to log out. It asks GNOME
  Shell what it has loaded, and checks whether the extension's files changed
  after the session started, which is how it notices a `git pull` between
  releases. It says to log out when the extension is `OUT OF DATE`, in
  `ERROR`, not loaded yet, another version, or changed since login. It says
  when a logout cannot help: the installed GNOME Shell is not supported,
  `metadata.json` is broken, or GNOME is set not to load extensions from the
  home directory. It also says when user extensions are switched off, and when
  the extension is stopped only because the screen is locked. The line under
  "Enabling the extension" and the advice at the end always agree, and the
  extension is reported as enabled only once GNOME shows it running. The
  README's update instructions match.

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
