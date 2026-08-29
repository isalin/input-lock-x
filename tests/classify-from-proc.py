#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Drive the real classifier with bitmaps from /proc/bus/input/devices.

The B: lines in that file are the same capability bitmaps EVIOCGBIT returns,
printed as space-separated unsigned longs, most significant group first. That
makes it a root-free way to check classification against real hardware -- run it
on a new distro or a new laptop before trusting `--list`, which needs root.

Usage: python3 tests/classify-from-proc.py [expected-grab-name ...]
Exits non-zero if the set of grabbed devices differs from the names given.
"""
import importlib.util, pathlib, struct, sys

# The kernel prints these bitmaps as `unsigned long`, so the group width is the
# word size of the running kernel, not a constant. Hardcoding 8 silently
# misparsed every bitmap on a 32-bit machine -- exactly the armhf/i686 hardware
# where checking classification before trusting the grab matters most.
LONG_BYTES = struct.calcsize("l")

# Relative to this file, not the CWD: the docstring tells people to run it on a
# new laptop to check classification, and they will not be standing in the
# repository root when they do.
DAEMON = pathlib.Path(__file__).resolve().parent.parent / "daemon" / "input-lock-x-daemon.py"
spec = importlib.util.spec_from_file_location("d", DAEMON)
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def bitmap(hex_groups, nbytes):
    buf = bytearray(nbytes)
    for i, group in enumerate(reversed(hex_groups.split())):
        value = int(group, 16)
        for byte in range(LONG_BYTES):
            index = i * LONG_BYTES + byte
            if index < nbytes:
                buf[index] = (value >> (byte * 8)) & 0xFF
    return buf


def parse(path="/proc/bus/input/devices"):
    devices, cur = [], None
    for line in open(path):
        line = line.rstrip("\n")
        if line.startswith("I: "):
            cur = {"bits": {}}
            devices.append(cur)
            for field in line[3:].split():
                k, _, v = field.partition("=")
                if k == "Bus":
                    cur["bus"] = int(v, 16)
        elif cur is None:
            continue
        elif line.startswith("N: Name="):
            cur["name"] = line.split("=", 1)[1].strip('"')
        elif line.startswith("H: Handlers="):
            ev = [h for h in line.split("=", 1)[1].split() if h.startswith("event")]
            cur["path"] = "/dev/input/" + ev[0] if ev else "?"
        elif line.startswith("B: "):
            k, _, v = line[3:].partition("=")
            cur["bits"][k] = v
    return [x for x in devices if "name" in x]


def make(dev):
    info = d.DeviceInfo.__new__(d.DeviceInfo)
    info.path, info.name, info.fd = dev.get("path", "?"), dev["name"], -1
    info.bustype = dev.get("bus", 0)
    b = dev["bits"]
    info.props = bitmap(b.get("PROP", "0"), d.INPUT_PROP_BYTES)
    info.keys = bitmap(b.get("KEY", "0"), d.KEY_CAP_BYTES)
    info.rels = bitmap(b.get("REL", "0"), d.REL_BYTES)
    info.abss = bitmap(b.get("ABS", "0"), d.ABS_BYTES)
    info.kind = info._classify()
    return info


config = d.read_config("/nonexistent")           # -> auto mode
print(f"mode: {config.mode}\n")
decisions = []
for dev in parse():
    info = make(dev)
    grab, reason = d.decide(info, config)
    decisions.append((info, grab, reason))
    print(f"  {'GRAB' if grab else 'skip'}  {info.name}")
    print(f"        bus={info.bus_name}  kind={info.kind}  props={info.prop_names}")
    print(f"        -> {reason}")

print("\nescape routes:", d.escape_routes(decisions))

actual_grab = {i.name for i, g, _ in decisions if g}
if len(sys.argv) > 1:
    expected_grab = set(sys.argv[1:])
    print("\nexpected GRAB:", sorted(expected_grab))
    print("actual   GRAB:", sorted(actual_grab))
    sys.exit(0 if actual_grab == expected_grab else 1)
print(f"\n{len(actual_grab)} device(s) would be grabbed:", sorted(actual_grab))
