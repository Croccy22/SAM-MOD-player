#!/usr/bin/env python3
"""Run the assembled multi-part loader code in a Z80 emulator.

Emulates just enough of a SAM Coupe: internal/external memory paging (HMPR,
XMPR), the keyboard RETURN key and the B-DOS hooks the loader uses (read
sector, select record, dvars). Disk images come from split_mod.py.

usage: test_multipart.py big.mod  (needs obj/loader from build.sh, and
                                   pip install z80)
"""

import ast
import os
import re
import subprocess
import sys
import tempfile

import z80

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import split_mod  # noqa: E402

PAGE_SCREEN, PAGE_LOADER, PAGE_DOS = 0x1e, 0x1f, 0x1d
DOS_SECTOR, INST_BUFFER = 0x4900, 0x4f00
SVAR_DOSFLG = 0x5bc2
DVARS = 0x100                       # dvars table, pointed to by DOS page 0x8000
DVAR_RECORDS, DVAR_RECORD = DVARS + 23, DVARS + 25
DRIVER = 0x7000
EMPTY_DISK = bytes(819200)


def load_symbols():
    """All loader symbols (the map file keeps only one name per address)."""
    out = subprocess.run(["pyz80", "-x", "-s", ".", "--obj=" + os.devnull,
                          os.path.join(ROOT, "src", "loader", "loader.s")],
                         check=True, capture_output=True, text=True).stdout
    table = ast.literal_eval(next(line for line in out.splitlines() if line.startswith("{")))
    syms, local = {}, {}
    for name, value in table.items():
        (local if name.startswith("@") else syms)[name] = int(value, 16)
    return syms, local


def assemble_driver(syms):
    """Tiny driver doing what sam.match / the listing do, then stopping."""
    src = "".join(f"{n}: equ 0x{a:04x}\n" for n, a in syms.items() if re.fullmatch(r"[a-z][a-z0-9._]*", n))
    src += f"""
    org {DRIVER}
load.file:
    ld sp,0x7f00
    ld (multi.part.sp),sp
    ld d,0
    ld e,1
    ld hl,{DOS_SECTOR}
    call bdos.read.sector       ; first directory sector, file is entry 0
    ld hl,{DOS_SECTOR}
    push hl
    inc l
    ld de,multi.part.name
    ld bc,10
    ldir
    pop hl
    call multi.part.get.entry
    push de
    call multi.part.init
    pop de
    push de
    ld hl,meg.load.mod.relocate
    ld de,{INST_BUFFER}
    ld bc,meg.load.mod.len
    ldir
    pop de
    ld a,(loader.drive)
    ld c,0
    ld hl,0x8000
    call {INST_BUFFER}
    ld (driver.dest),hl
    ld a,c
    ld (driver.page),a
    call multi.part.continue
driver.done:
    jr driver.done

list.dir:
    ld sp,0x7f00
    xor a
    ld (loader.entries),a
    ld de,loader.dir
    call bdos.directory.read
driver.listed:
    jr driver.listed

move.record:                    ; as the loader's record left / right keys
    ld sp,0x7f00
    xor a
    ld (loader.entries),a
    ld hl,(driver.target)
    call multi.part.select.record
    ld de,loader.dir
    call bdos.directory.read
    jr driver.listed

driver.target: defw 0

driver.dest: defw 0
driver.page: defb 0
"""
    with tempfile.TemporaryDirectory() as tmp:
        s = os.path.join(tmp, "driver.s")
        o = os.path.join(tmp, "driver")
        m = os.path.join(tmp, "driver.map")
        open(s, "w").write(src)
        subprocess.run(["pyz80", "--obj=" + o, "--mapfile=" + m, s], check=True, capture_output=True)
        code = open(o, "rb").read()
        dsyms = {}
        for line in open(m):
            if "=" in line:
                a, n = line.strip().split("=", 1)
                dsyms[n] = int(a, 16)
    return code, dsyms


class Sam:
    def __init__(self, records=None, floppies=None, mb=4, drive=2, record=1):
        self.syms, self.local = load_symbols()
        self.code, self.dsyms = assemble_driver(self.syms)
        self.internal = [bytearray(16384) for _ in range(32)]
        self.external = [bytearray(16384) for _ in range(256)]
        self.records = records or []            # record n = records[n - 1]
        self.floppies = floppies or [EMPTY_DISK]
        self.floppy = 0
        self.messages = []
        self.key_reads = 0
        self.returns = 0
        self.hmpr, self.xmpr = PAGE_SCREEN, [0, 1]
        self.mapped = (self.internal[PAGE_SCREEN], self.internal[PAGE_LOADER])

        loader = open(os.path.join(ROOT, "obj", "loader"), "rb").read()
        self.internal[PAGE_SCREEN][0x3800:0x4000] = loader[:0x800]
        self.internal[PAGE_LOADER][0:len(loader) - 0x800] = loader[0x800:]

        dos = self.internal[PAGE_DOS]
        dos[0:2] = (0x8000 + DVARS).to_bytes(2, "little")
        dos[DVAR_RECORDS:DVAR_RECORDS + 2] = len(self.records).to_bytes(2, "little")
        dos[DVAR_RECORD:DVAR_RECORD + 2] = record.to_bytes(2, "little")

        m = self.m = z80.Z80Machine()
        mem = m.memory
        mem[0x8000:0xc000] = self.mapped[0]
        mem[0xc000:0x10000] = self.mapped[1]
        mem[SVAR_DOSFLG] = PAGE_DOS
        mem[DRIVER:DRIVER + len(self.code)] = self.code
        mem[self.syms["loader.ram"]] = mb * 4 + 2
        mem[self.syms["loader.drive"]] = drive
        mem[self.syms["loader.dos.version"]] = 5    # B-DOS 1.5

        m.set_output_callback(self.out)
        m.set_input_callback(self.inp)
        for addr in (0x0008, self.local["@print.status"], self.syms["loader"],
                     self.dsyms["driver.done"], self.dsyms["driver.listed"]):
            m.set_breakpoint(addr)

    # memory paging ---------------------------------------------------------

    def flush(self):
        mem = self.m.memory
        self.mapped[0][:] = mem[0x8000:0xc000]
        self.mapped[1][:] = mem[0xc000:0x10000]

    def load(self):
        if self.hmpr & 0x80:
            self.mapped = (self.external[self.xmpr[0]], self.external[self.xmpr[1]])
        else:
            page = self.hmpr & 0x1f
            self.mapped = (self.internal[page], self.internal[(page + 1) & 0x1f])
        mem = self.m.memory
        mem[0x8000:0xc000] = self.mapped[0]
        mem[0xc000:0x10000] = self.mapped[1]

    def remap(self):
        self.flush()
        self.load()

    def out(self, port, value):
        port &= 0xff
        if port == 0xfb:
            self.hmpr = value
            self.remap()
        elif port in (0x80, 0x81):
            self.xmpr[port - 0x80] = value
            if self.hmpr & 0x80:
                self.remap()

    def inp(self, port):
        if port & 0xff == 0xfb:
            return self.hmpr
        if port & 0xff == 0xfe and (port >> 8) == 0xbf:     # hjkl return row
            self.key_reads += 1
            if self.key_reads % 2:                          # pressed, then released
                self.returns += 1
                self.floppy = min(self.floppy + 1, len(self.floppies) - 1)
                return 0xfe
        return 0xff

    # B-DOS ---------------------------------------------------------------------

    def disk(self, drive):
        if drive == 2:
            record = int.from_bytes(self.internal[PAGE_DOS][DVAR_RECORD:DVAR_RECORD + 2], "little")
            return self.records[record - 1]
        return self.floppies[self.floppy]

    def record(self):
        self.flush()
        return int.from_bytes(self.internal[PAGE_DOS][DVAR_RECORD:DVAR_RECORD + 2], "little")

    def rst8(self):
        m = self.m
        ret = m.memory[m.sp] | m.memory[m.sp + 1] << 8
        hook = m.memory[ret]
        if hook == 0xa0:                                    # read sector
            track, sector = m.d, m.e
            at = ((track & 0x7f) * 20 + (track >> 7) * 10 + sector - 1) * 512
            m.memory[m.hl:m.hl + 512] = self.disk(m.a)[at:at + 512]
        elif hook == 0x9c:                                  # select record
            assert m.a == 0
            self.flush()
            assert 1 <= m.hl <= len(self.records), m.hl
            self.internal[PAGE_DOS][DVAR_RECORD:DVAR_RECORD + 2] = m.hl.to_bytes(2, "little")
            self.load()
        else:
            raise RuntimeError(f"unexpected DOS hook {hook:02x}")
        m.sp += 2
        m.pc = ret + 1

    # running -------------------------------------------------------------------

    def run(self, entry):
        m = self.m
        m.pc = self.dsyms[entry]
        for _ in range(10_000_000):
            m.run()
            if m.pc == 0x0008:
                self.rst8()
            elif m.pc == self.local["@print.status"]:
                de = m.de
                text = bytes(m.memory[de:de + 32]).split(b"\0")[0].decode()
                self.messages.append(text.strip())
                m.step_over_breakpoint()
            elif m.pc == self.syms["loader"]:
                self.flush()
                return "loader"
            elif m.pc in (self.dsyms["driver.done"], self.dsyms["driver.listed"]):
                self.flush()
                return "done"
        raise RuntimeError("did not finish")

    def peek(self, name, n=1):
        a = self.syms[name]
        return bytes(self.m.memory[a:a + n])

    def external_bytes(self, n):
        return b"".join(self.external)[:n]


# tests -------------------------------------------------------------------------

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f" - {detail}" if detail else ""))
    return ok


def main():
    mod = open(sys.argv[1], "rb").read()
    size = split_mod.mod_size(mod)
    mod = (mod + bytes(max(0, size - len(mod))))[:size]
    parts = [mod[i:i + split_mod.MAX_FILE] for i in range(0, size, split_mod.MAX_FILE)]
    disks = [split_mod.make_disk(f"BIG.{n}", p, f"BIG {n}") for n, p in enumerate(parts, 1)]
    ok = True

    # 1. directory listing shows part 1 with the full size
    sam = Sam(records=disks, record=1)
    sam.run("list.dir")
    entries = sam.m.memory[sam.syms["loader.entries"]]
    entry = sam.syms["loader.dir"]
    name = bytes(sam.m.memory[entry:entry + 8]).decode()
    size_kb = int.from_bytes(sam.m.memory[entry + 38:entry + 40], "little")
    ok &= check("listing shows part 1", entries == 1 and name == "BIG.1   ", f"{entries} entries, {name!r}")
    ok &= check("listing size is whole mod", abs(size_kb - size / 1024) <= 1, f"{size_kb}K vs {size / 1024:.1f}K")

    sam = Sam(records=disks, record=2)
    sam.run("list.dir")
    ok &= check("part 2 is hidden", sam.m.memory[sam.syms["loader.entries"]] == 0)

    # 2. load from consecutive records, starting at record 3
    records = [EMPTY_DISK, EMPTY_DISK] + disks + [EMPTY_DISK]
    sam = Sam(records=records, record=3)
    result = sam.run("load.file")
    loaded = sam.external_bytes(size)
    ok &= check("records: loads to the end", result == "done", f"{sam.messages}")
    ok &= check("records: data matches mod", loaded == mod,
                next((f"first difference at {i}" for i in range(size) if loaded[i] != mod[i]), ""))
    ok &= check("records: size from header", int.from_bytes(sam.peek("multi.part.size", 3), "little") == size)
    ok &= check("records: record restored", sam.record() == 3, f"record {sam.record()}")
    ok &= check("records: progress shown", sam.messages == [f"Loading part {n}" for n in range(2, len(parts) + 1)],
                f"{sam.messages}")

    # 3. floppies, asking for each disk
    sam = Sam(floppies=disks, drive=1)
    result = sam.run("load.file")
    ok &= check("floppy: loads to the end", result == "done")
    ok &= check("floppy: data matches mod", sam.external_bytes(size) == mod)
    ok &= check("floppy: asks for each disk", sam.returns == len(parts) - 1 and
                sam.messages[1] == "Insert disk with part 2 - RETURN", f"{sam.messages[:3]}")

    # 4. missing part
    gap = [disks[0], disks[1], EMPTY_DISK] + disks[3:]
    sam = Sam(records=gap, record=1)
    result = sam.run("load.file")
    ok &= check("missing part: back to file list", result == "loader")
    ok &= check("missing part: message", sam.messages[-1] == "Part 3 not found - press RETURN", f"{sam.messages[-1:]}")
    ok &= check("missing part: record restored", sam.record() == 1)

    # 5. last record reached
    sam = Sam(records=disks[:2], record=1)
    result = sam.run("load.file")
    ok &= check("no more records: back to file list", result == "loader" and sam.messages[-1].startswith("Part 3"))

    # 6. not enough external memory
    sam = Sam(records=disks, record=1, mb=size // (1024 * 1024))
    result = sam.run("load.file")
    ok &= check("small RAM: refused", result == "loader" and sam.messages == ["Needs more external RAM - RETURN"],
                f"{sam.messages}")

    # 7. ordinary single file still loads with the rewritten routine
    small = mod[:100_000]
    sam = Sam(records=[split_mod.make_disk("SMALL", small, "SMALL")], record=1)
    result = sam.run("load.file")
    dest = int.from_bytes(bytes(sam.m.memory[sam.dsyms["driver.dest"]:sam.dsyms["driver.dest"] + 2]), "little")
    page = sam.m.memory[sam.dsyms["driver.page"]]
    end = page * 16384 + dest - 0x8000
    ok &= check("single file: loads", result == "done" and sam.external_bytes(len(small)) == small)
    ok &= check("single file: end pointer", 0 <= end - len(small) < 510, f"end {end}, length {len(small)}")
    ok &= check("single file: not multi-part", sam.peek("multi.part.active") == b"\0" and not sam.messages)

    # 8. moving through records skips records with only later parts
    other = split_mod.make_disk("OTHER", mod[:100_000], "OTHER")
    shelf = [disks[0]] + disks[1:] + [other, EMPTY_DISK, disks[1]]  # 1: BIG.1 .. 5: BIG.5, 6: other, 7: empty, 8: BIG.2

    def move(start, target):
        sam = Sam(records=shelf, record=start)
        a = sam.dsyms["driver.target"]
        sam.m.memory[a:a + 2] = target.to_bytes(2, "little")
        sam.run("move.record")
        return sam.record(), sam.m.memory[sam.syms["loader.entries"]]

    rec, n = move(1, 2)
    ok &= check("skip: up from part 1 to next mod", rec == 6 and n == 1, f"record {rec}, {n} files listed")
    rec, n = move(6, 5)
    ok &= check("skip: down to part 1", rec == 1 and n == 1, f"record {rec}")
    rec, n = move(6, 7)
    ok &= check("skip: empty record not skipped", rec == 7 and n == 0, f"record {rec}")
    rec, n = move(7, 8)
    ok &= check("skip: stops at the last record", rec == 8, f"record {rec}")
    rec, n = move(1, 4)
    ok &= check("skip: jump of 3 then on to the next mod", rec == 6, f"record {rec}")
    rec, n = move(1, 1)
    ok &= check("skip: same record not moved", rec == 1, f"record {rec}")

    print("ALL PASSED" if ok else "SOME TESTS FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
