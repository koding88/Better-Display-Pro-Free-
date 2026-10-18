#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Patch a copy of BetterDisplay 3.5.6 (40870) for a local Paddle licence server.

What gets patched
-----------------
1. Paddle.framework base URL:
       https://v3.paddleapi.com/3.2/  ->  http://127.0.0.1:8543/3.2/xxx
   (same length, so Mach-O offsets / CFString lengths stay valid)

2. BetterDisplay's own "list activations" URL:
       https://v3.paddleapi.com/3.2/license/activations
    -> http://127.0.0.1:8543/3.2/xx/license/activations

3. -[PADProduct destroyActivation] -> immediate return.
   BetterDisplay asks Paddle to remove the licence whenever its online
   verification fails.  With the local server that should not happen, but
   the app also calls this during its own licence-state handling; making it
   a no-op keeps the local licence file alive when the server is not running.

The framework is universal (x86_64 + arm64).  Function offsets are checked
against known byte signatures before anything is written; a different
BetterDisplay/Paddle build is rejected instead of being silently corrupted.
"""
import struct
import sys
from pathlib import Path

PORT = 8543

OLD_BASE = b"https://v3.paddleapi.com/3.2/"
NEW_BASE = b"http://127.0.0.1:%d/3.2/xxx" % PORT
assert len(OLD_BASE) == len(NEW_BASE) == 29

OLD_ACT = b"https://v3.paddleapi.com/3.2/license/activations"
NEW_ACT = b"http://127.0.0.1:%d/3.2/xx/license/activations" % PORT
assert len(OLD_ACT) == len(NEW_ACT) == 48

# Paddle.framework 4.4.3 (shipped with BetterDisplay 3.5.6 / 40870)
# (slice-relative file offset, expected leading bytes, replacement bytes)
DESTROY_PATCH = {
    0x0100000C: (0xB704, bytes.fromhex("fd7bbfa9fd030091"),
                 bytes.fromhex("c0035fd61f2003d5")),          # arm64: ret; nop
    0x01000007: (0xAF5F, bytes.fromhex("554889e5488b351e"),
                 bytes.fromhex("c390909090909090")),          # x86_64: ret; nops
}


def die(msg: str) -> None:
    print("ERROR: " + msg, file=sys.stderr)
    raise SystemExit(1)


def replace_all(data: bytearray, old: bytes, new: bytes) -> int:
    if len(old) != len(new):
        die("replacement length mismatch")
    n = data.count(old)
    if not n:
        return 0
    data[:] = data.replace(old, new)
    return n


def fat_slices(data: bytes):
    """Yield (cputype, offset, size) for a 32-bit fat Mach-O."""
    if len(data) < 8:
        die("file too small to be a Mach-O")
    magic = struct.unpack(">I", data[:4])[0]
    if magic != 0xCAFEBABE:
        die("not a universal (fat) Mach-O")
    n = struct.unpack(">I", data[4:8])[0]
    if n < 1 or n > 16:
        die("unexpected fat architecture count: %d" % n)
    for i in range(n):
        base = 8 + i * 20
        cputype, _cpusubtype, offset, size, _align = struct.unpack(
            ">IIIII", data[base:base + 20])
        yield cputype, offset, size


def patch_framework(path: Path) -> None:
    data = bytearray(path.read_bytes())

    n = replace_all(data, OLD_BASE, NEW_BASE)
    if n < 1:
        die("Paddle base URL not found (wrong Paddle version?)")
    print("  Paddle base URL -> localhost: %d occurrence(s)" % n)

    seen = set()
    for cputype, offset, size in fat_slices(bytes(data)):
        if cputype not in DESTROY_PATCH:
            print("  (skipping unknown architecture 0x%x)" % cputype)
            continue
        rel, expected, patch = DESTROY_PATCH[cputype]
        pos = offset + rel
        if pos + len(expected) > len(data):
            die("patch offset outside file for architecture 0x%x" % cputype)
        got = bytes(data[pos:pos + len(expected)])
        if got != expected:
            die("destroyActivation signature mismatch for architecture 0x%x\n"
                "      expected %s\n      found    %s\n"
                "      This is not BetterDisplay 3.5.6 / Paddle 4.4.3."
                % (cputype, expected.hex(), got.hex()))
        data[pos:pos + len(patch)] = patch
        seen.add(cputype)
        print("  destroyActivation no-op: arch 0x%x @ +0x%x" % (cputype, rel))

    for cputype in DESTROY_PATCH:
        if cputype not in seen:
            die("missing architecture 0x%x in Paddle.framework" % cputype)

    path.write_bytes(data)


def patch_app(path: Path) -> None:
    data = bytearray(path.read_bytes())
    n = replace_all(data, OLD_ACT, NEW_ACT)
    if n < 1:
        die("BetterDisplay activations URL not found (wrong app version?)")
    print("  activations URL -> localhost: %d occurrence(s)" % n)
    path.write_bytes(data)


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: patch_binary.py /Applications/BetterDisplay\\ Free.app",
              file=sys.stderr)
        raise SystemExit(2)
    app = Path(sys.argv[1]).resolve()
    fw = app / "Contents/Frameworks/Paddle.framework/Versions/A/Paddle"
    exe = app / "Contents/MacOS/BetterDisplay"
    if not fw.is_file() or not exe.is_file():
        die("not a BetterDisplay app bundle: %s" % app)

    print("→ patching Paddle.framework")
    patch_framework(fw)
    print("→ patching BetterDisplay executable")
    patch_app(exe)
    print("→ binary patches OK")


if __name__ == "__main__":
    main()
