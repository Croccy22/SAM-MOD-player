;SAM MOD player - multi-part mod loading

; Loads a mod that is too big for one disk / B-DOS record from several files.

; Naming: the first part ends in ".1", the next ".2", and so on up to ".9", for
; example "BIGSONG.1", "BIGSONG.2", "BIGSONG.3". Trailing spaces are ignored.

; - on a B-DOS mass storage drive, each next part is looked for in the next
;   record (part 1 in record n, part 2 in record n+1, ...)
; - on a floppy drive, the user is asked to insert the disk with the next part

; Parts are raw slices of the original mod file, each stored as a normal CODE
; file. Only part 1 starts with a mod header and so only part 1 shows up in the
; file list, with the size of the complete mod. Loading stops as soon as the
; size calculated from the mod header has been loaded. Multi-part mods need
; external memory (megabyte interface).

;-------------------------------------------------------------------------------
; variables

multi.part.name:        defs 10     ; full filename of part being loaded
multi.part.digit:       defw 0      ; address of part digit in multi.part.name
multi.part.active:      defb 0      ; 1 = loading a multi-part mod
multi.part.size:        defs 3      ; size of complete mod in bytes (lsb first)
multi.part.page:        defb 0      ; external page where current part starts
multi.part.dest:        defw 0      ; address where current part starts
multi.part.len.mod:     defw 0      ; length of current part modulo 16384
multi.part.len.pages:   defb 0      ; length of current part in 16K pages
multi.part.record:      defw 0      ; record selected when load started
multi.part.sp:          defw 0      ; stack pointer to restore on error

mod.multi.part:         defb 0      ; set to make mod.determine.type accept a
                                    ; part 1 and store its size

;-------------------------------------------------------------------------------
multi.part.digit.hl:

 ; check if filename is that of the first part of a multi-part mod

 ; input:
 ; - hl = 10 character filename

 ; output:
 ; - z  = filename ends in ".1" (trailing spaces ignored)
 ; - hl = address of part digit

    call multi.part.name.hl
    ret nz
    ld a,c
    cp "1"

    ret

;-------------------------------------------------------------------------------
multi.part.name.hl:

 ; check if filename is that of a part of a multi-part mod

 ; input:
 ; - hl = 10 character filename

 ; output:
 ; - z  = filename ends in ".1" to ".9" (trailing spaces ignored)
 ; - c  = part digit ["1"-"9"]
 ; - hl = address of part digit

    ld bc,9
    add hl,bc           ; -> last character

    ld b,9

  @loop:

    ld a,(hl)
    cp " "
    jr nz,@+found

    dec hl
    djnz @-loop

  @not.multi.part:

    or 1                ; nz
    ret

  @found:

    ld a,b              ; b = position of last character [0-9]
    cp 2
    jr c,@-not.multi.part   ; need at least one character before ".n"

    ld a,(hl)
    cp "1"
    jr c,@-not.multi.part
    cp "9" + 1
    jr nc,@-not.multi.part
    ld c,a

    dec hl
    ld a,(hl)
    inc hl
    cp "."

    ret

;-------------------------------------------------------------------------------
multi.part.select.record:

 ; select record hl when the user moves left or right through the records,
 ; remembering the direction so that records holding only later parts of
 ; multi-part mods (NAME.2 - NAME.9) are skipped when the directory is read

    push hl
    ld a,dvar.record
    call bdos.get.dvar.word     ; hl = current record
    pop de                      ; de = new record
    or a
    sbc hl,de
    ld a,1                      ; up
    jr c,@+direction
    ld a,-1                     ; down
    jr nz,@+direction
    xor a                       ; same record
  @direction:
    ld (multi.part.skip),a

    ex de,hl
    jp bdos.select.record.hl

;-------------------------------------------------------------------------------
multi.part.skip.records:

 ; called after a record's directory has been read (bdos.read.dir): if the
 ; user has just moved to this record and it holds only later parts, move on
 ; in the same direction until a record that is empty or holds anything else,
 ; or the first or last record

    call @parts.only
    jr nz,@+done

  multi.part.skip: equ $+1
    ld a,0                      ; 0 = no skipping, 1 = up, -1 = down
    or a
    ret z

    ld e,a
    ld d,0
    rla
    jr nc,$+3
    dec d                       ; de = direction

    push de
    ld a,dvar.record
    call bdos.get.dvar.word
    pop de
    add hl,de                   ; hl = next record
    ld a,h
    or l
    jr z,@+done                 ; before the first

    push hl
    ld a,dvar.records
    call bdos.get.dvar.word
    pop de
    or a
    sbc hl,de
    jr c,@+done                 ; past the last

    ex de,hl
    call bdos.select.record.hl
    call bdos.read.dir

    ld a,dvar.record            ; show the new record number
    call bdos.get.dvar.word
    ld de,loader.dir + loader.dir.len + 15
    call text.hl.decimal

    jr multi.part.skip.records

  @done:

    xor a
    ld (multi.part.skip),a

    ret

;-------------------------------------------------------------------------------
@parts.only:

 ; output:
 ; - z = the directory just read holds files, and all are later parts

    ld hl,loader.directory
    ld b,80
    ld c,0                      ; later parts found

  @loop:

    ld a,(hl)
    or a
    jr z,@+next                 ; no (code) file in this entry

    push bc
    push hl
    call multi.part.name.hl
    ld a,c
    pop hl
    pop bc
    ret nz                      ; not a part
    cp "2"
    jr c,@+not.later            ; part 1 is listed: stop here
    inc c

  @next:

    ld de,loader.directory.len
    add hl,de
    djnz @-loop

    ld a,c
    or a
    jr z,@+not.later            ; empty record: stop here
    xor a                       ; z
    ret

  @not.later:

    or 1                        ; nz
    ret

;-------------------------------------------------------------------------------
multi.part.set.flag.hl:

 ; set mod.multi.part when filename is that of a part 1

 ; input:
 ; - hl = 10 character filename

    call multi.part.digit.hl
    ld a,0
    jr nz,$+3
    inc a
    ld (mod.multi.part),a

    ret

;-------------------------------------------------------------------------------
multi.part.determine.type.ix:

 ; mod.determine.type for directory listing, accepting a part 1 of a
 ; multi-part mod (its size is then the size of the complete mod)

 ; input:
 ; - ix = loader.directory entry (starts with 10 character filename)
 ; - start of file at screen.free

 ; output:
 ; - a  = mod.type

    push ix
    pop hl
    call multi.part.set.flag.hl

    ld hl,screen.free + 9
    call mod.determine.type

    push af
    xor a
    ld (mod.multi.part),a
    pop af

    ret

;-------------------------------------------------------------------------------
multi.part.get.entry:

 ; input:
 ; - hl = start of samdos directory entry

 ; output:
 ; - d  = first track
 ; - e  = first sector
 ; - multi.part.len.* = file length

    ld l,samdos.dir.track
    ld d,(hl)
    inc l
    ld e,(hl)

    ld l,samdos.dir.length.pages
    ld a,(hl)
    ld (multi.part.len.pages),a

    ld l,samdos.dir.length.bytes
    ld a,(hl)
    ld (multi.part.len.mod + 0),a
    inc l
    ld a,(hl)
    and %00111111
    ld (multi.part.len.mod + 1),a

    ret

;-------------------------------------------------------------------------------
multi.part.init:

 ; called when a file has been selected, before it is loaded

 ; input:
 ; - de = first track / sector of selected file
 ; - multi.part.name = filename of selected file

    xor a
    ld (multi.part.active),a

    ld hl,multi.part.name
    call multi.part.digit.hl
    ret nz

    ld (multi.part.digit),hl

    ld a,(loader.ram)
    and %11100
    jp z,@no.external.memory

    ; read start of file to get size of complete mod from mod header

    push de

    ld hl,screen.free
    ld b,3

  @loop:

    push bc
    push hl

    ld hl,dos.sector
    call bdos.read.sector

    pop de              ; destination
    ld hl,dos.sector
    ld bc,510
    ldir

    ld bc,(dos.sector + 510)    ; c = next track, b = next sector
    ex de,hl
    ld d,c
    ld e,b

    pop bc

    ld a,d
    or e
    jr z,@+read

    djnz @-loop

  @read:

    ld a,1
    ld (mod.multi.part),a

    ld hl,screen.free + 9
    call mod.determine.type     ; -> multi.part.size

    push af
    xor a
    ld (mod.multi.part),a
    pop af

    pop de

    cp mod.type.invalid
    ret z

    ; check that the complete mod fits in external memory

    ld a,(loader.ram)
    and %11100          ; megabytes * 4
    add a,a
    add a,a             ; megabytes * 16 = 64K blocks
    ld b,a
    ld a,(multi.part.size + 2)
    cp b
    jp nc,@no.external.memory

    ld a,1
    ld (multi.part.active),a

    call multi.part.is.records
    ret nz

    ld a,dvar.record
    call bdos.get.dvar.word
    ld (multi.part.record),hl

    ret

  @no.external.memory:

    ld de,mes.multi.memory
    jp multi.part.error

;-------------------------------------------------------------------------------
multi.part.continue:

 ; called after the first part has been loaded into external memory

    ld a,(multi.part.active)
    or a
    ret z

    ld a,page.mod.megabyte
    ld (multi.part.page),a
    ld hl,load.offs
    ld (multi.part.dest),hl

  @loop:

    ; move to exact end of the part just loaded

    ld hl,(multi.part.dest)
    ld de,(multi.part.len.mod)
    add hl,de
    ld a,(multi.part.len.pages)
    ld b,a
    ld a,(multi.part.page)
    add a,b
    bit 6,h
    jr z,@+same.page
    res 6,h
    inc a
  @same.page:
    ld (multi.part.page),a
    ld (multi.part.dest),hl

    ; loaded = (page - first page) * 16384 + (address - 0x8000)

    sub page.mod.megabyte
    rrca
    rrca
    ld e,a              ; e = bits 23-16 (low 6 bits valid)
    and %11000000
    res 7,h
    or h
    ld h,a              ; h = bits 15-8
    ld a,e
    and %00111111
    ld e,a              ; ehl = bytes loaded

    ; done when loaded >= size

    ld a,(multi.part.size + 0)
    ld b,a
    ld a,l
    sub b
    ld a,(multi.part.size + 1)
    ld b,a
    ld a,h
    sbc a,b
    ld a,(multi.part.size + 2)
    ld b,a
    ld a,e
    sbc a,b
    jr nc,@+done

    ; next part

    ld hl,(multi.part.digit)
    ld a,(hl)
    cp "9"
    jr z,@+missing
    inc (hl)

    call @set.message.digits

    ld de,mes.multi.loading
    call @print.status

    call @next.disk
    jr nz,@+missing

    call multi.part.find
    jr nz,@+missing

    push de
    ld hl,meg.load.mod.relocate
    ld de,inst.buffer
    ld bc,meg.load.mod.len
    ldir
    pop de

    ld a,(multi.part.page)
    ld c,a
    ld hl,(multi.part.dest)
    ld a,(loader.drive)

    call meg.load.mod

    jr @-loop

  @done:

    jr @+restore.record

  @missing:

    call @restore.record

    ld de,mes.multi.missing
    jp multi.part.error

;-------------------------------------------------------------------------------
@restore.record:

    call multi.part.is.records
    ret nz

    ld hl,(multi.part.record)
    call bdos.select.record.hl
    di

    ret

;-------------------------------------------------------------------------------
@next.disk:

 ; select next record or ask for next disk

 ; output:
 ; - nz = no next record

    call multi.part.is.records
    jr nz,@+ask.disk

    ld a,dvar.record
    call bdos.get.dvar.word
    inc hl
    push hl

    ld a,dvar.records
    call bdos.get.dvar.word     ; hl = number of records

    pop de                      ; de = next record
    or a
    sbc hl,de
    jr c,@+no.record

    ex de,hl
    call bdos.select.record.hl
    di

    xor a                       ; z
    ret

  @no.record:

    or 1                        ; nz
    ret

  @ask.disk:

    ld de,mes.multi.insert
    call @print.status

    call multi.part.wait.return

    ld de,mes.multi.loading
    call @print.status

    xor a                       ; z
    ret

;-------------------------------------------------------------------------------
@set.message.digits:

    ld hl,(multi.part.digit)
    ld a,(hl)
    ld (mes.multi.loading.digit),a
    ld (mes.multi.insert.digit),a
    ld (mes.multi.missing.digit),a

    ret

;-------------------------------------------------------------------------------
@print.status:

 ; de = message, printed on bottom line

    ld b,32
    ld hl,screen + screen.32.rows * 31
    jp print.de.b

;-------------------------------------------------------------------------------
multi.part.error:

 ; show message, wait for return and go back to file selection

 ; input:
 ; - de = message

    call @print.status
    call multi.part.wait.return

    xor a
    ld (multi.part.active),a

    ld sp,(multi.part.sp)
    jp loader

;-------------------------------------------------------------------------------
multi.part.wait.return:

    call scan.keyboard.return
    jr z,multi.part.wait.return

    ret

;-------------------------------------------------------------------------------
multi.part.is.records:

 ; output:
 ; - z = loading from B-DOS mass storage record (drive 2)

    ld a,(loader.drive)
    cp 2
    ret nz

    ld a,(loader.dos.version)
    cp dvar.version.b_dos.max + 1
    jr nc,@+not.records

    xor a
    ret

  @not.records:

    or 1
    ret

;-------------------------------------------------------------------------------
multi.part.find:

 ; find multi.part.name in directory of current disk / record

 ; output:
 ; - z  = found
 ; - de = first track / sector
 ; - multi.part.len.* = file length

    ld d,0

  @loop.tracks:

    ld e,1

  @loop.sectors:

    ld hl,dos.sector
    call bdos.read.sector

    ld hl,dos.sector
    call @match.entry
    ret z

    ld hl,dos.sector + 0x100
    call @match.entry
    ret z

    inc e
    ld a,e
    cp 11
    jr nz,@-loop.sectors

    inc d
    ld a,d
    cp 4
    jr nz,@-loop.tracks

    or 1                ; nz = not found
    ret

  @match.entry:

    ; input:
    ; - hl = directory entry
    ; - de = current track / sector (kept when no match)

    ld a,(hl)
    cp samdos.filetype.code
    ret nz

    push de
    push hl

    inc l               ; samdos.dir.filename
    ld de,multi.part.name
    ld b,10

  @compare:

    ld a,(de)
    cp (hl)
    jr nz,@+no.match
    inc de
    inc l
    djnz @-compare

    pop hl
    pop de

    call multi.part.get.entry

    xor a               ; z
    ret

  @no.match:

    pop hl
    pop de
    ret                 ; nz

;-------------------------------------------------------------------------------
; messages (32 characters, digit filled in)

mes.multi.loading:          defm " Loading part "
mes.multi.loading.digit:    defm "2"
                            defb 0

mes.multi.insert:           defm "Insert disk with part "
mes.multi.insert.digit:     defm "2"
                            defm " - RETURN"
                            defb 0

mes.multi.missing:          defm "Part "
mes.multi.missing.digit:    defm "2"
                            defm " not found - press RETURN"
                            defb 0

mes.multi.memory:           defm "Needs more external RAM - RETURN"
                            defb 0
