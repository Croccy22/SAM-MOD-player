# SAM MOD player

[![build](https://github.com/stefandrissen/SAM-MOD-player/actions/workflows/ant.yml/badge.svg)](https://github.com/stefandrissen/SAM-MOD-player/actions/workflows/ant.yml)

## Structure

- boot
- loader
- burstplayer
- demo
- tracker
- example

### boot

This autoboot file will load the loading screen, all code and then start the SAM MOD player.

### loader

This is the initial front end. It provides a screen to select the output device:

- [saa1099 sound chip](https://www.worldofsam.org/products/saa1099)
- [samdac](https://www.worldofsam.org/products/samdac)
- dac
- [blue alpha sampler](https://www.worldofsam.org/products/sound-sampler)
- [quazar soundcard](https://www.worldofsam.org/products/quazar-surround)
- colour lookup table
- FPGA sample engine (see below)

And the type of Amiga the mod was intended for:

- pal
- ntsc

Once these have been selected, the burst player code is generated.

The disk (or mass storage device) is then scanned for mod files, the drive can be changed or rescanned. Mass storage device records can be selected with cursor left or right, when holding shift the selection jumps 10 records, when holding symbol the selecting jumps 50 records.

When a file is selected, it is loaded and the "demo" starts.

#### multi-part mods

A mod too big for one disk or B-DOS record (about 795K) can be split into parts, which needs external memory (megabyte interface) to load. The parts are named `NAME.1`, `NAME.2` and so on up to `NAME.9`, where `NAME` is up to 8 characters.

- on mass storage, put each part in the next record: part 1 in record n, part 2 in record n+1, ...
- on floppy, put each part on its own disk; the loader asks for the next disk

Only part 1 shows in the file list, with the size of the whole mod. When moving through records with cursor left or right (also with shift or symbol), records that hold only later parts are skipped: the selection carries on in the same direction to the next record that is empty or holds anything else, or stops at the first or last record. Loading stops once the size given by the mod header has been loaded, so no end marker is needed. If a part cannot be found, or the mod will not fit in the external memory fitted, a message is shown and the loader returns to the file list.

`tools/split_mod.py` splits a mod into parts, writing one disk image per part:

```
python3 tools/split_mod.py bigsong.mod --name BIGSONG --out parts
```

`tools/test_multipart.py` runs the assembled loader code in a Z80 emulator (`pip install z80`) against the split images to check that every byte is loaded back in place.

The multi-part code lives in the top 2K of the screen page (`multi.part.base`, 0xb800), which mode 2 does not use, since the loader page is full. The loader file therefore starts at 0xb800 and is loaded there by boot.

### FPGA sample engine

An Amiga Paula-style four-channel sample player in the Tang Nano 20K expansion, on ports 0xC0 and 0xC1 ([register layout](docs/sample-engine.md)). It reads the samples straight from the external memory it provides and mixes them itself, so MODs play at full quality instead of the burst player's 10.4 kHz.

- The device screen lists it as "FPGA sample engine" and shows "absent" (and won't select it) unless the engine's identification register answers and external memory is fitted.
- The tracker is unchanged apart from small hooks that record each channel's note starts, period, volume and sample (`se.channels` in `memory.i`, patched in by `se.patch` at init).
- For this device `burstplayer.create` still makes a screen-device burst player for its tables and helper routines, then `engine.setup` (`src/devices/engine.i`) replaces its run time: a 50 Hz frame interrupt that sets the frame palette and screen, calls the tracker, then sends the channels to the engine.
- The run time keeps ProTracker's sample start and length per channel, so sample offset (9xx) behaves as on the Amiga (it carries over to later notes without an instrument number, and an offset past the end leaves one word). Effect E0x switches the engine's Amiga filter.
- Samples are left exactly as in the file (no runways); `install.engine.low` fills in the sample table as ProTracker plays each sample.

`tools/test_engine.py` runs the assembled player for this device in a Z80 emulator, captures the engine register writes and renders them through a model of the engine to a WAV file. `tools/solo_mod.py` and `tools/compare_audio.py` compare that, channel by channel, with OpenMPT (`openmpt123`).

### burstplayer

This generates the code for the burst player based on the output device:

- ports
- channels
- manual timing

The burst player outputs the samples from the sample buffers to the output device.

The playback rate is 10,400 Hz, this is achieved by outputting sample data 208 times a frame, this is once every 1.5 scan line.
During the border area, timing is manual.  During the screen area line interrupts are set every 3 lines, the first output is on
the line interrupt, the second is timed manually at 1.5 line, after which control is given back to the "demo" until the next line
interrupt occurs.

### demo

This shows information on the module being played via various screens:

- help (f1)
- samples short (f2)
- samples detailed (f3)
- tracker (f4) - initial
- supported effects (f5)
- sample debug info (f6)

### tracker

This is the tracker. It is called every frame.
It reads the pattern and sample information and fills the pointers for the sample playback buffers.

### example

This is a simple example that replaces the "demo".

## compiling

Ant is used to invoke [pyz80](https://github.com/simonowen/pyz80) for assembling, this can be executed from Eclipse or Visual Studio Code.

"all" will assemble loader, demo, burstplayer and tracker, the four object files are then assembling boot which produces an autoboot disk image.
SimCoupe is then started with the disk image.

The properties used to find python, pyz80 and [SimCoupe](https://www.simcoupe.org/) are at the top of the build.xml file.
