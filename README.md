# Input Lock X

Disable the internal keyboard and touchpad with one tap, so folding a
convertible into tablet mode — or wiping the screen, or handing the machine to
a cat — stops generating accidental input.

- A **panel icon** in the top right toggles the lock.
- **Ctrl+Esc** locks *and* unlocks — the one combination that always works.
- An **"Input Disabled" / "Input Enabled"** notification confirms each change.
- The **touchscreen stays live**, so the icon is always tappable.

It was written for a Chuwi Minibook X, but nothing in it is specific to that
machine: devices are chosen by their evdev capabilities, not by a hardcoded
list. See [Which devices get locked](#which-devices-get-locked).

**Requirements:** GNOME Shell 45–50 on Wayland or X11, systemd, polkit ≥ 0.106,
Python 3 (stdlib only). Tested on Fedora; the packaging is distro-neutral.

**This repository is two halves.** The GNOME extension is the UI; the actual
locking is done by a small root daemon, because a shell extension cannot open
`/dev/input`. Installing only the extension from extensions.gnome.org gives you
a panel icon that says the daemon is missing. Run `./install.sh` from here to
get the working thing.

---

## Locked out? Read this first

From another machine:

```sh
ssh <this-laptop> input-lock-x-emergency-unlock
```

That stops the unit, kills the daemon (escalating to `SIGKILL`), clears any
sysfs inhibit flags, and reports the result. It is idempotent, makes no
assumptions about the current state, and **exits non-zero if recovery failed**,
so `ssh … input-lock-x-emergency-unlock && echo ok` means something.

You should rarely need it. In order, the ways back are:

| Method | Works when |
| --- | --- |
| Press **Ctrl+Esc** | always — the daemon watches for it in its own grabbed stream, so it needs neither the shell nor the configured shortcut |
| Tap the **panel icon** | whenever the session is unlocked (see below) |
| Type on an **external keyboard** | in auto mode — USB and Bluetooth devices are not grabbed unless you ask |
| `input-lock-x off` over SSH | always (see [Sudo and admin groups](#sudo-and-admin-groups)) |
| `input-lock-x-emergency-unlock` over SSH | even when the above are wedged |
| `sudo systemctl kill -s KILL input-lock-x` | last resort; the kernel releases the grab when the process dies |

There is no state in which a reboot fails to restore input — nothing is enabled
at boot.

Rows two and three assume auto mode, which is the default. `patterns` mode
grabs whatever the patterns name, including a touchscreen or a USB keyboard —
see [Which devices get locked](#which-devices-get-locked). Ctrl+Esc, SSH and
the reboot hold in every mode.

### On the lock screen, Ctrl+Esc is the only local way back

GNOME disables extensions while the screen is locked, so the panel icon is not
there — and the lock deliberately survives a shell restart, so it is still
engaged. If the session locks while input is disabled you cannot type your
password until you press **Ctrl+Esc**. The daemon handles that combination
itself, so it works regardless of what the shell is doing.

Adding `unlock-dialog` to the extension's session-modes would not help: the
unlock screen does not render extension-provided panel items.

---

## Install

```sh
./install.sh      # or: make install
```

Then **log out and back in** — Wayland cannot load a new extension in place.

The installer symlinks the extension rather than copying it, so edits in this
repo go live on the next login. It checks its prerequisites up front and names
what is missing, installs the daemon and unit under `sudo`, and finishes by
starting the unit for real — briefly locking and unlocking — because that is
the only check that proves the service can actually grab.

**Do the first install with an SSH session already open from another machine.**
Everything here is designed to be recoverable, but the first time you find out
whether your hardware is detected correctly is a good moment to have a way in.

`./install.sh --no-sudoers` skips the passwordless sudo drop-in; see below.

## Uninstall

```sh
./uninstall.sh    # or: make uninstall
```

It releases any active lock before removing anything, and cleans up both the
current and the pre-rename generation of files.

### Upgrading from `minibookx-hid-lock`

Earlier versions installed under `minibookx-*` / `hid-*` names. `install.sh`
migrates automatically: it releases any active lock first, copies
`/etc/minibookx-hid-lock.conf` to `/etc/input-lock-x.conf`, carries the
keybinding across in dconf, and removes the old unit, scripts, polkit rule and
extension. The old config is left on disk, and because it names devices
explicitly the daemon keeps grabbing exactly what it grabbed before — the
rename changes no behaviour. Delete `/etc/minibookx-hid-lock.conf` once you are
satisfied.

---

## How it works

```
  Ctrl+Esc (unlocked)  ─┐
  tap panel icon       ─┼─> extension ─ D-Bus ─> systemd StartUnit/StopUnit
                        │                          (polkit: no password)
                        │                                  │
                        │                                  v
                        │                        input-lock-x.service
                        │                        (root) input-lock-x-daemon.py
                        │                          · EVIOCGRAB keyboard+touchpad
                        │                          · reads its own raw stream
                        │                          · Ctrl+Esc -> ungrab, exit ─┐
                        │                                  │                   │
  extension  <─ Gio.FileMonitor ── /run/input-lock-x.state <─────────────┘
      └─> update icon + notification
```

The lock is an exclusive `EVIOCGRAB` on `/dev/input/event*`, taken by a small
root daemon. Nothing above the kernel — not the compositor, not any app — sees
input from a grabbed device.

**Why a grab and not `/sys/class/input/inputN/inhibited`:**

1. **Ctrl+Esc works both ways.** The daemon holds the exclusive grab, so it is
   the only thing that can still see the keyboard. It watches for Ctrl+Esc
   itself and releases. A sysfs inhibit drops the keypress in the kernel where
   nothing can observe it, so it could only ever *disable*.
2. **It cannot strand you.** A grab is tied to an open file descriptor. Kill the
   daemon, crash it, OOM it — the kernel drops the grab and input returns. A
   sysfs inhibit survives, including across a gnome-shell crash.

The grab is **all or nothing**, at startup and afterwards. If any matched device
fails to grab — another `EVIOCGRAB` holder, a second daemon instance — the
daemon releases what it got and refuses to start, so `systemctl start` fails and
nothing reports a lock. If a grabbed device later disappears (an i2c-HID
touchpad re-enumerated across suspend is the likely case) the daemon exits
rather than carry on holding a partial lock. A partial lock is the worst
available outcome: the icon would stay red and every consumer would say "locked"
while the device that dropped out kept generating input.

So a suspend/resume cycle may end the lock. That is deliberate — you get the
"Input Enabled" notification and an honest icon, rather than a red icon over a
live touchpad.

The **state file is the single source of truth**. The extension never assumes it
knows the state; it renders what the file says. So the icon stays correct
whether the change came from the panel, the shortcut, the daemon releasing
itself, or an SSH command.

### Sticky modifiers

When the lock is engaged from the Ctrl+Esc binding, both keys are still
physically held and the compositor has already seen them go down. Grabbing at
that instant would mean the compositor never sees the release and is left with a
stuck Ctrl. The daemon therefore polls `EVIOCGKEY` and waits for those keys to
come up before grabbing — and again before releasing.

It waits only on **modifiers and Esc**, not on the whole keyboard. Folded into
tablet mode the keyboard lies face down with ordinary keys held against the
table — the very situation this tool is for — so waiting for a completely idle
keyboard would time out on every lock and silently give up the protection above.

For the same reason the daemon seeds its Ctrl state from `EVIOCGKEY` right after
grabbing. If Ctrl was already held when the grab was taken, a fresh Esc still
counts as Ctrl+Esc, so the escape hatch cannot be missed.

---

## Which devices get locked

By default the daemon classifies every `/dev/input/event*` node by what the
kernel says it can do, rather than by name:

| Class | Detected by | Locked? |
| --- | --- | --- |
| Touchscreen | `INPUT_PROP_DIRECT`, or multitouch with no physical button | **never** — this is the escape hatch, enforced in code |
| Touchpad, pointing stick | `INPUT_PROP_POINTER`, `BUTTONPAD` or `POINTING_STICK`; or multitouch + `BTN_TOOL_FINGER`; or relative X/Y + `BTN_LEFT` | yes |
| Keyboard | reports a real alphanumeric key set (`KEY_A`, `KEY_Z`, `KEY_SPACE`, `KEY_ENTER`, `KEY_1`) | yes |
| Everything else | — | no |

Probing the key bitmap rather than the device name is what excludes `Power
Button`, `Video Bus`, `Intel HID events` and the other sparse-keymap devices
that also report `EV_KEY`.

Some panels driven through a generic HID path never set `INPUT_PROP_DIRECT`.
The second touchscreen rule catches those: a device with multitouch axes but no
`BTN_LEFT` and no pointer property has nothing to click, so it is a screen, not
a touchpad. Guessing "touchscreen" is the safe direction to be wrong in — it
locks less than you asked for, which is visible, rather than locking away the
way back.

**USB and Bluetooth devices are skipped**, so a plugged-in external keyboard
stays live and becomes another way back in. Flip that with `include_usb` /
`include_bluetooth` in the config if your machine's *internal* keyboard is
USB-attached — some convertibles wire it that way.

**Virtual (uinput) devices are never grabbed.** input-remapper, keyd, kmonad,
Steam Input, on-screen keyboards and remote-desktop agents all create one.
Grabbing it would swallow the events that tool is injecting — on a remapper
setup, the keyboard you actually type on. The physical device underneath is a
separate node and is still locked on its own merits.

Everything in this section describes **auto mode**. `patterns` mode does none
of it: a pattern is an explicit instruction, so it grabs what it matches
regardless of bus or class. The daemon warns on startup when a pattern matches
a touchscreen, but it obeys. If you need patterns for one device and the
guards for the rest, name only that device — `exclude` works in both modes, but
the class and bus rules do not.

Check what would happen on your hardware before trusting it:

```sh
make test                      # no root needed: classifies from /proc/bus/input/devices
sudo input-lock-x-daemon --list   # the real thing, reading the evdev nodes
sudo systemctl start input-lock-x # the check that actually matters
```

Run the last one too. On SELinux systems a shell `sudo` executes as
`unconfined_t` and can open input devices even when the service's domain cannot,
so `--list` succeeding does not prove the service will work.

### Configuration

`/etc/input-lock-x.conf`, never overwritten by a reinstall:

```ini
[devices]
mode = auto              # auto | patterns
include_usb = no
include_bluetooth = no
# patterns = AT Translated Set 2 keyboard
#            *Touchpad
# exclude  = *Fingerprint*

[behaviour]
max_lock_seconds = 0     # auto-release after N seconds; 0 disables
```

`patterns` are fnmatch globs against the evdev device name, for hardware auto
detection gets wrong. Setting `patterns` without setting `mode` selects patterns
mode — so a config written before auto detection existed keeps behaving exactly
as it did. `exclude` applies in both modes.

`include_usb` and `include_bluetooth` apply to auto mode only, as do the
touchscreen and virtual-device rules. In patterns mode the pattern is the whole
decision: it will grab a Bluetooth keyboard, a uinput node or a touchscreen if
that is what it matches.

Trailing `# comments` work on the single-value settings above. They are *not*
stripped from `patterns` and `exclude`, because an evdev device name may
legitimately contain a `#` and truncating one would silently grab the wrong
device. Put comments on their own line there.

In patterns mode the daemon warns when a pattern matches a touchscreen: that is
you grabbing your own escape hatch, and it will say so rather than quietly
comply. At startup it also logs which escape routes remain, and warns when the
only ones left are Ctrl+Esc and SSH.

### The shortcut

**Rebinding changes how the lock is engaged. It does not change how it is
released from a locked keyboard.** The daemon holds the internal keyboard
exclusively while the lock is on, so gnome-shell never sees those keypresses and
no shell shortcut can fire from that device — including this one.

What still works while locked:

- **Ctrl+Esc**, which the daemon watches for inside its own grab. Fixed in the
  daemon, not configurable: an escape hatch you can rebind is an escape hatch
  you can rebind into a lockout.
- The **panel icon**, via the touchscreen or an ungrabbed pointer.
- **This shortcut, from a device the daemon did not grab** — an external
  keyboard, which auto mode leaves alone. The binding is a real toggle; it is
  only the grabbed keyboard that cannot reach it.

The shortcut is only held while the daemon is installed. Mutter's grab is
system-wide, and Ctrl+Esc belongs to editors, IDEs and VM windows too, so
claiming it just to answer "not set up" would be worse than leaving it alone.
It binds itself the moment the daemon appears, without a re-login.

Rebind the engage shortcut in the extension's preferences (**Extensions → Input
Lock X → Settings**), or from a shell:

```sh
gsettings --schemadir ~/.local/share/gnome-shell/extensions/input-lock-x@isalin.github.io/schemas \
  set org.gnome.shell.extensions.input-lock-x toggle-hid "['<Control>Escape']"
```

The key is still named `toggle-hid` for continuity with older installs, even
though it only engages the lock.

---

## Sudo and admin groups

Two files decide who may toggle the lock without a password:

- `/etc/polkit-1/rules.d/49-input-lock-x.rules` lets a **local, active** session
  belonging to `wheel`, `sudo` or `admin` start and stop this one unit. That is
  what makes the panel icon work. Distros disagree on the admin group's name —
  Fedora, Arch and openSUSE use `wheel`, Debian and Ubuntu use `sudo` — so the
  rule names all three. A group that does not exist simply never matches, so
  this grants nothing extra.
- `/etc/sudoers.d/input-lock-x` gives the same three groups passwordless sudo
  for **only** `input-lock-x` and `input-lock-x-emergency-unlock`. This exists
  because `ssh host cmd` allocates no TTY, so without it sudo fails with "a
  terminal is required to read the password" — at the exact moment you need the
  command.

Decline the second one with `./install.sh --no-sudoers`, and recover with:

```sh
ssh -t <this-laptop> sudo input-lock-x-emergency-unlock
```

The scripts detect the situation and print that fallback rather than dying on a
prompt nobody can answer.

If you are in none of those three groups, `install.sh` says so. The panel button
will fail with a permission error until you either join your distro's admin
group or edit the group list in the polkit rule.

---

## Files

| Path | Purpose |
| --- | --- |
| `extension/` | GNOME Shell extension, symlinked to `~/.local/share/gnome-shell/extensions/input-lock-x@isalin.github.io` |
| `extension/common.js` | unit name and the installed-check, shared by `extension.js` and `prefs.js` |
| `lib/paths.sh` | every path this installs, shared by `install.sh` and `uninstall.sh` |
| `lib/legacy-paths.sh` | the pre-rename paths, shared by `install.sh` and `uninstall.sh` |
| `lib/release-lock.sh` | release any active grab, shared by `install.sh` and `uninstall.sh` |
| `daemon/input-lock-x-daemon.py` | the grab daemon → `/usr/local/bin/input-lock-x-daemon` |
| `daemon/input-lock-x.conf` | which devices to grab → `/etc/` |
| `daemon/input-lock-x.service` | on-demand unit → `/etc/systemd/system/` |
| `daemon/49-input-lock-x.rules` | passwordless start/stop for the desktop → `/etc/polkit-1/rules.d/` |
| `daemon/input-lock-x.sudoers` | passwordless recovery over SSH → `/etc/sudoers.d/` |
| `scripts/input-lock-x` | `on` / `off` / `toggle` / `status` → `/usr/local/bin/` |
| `scripts/input-lock-x-emergency-unlock` | unconditional recovery → `/usr/local/bin/` |
| `tests/classify-from-proc.py` | run the classifier against `/proc`, no root needed |

Stdlib Python 3 only — no `python3-evdev` or other new system packages.

`make check` syntax-checks everything; `make pack` builds the
extensions.gnome.org zip.

---

## Troubleshooting

```sh
make status                                   # lock state + matched devices
make logs                                     # journalctl -u input-lock-x -f
journalctl -f -o cat /usr/bin/gnome-shell     # extension errors
gnome-extensions info input-lock-x@isalin.github.io
```

**The panel icon is a yellow warning triangle.** The daemon is not installed —
the extension found no `input-lock-x.service`. This is what installing only the
extension from extensions.gnome.org looks like. Run `./install.sh` from this
repository.

**The shortcut does nothing.** If the panel icon is the warning triangle, that
is deliberate — the shortcut is not bound without the daemon, and binds itself
as soon as one is installed. Otherwise check the shell journal
(`journalctl -f -o cat /usr/bin/gnome-shell`), and whether something else has
claimed the same keys in **Settings → Keyboard → View and Customize Shortcuts**.

**"Not allowed to toggle the input lock".** polkit refused. Either the rule is
not installed (`ls /etc/polkit-1/rules.d/49-input-lock-x.rules`) or your user is
in none of `wheel`, `sudo`, `admin` — check with `id -nG`.

**The daemon refuses to start.** It exits non-zero rather than pretending to
lock. Check the journal — it distinguishes the causes:

- `no input devices matched` — auto detection found no keyboard or pointer, or
  your patterns match nothing. Compare against `sudo input-lock-x-daemon --list`.
- `permission denied opening N input device(s)` — being root is not sufficient;
  see SELinux below.

### SELinux (Fedora, RHEL, openSUSE)

The daemon lives in `/usr/local/bin` specifically so SELinux labels it `bin_t`,
which makes systemd transition the service into `unconfined_service_t`. From
`/usr/local/lib` (`lib_t`) there is no transition, the service stays in `init_t`,
and **every** `/dev/input/event*` open fails with `EACCES` even though the
service runs as root.

If it ever regresses, the symptom is a wall of "cannot open /dev/input/eventN:
Permission denied" in the journal. Check the label and the denials:

```sh
ls -Z /usr/local/bin/input-lock-x-daemon        # expect ...:bin_t:...
sudo restorecon -F /usr/local/bin/input-lock-x-daemon
sudo ausearch -m avc -ts recent
```

Distros without SELinux are unaffected; `install.sh` skips the relabel when
`restorecon` is absent.

### Interaction with `rotation-hid-lock`

The older `rotation-hid-lock@isalin.github.com` extension toggles the touchpad
through GSettings on rotation. This one never touches GSettings, so the two
cannot deadlock — but if both are enabled, the old one may flip the touchpad
GSettings key while this one holds a grab. The grab wins, so the effect is
cosmetic. Disable the old one to keep things predictable:

```sh
gnome-extensions disable rotation-hid-lock@isalin.github.com
```

---

## Licence

GPL-2.0-or-later. See [LICENSE](LICENSE).
