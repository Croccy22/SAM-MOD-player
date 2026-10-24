#!/usr/bin/env python3
"""Run the tracker's mod install (tracker.init + tracker.install.mod) in a Z80
emulator with a full SAM memory map and external memory, then check that every
sample ended up intact where the sample table says it is.

usage: test_install.py song.mod [megabytes]   (needs obj/tracker, pip install z80 numpy)
"""

import ast
import os
import subprocess
import sys

import numpy as np
import z80

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PAGE_TRACKER, PAGE_BURST = 0x1c, 0x1a
LMPR, HMPR = 0xfa, 0xfb
XMPR_C, XMPR_D = 0x80, 0x81
RETURN = 0x6000


def symbols(source):
    out = subprocess.run(["pyz80", "-x", "-s", ".", "--obj=" + os.devnull, source],
                         check=True, capture_output=True, text=True).stdout
    table = ast.literal_eval(next(line for line in out.splitlines() if line.startswith("{")))
    return {k: int(v, 16) for k, v in table.items()}


class Sam:
    def __init__(self, megabytes):
        self.internal = [np.zeros(16384, np.uint8) for _ in range(32)]
        self.external = [np.zeros(16384, np.uint8) for _ in range(megabytes * 64)]
        self.rom = np.zeros(16384, np.uint8)
        self.lmpr, self.hmpr, self.xmpr = 0, 0, [0, 1]
        self.m = z80.Z80Machine()
        self.m.set_output_callback(self.out)
        self.m.set_input_callback(self.inp)
        self.mem = np.frombuffer(self.m.memory, np.uint8)
        self.mapped = self.sections()
        self.snapshot = [b.copy() for b in self.mapped]
        self.load()

    def ext(self, page):
        if page < len(self.external):
            return self.external[page]
        return np.full(16384, 0xff, np.uint8)   # no memory fitted there

    def sections(self):
        a = self.internal[self.lmpr & 0x1f] if self.lmpr & 0x20 else self.rom
        b = self.internal[(self.lmpr + 1) & 0x1f]
        if self.hmpr & 0x80:
            c, d = self.ext(self.xmpr[0]), self.ext(self.xmpr[1])
        else:
            c = self.internal[self.hmpr & 0x1f]
            d = self.internal[(self.hmpr + 1) & 0x1f]
        return [a, b, c, d]

    def flush(self):
        # write back only bytes changed since mapping, so pages mapped twice stay right
        for i, backing in enumerate(self.mapped):
            now = self.mem[i * 16384:(i + 1) * 16384]
            changed = now != self.snapshot[i]
            backing[changed] = now[changed]

    def load(self):
        self.mapped = self.sections()
        for i, backing in enumerate(self.mapped):
            self.mem[i * 16384:(i + 1) * 16384] = backing
        self.snapshot = [self.mem[i * 16384:(i + 1) * 16384].copy() for i in range(4)]

    def out(self, port, value):
        port &= 0xff
        if port in (LMPR, HMPR, XMPR_C, XMPR_D):
            self.flush()
            if port == LMPR:
                self.lmpr = value
            elif port == HMPR:
                self.hmpr = value
            else:
                self.xmpr[port - XMPR_C] = value
            self.load()

    def inp(self, port):
        port &= 0xff
        return {LMPR: self.lmpr, HMPR: self.hmpr}.get(port, 0xff)

    def call(self, addr, a=0):
        m = self.m
        self.mem[RETURN] = 0x76                     # halt
        m.sp = 0x7000
        m.memory[m.sp - 2] = RETURN & 0xff
        m.memory[m.sp - 1] = RETURN >> 8
        m.sp -= 2
        m.a = a
        m.pc = addr
        m.set_breakpoint(RETURN)
        for _ in range(100_000_000):
            m.run()
            if m.pc == RETURN:
                break
        else:
            raise RuntimeError("did not return")
        self.flush()


def main():
    mod = open(sys.argv[1], "rb").read()
    megabytes = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    sym = symbols(os.path.join(ROOT, "src", "tracker", "tracker.s"))
    tracker = open(os.path.join(ROOT, "obj", "tracker"), "rb").read()

    sam = Sam(megabytes)
    image = tracker.ljust(32768, b"\0")
    sam.internal[PAGE_TRACKER][:] = np.frombuffer(image[:16384], np.uint8)
    sam.internal[PAGE_TRACKER + 1][:] = np.frombuffer(image[16384:32768], np.uint8)
    sam.internal[PAGE_BURST][53:56] = np.frombuffer(b"BUR", np.uint8)      # bp.id
    data = np.frombuffer(mod, np.uint8)
    for p in range(0, len(mod), 16384):
        sam.external[p // 16384][:len(data[p:p + 16384])] = data[p:p + 16384]

    # what demo.s sets up before calling the tracker
    sam.lmpr, sam.hmpr = 0x20, PAGE_TRACKER
    sam.load()
    t = sam.internal[PAGE_TRACKER]
    t[sym["tracker.ram"] - 0x8000] = megabytes * 4 + 2          # 512K + megabytes
    t[sym["tracker.ptr.page.mod"] - 0x8000] = 0
    sam.load()

    sam.call(sym["tracker.init"])
    sam.lmpr, sam.hmpr = 0x20, PAGE_TRACKER
    sam.load()
    sam.call(sym["tracker.install.mod"])

    # sample table (sample 0 is the silent one inserted at the end of install)
    t = sam.internal[PAGE_TRACKER]
    table = sym["sample.table"] - 0x8000
    pats = max(mod[952:1080]) + 1
    offset = 1084 + pats * 1024
    ok = True

    def read_ext(page, addr, n):
        out = bytearray()
        while n:
            take = min(n, 16384 - (addr - 0x8000))
            out += bytes(sam.ext(page)[addr - 0x8000:addr - 0x8000 + take])
            n -= take
            page, addr = page + 1, 0x8000
        return bytes(out)

    for i in range(31):
        e = 20 + i * 30
        length = int.from_bytes(mod[e + 22:e + 24], "big") * 2
        original = mod[offset:offset + length]
        offset += length
        if not length:
            continue
        st = table + (i + 1) * 16
        addr = int(t[st]) | int(t[st + 1]) << 8
        page = int(t[st + 2])
        got = read_ext(page, addr, length)
        same = got == original
        ok &= same
        where = f"page {page:3} ({page:#04x}) addr {addr:#06x}"
        first = "" if same else f" first bad byte {next(k for k in range(length) if got[k] != original[k])}"
        print(f"sample {i + 1:2} len {length:6} {where} {'ok' if same else 'CORRUPT' + first}")

    print("ALL SAMPLES INTACT" if ok else "SAMPLES DAMAGED")


if __name__ == "__main__":
    main()
