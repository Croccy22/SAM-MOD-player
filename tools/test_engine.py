#!/usr/bin/env python3
"""Play a MOD through the SAM MOD player's SAMantha device, emulated.

Runs the assembled player code in a Z80 emulator with a SAM memory map:
burstplayer.create for the engine device, tracker.init, tracker.install.mod,
engine.enable, then the engine run time's frame interrupt once per frame.
Every write to the engine's ports is captured, and a model of the engine
(written from docs/sample-engine.md) renders them to a WAV file.

usage: test_engine.py song.mod out.wav [seconds] [--ntsc] [--log regs.txt]

needs: obj/ from build.sh, pip install z80 numpy
"""

import argparse
import os
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import test_install as ti  # noqa: E402

PAGE_CREATE, PAGE_BURST, PAGE_TRACKER, PAGE_DEMO = 0x19, 0x1a, 0x1c, 0x1f
SE_INDEX, SE_DATA = 0xc0, 0xc1
STATUS = 0xf9
FRAME_RATE = 6_000_000 / 119_808        # SAM frame rate, 50.08 Hz
PAL, NTSC = 3_546_895, 3_579_545


class SamEngine(ti.Sam):
    """SAM with the sample engine's two ports (writes logged)."""

    def __init__(self, megabytes):
        super().__init__(megabytes)
        self.index = 0
        self.writes = []                # (index, value) this frame
        self.frame_interrupt = False

    def out(self, port, value):
        low = port & 0xff
        if low == SE_INDEX:
            self.index = value & 0x7f
        elif low == SE_DATA:
            self.writes.append((self.index, value))
            self.index = (self.index + 1) & 0x7f
        else:
            super().out(port, value)

    def inp(self, port):
        low = port & 0xff
        if low == STATUS:
            return 0xf7 if self.frame_interrupt else 0xff   # bit 3 low = frame
        if low == SE_DATA:
            reg = self.index
            self.index = (self.index + 1) & 0x7f
            return {0x7e: 0x53, 0x7f: 0x01}.get(reg, 0xff)
        return super().inp(port)

    def call_at(self, addr, sp=0x7ff0):
        m = self.m
        self.mem[ti.RETURN] = 0x76
        m.sp = sp - 2
        m.memory[m.sp] = ti.RETURN & 0xff
        m.memory[m.sp + 1] = ti.RETURN >> 8
        m.pc = addr
        m.set_breakpoint(ti.RETURN)
        for _ in range(10_000_000):
            m.run()
            if m.pc == ti.RETURN:
                break
        else:
            raise RuntimeError(f"call {addr:#06x} did not return")
        self.flush()


def setup(mod, ntsc=False, megabytes=4):
    bsym = ti.symbols(os.path.join(ROOT, "src", "burstplayer.s"))
    tsym = ti.symbols(os.path.join(ROOT, "src", "tracker", "tracker.s"))
    sam = SamEngine(megabytes)

    def put(page, data):
        data = data.ljust((len(data) + 16383) // 16384 * 16384, b"\0")
        for i in range(0, len(data), 16384):
            sam.internal[page + i // 16384][:] = np.frombuffer(data[i:i + 16384], np.uint8)

    put(PAGE_CREATE, open(os.path.join(ROOT, "obj", "burstplayer"), "rb").read())
    put(PAGE_TRACKER, open(os.path.join(ROOT, "obj", "tracker"), "rb").read())
    data = np.frombuffer(mod, np.uint8)
    for p in range(0, len(mod), 16384):
        sam.external[p // 16384][:len(data[p:p + 16384])] = data[p:p + 16384]

    # burstplayer.create, as device.s does
    c = sam.internal[PAGE_CREATE]
    c[bsym["burstplayer.device"] - 0x8000] = bsym["device.engine"]
    c[bsym["burstplayer.amiga"] - 0x8000] = 1 if ntsc else 0
    c[bsym["burstplayer.ram"] - 0x8000] = megabytes * 4 + 2
    c[bsym["burstplayer.page"] - 0x8000] = PAGE_BURST
    sam.lmpr, sam.hmpr = 0x20, PAGE_CREATE
    sam.load()
    sam.call_at(bsym["burstplayer.create"], sp=0x5000)

    # tracker.init and tracker.install.mod, as demo.s does
    t = sam.internal[PAGE_TRACKER]
    t[tsym["tracker.ram"] - 0x8000] = megabytes * 4 + 2
    t[tsym["tracker.ptr.page.mod"] - 0x8000] = 0
    sam.lmpr, sam.hmpr = 0x20, PAGE_TRACKER
    sam.load()
    sam.call_at(tsym["tracker.init"], sp=0x5000)
    sam.lmpr, sam.hmpr = 0x20, PAGE_TRACKER
    sam.load()
    sam.call_at(tsym["tracker.install.mod"], sp=0x5000)

    # playing: burst page low, demo page high. The demo sets int.rtn.pag to
    # -1 (no extra interrupt routine) before it enables the player
    sam.internal[PAGE_BURST][tsym["int.rtn.pag"]] = 0xff
    sam.lmpr, sam.hmpr = 0x20 | PAGE_BURST, PAGE_DEMO
    sam.load()
    sam.call_at(bsym["engine.enable"])
    return sam, bsym, tsym


def run_frames(sam, bsym, frames):
    """Return a list of register write lists, one per frame (first = enable)."""
    log = [sam.writes]
    for _ in range(frames):
        sam.writes = []
        sam.frame_interrupt = True
        sam.call_at(bsym["engine.interrupt"])
        sam.frame_interrupt = False
        log.append(sam.writes)
    return log


class Engine:
    """Model of the SAMantha (docs/sample-engine.md, draft 2)."""

    def __init__(self, memory, rate=48000, oversample=4):
        self.memory = memory                    # bytes, external memory
        self.regs = [0] * 0x80
        self.enabled = False
        self.ntsc = False
        self.filter = False
        self.separation = 255
        self.master = 64
        self.rate = rate
        self.os = oversample
        self.ch = [dict(playing=False, addr=0, left=0, phase=0.0, held=0,
                        period=0, volume=0, loop=0, looplen=0, pend_loop=None)
                   for _ in range(4)]
        self.lp = [np.zeros(2), np.zeros(2)]

    @staticmethod
    def linear(lo, hi, page):
        return page * 16384 + ((hi << 8 | lo) & 0x3fff)

    def write(self, index, value):
        if index == 0x40:
            self.enabled = bool(value & 1)
            if not self.enabled:
                for c in self.ch:
                    c.update(playing=False, held=0)
                self.filter = False
                return
            self.ntsc = bool(value & 2)
            self.filter = bool(value & 4)
            return
        if not self.enabled:
            return
        self.regs[index] = value
        if index == 0x41:
            self.separation = value
        elif index == 0x42:
            self.master = min(value, 64)
        elif index < 0x40:
            n, r = divmod(index, 16)
            c, g = self.ch[n], self.regs[n * 16:n * 16 + 16]
            if r == 0x9:                        # LOOPLEN_H commits LOOP + LOOPLEN
                c["loop"] = self.linear(g[5], g[6], g[7])
                c["looplen"] = (g[8] | g[9] << 8) or 65536
            elif r == 0xb:
                c["period"] = g[10] | g[11] << 8
            elif r == 0xc:
                c["volume"] = min(value, 64)
            elif r == 0xd:
                if value & 1:
                    c["playing"] = True
                    c["addr"] = self.linear(g[0], g[1], g[2])
                    c["left"] = ((g[3] | g[4] << 8) or 65536) * 2
                    c["phase"] = 0.0
                elif value & 2:
                    c.update(playing=False, held=0)

    def render(self, samples):
        """Render `samples` output samples with the current registers."""
        n = samples * self.os
        clock = NTSC if self.ntsc else PAL
        t = np.arange(n) / (self.rate * self.os)
        out = np.zeros((2, n))
        for i, c in enumerate(self.ch):
            if not c["playing"] or not c["period"]:
                level = np.full(n, c["held"] * c["volume"] if c["playing"] else 0.0)
            else:
                period = max(c["period"], 28)
                step = clock / period                       # bytes per second
                pos = c["phase"] + t * step                 # fractional byte index
                idx = np.floor(pos).astype(np.int64)        # byte being held
                total = int(np.floor(c["phase"] + n / (self.rate * self.os) * step))
                looplen = c["looplen"] * 2
                first = c["left"]
                addr = np.where(idx < first, c["addr"] + idx,
                                c["loop"] + (idx - first) % looplen)
                addr = np.minimum(addr, len(self.memory) - 1)
                byte = self.memory[addr].astype(np.int8).astype(float)
                # before the first byte arrives the previous level holds;
                # ignore that (a few microseconds)
                level = byte * c["volume"]
                c["held"] = byte[-1]
                # advance state
                if total < first:
                    c["addr"] += total
                    c["left"] = first - total
                else:
                    into = (total - first) % looplen
                    c["addr"] = c["loop"] + into
                    c["left"] = looplen - into
                c["phase"] = c["phase"] + n / (self.rate * self.os) * step - total
            side = 0 if i in (0, 3) else 1
            out[side] += level
        # separation: (L+R)/2 +- (L-R) * k/512
        k = 256 if self.separation == 255 else self.separation
        mid, diff = (out[0] + out[1]) / 2, (out[0] - out[1]) * k / 512
        mix = np.stack([mid + diff, mid - diff]) * self.master / 64
        # decimate (box filter)
        mix = mix.reshape(2, -1, self.os).mean(axis=2)
        if self.filter:                                     # LED filter, 2-pole 3.09 kHz
            mix = self.led(mix)
        return mix / (128 * 64 * 2) * 32767

    def led(self, mix):
        f, q = 3090.0, 0.66
        w = 2 * np.pi * f / self.rate
        alpha = np.sin(w) / (2 * q)
        b0 = (1 - np.cos(w)) / 2
        b = np.array([b0, 2 * b0, b0]) / (1 + alpha)
        a = np.array([1, -2 * np.cos(w), 1 - alpha]) / (1 + alpha)
        out = np.empty_like(mix)
        for s in range(2):
            x1 = x2 = 0.0
            y1, y2 = self.lp[s]
            for i, x in enumerate(mix[s]):
                y = b[0] * x + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
                x2, x1, y2, y1 = x1, x, y1, y
                out[s, i] = y
            self.lp[s] = np.array([y1, y2])
        return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("mod")
    ap.add_argument("wav")
    ap.add_argument("seconds", type=float, nargs="?", default=30)
    ap.add_argument("--ntsc", action="store_true")
    ap.add_argument("--log", help="write every frame's register writes to this file")
    ap.add_argument("--frame-rate", type=float, default=FRAME_RATE,
                    help="frames per second (default the SAM's 50.08)")
    args = ap.parse_args()

    mod = open(args.mod, "rb").read()
    sam, bsym, tsym = setup(mod, args.ntsc)
    frames = int(args.seconds * args.frame_rate)
    log = run_frames(sam, bsym, frames)

    memory = np.frombuffer(b"".join(bytes(p) for p in sam.external), np.uint8)
    engine = Engine(memory)
    chunks, done = [], 0
    for i, writes in enumerate(log):
        for index, value in writes:
            engine.write(index, value)
        upto = int(round((i + 1) * engine.rate / args.frame_rate))
        chunks.append(engine.render(upto - done))
        done = upto
    audio = np.clip(np.concatenate(chunks, axis=1), -32768, 32767).astype(np.int16)

    with wave.open(args.wav, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(engine.rate)
        w.writeframes(audio.T.tobytes())

    if args.log:
        with open(args.log, "w") as f:
            for i, writes in enumerate(log):
                if writes:
                    f.write(f"{i:5} " + " ".join(f"{a:02x}={v:02x}" for a, v in writes) + "\n")

    triggers = sum(1 for writes in log for a, v in writes if a < 0x40 and a % 16 == 0xd and v & 1)
    print(f"{frames} frames, {triggers} notes started, wrote {args.wav}")


if __name__ == "__main__":
    main()
