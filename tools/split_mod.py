#!/usr/bin/env python3
"""Split a large Amiga MOD into parts for the SAM MOD player's multi-part loader.

Each part goes on its own SAM disk image (.mgt), as a CODE file named
BASENAME.1, BASENAME.2, ... Put the images in consecutive B-DOS records
(part 1 in record n, part 2 in record n+1, ...), or write them to floppies.
The player needs external memory (megabyte interface) to load them.

usage: split_mod.py song.mod [--name BIGSONG] [--out DIR] [--part-size BYTES]
"""

import argparse
import datetime
import os
import re
import sys

SPT = 10                                # sectors per track
TRACKS = 80
SIDES = 2
SECTOR = 512
DATA_PER_SECTOR = 510                   # last 2 bytes link to next sector
DIR_TRACKS = 4
DATA_SECTORS = (TRACKS * SIDES - DIR_TRACKS) * SPT
MAX_FILE = DATA_SECTORS * DATA_PER_SECTOR - 9   # 9 byte file header

MAX_PARTS = 9                           # parts are numbered 1-9


def mod_size(data):
    """Size of the mod as calculated from its header (as the player does)."""
    mod_id = data[1080:1084] if len(data) >= 1084 else b""
    if mod_id in (b"M.K.", b"M!K!", b"FLT4", b"4CHN"):
        samples, header = 31, 1084
    elif re.fullmatch(rb"[0-9]CHN|[0-9][0-9]CH|FLT8|OCTA|CD81|TDZ[0-9]", mod_id):
        sys.exit(f"{mod_id.decode()} mod - the SAM MOD player only plays 4 channel mods")
    else:
        samples, header = 15, 600       # old Soundtracker, no id

    sample_bytes = 0
    for i in range(samples):
        entry = 20 + i * 30
        sample_bytes += int.from_bytes(data[entry + 22:entry + 24], "big") * 2

    positions = header - (4 if samples == 31 else 0) - 128
    patterns = max(data[positions:positions + 128]) + 1

    return header + patterns * 1024 + sample_bytes


def dsk_at(track, side, sector):
    # image order: track 0 side 0, track 0 side 1, track 1 side 0, ...
    return (track * SPT * SIDES + side * SPT + (sector - 1)) * SECTOR


def make_disk(filename, data, label):
    """Return an .mgt image holding data as a single CODE file."""
    image = bytearray(TRACKS * SIDES * SPT * SECTOR)
    length = len(data)
    nsectors = -(-(length + 9) // DATA_PER_SECTOR)
    if nsectors > DATA_SECTORS:
        raise ValueError("part too big for a disk")

    now = datetime.datetime.now()
    d = dsk_at(0, 0, 1)                 # first directory entry

    image[d + 0] = 19                   # CODE file
    image[d + 1:d + 11] = filename.ljust(10).encode("ascii")
    image[d + 11] = nsectors // 256
    image[d + 12] = nsectors % 256
    image[d + 13] = DIR_TRACKS          # first track (side 0)
    image[d + 14] = 1                   # first sector
    for s in range(nsectors):           # sector address map
        image[d + 15 + s // 8] |= 1 << (s & 7)
    image[d + 210:d + 220] = label.ljust(10)[:10].encode("ascii")   # disk name
    image[d + 236] = 1                  # start page
    image[d + 237] = 0x00               # start offset 0x8000
    image[d + 238] = 0x80
    image[d + 239] = length // 16384    # length in pages
    image[d + 240] = length % 256       # length modulo 16384
    image[d + 241] = (length % 16384) // 256
    image[d + 242:d + 245] = b"\xff\xff\xff"    # no execute address
    image[d + 245] = now.day
    image[d + 246] = now.month
    image[d + 247] = now.year % 100 + 100
    image[d + 248] = now.hour
    image[d + 249] = now.minute

    header = bytes([19, length % 256, (length % 16384) // 256, 0x00, 0x80,
                    0, 0, length // 16384, 1])
    stream = header + data

    track, side, sector = DIR_TRACKS, 0, 1
    for pos in range(0, len(stream), DATA_PER_SECTOR):
        at = dsk_at(track, side, sector)
        chunk = stream[pos:pos + DATA_PER_SECTOR]
        image[at:at + len(chunk)] = chunk

        sector += 1
        if sector > SPT:
            sector = 1
            track += 1
            if track == TRACKS:
                track, side = 0, side + 1

        if pos + DATA_PER_SECTOR < len(stream):  # link to next sector
            image[at + 510] = track + 128 * side
            image[at + 511] = sector

    return bytes(image)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("mod", help="mod file to split")
    parser.add_argument("--name", help="SAM file name, up to 8 characters (default: from mod file name)")
    parser.add_argument("--out", default=".", help="directory for the disk images (default: current)")
    parser.add_argument("--part-size", type=int, default=MAX_FILE,
                        help=f"bytes per part (default and maximum: {MAX_FILE}, a full disk)")
    args = parser.parse_args()

    data = open(args.mod, "rb").read()

    name = args.name or re.sub(r"[^A-Za-z0-9_-]", "", os.path.splitext(os.path.basename(args.mod))[0]).upper()
    name = name[:8]
    if not name or not name.isascii() or len(name) > 8:
        sys.exit("name must be 1-8 ASCII characters")

    if not 1 <= args.part_size <= MAX_FILE:
        sys.exit(f"part size must be 1-{MAX_FILE}")

    size = mod_size(data)
    if len(data) > size:
        print(f"removing {len(data) - size} bytes of trailing data after the mod")
        data = data[:size]
    elif len(data) < size:
        print(f"warning: file is {size - len(data)} bytes shorter than its header says, padding with zeros")
        data = data + bytes(size - len(data))

    if size > 4 * 1024 * 1024:
        print("warning: mod is bigger than 4MB, the most external memory the SAM can have")

    parts = [data[i:i + args.part_size] for i in range(0, len(data), args.part_size)]
    if len(parts) > MAX_PARTS:
        sys.exit(f"mod needs {len(parts)} parts, the loader supports up to {MAX_PARTS}")
    if len(parts) == 1:
        print("note: mod fits in one part - it can be loaded normally")

    os.makedirs(args.out, exist_ok=True)
    for number, part in enumerate(parts, 1):
        filename = f"{name}.{number}"
        image = os.path.join(args.out, f"{name}-{number}.mgt")
        with open(image, "wb") as f:
            f.write(make_disk(filename, part, f"{name} {number}/{len(parts)}"))
        print(f"{image}: {filename} ({len(part)} bytes)")

    print(f"{len(parts)} parts, {size} bytes - needs {size // (1024 * 1024) + 1}MB external memory")


if __name__ == "__main__":
    main()
