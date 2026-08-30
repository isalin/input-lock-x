# Copyright (C) 2026 Isak Lindgren
# SPDX-License-Identifier: GPL-2.0-or-later
"""Offline tests for the daemon's device classification and config parsing."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


DAEMON = Path(__file__).resolve().parents[1] / "daemon" / "input-lock-x-daemon.py"
spec = importlib.util.spec_from_file_location("input_lock_x_daemon", DAEMON)
daemon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(daemon)


def bitmap(codes, size):
    """Build the byte bitmap returned by an evdev capability ioctl."""
    result = bytearray(size)
    for code in codes:
        result[code // 8] |= 1 << (code % 8)
    return result


def device(name="device", bustype=0, props=(), keys=(), rels=(), abss=()):
    """Build a DeviceInfo without opening a real /dev/input node."""
    info = daemon.DeviceInfo.__new__(daemon.DeviceInfo)
    info.path = "/dev/input/event0"
    info.fd = -1
    info.name = name
    info.bustype = bustype
    info.props = bitmap(props, daemon.INPUT_PROP_BYTES)
    info.keys = bitmap(keys, daemon.KEY_CAP_BYTES)
    info.rels = bitmap(rels, daemon.REL_BYTES)
    info.abss = bitmap(abss, daemon.ABS_BYTES)
    info.kind = info._classify()
    return info


def auto_config(**overrides):
    values = {
        "mode": daemon.MODE_AUTO,
        "patterns": [],
        "exclude": [],
        "include_usb": False,
        "include_bluetooth": False,
        "max_lock_seconds": 0,
    }
    values.update(overrides)
    return daemon.Config(**values)


class ClassificationTests(unittest.TestCase):
    def test_direct_touchscreen_wins_over_other_capabilities(self):
        info = device(
            props=[daemon.INPUT_PROP_DIRECT, daemon.INPUT_PROP_POINTER],
            keys=[daemon.BTN_LEFT, *daemon.KEYBOARD_PROBE_KEYS],
            rels=[daemon.REL_X, daemon.REL_Y],
        )
        self.assertEqual(info.kind, daemon.CLASS_TOUCHSCREEN)

    def test_generic_multitouch_without_a_button_is_touchscreen(self):
        info = device(
            keys=[daemon.BTN_TOOL_FINGER],
            abss=[daemon.ABS_MT_POSITION_X],
        )
        self.assertEqual(info.kind, daemon.CLASS_TOUCHSCREEN)

    def test_pointer_and_buttonpad_are_pointers(self):
        pointer = device(
            props=[daemon.INPUT_PROP_POINTER],
            keys=[daemon.BTN_LEFT],
            rels=[daemon.REL_X, daemon.REL_Y],
        )
        buttonpad = device(props=[daemon.INPUT_PROP_BUTTONPAD])
        self.assertEqual(pointer.kind, daemon.CLASS_POINTER)
        self.assertEqual(buttonpad.kind, daemon.CLASS_POINTER)

    def test_keyboard_requires_all_probe_keys(self):
        keyboard = device(keys=daemon.KEYBOARD_PROBE_KEYS)
        sparse_keymap = device(keys=daemon.KEYBOARD_PROBE_KEYS[:-1])
        self.assertEqual(keyboard.kind, daemon.CLASS_KEYBOARD)
        self.assertEqual(sparse_keymap.kind, daemon.CLASS_OTHER)


class DecisionTests(unittest.TestCase):
    def test_auto_mode_grabs_internal_keyboard_and_pointer_only(self):
        config = auto_config()
        cases = (
            (device("keyboard", keys=daemon.KEYBOARD_PROBE_KEYS), True),
            (device("touchscreen", props=[daemon.INPUT_PROP_DIRECT]), False),
            (device("other"), False),
            (
                device("usb keyboard", daemon.BUS_USB,
                       keys=daemon.KEYBOARD_PROBE_KEYS),
                False,
            ),
            (
                device("virtual keyboard", daemon.BUS_VIRTUAL,
                       keys=daemon.KEYBOARD_PROBE_KEYS),
                False,
            ),
        )
        for info, expected in cases:
            with self.subTest(info=info.name):
                self.assertEqual(daemon.decide(info, config)[0], expected)

    def test_auto_mode_can_include_usb(self):
        info = device("internal usb keyboard", daemon.BUS_USB,
                      keys=daemon.KEYBOARD_PROBE_KEYS)
        grab, reason = daemon.decide(info, auto_config(include_usb=True))
        self.assertTrue(grab)
        self.assertIn("internal keyboard", reason)

    def test_patterns_override_safety_exemptions_but_not_exclude(self):
        config = auto_config(mode=daemon.MODE_PATTERNS, patterns=["*"],
                             exclude=["never"])
        touchscreen = device("touchscreen", props=[daemon.INPUT_PROP_DIRECT])
        usb = device("usb", daemon.BUS_USB, keys=daemon.KEYBOARD_PROBE_KEYS)
        virtual = device("virtual", daemon.BUS_VIRTUAL,
                         keys=daemon.KEYBOARD_PROBE_KEYS)
        excluded = device("never", keys=daemon.KEYBOARD_PROBE_KEYS)

        self.assertTrue(daemon.decide(touchscreen, config)[0])
        self.assertTrue(daemon.decide(usb, config)[0])
        self.assertTrue(daemon.decide(virtual, config)[0])
        self.assertFalse(daemon.decide(excluded, config)[0])

    def test_escape_routes_exclude_grabbed_and_virtual_devices(self):
        touchscreen = device("panel", props=[daemon.INPUT_PROP_DIRECT])
        pointer = device("mouse", props=[daemon.INPUT_PROP_POINTER])
        keyboard = device("spare keyboard", keys=daemon.KEYBOARD_PROBE_KEYS)
        virtual = device("virtual pointer", daemon.BUS_VIRTUAL,
                         props=[daemon.INPUT_PROP_POINTER])
        decisions = [
            (touchscreen, False, "kept"),
            (pointer, False, "kept"),
            (keyboard, True, "grabbed"),
            (virtual, False, "kept"),
        ]

        self.assertEqual(
            daemon.escape_routes(decisions),
            [
                "the touchscreen (tap the panel icon)",
                "an ungrabbed pointer (click the panel icon)",
            ],
        )


class ConfigTests(unittest.TestCase):
    def test_config_parses_multiline_patterns_and_scalar_comments(self):
        contents = """\
[devices]
mode = patterns  # use the explicit list
patterns = First Device
  Second Device
include_usb = yes  # an annotated boolean
include_bluetooth = no

[behaviour]
max_lock_seconds = 60  # release after one minute
"""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input-lock-x.conf"
            path.write_text(contents, encoding="utf-8")
            config = daemon.read_config(path)

        self.assertEqual(config.mode, daemon.MODE_PATTERNS)
        self.assertEqual(config.patterns, ["First Device", "Second Device"])
        self.assertTrue(config.include_usb)
        self.assertFalse(config.include_bluetooth)
        self.assertEqual(config.max_lock_seconds, 60)

    def test_negative_timeout_is_disabled(self):
        contents = "[behaviour]\nmax_lock_seconds = -60\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input-lock-x.conf"
            path.write_text(contents, encoding="utf-8")
            config = daemon.read_config(path)

        self.assertEqual(config.max_lock_seconds, 0)


if __name__ == "__main__":
    unittest.main()
