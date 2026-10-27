;SAM MOD player - SAMantha detection (docs/sample-engine.md)

; lives in the spare top 2K of the screen page with multipart.s, the loader
; page is full

;-------------------------------------------------------------------------------
engine.detect:

 ; called at the end of the device screen's memory check

    ld a,(loader.ram)
    and %11100
    ret z                           ; the engine plays from external memory

    ld a,se.id
    out (port.sample_engine.index),a
    in a,(port.sample_engine.data)
    cp se.id.value
    ret nz

    ld a,1
    ld (engine.fitted),a

    ret

;-------------------------------------------------------------------------------
engine.unusable:

 ; output:
 ; - z = sample engine selected but not fitted

    ld a,(device.device)
    cp device.engine
    ret nz

 engine.fitted: equ $+1
    ld a,0                          ; 1 = fitted
    or a

    ret

;-------------------------------------------------------------------------------
engine.details.de:

 ; output:
 ; - de = text after the sample engine's details
 ; - z

    ld de,text.blank
    ld a,(engine.fitted)
    or a
    jr nz,@fitted
    ld de,@text.absent
 @fitted:
    xor a

    ret

 @text.absent:  defm "absent"
                defb 0

;-------------------------------------------------------------------------------
; device screen texts moved here from device.s

text.speed.pal:     defm "7.093790 MHz"
                    defb 0
text.speed.ntsc:    defm "7.159090 MHz"
                    defb 0
