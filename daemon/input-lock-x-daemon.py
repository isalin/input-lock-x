#!/usr/bin/python3
# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
"""Input Lock X daemon.

Takes an exclusive EVIOCGRAB on the internal keyboard and pointers so that no
input from them reaches the compositor or any application. Because the grab is
exclusive to this process, this daemon is the only thing that can still see the
keyboard -- so it watches its own raw event stream for Ctrl+Esc and releases.

A grab lives and dies with the file descriptor: if this process is killed the
kernel releases it automatically. That is the failsafe, and the reason this is
preferred over /sys/class/input/inputN/inhibited (which persists).

Runs as root via input-lock-x.service. Stdlib only.
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

CONFIG_PATH = "/etc/input-lock-x.conf"
STATE_PATH = "/run/input-lock-x.state"

# struct input_event: struct timeval (2x long) + type + code + value. Native
# sizes, so this is correct on 32- and 64-bit alike.
EVENT_STRUCT = struct.Struct("llHHi")
EVENT_SIZE = EVENT_STRUCT.size

EV_KEY = 0x01
EV_REL = 0x02
EV_ABS = 0x03

# Bus types from <linux/input.h>. This is how auto mode tells an internal
# keyboard from one the user plugged in -- an external keyboard is both
# something they probably want to keep using and one of the ways back.
BUS_USB = 0x03
BUS_VIRTUAL = 0x06
BUS_BLUETOOTH = 0x05
BUS_NAMES = {
    0x01: "pci", 0x03: "usb", 0x05: "bluetooth", 0x06: "virtual",
    0x10: "isa", 0x11: "i8042", 0x18: "i2c", 0x19: "host",
    0x1C: "spi", 0x1D: "rmi",
}

# INPUT_PROP_* from <linux/input-event-codes.h>.
INPUT_PROP_POINTER = 0x00
INPUT_PROP_DIRECT = 0x01           # touchscreen: coordinates map to the screen
INPUT_PROP_BUTTONPAD = 0x02
INPUT_PROP_POINTING_STICK = 0x05
INPUT_PROP_BYTES = 4               # covers INPUT_PROP_MAX (0x1f)
PROP_NAMES = {
    INPUT_PROP_POINTER: "pointer",
    INPUT_PROP_DIRECT: "direct",
    INPUT_PROP_BUTTONPAD: "buttonpad",
    0x03: "semi_mt",
    0x04: "topbuttonpad",
    INPUT_PROP_POINTING_STICK: "pointing_stick",
    0x06: "accelerometer",
}

REL_X = 0x00
REL_Y = 0x01
REL_BYTES = 2

ABS_MT_POSITION_X = 0x35
ABS_BYTES = 8                      # covers ABS_MAX (0x3f)

BTN_LEFT = 0x110
BTN_TOOL_FINGER = 0x145

KEY_ESC = 1
KEY_LEFTCTRL = 29
KEY_LEFTSHIFT = 42
KEY_RIGHTSHIFT = 54
KEY_LEFTALT = 56
KEY_RIGHTCTRL = 97
KEY_RIGHTALT = 100
KEY_LEFTMETA = 125
KEY_RIGHTMETA = 126

# Probed against the *capability* bitmap to recognise a keyboard by what it can
# emit rather than by what it is called.
KEY_1 = 2
KEY_ENTER = 28
KEY_A = 30
KEY_Z = 44
KEY_SPACE = 57
KEYBOARD_PROBE_KEYS = (KEY_1, KEY_ENTER, KEY_A, KEY_Z, KEY_SPACE)

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

# Capability probing has to reach BTN_TOOL_FINGER at 0x145, so unlike the
# pressed-key check above it needs the whole KEY_MAX (0x2ff) range.
KEY_CAP_BYTES = 96

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


def EVIOCGPROP(length):
    return _IOC(_IOC_READ, "E", 0x09, length)


def EVIOCGBIT(ev, length):
    return _IOC(_IOC_READ, "E", 0x20 + ev, length)


EVIOCGID = _IOC(_IOC_READ, "E", 0x02, 8)


EVIOCGRAB = _IOC(_IOC_WRITE, "E", 0x90, ctypes.sizeof(ctypes.c_int))


def log(msg):
    """Log to stderr, which systemd routes to the journal."""
    print(msg, file=sys.stderr, flush=True)


def sd_notify(state):
    """Send a readiness message to systemd (Type=notify).

    Lets `systemctl start` -- and therefore the extension's StartUnit call and
    `input-lock-x on` -- fail honestly when the grab never happened, instead of
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


MODE_AUTO = "auto"
MODE_PATTERNS = "patterns"

CLASS_KEYBOARD = "keyboard"
CLASS_POINTER = "pointer"
CLASS_TOUCHSCREEN = "touchscreen"
CLASS_OTHER = "other"


class Config:
    """Parsed input-lock-x.conf."""

    def __init__(self, mode, patterns, exclude, include_usb, include_bluetooth,
                 max_lock_seconds):
        self.mode = mode
        self.patterns = patterns
        self.exclude = exclude
        self.include_usb = include_usb
        self.include_bluetooth = include_bluetooth
        self.max_lock_seconds = max_lock_seconds


def _lines(parser, section, option):
    raw = parser.get(section, option, fallback="")
    return [line.strip() for line in raw.splitlines() if line.strip()]


def _scalar(parser, section, option):
    """Read a single-value option, dropping any trailing `# ...` comment.

    ConfigParser is built without inline_comment_prefixes on purpose: a
    pattern is an evdev device name, an arbitrary vendor string that may
    legitimately contain a '#', and silently truncating one would grab the
    wrong device. But mode/include_usb/max_lock_seconds are keywords, numbers
    and booleans -- a '#' in those is always a comment, and treating it as
    part of the value made an annotated `max_lock_seconds = 60  # ...` fall
    back to 0, quietly disabling the auto-release safety net.
    """
    raw = parser.get(section, option, fallback="")
    for prefix in ("#", ";"):
        cut = raw.find(prefix)
        if cut != -1:
            raw = raw[:cut]
    return raw.strip()


BOOLEAN_WORDS = {
    "1": True, "yes": True, "true": True, "on": True,
    "0": False, "no": False, "false": False, "off": False,
}


def _flag(parser, section, option):
    raw = _scalar(parser, section, option)
    if not raw:
        return False
    value = BOOLEAN_WORDS.get(raw.lower())
    if value is None:
        log(f"{option}={raw!r} is not a yes/no value, using no")
        return False
    return value


def read_config(config_path):
    """Read the config, falling back to auto detection on anything unusable.

    Compatibility rule: a file that sets `patterns` but not `mode` is patterns
    mode. That is what every config written before auto detection existed looks
    like, and silently moving those machines onto a different set of devices
    would be the rudest possible upgrade.
    """
    # interpolation=None: device names are arbitrary strings and a bare '%' in
    # one would otherwise raise InterpolationSyntaxError out of get(), i.e.
    # outside the fallback handling below.
    parser = configparser.ConfigParser(interpolation=None)
    try:
        # open(), not ConfigParser.read(): read() catches OSError per file and
        # moves on, so an unreadable config -- an SELinux denial, mode 000, a
        # directory left in its place -- arrived here as the same empty result
        # as "no config at all" and silently moved a patterns-mode machine onto
        # auto detection. Opening it ourselves keeps absent and unreadable
        # distinct, and only one of the two is allowed to be quiet.
        try:
            with open(config_path, encoding="utf-8") as handle:
                text = handle.read()
        except FileNotFoundError:
            log(f"config {config_path} not found, using auto detection")
            text = ""
        parser.read_string(text, source=str(config_path))
    # UnicodeDecodeError is a ValueError, not a configparser.Error, so a
    # config saved in a single-byte encoding used to escape this handler and
    # kill the daemon with a traceback before it logged anything at all.
    except (configparser.Error, UnicodeDecodeError, OSError) as exc:
        log(f"config {config_path} is unreadable ({exc}), using auto detection")
        # Reset: read_string can fail partway and leave half a config behind.
        parser = configparser.ConfigParser(interpolation=None)

    patterns = _lines(parser, "devices", "patterns")
    exclude = _lines(parser, "devices", "exclude")

    mode = _scalar(parser, "devices", "mode").lower()
    if not mode:
        mode = MODE_PATTERNS if patterns else MODE_AUTO
    elif mode not in (MODE_AUTO, MODE_PATTERNS):
        log(f"mode={mode!r} is neither 'auto' nor 'patterns', using auto")
        mode = MODE_AUTO

    if mode == MODE_PATTERNS and not patterns:
        log("mode=patterns but no patterns are listed, using auto detection")
        mode = MODE_AUTO

    # The mirror case, and the easier one to walk into: the shipped config sets
    # mode = auto, so someone who only uncomments `patterns` gets auto
    # detection and no sign that the lines they added do nothing. Warn, but
    # leave the mode alone -- unlike patterns-with-no-patterns above, auto is a
    # working configuration, and overriding an explicit setting is worse than
    # saying what it means.
    if mode == MODE_AUTO and patterns:
        log("mode=auto, so the patterns in the config are ignored; "
            "set mode=patterns to use them")

    raw_max = _scalar(parser, "behaviour", "max_lock_seconds")
    try:
        max_lock = int(raw_max) if raw_max else 0
    except ValueError:
        log(f"max_lock_seconds={raw_max!r} is not an integer, using 0")
        max_lock = 0
    # int("-60") parses fine, and a negative deadline is silently treated as
    # "no limit" below -- indistinguishable from the 0 default. Someone who
    # means "off" gets what they wanted either way; someone who typed -60 for
    # 60 gets an unbounded lock and no hint. Say so.
    if max_lock < 0:
        log(f"max_lock_seconds={max_lock} is negative, using 0 (no limit)")
        max_lock = 0

    return Config(
        mode,
        patterns,
        exclude,
        _flag(parser, "devices", "include_usb"),
        _flag(parser, "devices", "include_bluetooth"),
        max_lock,
    )


def read_bitmap(fd, request, nbytes):
    """Read one evdev bitmap ioctl, or None if the device will not answer."""
    buf = bytearray(nbytes)
    try:
        fcntl.ioctl(fd, request, buf)
    except OSError:
        return None
    return buf


def bit_is_set(bitmap, code):
    index = code // 8
    return (bitmap is not None and index < len(bitmap)
            and bool(bitmap[index] & (1 << (code % 8))))


class DeviceInfo:
    """What the kernel says a device *is*, which is the part that generalises.

    Device names do not: they are whatever the vendor felt like, so the same
    touchpad is "SynPS/2 Synaptics TouchPad" on one machine and
    "MSFT0001:00 06CB:CE2D Touchpad" on the next. Capabilities and properties
    are the same everywhere, which is what makes auto mode work on hardware
    nobody has tested.
    """

    def __init__(self, path, fd, name):
        self.path = path
        self.fd = fd
        self.name = name

        # struct input_id is four __u16; the first is the bus type.
        ident = read_bitmap(fd, EVIOCGID, 8)
        self.bustype = struct.unpack_from("H", ident)[0] if ident else 0

        self.props = read_bitmap(fd, EVIOCGPROP(INPUT_PROP_BYTES), INPUT_PROP_BYTES)
        self.keys = read_bitmap(fd, EVIOCGBIT(EV_KEY, KEY_CAP_BYTES), KEY_CAP_BYTES)
        self.rels = read_bitmap(fd, EVIOCGBIT(EV_REL, REL_BYTES), REL_BYTES)
        self.abss = read_bitmap(fd, EVIOCGBIT(EV_ABS, ABS_BYTES), ABS_BYTES)
        self.kind = self._classify()

    def has_prop(self, prop):
        return bit_is_set(self.props, prop)

    def _classify(self):
        # Order matters. A touchscreen also reports keys (BTN_TOUCH) and
        # absolute axes, so INPUT_PROP_DIRECT has to be checked before anything
        # else gets the chance to call it a pointer and grab it.
        if self.has_prop(INPUT_PROP_DIRECT):
            return CLASS_TOUCHSCREEN

        has_pointer_prop = (self.has_prop(INPUT_PROP_POINTER)
                            or self.has_prop(INPUT_PROP_BUTTONPAD)
                            or self.has_prop(INPUT_PROP_POINTING_STICK))
        multitouch = (bit_is_set(self.abss, ABS_MT_POSITION_X)
                      and bit_is_set(self.keys, BTN_TOOL_FINGER))

        # A panel driven through a generic HID path can report multitouch
        # without ever setting INPUT_PROP_DIRECT, and would then fall through
        # to the pointer branch and be grabbed -- silently destroying the
        # escape hatch in exactly the tablet-mode case this tool is for.
        # BTN_LEFT is the discriminator: a touchpad has a physical button (or
        # is a BUTTONPAD, which is one), a touchscreen has nothing to press.
        # Guessing "touchscreen" here is the safe direction to be wrong in --
        # it under-locks, which is visible, rather than locking the way back.
        if multitouch and not has_pointer_prop and not bit_is_set(self.keys, BTN_LEFT):
            return CLASS_TOUCHSCREEN

        if (has_pointer_prop
                or multitouch
                or (bit_is_set(self.rels, REL_X)
                    and bit_is_set(self.rels, REL_Y)
                    and bit_is_set(self.keys, BTN_LEFT))):
            return CLASS_POINTER

        # Every one of these, not any: the point is to separate a real keyboard
        # from the sparse-keymap devices every laptop has -- power button, lid
        # switch, "Intel HID events", the volume rocker -- which all advertise
        # EV_KEY with a handful of codes and would otherwise look like one.
        if all(bit_is_set(self.keys, code) for code in KEYBOARD_PROBE_KEYS):
            return CLASS_KEYBOARD

        return CLASS_OTHER

    @property
    def bus_name(self):
        return BUS_NAMES.get(self.bustype, f"0x{self.bustype:02x}")

    @property
    def prop_names(self):
        names = sorted(label for prop, label in PROP_NAMES.items()
                       if self.has_prop(prop))
        return ",".join(names) or "-"


def decide(info, config):
    """Should this device be grabbed? Returns (grab, reason).

    The reason is not decoration. On hardware nobody has tested, `--list` and
    the startup log are the only way a user finds out why their keyboard was or
    was not covered.
    """
    if any(fnmatch(info.name, pattern) for pattern in config.exclude):
        return False, "excluded by config"

    if config.mode == MODE_PATTERNS:
        if not any(fnmatch(info.name, pattern) for pattern in config.patterns):
            return False, "no pattern matches"
        if info.kind == CLASS_TOUCHSCREEN:
            # Not overridden: an explicit pattern is an explicit choice. But it
            # is the escape hatch, so it does not happen quietly.
            return True, "matches a pattern -- WARNING, this is a touchscreen"
        return True, "matches a pattern"

    if info.kind == CLASS_TOUCHSCREEN:
        # The one rule auto mode will not break. Tapping the panel icon is the
        # only way back that needs neither a keyboard nor a second machine.
        return False, "touchscreen -- kept live as the way back"
    if info.kind == CLASS_OTHER:
        return False, "not a keyboard or pointer"
    if info.bustype == BUS_VIRTUAL:
        # uinput: input-remapper, keyd, kmonad, Steam Input, on-screen
        # keyboards, remote-desktop agents. Grabbing one blocks the events
        # another tool is injecting -- including, on a remapper setup, the
        # keyboard the user actually types on. The physical device underneath
        # it is a separate node and is still grabbed on its own merits.
        return False, "virtual device -- created by software, not locked"
    if info.bustype == BUS_USB and not config.include_usb:
        return False, "USB -- set include_usb = yes to grab it"
    if info.bustype == BUS_BLUETOOTH and not config.include_bluetooth:
        return False, "Bluetooth -- set include_bluetooth = yes to grab it"
    return True, f"internal {info.kind}"


def inspect_devices(config):
    """Open every event device and decide its fate.

    Returns (decisions, denied) where decisions is [(info, grab, reason)] with
    every fd still open, and denied counts the devices that could not be opened
    for lack of permission -- that failure looks identical to "nothing matched"
    from the outside and has a completely different cause.

    The caller owns every fd and must close the ones it does not keep.
    """
    decisions = []
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
        if name is None:
            os.close(fd)
            continue

        info = DeviceInfo(path, fd, name)
        grab, reason = decide(info, config)
        decisions.append((info, grab, reason))
    return decisions, denied


def find_devices(config):
    """The devices to grab, as [(path, name, fd)]. Everything else is closed.

    Also returns the full decision list, so the caller can report on what it is
    leaving live without opening every device a second time.
    """
    decisions, denied = inspect_devices(config)
    matched = []
    for info, grab, _reason in decisions:
        if grab:
            matched.append((info.path, info.name, info.fd))
        else:
            os.close(info.fd)
    return matched, denied, decisions


def escape_routes(decisions):
    """The ways back in that need no keyboard at all.

    Ctrl+Esc is not listed: it always works, because the daemon watches for it
    in its own grabbed stream. This is about what is left when the keyboard is
    face down on a table, which is the situation this tool exists for.
    """
    # A uinput node has nothing physical behind it, so it is never a way back
    # in -- and auto mode leaves every one of them ungrabbed, which means
    # without this filter a machine running input-remapper or a remote-desktop
    # agent would be told it has a route it cannot touch. This applies to all
    # three kinds: virtual pointers and virtual touchscreens exist too.
    def live(kind):
        return any(i.kind == kind and not g and i.bustype != BUS_VIRTUAL
                   for i, g, _ in decisions)

    routes = []
    if live(CLASS_TOUCHSCREEN):
        routes.append("the touchscreen (tap the panel icon)")
    if live(CLASS_POINTER):
        routes.append("an ungrabbed pointer (click the panel icon)")
    if live(CLASS_KEYBOARD):
        routes.append("an ungrabbed keyboard")
    return routes


def log_safety_notes(decisions):
    """Say what will still work once the grab is on -- before taking it."""
    for info, grab, _reason in decisions:
        if grab and info.kind == CLASS_TOUCHSCREEN:
            log(f"WARNING: {info.name} is a touchscreen and a pattern matched "
                f"it; the panel icon will not be tappable while locked")

    routes = escape_routes(decisions)
    if routes:
        log("ways back without the keyboard: " + ", ".join(routes))
    else:
        log("WARNING: nothing usable stays live -- no touchscreen, pointer or "
            "spare keyboard")
        log("WARNING: the only ways back will be Ctrl+Esc and SSH from another "
            "machine")


def read_key_bitmap(fd):
    """Current pressed-key bitmap for a device, or None if it cannot be read."""
    buf = bytearray(KEY_BITMAP_BYTES)
    try:
        fcntl.ioctl(fd, EVIOCGKEY(len(buf)), buf)
    except OSError:
        return None
    return buf


def held_sticky_keys(fds):
    """The STICKY_KEYS currently held down across the given devices."""
    held = set()
    for fd in fds:
        bitmap = read_key_bitmap(fd)
        if bitmap is None:
            continue
        held.update(code for code in STICKY_KEYS if bit_is_set(bitmap, code))
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


def list_devices(config):
    """Print every device, the verdict on it, and why. Grabs nothing."""
    decisions, denied = inspect_devices(config)

    print(f"mode: {config.mode}")
    # Printed in both modes. --list is where someone goes to find out why
    # their patterns did nothing, so this is the last place to omit them.
    for pattern in config.patterns:
        inert = "" if config.mode == MODE_PATTERNS else "  (ignored: mode is auto)"
        print(f"  pattern: {pattern}{inert}")
    for pattern in config.exclude:
        print(f"  exclude: {pattern}")
    if config.include_usb:
        print("  include_usb: yes")
    if config.include_bluetooth:
        print("  include_bluetooth: yes")

    print("\nDevices:")
    for info, grab, reason in decisions:
        print(f"  {'GRAB' if grab else 'skip'}  {info.name}")
        print(f"        {info.path}  bus={info.bus_name}  "
              f"kind={info.kind}  props={info.prop_names}")
        print(f"        -> {reason}")
        os.close(info.fd)

    grabbed = sum(1 for _, grab, _ in decisions if grab)
    print(f"\n{grabbed} device(s) would be grabbed.")

    routes = escape_routes(decisions)
    if routes:
        print("Ways back without the keyboard: " + ", ".join(routes))
    else:
        print("WARNING: nothing usable would stay live. The only ways back "
              "would be\n         Ctrl+Esc and SSH from another machine.")

    if denied:
        print(f"\n{denied} device(s) could not be opened -- run this as root.")
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
        """Forget a device that has gone away.

        Close its fd and drop the entry from both _devices and _grabbed. The
        _grabbed removal is the load-bearing one: main()'s finally calls
        release_all(), which set_grab()s every remaining entry, and a closed fd
        there means a spurious "[Errno 9] Bad file descriptor" on every
        device-disappeared shutdown.

        Not about select(): the one caller returns immediately afterwards, so
        the loop is never re-entered.
        """
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

            # No InterruptedError arm: PEP 475 makes select() retry on EINTR
            # itself, so a signal never surfaces here -- SIGTERM runs stop(),
            # which only clears the flag, and this call keeps waiting out its
            # timeout. Shutdown therefore lags by up to `timeout` (1.0s), well
            # inside the unit's TimeoutStopSec=5.
            try:
                readable, _, _ = select.select(self._fds, [], [], timeout)
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

    config = read_config(args.config)

    if args.list:
        return list_devices(config)

    devices, denied, decisions = find_devices(config)
    if not devices:
        if denied:
            # Being root is not sufficient here: SELinux decides separately.
            # This is what a service running in the wrong domain looks like.
            log(f"permission denied opening {denied} input device(s)")
            log("running as root is not enough under SELinux -- the service "
                "must run in a domain allowed to read input devices")
            log("check: ls -Z on this daemon (expect bin_t, not lib_t), and "
                "sudo ausearch -m avc -ts recent")
        elif config.mode == MODE_PATTERNS:
            log("no input devices matched; refusing to start")
            log(f"patterns were: {config.patterns}")
            log("compare against --list, or drop `patterns` from the config "
                "to use auto detection instead")
        else:
            log("auto detection found no internal keyboard or pointer; "
                "refusing to start")
            log("see --list for what is there; an internal device on USB needs "
                "include_usb = yes")
        return 1

    log_safety_notes(decisions)

    # Non-blocking so a partial read can never wedge the loop.
    for _, _, fd in devices:
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)

    locker = Locker(devices, config.max_lock_seconds)
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
        # grab nobody can observe is worse than no grab at all -- input-lock-x
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
        # Only if READY=1 went out. Both returns above leave without ever
        # having reported readiness, and STOPPING=1 from a service that never
        # started is a protocol lie; the non-zero exit is what systemd should
        # be reading there.
        if published:
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
            log("input lock ended, input restored")

    return 0


if __name__ == "__main__":
    sys.exit(main())
