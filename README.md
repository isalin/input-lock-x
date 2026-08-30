# Input Lock X

Input Lock X is an open-source GNOME Shell extension for Linux that temporarily
disables a convertible laptop's built-in keyboard and touchpad in tablet mode.
It uses a small companion root daemon to grab selected evdev devices while
leaving the touchscreen available in auto mode for recovery.

Use it when folding a 2-in-1 laptop into tablet mode or cleaning a touchscreen
without accidental input. It supports GNOME Shell 45–50 on Wayland and X11.

- Toggle the lock from the panel.
- Use **Ctrl+Esc** to engage or release it.
- The touchscreen stays available in auto mode, so the panel icon remains usable.
- Notifications show when input is disabled or enabled.

The project was written on a Chuwi Minibook X, but device selection is based on
evdev capabilities rather than a list of machine-specific names.

> **Warning:** this installs a root service and can disable every input device
> that matches its configuration. Keep an SSH session open during the first
> install and test. In auto mode, the touchscreen and USB/Bluetooth input are
> left alone by default.

## Requirements

- GNOME Shell 45–50, on Wayland or X11
- systemd
- polkit 0.106 or newer
- Python 3 (standard library only)
- `git`, `make`, and `glib-compile-schemas` for installation

It has been tested on Fedora. The installer does not depend on a particular
Linux distribution, but the service needs access to `/dev/input` and a working
systemd/polkit setup.

The extension and daemon are both required. The extension is not currently
published on extensions.gnome.org; install both parts from this repository.

## Recovery

If the lock does not release normally:

1. Press **Ctrl+Esc** on the locked keyboard. The daemon watches for this
   combination itself, so it also works on the lock screen.
2. Tap the panel icon from the touchscreen, or use an ungrabbed pointer.
3. In auto mode, use an external keyboard if one is available.
4. From another machine, run:

   ```sh
   ssh <this-machine> input-lock-x-emergency-unlock
   ```

5. As a last resort, kill the service. The kernel releases its input grabs when
   the daemon exits:

   ```sh
   sudo systemctl kill -s KILL input-lock-x.service
   ```

Rebooting also restores input; the service is never enabled at boot.

GNOME disables extensions on the lock screen, so the panel icon is not
available there. **Ctrl+Esc** is the local escape route in that situation.

## Installation

Run the installer as your normal user. It uses `sudo` for system files.

### 1. Install prerequisites

For example:

```sh
sudo dnf install git make glib2-devel        # Fedora/RHEL
sudo apt install git make libglib2.0-bin     # Debian/Ubuntu
sudo pacman -S git make glib2                # Arch
sudo zypper install git make glib2-devel     # openSUSE
```

### 2. Clone the repository

Keep the checkout in a permanent location. The installer symlinks the extension
directory to this checkout.

```sh
git clone https://github.com/isalin/input-lock-x.git
cd input-lock-x
```

### 3. Check device detection

This reads `/proc/bus/input/devices` and does not need root or install anything:

```sh
make test
```

Your internal keyboard and touchpad should be listed as `GRAB`. The touchscreen,
external keyboard, and other devices you need for recovery should be listed as
`skip`. If detection is wrong, use the configuration described below.

### 4. Install

```sh
./install.sh
```

The installer:

- compiles the GSettings schema;
- installs the daemon, service, polkit rule, and command-line tools;
- leaves an existing `/etc/input-lock-x.conf` unchanged;
- starts the service to verify that it can actually grab the matched devices;
- enables the extension when this checkout owns the extension directory.

It refuses to continue if the service cannot be verified. The first install
normally requires a logout and login before GNOME loads the extension.

After logging in, check the installation:

```sh
gnome-extensions info input-lock-x@isalin.github.io
input-lock-x status
```

Then test the complete round trip from another machine:

```sh
ssh <this-machine> input-lock-x on
# Press Ctrl+Esc on the laptop.
ssh <this-machine> input-lock-x-emergency-unlock  # if needed
```

### Installer options

```text
--no-sudoers       Do not install passwordless SSH recovery rules.
--daemon-only      Install only the system daemon and command-line tools.
--link-extension   Replace another extension install with this checkout.
```

Use `--daemon-only` when the extension was installed separately, for example
from extensions.gnome.org. It does not replace or enable that extension.

`--link-extension` is intended for development or when you explicitly want this
checkout to replace another copy. The installer asks before deleting a foreign
extension directory or repointing another symlink.

Without the sudoers file, use a TTY for SSH recovery:

```sh
ssh -t <this-machine> sudo input-lock-x-emergency-unlock
```

### Updating

Pull the changes and run the installer again:

```sh
git -C /path/to/input-lock-x pull
cd /path/to/input-lock-x
./install.sh
```

The daemon and system files are installed as copies. The extension is a symlink,
so do not delete or move the checkout while using it.

### Uninstalling

```sh
./uninstall.sh
```

It releases any active lock before removing the service and tools. Edited config
files are left in `/etc` so they can be reviewed or removed manually. An
extension directory that this installer did not create is left alone.

Older installations named `minibookx-hid-lock` are migrated automatically by
`install.sh`; their config and shortcut are carried over.

## Usage

The command-line tool can be used locally or over SSH:

```sh
input-lock-x on       # engage the lock
input-lock-x off      # release the lock
input-lock-x toggle   # switch between the two states
input-lock-x status   # show state and matched devices
```

The default shortcut engages the lock. Its setting can be changed in
**Extensions → Input Lock X → Settings**, or with:

```sh
gsettings --schemadir \
  ~/.local/share/gnome-shell/extensions/input-lock-x@isalin.github.io/schemas \
  set org.gnome.shell.extensions.input-lock-x toggle-hid "['<Control>Escape']"
```

The daemon's release shortcut is always **Ctrl+Esc** and cannot be rebound.
This is intentional: the escape route should not be possible to configure away.

## Device selection

Auto mode examines every `/dev/input/event*` device:

| Device | Auto mode |
| --- | --- |
| Touchscreen | Never grabbed |
| Internal keyboard | Grabbed |
| Internal touchpad or pointing stick | Grabbed |
| USB or Bluetooth keyboard/pointer | Skipped by default |
| Virtual/uinput device | Never grabbed |
| Other devices | Skipped |

The classifier uses evdev capabilities and input properties. It does not depend
on vendor names. USB and Bluetooth devices can be included when an internal
keyboard uses one of those buses.

### Configuration

The configuration file is `/etc/input-lock-x.conf`. It is installed once and
never overwritten by a reinstall.

```ini
[devices]
mode = auto              # auto or patterns
include_usb = no
include_bluetooth = no
# patterns = AT Translated Set 2 keyboard
#            *Touchpad
# exclude = *Fingerprint*

[behaviour]
max_lock_seconds = 0     # 0 disables automatic release
```

`patterns` are fnmatch globs against the evdev device name. Setting `patterns`
without setting `mode` also selects patterns mode for compatibility with older
configs. `exclude` applies in both modes.

In patterns mode, matching is explicit: touchscreen, USB/Bluetooth, and virtual
device safeguards do not apply. Do not match your touchscreen unless you have
another reliable way back in. Check the result before enabling the lock:

```sh
sudo input-lock-x-daemon --list
```

After editing the file, start the service once and check the journal. On SELinux
systems, a successful `--list` command does not necessarily mean the systemd
service can open the devices.

## Permissions and security

The polkit rule allows members of `wheel`, `sudo`, or `admin` to start and stop
this service from an active local session. By default, the installer also adds
`/etc/sudoers.d/input-lock-x`, allowing those groups to run only the two
installed control scripts without a password. This makes non-interactive SSH
recovery possible.

Review these files before installation if that privilege is not appropriate for
your machine. Use `./install.sh --no-sudoers` to omit the sudoers file.

## Troubleshooting

Show the current state and matched devices:

```sh
input-lock-x status
sudo input-lock-x-daemon --list
journalctl -u input-lock-x.service -b
```

**Yellow warning icon:** the extension cannot find
`input-lock-x.service`. Install the daemon with `./install.sh` or
`./install.sh --daemon-only`.

**The panel button or shortcut is denied:** check that the polkit rule exists
and that your user is in `wheel`, `sudo`, or `admin`:

```sh
id -nG
ls /etc/polkit-1/rules.d/49-input-lock-x.rules
```

**The daemon finds no devices:** compare its output with `--list`. An internal
device connected through USB may require `include_usb = yes` or a pattern.

**Permission denied in the service journal:** on SELinux systems, check the
daemon label and recent denials:

```sh
ls -Z /usr/local/bin/input-lock-x-daemon
sudo restorecon -F /usr/local/bin/input-lock-x-daemon
sudo ausearch -m avc -ts recent
```

## Development

```sh
make check    # syntax, schema, and available static checks
make test     # offline tests plus device classification
make pack     # build the GNOME extension ZIP
```

The GitHub Actions workflow runs `make check` and `make test` on pushes and pull
requests. `shellcheck` and `node` are optional for a local `make check`, but CI
requires them.

See [CHANGELOG.md](CHANGELOG.md) for the release history and
[GitHub Releases](https://github.com/isalin/input-lock-x/releases) for packaged
versions.

The main components are:

| Path | Purpose |
| --- | --- |
| `extension/` | GNOME Shell extension |
| `daemon/` | Root daemon, service, configuration, and policy files |
| `scripts/` | User-facing control and emergency recovery commands |
| `lib/` | Installer and uninstaller helpers |
| `tests/` | Offline unit tests and device classifier |

## License

Copyright (C) 2026 Isak Lindgren.

This project is licensed under the GNU General Public License, version 2 or
later. See [LICENSE](LICENSE).
