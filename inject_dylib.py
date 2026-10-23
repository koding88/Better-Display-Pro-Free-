#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Insert an LC_LOAD_DYLIB load command into a (fat) Mach-O, in-place.

Used to make a framework the app already loads (Sparkle) pull in our loader
dylib as a *declared* dependency — so it is mapped at launch like any normal
library and the app's anti-injection (dyld image monitoring) does not flag it.

The command is written into the zero padding between the end of the existing
load commands and the first section's file data, so file/slice offsets never
move (no fat-header fixups needed).

    python3 inject_dylib.py <macho> <@rpath/yourlib.dylib>
"""
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19


def make_cmd(name: str) -> bytes:
    raw = name.encode() + b"\x00"
    while len(raw) % 8:
        raw += b"\x00"
    cmdsize = 8 + 16 + len(raw)
    return struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000) + raw


def already_present(data: bytearray, base: int, name: str) -> bool:
    ncmds = struct.unpack("<I", data[base + 16:base + 20])[0]
    off = base + 32
    want = name.encode()
    for _ in range(ncmds):
        c, cs = struct.unpack("<II", data[off:off + 8])
        if c == LC_LOAD_DYLIB and want in bytes(data[off:off + cs]):
            return True
        off += cs
    return False


def insert_slice(data: bytearray, base: int, cmd: bytes) -> bool:
    magic = struct.unpack("<I", data[base:base + 4])[0]
    if magic != MH_MAGIC_64:
        raise SystemExit("slice at 0x%x is not a 64-bit Mach-O (0x%x)" % (base, magic))
    ncmds, sizeofcmds = struct.unpack("<II", data[base + 16:base + 24])
    off = base + 32
    first_data = None
    for _ in range(ncmds):
        c, cs = struct.unpack("<II", data[off:off + 8])
        if c == LC_SEGMENT_64:
            nsects = struct.unpack("<I", data[off + 64:off + 68])[0]
            so = off + 72
            for _s in range(nsects):
                secoff = struct.unpack("<I", data[so + 48:so + 52])[0]
                if secoff:
                    first_data = secoff if first_data is None else min(first_data, secoff)
                so += 80
        off += cs
    end_lc = 32 + sizeofcmds
    pad = (first_data if first_data is not None else end_lc) - end_lc
    if pad < len(cmd):
        raise SystemExit("not enough header padding in slice 0x%x (%d < %d)"
                         % (base, pad, len(cmd)))
    data[base + end_lc:base + end_lc + len(cmd)] = cmd
    struct.pack_into("<II", data, base + 16, ncmds + 1, sizeofcmds + len(cmd))
    return True


def main() -> None:
    if len(sys.argv) != 3:
        print("usage: inject_dylib.py <macho> <@rpath/lib.dylib>", file=sys.stderr)
        raise SystemExit(2)
    path, name = sys.argv[1], sys.argv[2]
    data = bytearray(open(path, "rb").read())
    cmd = make_cmd(name)
    magic = struct.unpack(">I", data[:4])[0]
    bases = []
    if magic == FAT_MAGIC:
        n = struct.unpack(">I", data[4:8])[0]
        for i in range(n):
            _ct, _cs, off, _sz, _al = struct.unpack(">IIIII", data[8 + i * 20:8 + i * 20 + 20])
            bases.append(off)
    else:
        bases.append(0)

    changed = False
    for b in bases:
        if already_present(data, b, name):
            print("  (slice 0x%x already loads %s)" % (b, name))
            continue
        insert_slice(data, b, cmd)
        changed = True
        print("  injected LC_LOAD_DYLIB %s into slice 0x%x" % (name, b))

    if changed:
        open(path, "wb").write(data)


if __name__ == "__main__":
    main()
