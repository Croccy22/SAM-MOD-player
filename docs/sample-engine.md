# FPGA sample engine: register layout

Draft 1. An Amiga Paula-style four-channel sample player in the Tang Nano 20K
expansion, so the SAM MOD player can play MODs at full quality. The FPGA reads
sample data straight from the external memory it already provides and mixes
the channels itself. The SAM only tells it, once a frame, what each channel
should play.

## Ports

| Port | Name | Read | Write |
|---|---|---|---|
| 0xC0 (192) | INDEX | current register index | set register index (0x00-0x7F) |
| 0xC1 (193) | DATA | register at INDEX, then INDEX + 1 | register at INDEX, then INDEX + 1 |

- Only A0-A7 are decoded. The upper address byte is ignored, so `OTIR` and
  `INIR` work (they put their counter on A8-A15).
- INDEX steps on by one after every DATA read or write, wrapping from 0x7F to
  0x00. One `OUT (0xC0)` followed by one `OTIR` to 0xC1 writes a block.
- Unused registers read 0xFF and ignore writes.

## Register map

| Index | Block |
|---|---|
| 0x00-0x0F | channel 0 (left) |
| 0x10-0x1F | channel 1 (right) |
| 0x20-0x2F | channel 2 (right) |
| 0x30-0x3F | channel 3 (left) |
| 0x40-0x4F | global and status |
| 0x7E-0x7F | identification |

Channels sit left, right, right, left, as on the Amiga.

### Channel registers (channel n at index n × 16)

| Offset | Name | Description |
|---|---|---|
| 0x0 | START_L | sample start: offset low byte |
| 0x1 | START_H | sample start: offset high byte (0x80-0xBF; bits 6-7 ignored) |
| 0x2 | START_PAGE | sample start: external memory page (as written to port 128) |
| 0x3 | LEN_L | length in words, low byte |
| 0x4 | LEN_H | length in words, high byte (0 = 65536 words) |
| 0x5 | LOOP_L | loop start: offset low byte |
| 0x6 | LOOP_H | loop start: offset high byte (0x80-0xBF) |
| 0x7 | LOOP_PAGE | loop start: external memory page |
| 0x8 | LOOPLEN_L | loop length in words, low byte |
| 0x9 | LOOPLEN_H | loop length in words, high byte (0 = 65536 words) |
| 0xA | PERIOD_L | Amiga period, low byte |
| 0xB | PERIOD_H | Amiga period, high byte |
| 0xC | VOLUME | 0-64 (higher values act as 64) |
| 0xD | CONTROL | write: bit 0 = trigger, bit 1 = stop. Read: bit 0 = playing |
| 0xE-0xF | | reserved |

**Addresses** use the same page-and-offset form the player already keeps in
its sample table, so the Z80 does no conversion. The FPGA turns them into a
memory address:

```
address = page × 16384 + (offset AND 0x3FFF)
```

`page` is the external memory page number the SAM writes to ports 128 and 129.
All 4 MB is pages 0-255.

**Playback follows Paula:**

- **Trigger** loads the channel's play position from START and LEN and starts
  playing from there.
- When the current block runs out, the channel continues from LOOP and
  LOOPLEN, and keeps repeating that loop until it is triggered or stopped
  again. A one-shot sample is a 1-word loop on its first word, which MOD files
  keep silent, so no special case is needed.
- **Stop** silences the channel; it does not read memory until triggered.
- START and LEN are only used at trigger, so changing them never affects a
  sample that is already playing. Writing LOOP and LOOPLEN without a trigger
  swaps in a new loop when the current block ends. That is how ProTracker's
  "new sample number without a note" behaves.
- Each channel reads its next byte every PERIOD ticks of the Amiga clock
  (3,546,895 Hz PAL, 3,579,545 Hz NTSC, chosen in GLOBAL_CONTROL), and holds
  it until the next one, as Paula does. Samples are signed 8-bit.

**Multi-byte values change together.** The FPGA holds each value's lower
bytes until its last byte is written, so a channel never uses half an update:

| Value | Takes effect when this byte is written |
|---|---|
| START, LEN | used only at trigger |
| LOOP, LOOPLEN | LOOPLEN_H |
| PERIOD | PERIOD_H |
| VOLUME | VOLUME |

Writing a channel's registers in index order, ending with CONTROL, always
works.

### Global registers

| Index | Name | Description |
|---|---|---|
| 0x40 | GLOBAL_CONTROL | bit 0 = enable (0 stops and silences all channels), bit 1 = NTSC clock, bit 2 = Amiga low-pass filter on (MOD effect E0x) |
| 0x41 | SEPARATION | stereo separation: 0 = mono, 255 = hard left/right as on the Amiga |
| 0x42 | MASTER_VOLUME | 0-64 |
| 0x48 | STATUS (read) | bits 0-3: channel 0-3 reached the end of a block since the last read (cleared by reading). Bits 4-7: channel 0-3 playing |
| 0x4C-0x4F | PEAK 0-3 (read) | loudest output of each channel since the last read, 0-127 after volume (cleared by reading). For level meters |

At power-on and while enable is 0: all channels are stopped and their registers
are 0, SEPARATION is 255, MASTER_VOLUME is 64 and the filter is off.

### Identification

| Index | Read |
|---|---|
| 0x7E | 0x53 ("S") |
| 0x7F | version, 0x01 for this layout |

## Using it from the Z80

Detect the engine:

```
    ld a,0x7e
    out (0xc0),a
    in a,(0xc1)         ; 0x53 if fitted (0xff if not)
    cp 0x53
    jr nz,not.fitted
    in a,(0xc1)         ; version
```

Start a note on channel `n` (a whole channel in one `OTIR`):

```
    ld a,n * 16
    out (0xc0),a
    ld hl,channel.buffer    ; START (3), LEN (2), LOOP (3), LOOPLEN (2),
                            ; PERIOD (2), VOLUME (1), CONTROL = 1 (trigger)
    ld bc,14 * 256 + 0xc1
    otir
```

Change period and volume (vibrato, slides, volume effects):

```
    ld a,n * 16 + 0x0a
    out (0xc0),a
    ld hl,period.and.volume ; PERIOD (2), VOLUME (1)
    ld bc,3 * 256 + 0xc1
    otir
```

Even if all four channels start a note in the same frame, that's under 1,500
T-states, about 0.5% of a frame.

## Player changes (SAM MOD player)

- A new output device in the device menu, offered when the engine is detected.
  The existing devices are unchanged.
- MODs are always loaded into external memory for this device, since the FPGA
  can only read its own RAM. The board always provides it.
- The sample install skips the gaps ("runways") and loop copying that the
  burst player needs. The samples stay exactly as they are in the file, and
  START and LOOP point straight at them.
- The tracker writes channel registers instead of burst player pointers:
  trigger on a new note (and for effects 9xx, E9x and EDx), PERIOD and VOLUME
  when they change, LOOP and LOOPLEN on a sample change without a note, stop on
  ECx note cut, filter bit for E0x.
- With no burst player, the tracker runs from the normal 50 Hz frame
  interrupt, and the display screens get nearly all of the Z80's time.

## FPGA notes

- Memory reads: at most about 31,000 bytes a second per channel (period 113),
  so about 125,000 a second for all four. They go into gaps between the SAM's
  own accesses to the SDRAM. A small buffer per channel (fetching a word at a
  time, as Paula does) removes any timing pressure.
- Timing: derive the Amiga clock from the system clock with a fractional
  accumulator. Each channel has a down-counter loaded with PERIOD that fetches
  the next byte when it reaches zero.
- Mixing: each channel's byte × VOLUME (14-bit signed), channels 0 and 3 to the
  left, 1 and 2 to the right, then SEPARATION, MASTER_VOLUME and the optional
  filter, into the existing DAC mixer next to the Quazar, SAMdac and VoiceBox.
