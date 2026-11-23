#!/usr/bin/env python3
"""Check the SAMantha stereo separation (key S) in a Z80 emulator.

- engine.enable starts every tune at 25% (SEPARATION 64)
- the demo's stereo.send sends the chosen value, stereo.next steps
  100 -> 75 -> 60 -> 50 -> 25 -> 0% -> 100%
- stereo.send leaves interrupts off when paused and on otherwise
- other devices: stereo.send writes nothing
- rendered with the engine model, a left-only channel at 25% comes out
  62.5% left, 37.5% right

usage: test_stereo.py   (needs obj/ from build.sh, pip install z80 numpy)
"""

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import test_engine as te  # noqa: E402
import test_install as ti  # noqa: E402

BP_DEVICE = 105                         # memory.i: bp.device (burst page)
STEPS = [255, 191, 153, 128, 64, 0]     # demo.s: stereo.values


def make_mod():
    """A 31-sample M.K. MOD: one looped square-wave sample, played by
    channel 0 only (a left channel) for one pattern."""
    mod = bytearray(b"stereo test".ljust(20, b"\0"))
    length = 512
    for i in range(31):
        name = bytearray(22)
        if i == 0:
            mod += name + length.to_bytes(2, "big") + bytes([0, 64]) + (0).to_bytes(2, "big") + length.to_bytes(2, "big")
        else:
            mod += name + bytes([0, 0, 0, 0, 0, 0, 0, 1])
    mod += bytes([1, 127]) + bytes(128) + b"M.K."
    pattern = bytearray(1024)
    pattern[0:4] = bytes([0x01, 0xac, 0x10, 0x00])        # sample 1, period 428 (C-2)
    mod += pattern
    mod += bytes(([100] * 8 + [156] * 8) * (length * 2 // 16))
    return bytes(mod)


def main():
    ok = True

    def check(cond, text):
        nonlocal ok
        ok &= bool(cond)
        print(("  ok    " if cond else "  FAIL  ") + text)

    mod = make_mod()
    sam, bsym, tsym = te.setup(mod)
    enable = sam.writes
    check((0x41, 64) in enable, f"engine.enable writes SEPARATION 64 (writes: {[(f'{a:02x}', v) for a, v in enable if a >= 0x40]})")

    # the demo, as boot.s loads it: page 0x1f from offset 0x2000, run with
    # HMPR = page.demo - 1 (its code in section D)
    dsym = ti.symbols(os.path.join(ROOT, "src", "demo", "demo.s"))
    demo = np.frombuffer(open(os.path.join(ROOT, "obj", "demo"), "rb").read(), np.uint8)
    sam.internal[te.PAGE_DEMO][0x2000:0x2000 + len(demo)] = demo
    sam.lmpr, sam.hmpr = 0x20 | te.PAGE_BURST, te.PAGE_DEMO - 1
    sam.load()
    check(sam.mem[BP_DEVICE] == bsym["device.engine"], "bp.device is SAMantha")
    check(sam.mem[dsym["stereo.step"]] == 4, "stereo.step starts at 25%")

    def send(paused):
        sam.writes = []
        sam.m.iff1 = sam.m.iff2 = 1
        sam.m.a = 1 if paused else 0
        sam.call_at(dsym["stereo.send"])
        return sam.writes, sam.m.iff1

    writes, iff = send(False)
    check(writes == [(0x41, 64)] and iff, "after enable: sends 64, interrupts on")

    seen = []
    for _ in range(len(STEPS)):
        sam.call_at(dsym["stereo.next"])
        writes, iff = send(False)
        seen.append(writes[0][1] if len(writes) == 1 and writes[0][0] == 0x41 else writes)
        if not iff:
            check(False, "interrupts on after S while playing")
    check(seen == [0, 255, 191, 153, 128, 64], f"S steps 0, 100, 75, 60, 50, 25%: {seen}")

    writes, iff = send(True)
    check(writes == [(0x41, 64)] and not iff, "while paused: sends, interrupts stay off")

    sam.internal[te.PAGE_BURST][BP_DEVICE] = 0
    sam.load()
    writes, iff = send(False)
    check(writes == [] and iff, "other device: nothing written")

    # sound: channel 0 only, at 25%, 60%, 100% and mono
    for sep, want in ((64, 0.6), (153, 0.25), (255, 0.0), (0, 1.0)):
        sam2, bsym2, _ = te.setup(mod)
        log = te.run_frames(sam2, bsym2, 50)
        memory = np.frombuffer(b"".join(bytes(p) for p in sam2.external), np.uint8)
        engine = te.Engine(memory)
        audio = []
        for i, writes in enumerate(log):
            for index, value in writes:
                engine.write(index, value)
            if i == 0:
                engine.write(0x41, sep)
            audio.append(engine.render(960))
        audio = np.concatenate(audio, axis=1)[:, 4800:]
        left, right = np.sqrt((audio ** 2).mean(axis=1))
        check(left > 100 and abs(right / left - want) < 0.01,
              f"SEPARATION {sep}: right / left = {right / left:.3f} (want {want})")

    print("ALL STEREO CHECKS PASS" if ok else "STEREO CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
