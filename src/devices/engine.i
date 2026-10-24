; FPGA sample engine - run time (docs/sample-engine.md)

; The engine plays the samples itself, so instead of the burst player this
; run time only:
; - takes the 50 Hz frame interrupt (no line interrupts)
; - sets the frame palette and screen as the burst player does
; - calls the tracker, then sends each channel to the engine
;
; The tracker still writes its burst player variables (here: engine.shadow)
; and the hooks in its channel routines fill in se.channels (memory.i).

;===============================================================================
engine.setup:

 ; called by @go.burst after maker has made a burst player for the screen
 ; device (that leaves the volume and pitch tables and the helper routines
 ; used by the tracker in place, everything after them is replaced)

    ld hl,engine.runtime.source
    ld de,engine.runtime
    ld bc,engine.runtime.len
    ldir

    ld a,opcode.jp_nn
    ld (0x0038),a
    ld hl,engine.interrupt
    ld (0x0039),hl

    ld hl,engine.run
    ld (run.program + 1),hl

    ld hl,engine.tracker.addr
    ld (bp.ptr.addr.tracker),hl
    ld hl,engine.tracker.page
    ld (bp.ptr.page.tracker),hl
    ld hl,engine.demo.addr
    ld (bp.ptr.addr.demo),hl
    ld hl,engine.demo.page
    ld (bp.ptr.page.demo),hl
    ld hl,engine.enable
    ld (bp.ptr.addr.enable),hl
    ld hl,engine.exit
    ld (bp.ptr.addr.exit),hl

    ; burst player variable pointers -> shadow variables

    ld hl,engine.shadow
    ld de,bp.pointers.sample
    ld b,4

    @loop:

        ld a,es.page
        call @pointer
        ld a,es.offset
        call @pointer
        ld a,es.volume
        call @pointer
        ld a,es.speed.low
        call @pointer
        ld a,es.speed.high
        call @pointer
        ld a,es.speed.fraction
        call @pointer

        ld a,l
        add a,es.len
        ld l,a
        jr nc,$+3
        inc h

        djnz @-loop

    ld a,device.engine
    ld (bp.device),a

    ld a,(burstplayer.amiga)
    or a
    ld a,se.global.enable
    jr z,$+4
    ld a,se.global.enable + se.global.ntsc
    ld (engine.global),a

    ret

 @pointer:

    ; (de) = hl + a, de += 2

    push hl
    add a,l
    ld l,a
    jr nc,$+3
    inc h
    ex de,hl
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ex de,hl
    pop hl

    ret

;===============================================================================
engine.runtime.source:

    org bp.audio_buffer.1           ; burst page, after the tracker's helpers

engine.runtime:

;-------------------------------------------------------------------------------
engine.run:

 ; entered from run.program: LMPR = burst page, SP = 0x8000, interrupts off

    call engine.disable

 engine.demo.page: equ $+1
    ld a,0
    out (port.hmpr),a
 engine.demo.addr: equ $+1
    jp 0

;-------------------------------------------------------------------------------
engine.enable:

 ; called by the demo (enable.burst) to start playing

    di

    ld hl,se.channels
    ld b,4 * se.ch.len
    @loop:
        ld (hl),0
        inc hl
        djnz @-loop

    ld hl,engine.state
    ld b,4 * ps.len
    @loop:
        ld (hl),0
        inc hl
        djnz @-loop

    ld hl,0xffff
    ld (engine.last.row),hl

    xor a
    ld (engine.filter),a

    ld a,se.global.control          ; enable first
    out (port.sample_engine.index),a
 engine.global: equ $+1
    ld a,se.global.enable           ; + se.global.ntsc
    out (port.sample_engine.data),a ; -> SEPARATION
    ld (engine.enabled),a
    ld (engine.global.sent),a
    ld a,255
    out (port.sample_engine.data),a ; SEPARATION: hard left / right
    ld a,64
    out (port.sample_engine.data),a ; MASTER_VOLUME

    ld a,0xff
    out (port.line_interrupt),a     ; frame interrupts only

    ei
    ret

;-------------------------------------------------------------------------------
engine.exit:

 ; called by the demo (exit.burst) to stop playing

    di
    call engine.disable
    jp bp.exit

;-------------------------------------------------------------------------------
engine.disable:

    ld a,se.global.control
    out (port.sample_engine.index),a
    xor a
    out (port.sample_engine.data),a ; stops all channels
    ld (engine.enabled),a

    ret

;-------------------------------------------------------------------------------
engine.interrupt:

    push af

    in a,(port.status)
    and frame.interrupt
    jr nz,@not.frame                ; active low

    push bc
    push de
    push hl
    push ix
    push iy
    ex af,af'
    push af
    exx
    push bc
    push de
    push hl

    in a,(port.hmpr)
    push af

    ; frame palette and screen (as the burst player)

    ld hl,frame.palette + 15
    ld bc,16 * 0x100 + port.clut
    otdr

    in a,(port.vmpr)
    ld e,a
    ld a,(frame.screen)
    and a
    jr nz,$+3
    ld a,e
    out (port.vmpr),a

 engine.tracker.page: equ $+1
    ld a,0
    out (port.hmpr),a
 engine.tracker.addr: equ $+1
    call 0

    ld a,(engine.tracker.page)      ; sample table in view
    out (port.hmpr),a
    call engine.flush

    pop af
    out (port.hmpr),a

    pop hl
    pop de
    pop bc
    exx
    pop af
    ex af,af'
    pop iy
    pop ix
    pop hl
    pop de
    pop bc

 @not.frame:

    pop af
    ei
    ret

;-------------------------------------------------------------------------------
engine.flush:

 ; send the four channels and the filter to the engine

    ; a new row was read if the song position or row changed (a pattern
    ; delay repeats a row without new notes)

    ld a,(song.position)
    ld l,a
    ld a,(pattern.row)
    ld h,a
    ld de,(engine.last.row)
    xor a
    sbc hl,de
    jr z,@same.row
    add hl,de
    ld (engine.last.row),hl
    inc a
 @same.row:
    ld (engine.new.row),a

    ld ix,se.channels
    ld hl,engine.state
    ld c,0                          ; channel's first register
    ld b,4

    @loop:

        push bc
        push hl
        call @channel
        pop hl
        ld de,ps.len
        add hl,de
        ld de,se.ch.len
        add ix,de
        pop bc
        ld a,c
        add a,se.channel.len
        ld c,a

        djnz @-loop

    ; filter: E00 = on, E01 = off, in the row being played

    ld hl,mod.current.row + 2
    ld b,4

    @loop:

        ld a,(hl)
        and 0x0f
        cp 0x0e
        jr nz,@next
        inc hl
        ld a,(hl)
        dec hl
        cp 0x02                     ; E00 or E01
        jr nc,@next
        xor 1                       ; 1 = on
        add a,a
        add a,a                     ; -> se.global.filter
        ld (engine.filter),a
     @next:
        inc hl
        inc hl
        inc hl
        inc hl

        djnz @-loop

    ld a,(engine.enabled)
    or a
    ret z
 engine.filter: equ $+1
    or 0
 engine.global.sent: equ $+1
    cp 0
    ret z

    ld (engine.global.sent),a
    ld b,a
    ld a,se.global.control
    out (port.sample_engine.index),a
    ld a,b
    out (port.sample_engine.data),a

    ret

;-------------------------------------------------------------------------------
@channel:

 ; input:
 ; - ix = channel in se.channels (from the tracker's hooks)
 ; - hl = channel in engine.state (ProTracker's sample start and length)
 ; - c  = channel's first engine register

    ld (@state),hl
    ld de,@work
    push bc
    ld bc,ps.len
    ldir
    pop bc

    call @channel.body

 @state: equ $+1
    ld de,0
    ld hl,@work
    ld bc,ps.len
    ldir

    ret

 @work:
    @work.start:    defs 3          ; linear address (lsb first)
    @work.length:   defw 0          ; words
    @work.offset:   defb 0          ; last sample offset (9xx)

;-------------------------------------------------------------------------------
@channel.body:

    ld a,(engine.new.row)
    or a
    call nz,@new.row

    ld a,(ix + se.ch.flags)
    ld (ix + se.ch.flags),0
    rra
    jr c,@trigger
    rra
    jr nc,@period.volume

    ; new sample without a note: its loop takes over when the current block
    ; ends (ProTracker)

    call @entry.iy
    jr z,@period.volume
    ld a,c
    add a,se.loop
    out (port.sample_engine.index),a
    call @out.loop

 @period.volume:

    ld a,c
    add a,se.period
    out (port.sample_engine.index),a

 @out.period.volume:

    ld a,(ix + se.ch.period + 0)
    out (port.sample_engine.data),a
    ld a,(ix + se.ch.period + 1)
    out (port.sample_engine.data),a
    ld a,(ix + se.ch.volume)
    cp 0x3f                         ; tracker volumes stop at 0x3f
    jr nz,$+4
    ld a,0x40
    out (port.sample_engine.data),a

    ret

 @out.loop:

    ld a,(iy + st.engine.loop.start - st.engine.end + 0)
    out (port.sample_engine.data),a
    ld a,(iy + st.engine.loop.start - st.engine.end + 1)
    out (port.sample_engine.data),a
    ld a,(iy + st.engine.loop.start - st.engine.end + 2)
    out (port.sample_engine.data),a
    ld a,(iy + st.engine.loop.len - st.engine.end + 0)
    out (port.sample_engine.data),a
    ld a,(iy + st.engine.loop.len - st.engine.end + 1)
    out (port.sample_engine.data),a

    ret

 @entry.iy:

    ; output:
    ; - iy = st.end of the channel's sample
    ; - z  = no sample yet

    ld l,(ix + se.ch.entry + 0)
    ld h,(ix + se.ch.entry + 1)
    push hl
    pop iy
    ld a,h
    or l

    ret

;-------------------------------------------------------------------------------
@trigger:

 ; start a note from ProTracker's sample start and length

    call @entry.iy
    jr z,@stop                      ; no sample yet

    ld a,(iy + st.engine.loop.len - st.engine.end + 0)
    or (iy + st.engine.loop.len - st.engine.end + 1)
    jr z,@stop                      ; empty sample

    ; linear start -> page and offset

    ld hl,(@work.start)
    ld a,h
    rlca
    rlca
    and 0x03
    ld b,a
    ld a,(@work.start + 2)
    add a,a
    add a,a
    or b
    ld b,a                          ; page
    ld a,h
    and 0x3f
    or 0x80
    ld d,a
    ld e,l                          ; offset

    ld a,c
    out (port.sample_engine.index),a
    ld a,e
    out (port.sample_engine.data),a ; START
    ld a,d
    out (port.sample_engine.data),a
    ld a,b
    out (port.sample_engine.data),a
    ld hl,(@work.length)
    ld a,l
    out (port.sample_engine.data),a ; LEN
    ld a,h
    out (port.sample_engine.data),a
    call @out.loop                  ; LOOP, LOOPLEN
    call @out.period.volume         ; PERIOD, VOLUME
    ld a,se.control.trigger
    out (port.sample_engine.data),a ; CONTROL

    ret

 @stop:

    ld a,c
    add a,se.control
    out (port.sample_engine.index),a
    ld a,se.control.stop
    out (port.sample_engine.data),a

    jp @period.volume

;-------------------------------------------------------------------------------
@new.row:

 ; ProTracker keeps a sample start and length per channel:
 ; - an instrument number sets them to its sample
 ; - sample offset (9xx) moves the start on and shortens the length, with or
 ;   without a note, until the next instrument number (an offset past the
 ;   end leaves a length of one word)

    ld a,c                          ; channel * 16 -> channel * 4
    rrca
    rrca
    add a,mod.current.row \ 0x100
    ld l,a
    ld h,mod.current.row / 0x100    ; hl = channel's note: SPppsECC

    ld a,(hl)
    and 0xf0
    ld b,a
    inc hl
    inc hl
    ld a,(hl)
    rrca
    rrca
    rrca
    rrca
    and 0x0f
    or b
    jr z,@no.instrument

    push hl
    call @instrument
    pop hl

 @no.instrument:

    ld a,(hl)
    and 0x0f
    cp 9
    ret nz

    inc hl
    ld a,(hl)
    or a
    jr nz,@offset.new
    ld a,(@work.offset)             ; 900 = previous offset
 @offset.new:
    ld (@work.offset),a
    or a
    ret z

    ld d,a                          ; offset in words = xx * 128
    ld e,0
    srl d
    rr e
    ld hl,(@work.length)
    or a
    sbc hl,de
    jr c,@one.word
    jr z,@one.word
    ld (@work.length),hl

    ld hl,@work.start + 1           ; start + xx * 256 bytes
    add a,(hl)
    ld (hl),a
    ret nc
    inc hl
    inc (hl)
    ret

 @one.word:

    ld hl,1
    ld (@work.length),hl

    ret

;-------------------------------------------------------------------------------
@instrument:

 ; set sample start and length from the sample (the tracker's hook has just
 ; stored its sample table entry)

    call @entry.iy
    ret z

    ld l,(iy + st.engine.start - st.engine.end + 0)
    ld h,(iy + st.engine.start - st.engine.end + 1)
    ld a,(iy + st.engine.start - st.engine.end + 2)
    call @linear
    ld (@work.start),hl
    ld (@work.start + 2),a
    ld b,a
    push hl

    ld l,(iy + 0)
    ld h,(iy + 1)
    ld a,(iy + 2)
    call @linear                    ; ahl = end

    pop de
    or a
    sbc hl,de
    sbc a,b                         ; ahl = length in bytes

    srl a
    rr h
    rr l                            ; -> words
    or a
    jr z,@length.ok
    ld hl,0xffff
 @length.ok:
    ld (@work.length),hl

    ret

;-------------------------------------------------------------------------------
@linear:

 ; input:
 ; - hl = offset (0x8000-0xbfff)
 ; - a  = external memory page

 ; output:
 ; - ahl = page * 16384 + (offset & 0x3fff)

    ld d,a
    ld a,h
    and 0x3f
    ld h,a
    ld a,d
    rrca
    rrca
    ld d,a
    and 0xc0
    or h
    ld h,a
    ld a,d
    and 0x3f

    ret

;-------------------------------------------------------------------------------
; ProTracker's sample start and length per channel (see @new.row)

engine.state:

    ps.start:           equ 0       ; linear address
    ps.length:          equ 3       ; words
    ps.offset:          equ 5       ; last sample offset
    ps.len:             equ 6

    defs 4 * ps.len

engine.last.row:    defw 0xffff     ; song position, pattern row
engine.new.row:     defb 0

;-------------------------------------------------------------------------------
; shadow of the burst player variables the tracker writes, per channel

engine.shadow:

    es.page:            equ 0       ; play position, set when a note starts
    es.offset:          equ 1
    es.volume:          equ 3       ; burst player volume table (not used)
    es.speed.low:       equ 4       ; burst player speed (not used)
    es.speed.high:      equ 5
    es.speed.fraction:  equ 6
    es.len:             equ 7

    defs 4 * es.len

engine.enabled:     defb 0      ; GLOBAL_CONTROL without filter, 0 = disabled

engine.runtime.len: equ $ - engine.runtime

    assert $ < 0x7000               ; well below the stack

    org engine.runtime.source + engine.runtime.len
