#!/usr/bin/env python3
"""Write a copy of a 4-channel MOD that keeps only one channel's notes.

The other channels keep only effects that change the song flow (Bxx position
jump, Dxx pattern break, Fxx speed, E6x loop, EEx pattern delay), so timing
is unchanged.

usage: solo_mod.py in.mod out.mod channel(0-3)
"""

import sys


def solo(data, keep):
    data = bytearray(data)
    patterns = max(data[952:1080]) + 1
    for p in range(patterns):
        for row in range(64):
            for ch in range(4):
                if ch == keep:
                    continue
                o = 1084 + p * 1024 + row * 16 + ch * 4
                cmd, arg = data[o + 2] & 0x0f, data[o + 3]
                flow = cmd in (0xb, 0xd, 0xf) or (cmd == 0xe and arg >> 4 in (0x6, 0xe))
                data[o:o + 4] = bytes([0, 0, cmd if flow else 0, arg if flow else 0])
    return bytes(data)


if __name__ == "__main__":
    src, dst, ch = sys.argv[1], sys.argv[2], int(sys.argv[3])
    open(dst, "wb").write(solo(open(src, "rb").read(), ch))
