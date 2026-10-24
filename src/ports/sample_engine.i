; FPGA sample engine - see docs/sample-engine.md
;---------------------------------------------------------------

port.sample_engine.index:           equ 0xc0 ; 192 - register index (auto increments)
port.sample_engine.data:            equ 0xc1 ; 193 - register data

;---------------------------------------------------------------
; channel registers - channel n at index n * se.channel.len

se.channel.len:                     equ 0x10

se.start:                           equ 0x00 ; offset (2) + page
se.start.page:                      equ 0x02
se.len:                             equ 0x03 ; words, 0 = 65536
se.loop:                            equ 0x05 ; offset (2) + page
se.loop.page:                       equ 0x07
se.loop.len:                        equ 0x08 ; words, 0 = 65536
se.period:                          equ 0x0a ; amiga period
se.volume:                          equ 0x0c ; 0-64
se.control:                         equ 0x0d
    se.control.trigger:                 equ %00000001
    se.control.stop:                    equ %00000010
    se.control.playing:                 equ %00000001 ; read

se.trigger.len:                     equ se.control + 1 ; bytes written to start a note

;---------------------------------------------------------------
; global registers

se.global.control:                  equ 0x40
    se.global.enable:                   equ %00000001
    se.global.ntsc:                     equ %00000010
    se.global.filter:                   equ %00000100
se.separation:                      equ 0x41 ; 0 = mono, 255 = hard left / right
se.master.volume:                   equ 0x42 ; 0-64
se.status:                          equ 0x48 ; read, bits 0-3 block ended (cleared), 4-7 playing
se.peak:                            equ 0x4c ; read, 4 bytes, 0-127 (cleared)

;---------------------------------------------------------------
; identification

se.id:                              equ 0x7e
    se.id.value:                        equ 0x53 ; "S"
se.version:                         equ 0x7f
    se.version.value:                   equ 0x01
