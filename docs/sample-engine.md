# SAMantha (FPGA sample engine): register layout

Draft 2 (24 October 2026), as built in the FPGA firmware. An Amiga
Paula-style four-channel sample player in the Tang Nano 20K expansion, so the
SAM MOD player can play MODs at full quality. The FPGA reads sample data
straight from the external memory it already provides and mixes the channels
itself. The SAM only tells it, once a frame, what each channel should play.

Changes from draft 1 are marked **(new)**. The register layout is unchanged;
the new points settle behaviour draft 1 left open.

## Ports

| Port | Name | Read | Write |
|---|---|---|---|
| 0xC0 (192) | INDEX | current register index | set register index (0x00-0x7F; bit 7 ignored) |
| 0xC1 (193) | DATA | register at INDEX, then INDEX + 1 | register at INDEX, then INDEX + 1 |

- Only A0-A7 are decoded. The upper address byte is ignored, so `OTIR` and
  `INIR` work (they put their counter on A8-A15).
- INDEX steps on by one after every DATA read or write, wrapping from 0x7F to
  0x00. One `OUT (0xC0)` followed by one `OTIR` to 0xC1 writes a block.
- Unused registers read 0xFF and ignore writes.
- **(new)** INDEX, the identification registers, STATUS and PEAK work at all
  times, including while the engine is disabled, so detection never needs
  the engine enabled.

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

Registers 0x0-0xC read back what was last written to them (VOLUME reads back
the value written, even above 64).

**Addresses** use the same page-and-offset form the player already keeps in
its sample table, so the Z80 does no conversion. The FPGA turns them into a
memory address:

```
address = page × 16384 + (offset AND 0x3FFF)
```

`page` is the external memory page number the SAM writes to ports 128 and 129.
All 4 MB is pages 0-255. A sample can start at any byte (odd addresses are
fine) and can run across a page boundary into the next page: pages are
consecutive in memory.

**Playback follows Paula:**

- **Trigger** loads the channel's play position from START and LEN and starts
  playing from there. **(new)** Triggering a channel that is already playing
  restarts it straight away. The channel holds its previous output level until
  the first byte arrives (a few microseconds), so a retrigger doesn't click.
- When the current block runs out, the channel continues from LOOP and
  LOOPLEN, and keeps repeating that loop until it is triggered or stopped
  again. A one-shot sample is a 1-word loop on its first word, which MOD files
  keep silent, so no special case is needed.
- **Stop** silences the channel; it does not read memory until triggered.
  **(new)** If a CONTROL write has both bits set, trigger wins.
- START and LEN are only used at trigger, so changing them never affects a
  sample that is already playing. Writing LOOP and LOOPLEN without a trigger
  swaps in a new loop when the current block ends. That is how ProTracker's
  "new sample number without a note" behaves. **(new)** The FPGA reads a few
  bytes ahead (up to 8), so the swap uses whatever LOOP and LOOPLEN hold when
  the FPGA *fetches* the end of the block, up to 8 sample periods before it
  is heard (Paula also latches its location registers at fetch time). In
  practice: a loop written in the same frame as the block ends may take
  effect one loop later.
- Each channel reads its next byte every PERIOD ticks of the Amiga clock
  (3,546,895 Hz PAL, 3,579,545 Hz NTSC, chosen in GLOBAL_CONTROL), and holds
  it until the next one, as Paula does. Samples are signed 8-bit.
- **(new)** PERIOD 0 pauses the channel: it outputs silence and stays where it
  is (still "playing" in CONTROL and STATUS); a non-zero period carries on
  from there. Periods 1-27 play as 28 (126.7 kHz PAL, over four times faster
  than ProTracker's highest note, period 113). There is no upper limit
  (65535 is about 54 Hz).

**Multi-byte values change together.** The FPGA holds each value's lower
bytes until its last byte is written, so a channel never uses half an update:

| Value | Takes effect when this byte is written |
|---|---|
| START, LEN | used only at trigger |
| LOOP, LOOPLEN | LOOPLEN_H |
| PERIOD | PERIOD_H |
| VOLUME | VOLUME |

Writing a channel's registers in index order, ending with CONTROL, always
works. **(new)** A new PERIOD takes effect at the channel's next byte, as on
Paula.

### Global registers

| Index | Name | Description |
|---|---|---|
| 0x40 | GLOBAL_CONTROL | bit 0 = enable (0 stops and silences all channels), bit 1 = NTSC clock, bit 2 = Amiga low-pass filter on (MOD effect E0x) |
| 0x41 | SEPARATION | stereo separation: 0 = mono, 255 = hard left/right as on the Amiga |
| 0x42 | MASTER_VOLUME | 0-64 (higher values act as 64) |
| 0x48 | STATUS (read) | bits 0-3: channel 0-3 reached the end of a block since the last read (cleared by reading). Bits 4-7: channel 0-3 playing |
| 0x4C-0x4F | PEAK 0-3 (read) | loudest output of each channel since the last read, 0-127 after volume (cleared by reading). For level meters |

At power-on and while enable is 0: all channels are stopped and their registers
are 0, SEPARATION is 255, MASTER_VOLUME is 64 and the filter is off.

- **(new)** While enable is 0, writes to every register except
  GLOBAL_CONTROL are ignored, so **set enable first**, then SEPARATION,
  MASTER_VOLUME and the channels. Writing GLOBAL_CONTROL with bit 0 clear
  clears the other bits too (it reads back 0).
- **(new)** A SAM reset disables the engine (as at power-on).
- **(new)** STATUS bits 0-3 are set when the last byte of a block is played
  (heard), every time, including each pass of a loop. Reading STATUS clears
  only the bits it returned, so a block ending during the read isn't lost.
- **(new)** PEAK is |byte × VOLUME| / 64 (before SEPARATION and
  MASTER_VOLUME), so a full-volume −128 reads 127, not 128. Reading it
  clears it, and it starts again from the byte the channel is holding.
- **(new)** SEPARATION mixes each side as `(L + R)/2 ± (L − R) × k/512`,
  with k = SEPARATION, plus 1 for values 128-255 (so 255 gives 256,
  exactly hard left/right). Mono (0) gives each side the average of all four
  channels, so the overall level doesn't change with separation.
- Each channel is heard (256 + k) / 512 on its own side, the rest on the
  other. A separation of s% is k = s × 2.56: 100% = 255, 75% = 191,
  60% = 153 (k 154: 80% own side, 20% other), 50% = 128 (k 129, 50.4%),
  25% = 64, mono = 0.
- The MOD player starts every tune at 64 (25%); key S steps 100, 75, 60,
  50, 25 and 0%, and the choice is kept for later tunes until a reboot.
- **(new)** The filter (bit 2) is the Amiga's "LED" filter: 2-pole low-pass,
  3.09 kHz, Q 0.66, as on the A500 and A1200, matched to within 0.03 dB of the
  analogue response. There is no fixed A500 filter, so with bit 2 clear the
  sound has the full bandwidth of an A1200.

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

Enable it **(new: before anything else)**:

```
    ld a,0x40
    out (0xc0),a
    ld a,se.global.enable       ; plus se.global.ntsc for NTSC MODs
    out (0xc1),a                ; INDEX is now 0x41
    ld a,64
    out (0xc1),a                ; SEPARATION: 25% (255 = hard left/right)
    ld a,64
    out (0xc1),a                ; MASTER_VOLUME
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

Filter on and off (E0x): write GLOBAL_CONTROL with bit 0 still set, e.g.
`se.global.enable + se.global.filter`.

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
- **(new)** Enable the engine (GLOBAL_CONTROL bit 0) before writing any other
  register, and disable it (write 0) when leaving the device or the player:
  that stops all four channels at once.
- **(new)** Level meters can read PEAK 0-3 once a frame (one `OUT`, then
  four `IN`s, or `INIR`).

## FPGA notes (as built)

- **Memory reads:** each fetch reads a whole 32-bit SDRAM word (up to 4
  sample bytes) into an 8-byte buffer per channel, so even four channels at
  ProTracker's highest note need only about 31,000 reads a second. The SDRAM
  controller only serves these at the same safe moments it already uses for
  refresh (during a Z80 refresh cycle or straight after a memory read, at
  least once per instruction), so the SAM's own reads are never delayed; a
  fallback serves them anyway if the Z80 stops (reset). Simulated with all
  four channels at period 28 under display contention: no byte was ever late.
- **Timing:** the Amiga clock comes from the 64.8 MHz system clock with a
  32-bit fractional accumulator (error under 0.01 Hz). Each channel has a
  down-counter loaded with PERIOD.
- **Mixing:** every system clock (64.8 MHz), so a byte changes exactly when it
  should rather than at a resampling rate: byte × VOLUME per channel, channels
  0+3 left and 1+2 right, SEPARATION, MASTER_VOLUME, then the optional LED
  filter (a state-variable filter at 4.05 MHz). Full volume on both
  channels of one side matches two full Quazar channels, so the trimmer
  setting for the Quazar suits the engine too.
- **Output:** into the existing DAC mixer next to the Quazar, SAMdac and
  VoiceBox, now a second-order 16-bit delta-sigma modulator (the old one was
  first-order 10-bit, which would have thrown away the engine's extra
  resolution). No hardware changes.
- **Bus monitor:** an `SE` line once a second while enabled; writes to C0/C1
  are not shown as `OUT` lines.
