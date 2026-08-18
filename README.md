# Minibook X input toggle

Disable the internal keyboard and touchpad on a Chuwi Minibook X with one tap,
so folding it into yoga/tablet mode stops generating accidental input.

- A **panel icon** in the top right toggles the lock.
- **Ctrl+Esc** toggles it too, in **both** directions.
- A **"HID Disabled" / "HID Enabled"** notification confirms each change.
- The **touchscreen stays live**, so the icon is always tappable.

---

## Locked out? Read this first

From another machine:

```sh
ssh <this-laptop> hid-emergency-unlock
```

That stops the unit, kills the daemon (escalating to `SIGKILL`), clears any
sysfs inhibit flags, and reports the result. It is idempotent, makes no
assumptions about the current state, and **exits non-zero if recovery failed**,
so `ssh … hid-emergency-unlock && echo ok` means something.

`install.sh` adds `/etc/sudoers.d/minibookx-hid-lock`, granting the `wheel`
group passwordless sudo for **only** `hid-emergency-unlock` and `hid-toggle`.
That is what makes the one-liner above work: `ssh host cmd` allocates no TTY, so
without it sudo fails with "a terminal is required to read the password" — at
the exact moment you need the command. If you would rather not have that entry,
delete it and use:

```sh
ssh -t <this-laptop> sudo hid-emergency-unlock
```

The scripts detect the situation and print that fallback rather than dying on a
prompt nobody can answer.

You should rarely need it. In order, the ways back are:

| Method | Works when |
| --- | --- |
| Press **Ctrl+Esc** | always — the daemon watches for it in its own grabbed stream, so it does not depend on the shell |
| Tap the **panel icon** | whenever the session is unlocked (see below) |
| `hid-toggle off` over SSH | always (see the sudo note below) |
| `hid-emergency-unlock` over SSH | even when the above are wedged |
| `sudo systemctl kill -s KILL minibookx-hid-lock` | last resort; the kernel releases the grab when the process dies |

There is no state in which a reboot fails to restore input — nothing is enabled
at boot.

### On the lock screen, Ctrl+Esc is the only local way back

GNOME disables extensions while the screen is locked, so the panel icon is not
there — and the lock deliberately survives a shell restart, so it is still
engaged. If the session locks while HID is disabled you cannot type your
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
repo go live on the next login.

## Uninstall

```sh
./uninstall.sh    # or: make uninstall
```

It releases any active lock before removing anything.

---

## How it works

```
  Ctrl+Esc (unlocked)  ─┐
  tap panel icon       ─┼─> extension ─ D-Bus ─> systemd StartUnit/StopUnit
                        │                          (polkit: no password)
                        │                                  │
                        │                                  v
                        │                        minibookx-hid-lock.service
                        │                        (root) hid-lock-daemon.py
                        │                          · EVIOCGRAB keyboard+touchpad
                        │                          · reads its own raw stream
                        │                          · Ctrl+Esc -> ungrab, exit ─┐
                        │                                  │                   │
  extension  <─ Gio.FileMonitor ── /run/minibookx-hid-lock.state <─────────────┘
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
"HID Enabled" notification and an honest icon, rather than a red icon over a
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

## Files

| Path | Purpose |
| --- | --- |
| `extension/` | GNOME Shell 50 extension, symlinked to `~/.local/share/gnome-shell/extensions/minibookx-input-toggle@isalin.github.com` |
| `daemon/hid-lock-daemon.py` | the grab daemon → `/usr/local/bin/hid-lock-daemon` |
| `daemon/minibookx-hid-lock.conf` | which devices to grab → `/etc/` |
| `daemon/minibookx-hid-lock.service` | on-demand unit → `/etc/systemd/system/` |
| `daemon/49-minibookx-hid-lock.rules` | passwordless start/stop for the desktop → `/etc/polkit-1/rules.d/` |
| `daemon/minibookx-hid-lock.sudoers` | passwordless recovery over SSH → `/etc/sudoers.d/` |
| `scripts/hid-toggle` | `on` / `off` / `toggle` / `status` → `/usr/local/bin/` |
| `scripts/hid-emergency-unlock` | unconditional recovery → `/usr/local/bin/` |

Stdlib Python 3 only — no `python3-evdev` or other new system packages.

## Configuration

Which devices get locked is `/etc/minibookx-hid-lock.conf` (fnmatch patterns
against the evdev device name). Defaults:

```ini
patterns = AT Translated Set 2 keyboard
           *Touchpad
```

Check what a change matches before relying on it:

```sh
sudo hid-lock-daemon --list
sudo systemctl start minibookx-hid-lock   # the check that actually matters
```

Run both. A shell `sudo` executes as `unconfined_t` and can open input devices
even when the service's SELinux domain cannot, so `--list` succeeding does not
prove the service will work.

The Goodix touchscreen is deliberately absent — it is the escape hatch. Add it
only if you are sure you have another way back in.

`max_lock_seconds` in the same file auto-releases the lock after N seconds; `0`
(the default) disables that.

The shortcut itself is a GSettings key, so it is rebindable:

```sh
gsettings --schemadir ~/.local/share/gnome-shell/extensions/minibookx-input-toggle@isalin.github.com/schemas \
  set org.gnome.shell.extensions.minibookx-input-toggle toggle-hid "['<Control>Escape']"
```

## Troubleshooting

```sh
make status                                   # lock state + matched devices
make logs                                     # journalctl -u minibookx-hid-lock -f
journalctl -f -o cat /usr/bin/gnome-shell     # extension errors
gnome-extensions info minibookx-input-toggle@isalin.github.com
```

**Tapping the icon does nothing and a "HID toggle failed" notification appears.**
The polkit rule or the unit is not installed. Re-run `./install.sh` and check
`systemctl cat minibookx-hid-lock.service`.

**The daemon refuses to start.** It exits non-zero rather than pretending to
lock. Check the journal — it distinguishes the two causes:

- `no input devices matched` — your config patterns do not match anything.
  Compare against `sudo hid-lock-daemon --list`.
- `permission denied opening N input device(s)` — SELinux. Being root is not
  sufficient; the service must run in a domain allowed to read input devices.

### SELinux

The daemon lives in `/usr/local/bin` specifically so SELinux labels it `bin_t`,
which makes systemd transition the service into `unconfined_service_t`. From
`/usr/local/lib` (`lib_t`) there is no transition, the service stays in `init_t`,
and **every** `/dev/input/event*` open fails with `EACCES` even though the
service runs as root.

If it ever regresses, the symptom is a wall of "cannot open /dev/input/eventN:
Permission denied" in the journal. Check the label and the denials:

```sh
ls -Z /usr/local/bin/hid-lock-daemon        # expect ...:bin_t:...
sudo restorecon -F /usr/local/bin/hid-lock-daemon
sudo ausearch -m avc -ts recent
```

### Interaction with `rotation-hid-lock`

The older `rotation-hid-lock@isalin.github.com` extension toggles the touchpad
through GSettings on rotation. This one never touches GSettings, so the two
cannot deadlock — but if both are enabled, the old one may flip the touchpad
GSettings key while this one holds a grab. The grab wins, so the effect is
cosmetic. Disable the old one to keep things predictable:

```sh
gnome-extensions disable rotation-hid-lock@isalin.github.com
```
