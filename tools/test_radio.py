#!/usr/bin/env python3
"""The Radio Station's SAM side in a Z80 emulator.

Runs the assembled loader (loader/radio.s, with the ADOS overlay over fat.s)
and the demo's radio code against a pretend samfpga comms port: a stand-in
for the board's ESP32 that answers AT$RADIO commands as its modem does
(samfpga esp32/sam_companion/radio.h), with echo and results switchable.
The ADOS load itself is a breakpoint here (radio.load.vector), as are the
loader's entry points the radio goes back to.

usage: test_radio.py   (needs pyz80 and pip install z80; assembles the player
                        with tools/build_ados_test.sh first)
"""

import ast
import os
import subprocess
import sys

import z80

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

PAGE_SCREEN, PAGE_LOADER = 0x1e, 0x1f
STUB_LOAD = 0x7000                  # stands in for the ADOS overlay's @radio.load
STACK = 0x7f00
VAR = 256


def symbols(src, extra=()):
    out = subprocess.run(["pyz80", "-x", "-s", ".", "--obj=" + os.devnull, *extra, src],
                         check=True, capture_output=True, text=True, cwd=ROOT).stdout
    table = ast.literal_eval(next(line for line in out.splitlines() if line.startswith("{")))
    return {n: int(v, 16) for n, v in table.items()}


class Esp:
    """The board's ESP32 behind the comms port: lines in, answers out."""

    def __init__(self, answers=None, echo=True, results=True):
        self.answers = answers or {}    # command -> list of answers, used in turn (the last repeats)
        self.echo, self.results = echo, results
        self.got = []                   # commands received
        self.out = bytearray()
        self.line = bytearray()
        self.controls = []

    def byte(self, b):
        if self.echo:
            self.out.append(b)
        if b != 13:
            self.line.append(b)
            return
        cmd = self.line.decode()
        self.line.clear()
        if not cmd:
            return
        self.got.append(cmd)
        a = self.answers.get(cmd.split(",")[0] if cmd.startswith("AT$RADIO=ON") else cmd, ["ERROR"])
        reply = a.pop(0) if len(a) > 1 else a[0]
        lines = reply.split("\n") if reply else []
        if lines and lines[-1] == "ERROR":
            body, end = lines[:-1], "ERROR"
        else:
            body, end = lines, "OK"
        for ln in body:
            self.out += b"\r\n" + ln.encode()
        if self.results:
            self.out += b"\r\n" + end.encode() + b"\r\n"


class Sam:
    def __init__(self, esp=None, mb=4, ram512=True, board=True):
        self.ls = symbols("src/loader/loader.s")
        subprocess.run(["bash", "tools/build_ados_test.sh", "/tmp/radio_test.mgt"], check=True, cwd=ROOT, capture_output=True)
        loader = open(os.path.join(ROOT, "obj", "loader"), "rb").read()
        ados = open(os.path.join(ROOT, "obj", "ados"), "rb").read()
        self.esp = esp or Esp()
        self.board = board
        self.esc_presses = 0            # ESC: pressed (and let go) after this many reads (0: never)
        self.esc_reads = 0
        self.statuses = []              # bottom-line texts (radio.status)
        m = self.m = z80.Z80Machine()
        mem = m.memory
        # the loader as boot puts it: the multi-part 2K at 0xb800, then the loader page
        mem[0xb800:0xc000] = loader[:0x800]
        mem[0xc000:0xc000 + len(loader) - 0x800] = loader[0x800:]
        fdr = self.ls["fat.disk.read"]
        mem[fdr:fdr + len(ados)] = ados
        mem[self.ls["loader.ram"]] = (mb * 4 if mb else 0) + (2 if ram512 else 1)
        self.ads = symbols("src/loader/ados.s", ["--importfile=obj/loader.sym"])
        m.set_output_callback(self.out)
        m.set_input_callback(self.inp)
        for a in (self.ls["loader"], STUB_LOAD, self.ls["radio.status"]):
            m.set_breakpoint(a)

    def peek_str(self, a, n=80):
        return bytes(self.m.memory[a:a + n]).split(b"\0")[0].decode()

    def out(self, port, value):
        port &= 0xff
        if port == 197:
            self.esp.byte(value)
        elif port == 196:
            self.esp.controls.append(value)
            if value & 1:
                self.esp.out.clear()

    def inp(self, port):
        p = port & 0xff
        if p == 196:
            if not self.board:
                return 0xff
            return 0x66 | (1 if self.esp.out else 0)        # ID 01, DTR, LINK, TXE (+ RXR)
        if p == 197:
            return self.esp.out.pop(0) if self.esp.out else 0
        if p == 0xf9 and (port >> 8) == 0xf7:                # ESC row
            self.esc_reads += 1
            if self.esc_presses and self.esc_reads >= self.esc_presses and self.esc_reads < self.esc_presses + 3:
                return 0xff & ~0x20
            return 0xff
        return 0xff

    def call(self, entry, stack=()):
        """Runs from entry (a symbol) until the radio leaves: 'loader', 'load' or 'ret'."""
        m = self.m
        sp = STACK
        for w in reversed(list(stack) + [0xfffe]):             # a return address that's caught
            sp -= 2
            m.memory[sp] = w & 0xff
            m.memory[sp + 1] = w >> 8
        m.sp = sp
        m.pc = self.ls[entry]
        m.set_breakpoint(0xfffe)
        for _ in range(2_000_000):
            m.run()
            if m.pc == self.ls["radio.status"]:
                self.statuses.append(self.peek_str(m.de, 32))
                m.step_over_breakpoint()
            elif m.pc == self.ls["loader"]:
                return "loader"
            elif m.pc == STUB_LOAD:
                return "load"
            elif m.pc == 0xfffe:
                return "ret"
        raise RuntimeError("didn't finish: pc %04x" % m.pc)

    def vars(self):
        mem = self.m.memory
        return mem[self.ls["radio.on"]], mem[self.ls["radio.action"]]


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f" - {detail}" if detail else ""))
    return ok


def ready_sam(esp, **kw):
    s = Sam(esp, **kw)
    vec = s.ls["radio.load.vector"]
    s.m.memory[vec] = STUB_LOAD & 0xff                      # (ados.s sets it at each listing)
    s.m.memory[vec + 1] = STUB_LOAD >> 8
    return s


def loader_tests():
    ok = True
    READY = "READY \\RADIO\\R0001.MOD\nINFO Jester - Elysium"

    # 1. no board: says so, back to the file list
    s = ready_sam(Esp(), board=False)
    r = s.call("radio.start", [0])
    ok &= check("no board: back to the list", r == "loader" and s.vars()[0] == 0, r)
    ok &= check("no board: why", "Needs the SAM FPGA board's Wi-Fi" in s.statuses, str(s.statuses))
    ok &= check("no board: nothing sent", not s.esp.got)

    # 2. an ESP32 without the radio (ERROR)
    s = ready_sam(Esp())
    r = s.call("radio.start", [0])
    ok &= check("old ESP32: back to the list", r == "loader" and s.vars()[0] == 0, r)
    ok &= check("old ESP32: why", s.statuses[-1] == "Update the board's ESP32", str(s.statuses))

    # 3. no ADOS overlay (the vector never set)
    s = Sam(Esp({"AT$RADIO=ON": ["RADIO ON"]}))
    r = s.call("radio.start", [0])
    ok &= check("no ADOS: back to the list", r == "loader" and s.statuses[-1] == "The radio needs ADOS" and not s.esp.got, str(s.statuses))

    # 4. on, a wait, then a tune; 4 MB of external memory
    esp = Esp({"AT$RADIO=ON": ["RADIO ON"], "AT$RADIO=NEXT": ["WAIT Finding a tune...", READY]})
    s = ready_sam(esp)
    r = s.call("radio.start", [0])
    ok &= check("on: SHOW=MUSIC (the board's LEDs: the equaliser), then ON with the memory", esp.got[:2] == ["AT$SHOW=MUSIC", "AT$RADIO=ON,4096"], str(esp.got))
    ok &= check("on: NEXT asked twice (WAIT, then READY)", esp.got[2:] == ["AT$RADIO=NEXT", "AT$RADIO=NEXT"], str(esp.got))
    ok &= check("on: the wait shown", "Finding a tune..." in s.statuses, str(s.statuses))
    ok &= check("on: loads the tune", r == "load" and s.peek_str(s.m.hl) == "\\RADIO\\R0001.MOD", f"{r} {s.peek_str(s.m.hl)!r}")
    ok &= check("on: the type on the stack, as select.key keeps it",
                s.m.memory[s.m.sp + 1] == 0 and s.m.sp == STACK - 4, hex(s.m.sp))    # (push af: a, the type, on top)
    ok &= check("on: radio on, action cleared", s.vars() == (1, 0), str(s.vars()))
    ok &= check("on: the receive buffer emptied before each command", esp.controls.count(7) == 4, str(esp.controls))
    info = s.peek_str(s.ls["radio.info"])
    ok &= check("on: INFO kept", info == "Jester - Elysium", repr(info))

    # 5. after the tune (ended / N): the next one
    esp.answers["AT$RADIO=NEXT"] = ["READY \\RADIO\\R0002.MOD"]
    esp.got.clear()
    s.m.memory[s.ls["radio.action"]] = 1
    r = s.call("radio.after")
    ok &= check("after N: NEXT, then loads", esp.got == ["AT$RADIO=NEXT"] and r == "load" and s.peek_str(s.m.hl) == "\\RADIO\\R0002.MOD", f"{esp.got} {r}")
    ok &= check("after N: action cleared", s.vars() == (1, 0))

    # 6. a tune that wouldn't load: BAD, then the next
    esp.got.clear()
    r = s.call("radio.failed")
    ok &= check("failed: BAD then NEXT", esp.got == ["AT$RADIO=BAD", "AT$RADIO=NEXT"] and r == "load", str(esp.got))

    # 7. ESC in the demo: OFF, back to the list
    esp.answers["AT$RADIO=OFF"] = [""]
    esp.got.clear()
    s.m.memory[s.ls["radio.action"]] = 2
    r = s.call("radio.after")
    ok &= check("ESC: OFF, back to the list", esp.got == ["AT$RADIO=OFF"] and r == "loader" and s.vars()[0] == 0, f"{esp.got} {r}")

    # 8. ESC while waiting
    esp = Esp({"AT$RADIO=ON": ["RADIO ON"], "AT$RADIO=NEXT": ["WAIT No Wi-Fi"], "AT$RADIO=OFF": [""]})
    s = ready_sam(esp)
    s.esc_presses = 50
    r = s.call("radio.start", [0])
    ok &= check("ESC while waiting: OFF, back to the list", r == "loader" and esp.got[-1] == "AT$RADIO=OFF" and s.vars()[0] == 0, f"{r} {esp.got}")
    ok &= check("ESC while waiting: the wait shown", "No Wi-Fi" in s.statuses, str(s.statuses))

    # 9. echo off and no results (ATE0 ATQ1): READY is still taken, after the quiet time
    esp = Esp({"AT$RADIO=ON": ["RADIO ON"], "AT$RADIO=NEXT": [READY]}, echo=False, results=False)
    s = ready_sam(esp, mb=0)
    r = s.call("radio.start", [0])
    ok &= check("quiet modem: loads", r == "load" and s.peek_str(s.m.hl) == "\\RADIO\\R0001.MOD", r)
    ok &= check("512K, no external memory: 384K", esp.got[1] == "AT$RADIO=ON,0384", esp.got[1])

    s = ready_sam(Esp({"AT$RADIO=ON": ["RADIO ON"], "AT$RADIO=NEXT": [READY]}), mb=0, ram512=False)
    s.call("radio.start", [0])
    ok &= check("256K: 128K", s.esp.got[1] == "AT$RADIO=ON,0128", s.esp.got[1])
    s = ready_sam(Esp({"AT$RADIO=ON": ["RADIO ON"], "AT$RADIO=NEXT": [READY]}), mb=1)
    s.call("radio.start", [0])
    ok &= check("1 MB: 1024K", s.esp.got[1] == "AT$RADIO=ON,1024", s.esp.got[1])

    # 10. a long INFO line: kept to 63 characters, the rest dropped
    long = "INFO " + "x" * 90
    esp = Esp({"AT$RADIO=ON": ["RADIO ON"], "AT$RADIO=NEXT": ["READY \\RADIO\\R0001.MOD\n" + long]})
    s = ready_sam(esp)
    s.call("radio.start", [0])
    info = s.peek_str(s.ls["radio.info"], 100)
    ok &= check("long INFO cut", info == "x" * 58, f"{len(info)} {info[:10]!r}")
    return ok


def demo_tests():
    ok = True
    ds = symbols("src/demo/demo.s")
    demo = open(os.path.join(ROOT, "obj", "demo"), "rb").read()
    on, action = ds["radio.on"], ds["radio.action"]
    disable_pos, countint, maxpos = VAR + 54, VAR + 41, VAR + 56
    esp = Esp(echo=False)
    keys = {"f": False, "n": False, "esc": False}

    m = z80.Z80Machine()
    # the demo file loads at demo.setup (0x6000); all but its start runs 0x8000
    # higher (section D), with the screen page (and the radio's variables) in C
    split = ds["demo.palette"] - 0x8000 - ds["demo.setup"]
    m.memory[ds["demo.setup"]:ds["demo.setup"] + split] = demo[:split]
    m.memory[ds["demo.palette"]:ds["demo.palette"] + len(demo) - split] = demo[split:]

    def inp(port):
        p, row = port & 0xff, port >> 8
        if p == 196:
            return 0x66
        if p == 0xf9 and row == 0xf7:
            return 0xff & ~0x20 if keys["esc"] else 0xff
        if p == 0xfe and row == 0x7f:
            return 0xff & ~0x08 if keys["n"] else 0xff
        if p == 0xfe and row == 0xfd:
            return 0xff & ~0x08 if keys["f"] else 0xff
        return 0xff

    m.set_input_callback(inp)
    m.set_output_callback(lambda port, v: esp.byte(v) if port & 0xff == 197 else None)

    def call(entry):
        m.sp = STACK - 2
        m.memory[m.sp:m.sp + 2] = b"\xfe\xff"
        m.pc = ds[entry]
        m.set_breakpoint(0xfffe)
        for _ in range(100000):
            m.run()
            if m.pc == 0xfffe:
                return not (m.f & 0x40)     # True: carry on (nz)
        raise RuntimeError(entry)

    m.memory[on] = 0
    m.memory[disable_pos] = 2
    call("radio.demo.start")
    ok &= check("demo, radio off: disable.pos 2 back to 0", m.memory[disable_pos] == 0 and not esp.got)
    m.memory[disable_pos] = 1
    call("radio.demo.start")
    ok &= check("demo, radio off: L's setting kept", m.memory[disable_pos] == 1)

    m.memory[on] = 1
    m.memory[maxpos] = 9
    m.memory[countint] = 200
    keys["f"] = True                                        # held from before
    call("radio.demo.start")
    ok &= check("demo start: PLAYING sent", esp.got == ["AT$RADIO=PLAYING"], str(esp.got))
    ok &= check("demo start: stop at the end, positions from 0", m.memory[disable_pos] == 2 and m.memory[maxpos] == 0)
    ok &= check("demo: F held from before doesn't count", call("radio.demo.poll") and esp.got == ["AT$RADIO=PLAYING"], str(esp.got))
    keys["f"] = False
    call("radio.demo.poll")
    keys["f"] = True
    r1 = call("radio.demo.poll")
    r2 = call("radio.demo.poll")
    ok &= check("demo: F once per press", r1 and r2 and esp.got == ["AT$RADIO=PLAYING", "AT$RADIO=FAV"], str(esp.got))
    keys["f"] = False
    keys["n"] = True                                        # held from the last tune's N
    call("radio.demo.start")
    ok &= check("demo: N held from before doesn't count", call("radio.demo.poll"))
    keys["n"] = False
    call("radio.demo.poll")
    keys["n"] = True
    ok &= check("demo: N stops it, action next", not call("radio.demo.poll") and m.memory[action] == 1)
    keys["n"] = False
    m.memory[action] = 0
    keys["esc"] = True
    ok &= check("demo: ESC stops it, action stop", not call("radio.demo.poll") and m.memory[action] == 2)
    keys["esc"] = False
    m.memory[action] = 9

    # the time: 7 minutes of frames (countint wraps every 256)
    call("radio.demo.start")
    frames, stopped = 0, None
    while frames < 22000:
        frames += 50
        m.memory[countint] = (m.memory[countint] + 50) & 0xff
        if not call("radio.demo.poll"):
            stopped = frames
            break
    ok &= check("demo: stops after 7 minutes", stopped is not None and 21000 <= stopped <= 21050 and m.memory[action] == 0, f"after {stopped} frames")
    return ok


def tracker_tests():
    """next.position (tracker.s, the shared part): the end of a tune."""
    ok = True
    ts = symbols("src/tracker/tracker.s")
    code = open(os.path.join(ROOT, "obj", "tracker"), "rb").read()
    pos, dpos, mst, pmax = ts["song.position"], ts["disable.pos"], ts["mstatus"], ts["song.position.max"]

    def step(position, disable, length=10, maxp=0, jumped_to=None):
        m = z80.Z80Machine()
        m.memory[0x8000:0x8000 + len(code)] = code[:0x8000]
        m.memory[ts["song.length"]] = length
        m.memory[pos] = position if jumped_to is None else (jumped_to - 1) & 0xff   # (a "B": parameter - 1)
        m.memory[dpos], m.memory[mst], m.memory[pmax] = disable, 0, maxp
        m.sp = STACK - 2
        m.memory[m.sp:m.sp + 2] = b"\xfe\xff"
        m.pc = ts["next.position"]
        m.set_breakpoint(0xfffe)
        for _ in range(100000):
            m.run()
            if m.pc == 0xfffe:
                return m.memory[pos], m.memory[mst], m.memory[pmax]
        raise RuntimeError("next.position")

    ok &= check("tracker: on as before", step(3, 0) == (4, 0, 0), str(step(3, 0)))
    ok &= check("tracker: repeats at the end as before", step(9, 0)[:2] == (0, 0), str(step(9, 0)))
    ok &= check("tracker: L stops at the end as before", step(9, 1)[1] == 1, str(step(9, 1)))
    ok &= check("radio: on, furthest kept", step(3, 2, maxp=3) == (4, 0, 4), str(step(3, 2, maxp=3)))
    ok &= check("radio: a jump on is fine", step(3, 2, maxp=3, jumped_to=7) == (7, 0, 7), str(step(3, 2, maxp=3, jumped_to=7)))
    ok &= check("radio: a jump back ends it", step(6, 2, maxp=6, jumped_to=2)[1] == 1, str(step(6, 2, maxp=6, jumped_to=2)))
    ok &= check("radio: a jump to here ends it", step(6, 2, maxp=6, jumped_to=6)[1] == 1, str(step(6, 2, maxp=6, jumped_to=6)))
    ok &= check("radio: back to the start ends it", step(6, 2, maxp=6, jumped_to=0)[1] == 1, str(step(6, 2, maxp=6, jumped_to=0)))
    ok &= check("radio: the last position ends it", step(9, 2, maxp=9)[1] == 1, str(step(9, 2, maxp=9)))
    ok &= check("radio: the first position on from 0", step(0, 2) == (1, 0, 1), str(step(0, 2)))
    return ok


def listing_tests():
    """ados.s: the Radio Station moved to the very top of the list, above the drives (27 Nov 2026)."""
    ok = True
    s = ready_sam(Esp())
    m, a, L = s.m, s.ads, s.ads["loader.dir.len"]
    names = [b"drive 1", b"drive 2", b"..", b"Radio Station"]
    for n in (2, 3, 4):                         # one drive; two; two and ".."
        rows = names[:n - 1] + names[-1:]
        for i, r in enumerate(rows):
            m.memory[a["loader.dir"] + i * L:a["loader.dir"] + (i + 1) * L] = (r.ljust(L, b"#"))[:L]
        m.memory[a["loader.entries"]] = n
        end = a["loader.dir"] + n * L
        m.memory[a["@entry"]], m.memory[a["@entry"] + 1] = end & 0xff, end >> 8
        m.memory[a["loader.radio.top"]] = 0
        sp = STACK - 2
        m.memory[sp], m.memory[sp + 1] = 0xfe, 0xff
        m.sp, m.pc = sp, a["@radio.to.top"]
        m.set_breakpoint(0xfffe)
        for _ in range(1000):
            m.run()
            if m.pc == 0xfffe:
                break
        got = [bytes(m.memory[a["loader.dir"] + i * L:a["loader.dir"] + (i + 1) * L]).rstrip(b"#") for i in range(n)]
        want = [names[-1]] + names[:n - 1]
        ok &= check(f"listing, {n} entries: the Radio Station first, the rest in order", got == want, str(got))
        ok &= check(f"listing, {n} entries: the cursor a line lower", m.memory[a["loader.radio.top"]] == 1)
        ok &= check(f"listing, {n} entries: nothing after the list touched",
                    bytes(m.memory[end:end + 4]) != b"Radi", bytes(m.memory[end:end + 4]))
    return ok


def main():
    ok = loader_tests()
    ok &= listing_tests()
    ok &= demo_tests()
    ok &= tracker_tests()
    print("ALL RADIO CHECKS PASS" if ok else "SOME RADIO CHECKS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
