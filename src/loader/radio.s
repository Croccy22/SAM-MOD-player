; SAM MOD player - loader: the Radio Station

; Random MODs, one after another, from the SAM FPGA board (samfpga): its
; ESP32 finds them on Modland and puts them on the SD card, ADOS loads them.
; Under ADOS, the file list has "Radio Station" at the top while the board's
; comms port is there (ados.s). Chosen, the player asks the board for a tune
; over the comms port (the board's ESP32 answers AT$RADIO commands, as its
; modem answers AT commands; samfpga docs/radio.md):
;
;   AT$RADIO=ON,kb   the biggest MOD this SAM can load, in K
;   AT$RADIO=NEXT    -> READY \RADIO\R0001.MOD and INFO artist - title, or
;                       WAIT what's happening (then asked again)
;   AT$RADIO=BAD     the last one wouldn't load
;   AT$RADIO=OFF     back to the file list
;
; The tune loads through the ADOS overlay (radio.load.vector) as a chosen MOD
; does, and plays in the demo, which sends PLAYING and FAV (F) itself, stops
; the tune at its end (or after 7 minutes) and keeps N (next) and ESC (stop)
; in radio.action. The loader comes back here then (radio.after), or after a
; failed load (radio.failed): loader.s checks radio.on at both.
;
; Lives after the multi-part code in the top 2K of the screen page; the
; loader runs with interrupts off, so waits are counted in loops.

radio.port.status:      equ 196         ; the board's comms port: status / control
radio.port.data:        equ 197
radio.status.txe:       equ %00000010
radio.status.rxr:       equ %00000001

;-------------------------------------------------------------------------------
radio.present:

 ; output:
 ; - z = the board's comms port is there and its ESP32 answers (ID 01, LINK)

    in a,(radio.port.status)
    and %11000100
    cp  %01000100
    ret

;-------------------------------------------------------------------------------
radio.start:

 ; from ados.s (fat.file.find): Radio Station chosen

    pop af                          ; (the type select.key kept)

    call radio.show.screen
    ld de,radio.txt.starting
    call radio.status

    call radio.present
    ld de,radio.txt.no.board
    jr nz,radio.give.up

    ld hl,(radio.load.vector)
    ld a,h
    or l
    ld de,radio.txt.no.ados
    jr z,radio.give.up

    ld hl,radio.cmd.show            ; AT$SHOW=MUSIC: the board's LEDs and OLED show the
    call radio.ask                  ; equaliser, not modem lights, while we have DTR up
                                    ; (an ESP32 from before 27 Nov 2026 says ERROR: no matter)
    ld a,1
    ld (radio.on),a
    call radio.make.on              ; AT$RADIO=ON,kb
    ld hl,radio.cmd.buf
    call radio.ask
    ld a,(radio.got.on)
    or a
    jr nz,radio.next

    ld de,radio.txt.old.board       ; an ESP32 without the radio: ERROR
    ld a,(radio.got.error)
    or a
    jr nz,radio.give.up
    ld de,radio.txt.no.answer

radio.give.up:

 ; de = why, on the bottom line for a few seconds (or until a key)

    xor a
    ld (radio.on),a
    call radio.status
    ld b,4
 radio.give.up.wait:
    push bc
    call radio.pause
    pop bc
    jr nz,radio.give.up.key
    djnz radio.give.up.wait
 radio.give.up.key:
    jp loader

;-------------------------------------------------------------------------------
radio.failed:

 ; from loader: (radio.on set) the MOD didn't load

    ld hl,radio.cmd.bad
    call radio.ask
    call radio.show.screen
    jr radio.next

;-------------------------------------------------------------------------------
radio.after:

 ; from loader's file selection (radio.on set): the demo has finished

    ld a,(radio.action)
    cp radio.action.stop
    jr z,radio.stop
    call radio.show.screen

radio.next:

    ld hl,radio.cmd.next
    call radio.ask
    ld a,(radio.got.ready)
    or a
    jr nz,radio.load

    ld de,radio.text                ; WAIT: what the board says
    ld a,(radio.got.wait)
    or a
    jr nz,radio.waiting
    ld de,radio.txt.no.answer
    ld a,(radio.got.error)
    or a
    jr z,radio.waiting
    ld de,radio.txt.error

 radio.waiting:

    call radio.status
    call radio.pause                ; about a second, then ask again
    jr nz,radio.stop
    call radio.pause
    jr nz,radio.stop
    jr radio.next

;-------------------------------------------------------------------------------
radio.load:

    ld de,radio.txt.loading
    ld hl,screen + screen.32.rows * 12
    ld b,32
    call print.de.b
    ld de,radio.info
    ld hl,screen + screen.32.rows * 14
    ld b,32
    call print.de.b
    ld de,radio.txt.loading.status
    call radio.status

    xor a
    ld (radio.action),a
    push af                         ; the type, as select.key keeps it
    ld hl,(radio.load.vector)
    ld (radio.load.jump + 1),hl
    ld hl,radio.path
 radio.load.jump:
    jp 0                            ; (ados.s: back to loader, or on to file.loaded)

;-------------------------------------------------------------------------------
radio.stop:

    ld hl,radio.cmd.off
    call radio.ask
    xor a
    ld (radio.on),a
    jp loader

;-------------------------------------------------------------------------------
radio.show.screen:

    call cls
    ld de,radio.screen
    ld ix,radio.attributes
    jp print.screen

;-------------------------------------------------------------------------------
radio.status:

 ; de = text for the bottom line

    ld hl,screen + screen.32.rows * 31
    ld b,32
    jp print.de.b

;-------------------------------------------------------------------------------
radio.pause:

 ; about a second
 ; output:
 ; - nz = ESC pressed (and let go)

    ld b,2
    ld de,0

 radio.pause.loop:

    ld a,keyboard.caps_tab_esc
    in a,(port.status)
    and %00100000
    jr z,radio.pause.esc
    dec de
    ld a,d
    or e
    jr nz,radio.pause.loop
    djnz radio.pause.loop
    xor a
    ret

 radio.pause.esc:

    ld a,keyboard.caps_tab_esc
    in a,(port.status)
    and %00100000
    jr z,radio.pause.esc
    or 1
    ret

;-------------------------------------------------------------------------------
radio.make.on:

 ; radio.cmd.buf = "AT$RADIO=ON,kb": the biggest MOD that loads, in K

    ld hl,radio.cmd.on
    ld de,radio.cmd.buf
    ld bc,radio.cmd.on.len
    ldir

    ld a,(loader.ram)
    and %11100                      ; external memory: megabytes * 4
    jr z,radio.make.internal
    rrca
    rrca                            ; megabytes
    ld h,a
    ld l,0
    add hl,hl
    add hl,hl                       ; * 1024
    jr radio.make.number

 radio.make.internal:

    ld a,(loader.ram)               ; the pages from page.mod up to the burst player's
    and %00000010
    ld a,page.create.burstplayer & 0x0f
    jr z,$+4
    ld a,page.create.burstplayer
    sub page.mod
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl                       ; * 16K

 radio.make.number:

    ld bc,-1000
    call radio.digit
    ld bc,-100
    call radio.digit
    ld bc,-10
    call radio.digit
    ld a,l
    add "0"
    ld (de),a
    inc de
    xor a
    ld (de),a
    ret

 radio.digit:

    ld a,"0" - 1

    radio.digit.loop:
        inc a
        add hl,bc
        jr c,radio.digit.loop

    sbc hl,bc
    ld (de),a
    inc de
    ret

;-------------------------------------------------------------------------------
radio.ask:

 ; sends the command at hl (0-terminated) and reads the answer up to OK or
 ; ERROR (or two quiet seconds: ATQ1 drops those), noting what came

    push hl
    xor a
    ld hl,radio.got
    ld b,radio.got.len

    radio.ask.clear:
        ld (hl),a
        inc hl
        djnz radio.ask.clear

    ld a,%00000111                  ; empty the receive buffer, clear OVR, DTR on
    out (radio.port.status),a
    pop hl

    radio.ask.send:
        ld a,(hl)
        or a
        jr z,radio.ask.sent
        call radio.put
        inc hl
        jr radio.ask.send

 radio.ask.sent:

    ld a,13
    call radio.put

    radio.ask.lines:

        call radio.get.line
        ret c                       ; quiet: done
        call radio.parse
        jr nz,radio.ask.lines

    ret

;-------------------------------------------------------------------------------
radio.put:

 ; a = byte to send (dropped if there's no room for a while)

    ld c,a
    ld de,0

 radio.put.wait:

    in a,(radio.port.status)
    and radio.status.txe
    jr nz,radio.put.go
    dec de
    ld a,d
    or e
    jr nz,radio.put.wait
    ret

 radio.put.go:

    ld a,c
    out (radio.port.data),a
    ret

;-------------------------------------------------------------------------------
radio.get.line:

 ; output:
 ; - radio.line = the next line (0-terminated, up to 63 characters kept)
 ; - carry = nothing for about two seconds

    ld hl,radio.line
    ld c,0                          ; length

 radio.get.byte:

    ld b,6                          ; quiet time: 6 * 65536 loops
    ld de,0

 radio.get.wait:

    in a,(radio.port.status)
    and radio.status.rxr
    jr nz,radio.get.got
    dec de
    ld a,d
    or e
    jr nz,radio.get.wait
    djnz radio.get.wait
    ld (hl),0                       ; quiet: a line not ended (ATQ1 leaves the
    ld a,c                          ; last one so) is taken as it is
    or a
    scf
    ret z
    or a
    ret

 radio.get.got:

    in a,(radio.port.data)
    cp 10
    jr z,radio.get.byte             ; (LF: ignored)
    cp 13
    jr z,radio.get.end
    ld e,a
    ld a,c
    cp 63
    jr nc,radio.get.byte            ; (too long: the rest dropped)
    ld (hl),e
    inc hl
    inc c
    jr radio.get.byte

 radio.get.end:

    ld (hl),0
    ld a,c
    or a
    jr z,radio.get.line             ; (blank lines: skipped)
    ret                             ; (nc)

;-------------------------------------------------------------------------------
radio.parse:

 ; notes what the line in radio.line says
 ; output:
 ; - z = the end of the answer (OK or ERROR)

    ld de,radio.word.ok
    call radio.match
    jr nz,radio.parse.error
    ld a,(hl)
    or a                            ; exactly OK
    ret z

 radio.parse.error:

    ld de,radio.word.error
    call radio.match
    jr nz,radio.parse.ready
    ld a,1
    ld (radio.got.error),a
    xor a
    ret

 radio.parse.ready:

    ld de,radio.word.ready
    call radio.match
    jr nz,radio.parse.wait
    ld de,radio.path
    ld a,1
    ld (radio.got.ready),a
    jr radio.parse.copy

 radio.parse.wait:

    ld de,radio.word.wait
    call radio.match
    jr nz,radio.parse.info
    ld de,radio.text
    ld a,1
    ld (radio.got.wait),a
    jr radio.parse.copy

 radio.parse.info:

    ld de,radio.word.info
    call radio.match
    jr nz,radio.parse.on
    ld de,radio.info

 radio.parse.copy:

 ; hl = the rest of the line -> de (0-terminated)

    ld b,63

    radio.parse.copy.loop:
        ld a,(hl)
        ld (de),a
        or a
        jr z,radio.parse.copied
        inc hl
        inc de
        djnz radio.parse.copy.loop

    xor a
    ld (de),a

 radio.parse.copied:

    or 1
    ret

 radio.parse.on:

    ld de,radio.word.on
    call radio.match
    ret nz                          ; (anything else: the command's echo, ...)
    ld a,1
    ld (radio.got.on),a
    or a                            ; (nz)
    ret

;-------------------------------------------------------------------------------
radio.match:

 ; output:
 ; - z = radio.line starts with the 0-terminated word at de, hl = after it

    ld hl,radio.line

    radio.match.loop:
        ld a,(de)
        or a
        ret z
        cp (hl)
        ret nz
        inc hl
        inc de
        jr radio.match.loop

;-------------------------------------------------------------------------------
radio.screen:

    defm "SAM MOD player - Radio Station"
    defb 0,2
    defm "Random MODs from Modland,"
    defb 0
    defm "through the SAM FPGA board."
    defb 0,2
    defm "While a tune plays:"
    defb 0
    defm " F    keep it (favourites)"
    defb 0
    defm " N    next tune"
    defb 0
    defm " ESC  stop the radio"
    defb 0,0

radio.attributes:
    defb  3,colour.orange
    defb  1,colour.green
    defb 25,colour.blue
    defb  2,colour.green
    defb  1,colour.yellow

radio.cmd.on:       defm "AT$RADIO=ON,"
radio.cmd.on.len:   equ $ - radio.cmd.on
radio.cmd.next:     defm "AT$RADIO=NEXT",0
radio.cmd.show:     defm "AT$SHOW=MUSIC",0
radio.cmd.bad:      defm "AT$RADIO=BAD",0
radio.cmd.off:      defm "AT$RADIO=OFF",0

radio.word.ok:      defm "OK",0
radio.word.error:   defm "ERROR",0
radio.word.ready:   defm "READY ",0
radio.word.wait:    defm "WAIT ",0
radio.word.info:    defm "INFO ",0
radio.word.on:      defm "RADIO ON",0

radio.txt.starting:     defm "Tuning in...",0
radio.txt.loading:      defm "Loading:",0
radio.txt.loading.status: defm "Loading the next tune...",0
radio.txt.no.board:     defm "Needs the SAM FPGA board's Wi-Fi",0
radio.txt.no.ados:      defm "The radio needs ADOS",0
radio.txt.old.board:    defm "Update the board's ESP32",0
radio.txt.no.answer:    defm "No answer from the board",0
radio.txt.error:        defm "The board said ERROR",0

;-------------------------------------------------------------------------------
; work space: the end of the screen page's free 2K (ados.s uses its start
; for MOD headers while listing; the radio doesn't list)

radio.got:          equ screen.free + 0x600
radio.got.ready:    equ radio.got + 0   ; READY came: radio.path
radio.got.wait:     equ radio.got + 1   ; WAIT came: radio.text
radio.got.on:       equ radio.got + 2   ; RADIO ON came
radio.got.error:    equ radio.got + 3   ; ERROR came
radio.got.len:      equ 4

radio.cmd.buf:      equ radio.got + 0x10    ; "AT$RADIO=ON,4096" (20)
radio.line:         equ radio.got + 0x40    ; 64 each
radio.path:         equ radio.line + 0x40
radio.info:         equ radio.path + 0x40
radio.text:         equ radio.info + 0x40

    assert radio.text + 0x40 <= screen.attributes
