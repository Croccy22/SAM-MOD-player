 ;---------------------------------------------------------------
 ; Effect B - Position Jump
 ;---------------------------------------------------------------
 ; disable.pos: 0 = jump, 1 = ignored (L), 2 = jump (the Radio Station:
 ; next.position ends the tune if that goes back)
    ld a,(disable.pos)
    dec a
    ret z
 r1.111:
    ld a,(parameter)
    dec a
    ld (song.position),a
 pj2:
    xor a
    ld (pattern_break.row),a
    inc a
    ld (position_jump.flag),a

    ret
