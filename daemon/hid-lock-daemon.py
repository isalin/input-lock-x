#!/usr/bin/python3
"""Minibook X HID lock daemon.

Takes an exclusive EVIOCGRAB on the internal keyboard and touchpad so that no
input from them reaches the compositor or any application. Because the grab is
exclusive to this process, this daemon is the only thing that can still see the
keyboard -- so it watches its own raw event stream for Ctrl+Esc and releases.

A grab lives and dies with the file descriptor: if this process is killed the
kernel releases it automatically. That is the failsafe, and the reason this is
preferred over /sys/class/input/inputN/inhibited (which persists).

Runs as root via minibookx-hid-lock.service. Stdlib only.
"""

import argparse
import configparser
import ctypes
import errno
import fcntl
import glob
import os
import select
import signal
import socket
import struct
import sys
import time
from fnmatch import fnmatch

CONFIG_PATH = "/etc/minibookx-hid-lock.conf"
STATE_PATH = "/run/minibookx-hid-lock.state"

DEFAULT_PATTERNS = ["AT Translated Set 2 keyboard", "*Touchpad"]

# struct input_event on x86_64: struct timeval (2x long) + type + code + value
EVENT_STRUCT = struct.Struct("llHHi")
EVENT_SIZE = EVENT_STRUCT.size

EV_KEY = 0x01

KEY_ESC = 1
KEY_LEFTCTRL = 29
KEY_LEFTSHIFT = 42
KEY_RIGHTSHIFT = 54
KEY_LEFTALT = 56
KEY_RIGHTCTRL = 97
KEY_RIGHTALT = 100
KEY_LEFTMETA = 125
KEY_RIGHTMETA = 126

CTRL_KEYS = (KEY_LEFTCTRL, KEY_RIGHTCTRL)

# Keys whose held state actually matters when we grab or ungrab: the modifiers,
# which the compositor latches, plus the Esc of the Ctrl+Esc that got us here.
#
# Waiting on *every* key would be wrong for this hardware. Folded into tablet
# mode the keyboard lies face down, so ordinary keys are held constantly --
# which is the entire reason this tool exists. Waiting for those to come up
# would time out on every single lock and quietly forfeit the protection below.
STICKY_KEYS = (
    KEY_ESC,
    KEY_LEFTCTRL, KEY_RIGHTCTRL,
    KEY_LEFTSHIFT, KEY_RIGHTSHIFT,
    KEY_LEFTALT, KEY_RIGHTALT,
    KEY_LEFTMETA, KEY_RIGHTMETA,
)

# Covers key codes 0..255, i.e. the KEY_* range. BTN_* codes start at 0x100, so
# this also keeps BTN_TOUCH and BTN_LEFT out of the picture.
KEY_BITMAP_BYTES = 32

# _drain() outcomes.
DRAIN_OK = "ok"
DRAIN_RELEASE = "release"
DRAIN_DEAD = "dead"

# _IOC encoding, from <asm-generic/ioctl.h>
_IOC_NRBITS = 8
_IOC_TYPEBITS = 8
_IOC_SIZEBITS = 14
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS
_IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS
_IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS
_IOC_NONE = 0
_IOC_WRITE = 1
_IOC_READ = 2


def _IOC(direction, typ, nr, size):
    return (
        (direction << _IOC_DIRSHIFT)
        | (ord(typ) << _IOC_TYPESHIFT)
        | (nr << _IOC_NRSHIFT)
        | (size << _IOC_SIZESHIFT)
    )


def EVIOCGNAME(length):
    return _IOC(_IOC_READ, "E", 0x06, length)


def EVIOCGKEY(length):
    return _IOC(_IOC_READ, "E", 0x18, length)


EVIOCGRAB = _IOC(_IOC_WRITE, "E", 0x90, ctypes.sizeof(ctypes.c_int))


def log(msg):
    """Log to stderr, which systemd routes to the journal."""
    print(msg, file=sys.stderr, flush=True)


def sd_notify(state):
    """Send a readiness message to systemd (Type=notify).

    Lets `systemctl start` -- and therefore the extension's StartUnit call and
    `hid-toggle on` -- fail honestly when the grab never happened, instead of
    reporting success at fork time and leaving the user with a lock they think
    is engaged.
    """
    address = os.environ.get("NOTIFY_SOCKET")
    if not address:
        return
    if address.startswith("@"):  # abstract namespace
        address = "\0" + address[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as sock:
            sock.connect(address)
            sock.sendall(state.encode())
    except OSError as exc:
        log(f"sd_notify({state!r}) failed: {exc}")


def device_name(fd):
    buf = bytearray(256)
    try:
        fcntl.ioctl(fd, EVIOCGNAME(len(buf)), buf)
    except OSError:
        return None
    return buf.split(b"\x00", 1)[0].decode("utf-8", "replace")


def read_patterns(config_path):
    """Read device name patterns from the config, falling back to defaults."""
    # interpolation=None: device names are arbitrary strings and a bare '%' in
    # one would otherwise raise InterpolationSyntaxError out of get(), i.e.
    # outside the fallback handling below.
    parser = configparser.ConfigParser(interpolation=None)
    try:
        if not parser.read(config_path):
            log(f"config {config_path} not found, using built-in defaults")
            return DEFAULT_PATTERNS, 0
    except configparser.Error as exc:
        log(f"config {config_path} is malformed ({exc}), using built-in defaults")
        return DEFAULT_PATTERNS, 0

    raw = parser.get("devices", "patterns", fallback="")
    patterns = [line.strip() for line in raw.splitlines() if line.strip()]
    if not patterns:
        log("config lists no device patterns, using built-in defaults")
        patterns = DEFAULT_PATTERNS

    try:
        max_lock = parser.getint("behaviour", "max_lock_seconds", fallback=0)
    except ValueError:
        raw_value = parser.get("behaviour", "max_lock_seconds", fallback="")
        log(f"max_lock_seconds={raw_value!r} is not an integer, using 0")
        max_lock = 0

    return patterns, max_lock


def find_devices(patterns):
    """Find event devices matching a pattern.

    Returns (matched, denied) where matched is [(path, name, fd)] and denied is
    the number of devices that could not be opened for lack of permission --
    the two failures look identical from the outside otherwise, and they have
    completely different causes.

    Devices that do not match are closed again immediately.
    """
    matched = []
    denied = 0
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError as exc:
            if exc.errno in (errno.EACCES, errno.EPERM):
                denied += 1
            log(f"cannot open {path}: {exc}")
            continue

        name = device_name(fd)
        if name is not None and any(fnmatch(name, p) for p in patterns):
            matched.append((path, name, fd))
        else:
            os.close(fd)
    return matched, denied


def read_key_bitmap(fd):
    """Current pressed-key bitmap for a device, or None if it cannot be read."""
    buf = bytearray(KEY_BITMAP_BYTES)
    try:
        fcntl.ioctl(fd, EVIOCGKEY(len(buf)), buf)
    except OSError:
        return None
    return buf


def key_is_set(bitmap, code):
    index = code // 8
    return index < len(bitmap) and bool(bitmap[index] & (1 << (code % 8)))


def held_sticky_keys(fds):
    """The STICKY_KEYS currently held down across the given devices."""
    held = set()
    for fd in fds:
        bitmap = read_key_bitmap(fd)
        if bitmap is None:
            continue
        held.update(code for code in STICKY_KEYS if key_is_set(bitmap, code))
    return held


def wait_for_sticky_keys_released(fds, timeout=2.0):
    """Block until no modifier (or Esc) is held, or until timeout.

    This matters at both ends of a lock. We are normally invoked *from* the
    Ctrl+Esc binding, so both keys are still physically down and the compositor
    has already seen their press. Grabbing at that moment means the compositor
    never sees the release and is left with a stuck Ctrl modifier. Same in
    reverse when we ungrab.

    Only modifiers and Esc are waited on -- see STICKY_KEYS for why the full
    keyboard would be the wrong thing to check on a folded-back laptop.
    """
    deadline = time.monotonic() + timeout
    while True:
        held = held_sticky_keys(fds)
        if not held:
            return True
        if time.monotonic() >= deadline:
            log(f"timed out waiting for keys {sorted(held)} to be released, "
                f"continuing anyway")
            return False
        time.sleep(0.02)


def set_grab(fd, name, grab):
    try:
        fcntl.ioctl(fd, EVIOCGRAB, 1 if grab else 0)
        return True
    except OSError as exc:
        verb = "grab" if grab else "release"
        log(f"failed to {verb} {name}: {exc}")
        return False


def write_state():
    """Publish the locked state. Returns False if it could not be written."""
    try:
        with open(STATE_PATH, "w") as handle:
            handle.write("locked\n")
        return True
    except OSError as exc:
        log(f"could not write {STATE_PATH}: {exc}")
        return False


def clear_state():
    try:
        os.unlink(STATE_PATH)
    except OSError as exc:
        if exc.errno != errno.ENOENT:
            log(f"could not remove {STATE_PATH}: {exc}")


def list_devices(patterns):
    print("Patterns:")
    for pattern in patterns:
        print(f"  {pattern}")
    print("\nDevices:")
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError as exc:
            print(f"  {path:22} <cannot open: {exc.strerror}>")
            continue
        try:
            name = device_name(fd) or "<unknown>"
        finally:
            os.close(fd)
        mark = "MATCH " if any(fnmatch(name, p) for p in patterns) else "      "
        print(f"  {mark}{path:22} {name}")
    return 0


class Locker:
    def __init__(self, devices, max_lock_seconds):
        self._devices = devices
        self._max_lock_seconds = max_lock_seconds
        self._grabbed = []
        self._ctrl_down = set()
        self._running = True

    @property
    def _fds(self):
        return [fd for _, _, fd in self._devices]

    def stop(self, signum=None, _frame=None):
        if signum is not None:
            log(f"received signal {signum}, releasing")
        self._running = False

    def grab_all(self):
        wait_for_sticky_keys_released(self._fds)
        for path, name, fd in self._devices:
            if set_grab(fd, name, True):
                self._grabbed.append((path, name, fd))
                log(f"grabbed {path} ({name})")
        # All or nothing. A partial grab is the worst outcome available: every
        # consumer reports "locked" and the icon turns red while the device
        # that failed -- quite possibly the keyboard -- keeps typing, which is
        # exactly the accidental input this tool exists to stop.
        if len(self._grabbed) != len(self._devices):
            held = {fd for _, _, fd in self._grabbed}
            for _, name, fd in self._devices:
                if fd not in held:
                    log(f"could not grab {name}; refusing a partial lock")
            self.release_all()
            return False

        self._discard_backlog()
        self._seed_modifier_state()
        return True

    def _discard_backlog(self):
        """Throw away everything queued between open() and the grab.

        evdev fills the queue from open() onward, whether or not we hold the
        grab, and we may have sat in wait_for_sticky_keys_released() for two
        seconds first. Those events already reached the compositor; replaying
        them through _handle_key() would be wrong, and actively dangerous --
        an Esc that the table pressed during the wait, or an impatient second
        Ctrl+Esc, would unlock again milliseconds after locking.
        """
        discarded = 0
        for _, _, fd in self._devices:
            while True:
                try:
                    data = os.read(fd, EVENT_SIZE * 64)
                except OSError:
                    break
                if not data:
                    break
                discarded += len(data) // EVENT_SIZE
        if discarded:
            log(f"discarded {discarded} event(s) queued before the grab")

    def _seed_modifier_state(self):
        """Record Ctrl keys that were already held when we grabbed.

        The wait above can time out -- someone holding Ctrl, or a folded
        keyboard pressing one against the table. Without seeding, _ctrl_down
        would start empty and the very next Esc would not be recognised as
        Ctrl+Esc, breaking the escape hatch until the user released and
        re-pressed Ctrl.
        """
        held = held_sticky_keys(self._fds)
        self._ctrl_down = {code for code in CTRL_KEYS if code in held}
        if self._ctrl_down:
            log(f"ctrl already held at grab time: {sorted(self._ctrl_down)}")

    def release_all(self):
        # Wait for a clean keyboard first so the compositor is not handed
        # release events for keys it never saw pressed.
        wait_for_sticky_keys_released(self._fds, timeout=1.0)
        for path, name, fd in self._grabbed:
            if set_grab(fd, name, False):
                log(f"released {path} ({name})")
        self._grabbed = []

    def _drop_device(self, dead_fd):
        """Forget a device that has gone away, so select() stops waking on it."""
        for entry in list(self._devices):
            path, name, fd = entry
            if fd != dead_fd:
                continue
            log(f"device disappeared, dropping {path} ({name})")
            self._devices.remove(entry)
            if entry in self._grabbed:
                self._grabbed.remove(entry)
            try:
                os.close(fd)
            except OSError:
                pass

    def _handle_key(self, code, value):
        """Return True if the release combo was pressed."""
        if code in CTRL_KEYS:
            # value 0 = up, 1 = down, 2 = autorepeat. Tracked per key so that
            # releasing one Ctrl while the other is held does not clear it.
            if value == 0:
                self._ctrl_down.discard(code)
            else:
                self._ctrl_down.add(code)
        elif code == KEY_ESC and value == 1 and self._ctrl_down:
            log("Ctrl+Esc detected, unlocking")
            return True
        return False

    def _drain(self, fd):
        """Read and interpret all pending events on one device.

        Returns DRAIN_RELEASE if the unlock combo was seen, DRAIN_DEAD if the
        device is gone, DRAIN_OK otherwise.
        """
        while True:
            try:
                data = os.read(fd, EVENT_SIZE * 64)
            except BlockingIOError:
                return DRAIN_OK
            except OSError as exc:
                # Anything other than "nothing to read" means this device is
                # not coming back -- typically an i2c-HID touchpad re-probed
                # across suspend. Returning OK here would leave a permanently
                # readable fd in the select set and spin the loop at 100% CPU.
                log(f"read error on fd {fd}: {exc}")
                return DRAIN_DEAD
            if not data:
                return DRAIN_OK

            for offset in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
                _, _, etype, code, value = EVENT_STRUCT.unpack_from(data, offset)
                if etype == EV_KEY and self._handle_key(code, value):
                    return DRAIN_RELEASE

            if len(data) < EVENT_SIZE * 64:
                return DRAIN_OK

    def run(self):
        deadline = (
            time.monotonic() + self._max_lock_seconds
            if self._max_lock_seconds > 0
            else None
        )

        while self._running:
            timeout = 1.0
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    log(f"max_lock_seconds ({self._max_lock_seconds}) reached, unlocking")
                    break
                timeout = min(timeout, remaining)

            try:
                readable, _, _ = select.select(self._fds, [], [], timeout)
            except InterruptedError:
                continue
            except OSError as exc:
                log(f"select failed: {exc}")
                break

            for fd in readable:
                outcome = self._drain(fd)
                if outcome == DRAIN_RELEASE:
                    return
                if outcome == DRAIN_DEAD:
                    self._drop_device(fd)
                    # The same all-or-nothing rule grab_all() applies at
                    # startup. Once a device is gone we can no longer hold a
                    # full lock, and staying alive would keep the state file --
                    # and the red icon -- advertising one over live input. A
                    # touchpad re-enumerated across suspend is the likely case.
                    # Exiting releases everything and lets the icon and the
                    # notification tell the truth.
                    log("a grabbed device disappeared; releasing the whole lock")
                    return


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--list",
        action="store_true",
        help="list input devices and which ones would be grabbed, then exit",
    )
    parser.add_argument(
        "--config", default=CONFIG_PATH, help=f"config file (default: {CONFIG_PATH})"
    )
    args = parser.parse_args()

    patterns, max_lock_seconds = read_patterns(args.config)

    if args.list:
        return list_devices(patterns)

    devices, denied = find_devices(patterns)
    if not devices:
        if denied:
            # Being root is not sufficient here: SELinux decides separately.
            # This is what a service running in the wrong domain looks like.
            log(f"permission denied opening {denied} input device(s)")
            log("running as root is not enough under SELinux -- the service "
                "must run in a domain allowed to read input devices")
            log("check: ls -Z on this daemon (expect bin_t, not lib_t), and "
                "sudo ausearch -m avc -ts recent")
        else:
            log("no input devices matched; refusing to start")
            log(f"patterns were: {patterns}")
        return 1

    # Non-blocking so a partial read can never wedge the loop.
    for _, _, fd in devices:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    locker = Locker(devices, max_lock_seconds)
    signal.signal(signal.SIGTERM, locker.stop)
    signal.signal(signal.SIGINT, locker.stop)

    grabbed = False
    published = False
    try:
        if not locker.grab_all():
            log("did not get an exclusive grab on every matched device; "
                "refusing to stay running")
            return 1
        grabbed = True

        # The state file is the single source of truth for every consumer. A
        # grab nobody can observe is worse than no grab at all -- hid-toggle
        # would report "NOT engaged" and the panel icon would show unlocked
        # while the keyboard was dead -- so treat this as fatal.
        if not write_state():
            log("refusing to hold a lock that nothing can observe")
            return 1
        published = True

        # Only now is the lock genuinely engaged, so this is where readiness
        # is reported. Anything that fails above fails `systemctl start` too.
        sd_notify("READY=1")

        locker.run()
    finally:
        sd_notify("STOPPING=1")
        if grabbed:
            locker.release_all()
        # Only remove a state file this process created. A second instance
        # started by hand gets EBUSY on every grab and exits -- if it cleared
        # the file on the way out it would tell the world "unlocked" while the
        # real daemon still held the keyboard, and StartUnit on an
        # already-active unit would not recreate it.
        if published:
            clear_state()
        for _, _, fd in devices:
            try:
                os.close(fd)
            except OSError:
                pass
        if grabbed:
            log("hid lock ended, input restored")

    return 0


if __name__ == "__main__":
    sys.exit(main())
