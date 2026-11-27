; SAM MOD player - loader: ADOS overlay

; ADOS (Adrian Brown's DOS for FAT cards, hard drives and floppies) lets the
; loader read MODs as single files from any folder of a FAT card. boot.s
; loads this file over the msdos (FAT12 floppy) code of the loader, fat.s,
; when ADOS is the DOS (DVAR 7 >= 60): ADOS reads only SAM disks through the
; sector hooks fat.s uses, so fat.s is no use under ADOS, and the loader page
; has no room for both.
;
; It keeps fat.s's entry points and the variables the rest of the loader uses
; at the same addresses (assembled with the loader's symbols, see build.xml):
;
; - fat.disk.read        sets msdos, so the loader lists with fat.directory.read
; - fat.directory.read   lists the current folder: folders, disk images and MODs
; - fat.file.find        a folder or disk image: goes into it; a MOD: loads it
; - save.sam.sp+1, fat.parafile, fat.path are data the loader writes
;
; The folder is listed by catching what ADOS's directory hook (165) prints:
; the current channel's output routine is pointed at a routine that stores
; the text in the mod page. In a FAT folder a line is " name  size" (the
; size in bytes, "nnnK" from 64K, or <DIR>); on a SAM disk (a floppy, or
; inside a disk image) it is "  n name       sectors TYPE" and the last line
; ends in "free". A disk image is any 800K file. Each MOD is opened (hooks
; 195 and 158: any name, long names too) and its first 1536 bytes checked as
; the other DOSes' files are. The listing stays in the mod page until a MOD
; is loaded, and each entry keeps the offset of its line there (in its date,
; which ADOS doesn't give), so the full name can be found again when chosen.
;
; DVAR 48 is set around the hooks, so ADOS gives errors back (carry in F')
; instead of stopping the loader with a BASIC error.

;-------------------------------------------------------------------------------

@sam.dvar48:            equ 0x4250      ; DVAR 48 in the DOS page, seen in section B
@chans:                 equ 0x5c4f      ; ROM: the channel table, 5 bytes each (output routine first)
@hook.dir:              equ 165
@hook.set.dir:          equ 145
@hook.open:             equ 158
@hook.read:             equ 161
@hook.close:            equ 194
@hook.long.name:        equ 195

@dir.file:              equ 0           ; loader.dir entry
@dir.title:             equ 8
@dir.type:              equ 28
@dir.patterns:          equ 29
@dir.date:              equ 30          ; "*", then the line's offset in the listing
@dir.size:              equ 38
@dir.samples:           equ 40
@dir.len:               equ 41

@line:                  equ dos.sector          ; a line of the listing (page 0)
@name:                  equ dos.sector + 256    ; the name in it, for the hooks
@parent.offset:         equ 0xffff

;===============================================================================
    org fat.disk.read

    jp @disk.read

@disk.read:

    ld (save.sam.sp+1),sp
    ld hl,@radio.load       ; for the Radio Station (radio.s)
    ld (radio.load.vector),hl
    ld a,1
    ld (msdos+1),a          ; -> fat.directory.read
    ret

;===============================================================================
    defs fat.directory.read - $

    jp @dir.read

@dir.read:

 ; input:
 ; - de = next free loader.dir entry

    ld (@entry),de

 @again:
    call @prepare

    ld hl,(@chans)          ; catch the listing: the ROM's K and S channels
    ld e,(hl)               ; (the first two) print through the same routine
    inc hl
    ld d,(hl)
    ld (@chan.out+1),de
    ld de,ib.cap
    call @set.channels
    ld hl,0x8000
    ld (ib.cap.ptr),hl

    call @uifa.clear
    ld (ix + 1),"*"         ; everything in the current folder
    rst 8
    defb @hook.dir

 @chan.out:
    ld de,0
    call @set.channels

    xor a
    call ib.cap             ; the end

    ; a SAM disk listing ends in "n files, nK free"

    xor a
    ld (@sam),a
    ld hl,0x8000

    @loop.sam:

        call ib.line
        jr z,@sam.checked
        push hl
        call @line.has.free
        pop hl
        jr nz,@-loop.sam

        ld a,1
        ld (@sam),a

 @sam.checked:

    ld a,(@sam)             ; the first listing, in the player's own disk:
    ld hl,@first            ; out of it, to the folder last played from
    and (hl)
    ld (hl),0
    jr z,@+listing
    call @goto.saved
    call @finish
    jr @-again

 @listing:

    ; the first line with text is the path: its end becomes the label

    ld hl,0x8000

    @loop:
        call ib.line        ; (after a blank line)
        jr z,@+path
        inc b
        dec b
        jr z,@-loop

 @path:
    ld (@next),hl
    ld a,b
    push af
    call @set.label
    pop bc

    ld a,(@sam)             ; ".." in a disk image, or below the root
    or a
    jr nz,@add.parent
    ld a,b
    cp 4                    ; "C:\" is the root
    jr c,@+add.radio

 @add.parent:

    ld hl,@parent.offset
    ld (@offset),hl
    ld hl,@txt.parent
    ld de,@name
    ld bc,3
    ldir
    call @add.folder

 @add.radio:

    ld a,(@sam)             ; the Radio Station, in a FAT folder with the
    or a                    ; samfpga board's comms port there (radio.s)
    jr nz,@+loop.lines
    call radio.present
    jr nz,@+loop.lines
    ld hl,@radio.offset
    ld (@offset),hl
    ld hl,@txt.radio
    ld de,@name
    ld bc,@txt.radio.len
    ldir
    ld hl,@txt.radio.tag
    call @add.folder.hl
    call @radio.to.top

    @loop.lines:

        ld a,(loader.entries)
        cp 27
        jr nc,@+listed

        ld hl,(@next)
        ld (@offset),hl
        call ib.line
        jr z,@+listed
        ld (@next),hl

        call @parse.line    ; -> a = 0 nothing, 1 folder, 2 file
        or a
        jr z,@-loop.lines
        dec a
        jr nz,@is.file

        call @add.folder
        jr @-loop.lines

     @is.file:

        call @add.mod
        jr @-loop.lines

 @listed:

    rst 8
    defb @hook.close
    jp @finish

;-------------------------------------------------------------------------------
@set.channels:

 ; de = the output routine of the K and S channels

    ld hl,(@chans)
    ld (hl),e
    inc hl
    ld (hl),d
    ld bc,4
    add hl,bc
    ld (hl),e
    inc hl
    ld (hl),d
    ret

;-------------------------------------------------------------------------------
@line.has.free:

 ; output:
 ; - z = the line in @line ends with "free"

    ld a,b
    cp 4
    jr c,@+no
    ld hl,@line - 4
    ld e,b
    ld d,0
    add hl,de
    ld de,@txt.free
    ld b,4

    @loop:

        ld a,(de)
        cp (hl)
        ret nz
        inc hl
        inc de
        djnz @-loop

    ret

 @no:
    or 1
    ret

@txt.free:      defm "free"
@txt.cfg:       defm "\.samfpga\MODPLAY.CFG",0 ; the folder last played from (the samfpga interface's hidden folder)
@txt.cfg.len:   equ $ - @txt.cfg
@txt.parent:    defm "..",0
@txt.dir:       defm "  <DIR> "
@txt.radio.tag: defm " (RADIO)"

;-------------------------------------------------------------------------------
@radio.to.top:

 ; the Radio Station, just added at the end of the list, moved to the very top,
 ; above the drives and the folders (owner, 27 Nov 2026); the loader starts the
 ; cursor a line lower (loader.radio.top)

    ld a,(loader.entries)
    dec a                   ; the entries before it
    ret z
    ld hl,0
    ld de,loader.dir.len

    @loop:
        add hl,de
        dec a
        jr nz,@-loop

    push hl                 ; their size
    ld hl,(@entry)
    or a
    sbc hl,de               ; the Radio Station's entry
    push hl
    ld de,@swap
    ld bc,loader.dir.len
    ldir                    ; kept aside
    pop hl
    dec hl                  ; the last byte before it
    ld de,loader.dir.len
    ex de,hl
    add hl,de
    ex de,hl                ; de = the Radio Station's last byte
    pop bc
    lddr                    ; the others down one
    ld hl,@swap
    ld de,loader.dir
    ld bc,loader.dir.len
    ldir                    ; it, first
    ld a,1
    ld (loader.radio.top),a
    ret

@swap:  defs loader.dir.len
@txt.radio:     defm "Radio Station",0
@txt.radio.len: equ $ - @txt.radio
@radio.offset:  equ 0xfffe              ; (as @parent.offset: not a line of the listing)

;-------------------------------------------------------------------------------
@add.folder:

 ; adds the folder or image in @name (0-terminated)

    ld hl,@txt.dir

@add.folder.hl:

 ; hl = its 8 character tag

    ld de,(@entry)
    ld bc,8
    ldir
    ld hl,@name
    ld b,20
    call @copy.padded
    ld a,mod.type.invalid   ; (no type text)
    ld (de),a
    inc de
    xor a
    ld (de),a               ; patterns
    inc de
    call @put.date
    xor a
    ld (de),a               ; size
    inc de
    ld (de),a
    inc de
    ld (de),a               ; samples
    inc de
    jp @entry.added

;-------------------------------------------------------------------------------
@put.date:

    ld a,"*"                ; no date
    ld (de),a
    inc de
    ld hl,(@offset)
    ex de,hl
    ld (hl),e
    inc hl
    ld (hl),d
    inc hl
    ex de,hl
    ld b,5
    ld a," "

    @loop:
        ld (de),a
        inc de
        djnz @-loop

    ret

;-------------------------------------------------------------------------------
@copy.padded:

 ; copies the 0-terminated text at hl to de, b characters, padded with spaces

    ld a,(hl)
    or a
    jr z,@+pad
    ld (de),a
    inc hl
    inc de
    djnz @copy.padded
    ret

 @pad:
    ld a," "

    @loop:
        ld (de),a
        inc de
        djnz @-loop

    ret

;-------------------------------------------------------------------------------
@entry.added:

    ld (@entry),de
    ld hl,loader.entries
    inc (hl)
    ret

;===============================================================================
    defs save.sam.sp - $

    ld sp,0                 ; (the loader's errnodisc reads the word)

;-------------------------------------------------------------------------------
@prepare:

    ld hl,@ib.source
    ld de,inst.buffer
    ld bc,@ib.len
    ldir

    xor a
    ld (mod.multi.part),a   ; one file, not parts

    inc a                   ; errors back to us
    jr @dvar48

@finish:

    xor a

@dvar48:

 ; input:
 ; - a = DVAR 48 (0 = BASIC errors, 1 = given back)

    ld e,a
    di                      ; (and left off: the loader runs with interrupts off,
                            ; and the DOS turns them on in its hooks)
    in a,(port.lmpr)
    ld d,a
    ld a,(svar.dosflg)
    dec a
    ld c,a
    ld a,d
    and %11100000
    or c
    out (port.lmpr),a       ; the DOS page in section B (no stack use now)
    ld a,e
    ld (@sam.dvar48),a
    ld a,d
    out (port.lmpr),a
    ret


;-------------------------------------------------------------------------------
@add.mod:

 ; @name = file: adds it if it is a mod

    call @open
    ret c

    ld hl,screen.free       ; its first 1536 bytes (the screen page is in section C)
    ld de,1536
    xor a
    rst 8
    defb @hook.read
    ex af,af'
    ret c
    ex af,af'

    ld hl,screen.free
    call mod.determine.type
    cp mod.type.invalid
    ret z

    ld (@type),a
    ld de,(@entry)
    ld hl,@name
    ld b,8
    call @copy.padded
    ld hl,screen.free + mod.sample.title
    ld bc,mod.title.len
    ldir
 @type: equ $+1
    ld a,0
    ld (de),a
    inc de
    call mod.get.patterns.a
    ld (de),a
    inc de
    call @put.date
    call insert.file.size   ; size (file.size_kb) and samples: hl -> samples
    inc hl
    ex de,hl
    jp @entry.added

;===============================================================================
    defs fat.file.find - $

    jp @file.find

;-------------------------------------------------------------------------------
@uifa.clear:

    ld hl,uifa              ; type 0 (any), name ignored (hook 195 gives it)
    ld (hl),0
    inc hl
    ld b,14

    @loop:
        ld (hl)," "
        inc hl
        djnz @-loop

    ld b,0x30 - 15

    @loop:
        ld (hl),0
        inc hl
        djnz @-loop

    ld ix,uifa
    ret

;===============================================================================
    defs fat.load - $

    ret                     ; (fat.file.find doesn't come back)

;-------------------------------------------------------------------------------
@file.find:

 ; input:
 ; - ix = the loader.dir entry chosen

    pop hl                  ; the return to select.key: not needed

    call @prepare

    ld l,(ix + @dir.date + 1)
    ld h,(ix + @dir.date + 2)
    ld a,h
    and l
    cp @radio.offset & 0xff
    jp z,radio.start        ; (listing lines are at 0x8000-0xbfff: never 0xfffe)
    inc a
    jr z,@up

    call ib.line
    call @parse.line
    dec a
    jr nz,@load

    ; a folder or disk image: in, and list it

 @set.dir:

    call @name.args
    rst 8
    defb @hook.set.dir

 @relist:

    call @finish
    pop af                  ; the type select.key kept
    jp loader

 @up:

    ld hl,@txt.parent
    ld de,@name
    ld bc,3
    ldir
    jr @-set.dir

 @load:

    call @open
    jr c,@-relist

    exx                     ; de:hl = length
    push de
    push hl
    exx
    call @save.path
    pop hl
    pop de

    ld a,(loader.ram)
    and %11100
    jr nz,@external

    ; internal memory: in one read from page.mod on

    ld a,d                  ; pages = length / 16K
    or a
    jr nz,@-relist          ; (over 16M)
    ld a,h
    rlca
    rlca
    and %00000011
    ld c,a
    ld a,e
    add a,a
    add a,a
    or c                    ; a = whole pages
    ld b,a
    ld a,h
    and %00111111
    ld d,a
    ld e,l                  ; de = bytes mod 16K
    ld a,d
    or e
    ld a,b
    jr z,$+3
    inc a                   ; pages used
    ld c,a
    ld a,(loader.ram)
    and %00000010           ; 512K
    ld a,page.create.burstplayer & 0x0f
    jr z,$+4
    ld a,page.create.burstplayer
    sub page.mod
    cp c
    jr c,@-relist           ; too big for the memory fitted

    ld a,b
    ld c,page.mod
    call ib.read
    jr @loaded

 @external:

    ld c,page.mod.megabyte
    ld hl,load.offs
    call ib.xread

 @loaded:

    ex af,af'
    jr c,@-relist

    rst 8
    defb @hook.close
    call @finish
    jp file.loaded          ; with the type select.key kept on the stack

;-------------------------------------------------------------------------------
@radio.load:

 ; the Radio Station's tune (radio.s): hl = its path (0-terminated), the
 ; stack as at fat.file.find after its return address (the type)

    ld de,@name
    ld bc,64
    ldir
    call @prepare
    jp @-load

;-------------------------------------------------------------------------------
@open:

 ; opens @name: carry = failed, else de':hl' = length and file.size_kb set

    call @name.args
    rst 8
    defb @hook.long.name
    ex af,af'
    ret c
    call @uifa.clear
    rst 8
    defb @hook.open
    ex af,af'
    ret c
    exx
    ld a,h
    ld (file.size_kb + 1),a ; in 256 bytes
    ld a,e
    ld (file.size_kb + 2),a
    ld a,d
    exx
    cp 1
    ccf                     ; over 16M: no
    ret

;-------------------------------------------------------------------------------
@name.args:

 ; @name as hook 145/195 arguments: a = page 0, de = as in section C, bc = length

    ld hl,@name
    ld bc,0

    @loop:
        ld a,(hl)
        or a
        jr z,@+done
        inc hl
        inc bc
        jr @-loop

 @done:

    ld de,@name + 0x4000
    xor a
    ret

;===============================================================================
    defs fat.parafile + 11 - $      ; (the loader writes the name there)

;===============================================================================
    defs fat.path + 2 - $           ; (the loader writes the pointer there)

;-------------------------------------------------------------------------------
@set.label:

 ; the end of the path in @line (b long) -> text.volume.label (16)

    ld hl,@line
    ld a,b
    sub 16
    jr c,@+short
    ld e,a
    ld d,0
    add hl,de

 @short:

    ld de,text.volume.label
    ld b,16
    jp @copy.padded

;-------------------------------------------------------------------------------
@parse.line:

 ; input:
 ; - @line, b = length
 ; output:
 ; - a = 0 nothing, 1 folder or disk image, 2 file; @name = its name

    ld a,(@sam)
    or a
    jr nz,@sam.line

    ld a,(@line)            ; " name  size"
    cp " "
    jr nz,@nothing
    ld a,b
    cp 3
    jr c,@nothing

    ld hl,@line - 1         ; the last space
    ld e,b
    ld d,0
    add hl,de               ; -> last character

    @loop:
        ld a,(hl)
        cp " "
        jr z,@+space
        dec hl
        djnz @-loop
        jr @nothing

 @space:

    ld a,b
    cp 2
    jr c,@nothing           ; (the leading space: no size)
    push hl                 ; the size starts after it
    @loop:
        dec hl              ; back over the padding
        ld a,(hl)
        cp " "
        jr z,@-loop
    inc hl
    ld (hl),0               ; the name ends here
    pop hl
    inc hl

    ld de,@txt.dir.size     ; <DIR>
    call @compare
    ld a,1
    jr z,@+got.name
    ld de,@txt.image.size   ; 800K: a disk image
    call @compare
    ld a,1
    jr z,@+got.name
    inc a

 @got.name:

    push af
    ld hl,@line + 1
    ld de,@name
    ld bc,200
    ldir
    pop af
    ret

 @nothing:

    xor a
    ret

 @sam.line:                 ; "  n name       sectors CODE"

    ld hl,@line

    @loop:
        ld a,(hl)
        inc hl
        cp " "
        jr z,@-loop
        sub "0"
        cp 10
        jr nc,@-nothing     ; not a file line

    @loop:
        ld a,(hl)
        inc hl
        sub "0"
        cp 10
        jr c,@-loop         ; hl -> past the space after the number

    push hl                 ; long enough for a name?
    ld de,10
    add hl,de
    ld a,(hl)
    or a
    pop hl
    jr z,@-nothing

    push hl                 ; (the type is the last 4 characters)
    ld hl,@line - 4
    ld e,b
    ld d,0
    add hl,de
    ld de,@txt.code
    call @compare
    pop hl
    jr nz,@-nothing

    ld de,@name             ; the 10 character name, without trailing spaces
    ld bc,10
    ldir
    ld b,10

    @loop:
        dec de
        ld a,(de)
        cp " "
        jr nz,@+end
        djnz @-loop

 @end:

    inc de
    xor a
    ld (de),a
    ld a,2
    ret

;-------------------------------------------------------------------------------
@compare:

 ; output:
 ; - z = the 0-terminated text at hl is the one at de

    push hl

    @loop:
        ld a,(de)
        cp (hl)
        jr nz,@+done
        inc hl
        inc de
        or a
        jr nz,@-loop

 @done:

    pop hl
    ret

@txt.dir.size:      defm "<DIR>",0
@txt.image.size:    defm "800K",0
@txt.code:          defm "CODE",0

;-------------------------------------------------------------------------------
@first:     defb 1          ; (the overlay is loaded afresh at each boot)
@entry:     defw 0
@offset:    defw 0
@next:      defw 0
@sam:       defb 0

;-------------------------------------------------------------------------------
@cfg.name:

    ld hl,@txt.cfg
    ld de,@name
    ld bc,@txt.cfg.len
    ldir
    ret

;-------------------------------------------------------------------------------
@goto.saved:

 ; DIR = "..", then DIR = the path in \.samfpga\MODPLAY.CFG, if there is one

    ld hl,@txt.parent
    ld de,@name
    ld bc,3
    ldir
    call @name.args
    rst 8
    defb @hook.set.dir
    ex af,af'
    ret c

    call @cfg.name
    call @open
    ret c
    xor a                   ; its first 255 bytes to the mod page
    ld de,255
    ld c,page.mod
    call ib.read
    rst 8
    defb @hook.close
    ex af,af'
    ret c
    ld hl,0x8000
    call ib.line            ; the path, ended by CR
    inc b
    dec b
    ret z
    ld hl,@line
    ld de,@name
    ld bc,201
    ldir
    call @name.args
    rst 8
    defb @hook.set.dir
    ret

;-------------------------------------------------------------------------------
@save.path:

 ; a FAT folder's path (the first line of its listing) -> \.samfpga\MODPLAY.CFG,
 ; ended by CR. Errors are ignored. Not for the Radio Station's tunes

    ld a,(radio.on)
    ld hl,@sam
    or (hl)
    ret nz

    ld hl,0x8000

    @loop:
        call ib.line
        ret z
        inc b
        dec b
        jr z,@-loop

    ld hl,@line
    ld e,b
    ld d,0
    add hl,de
    ld (hl),13
    inc b
    push bc

    call @cfg.name
    call @name.args
    rst 8
    defb @hook.long.name

    call @uifa.clear        ; CODE, from @line (page 0)
    pop bc
    ld (ix + 0),19
    ld (ix + 32),@line & 0xff
    ld (ix + 33),(@line >> 8) + 0x40
    ld (ix + 35),b
    rst 8
    defb 132                ; save (replaces the old one)
    ret

;===============================================================================
; helpers run at inst.buffer (section B), which page the mod page into
; section C

@ib.source:

    org inst.buffer

ib.cap:

 ; the channel output routine while listing: a = character

    ld e,a
    in a,(port.hmpr)
    ld d,a
    ld a,page.mod
    out (port.hmpr),a
 ib.cap.ptr: equ $+1
    ld hl,0x8000
    ld a,e
    or a
    jr z,@+store            ; (the end always goes in)
    ld a,h
    cp 0xbf
    jr nc,@+full

 @store:
    ld (hl),e
    inc hl
    ld (ib.cap.ptr),hl

 @full:
    ld a,d
    out (port.hmpr),a
    ret

;-------------------------------------------------------------------------------
ib.line:

 ; input:
 ; - hl = a line in the listing (0x8000 on, in the mod page)
 ; output:
 ; - @line = the line (0-terminated, up to 200 characters), b = its length
 ; - hl = the next line; z = no line (the end of the listing)

    in a,(port.hmpr)
    ld c,a
    ld a,page.mod
    out (port.hmpr),a
    ld de,@line
    ld b,0

    @loop:

        ld a,(hl)
        or a
        jr z,@+end          ; (stays on the end)
        inc hl
        cp 13
        jr z,@+eol
        ex af,af'
        ld a,b
        cp 200
        jr nc,@-loop
        ex af,af'
        ld (de),a
        inc de
        inc b
        jr @-loop

 @eol:
    ld a,1
    jr @+done

 @end:
    ld a,b                  ; 0: no line

 @done:
    ex de,hl
    ld (hl),0
    ex de,hl
    ld e,a
    ld a,c
    out (port.hmpr),a
    ld a,e
    or a
    ret

;-------------------------------------------------------------------------------
ib.read:

 ; reads the open file into internal memory: a = pages, de = bytes mod 16K,
 ; c = first page. f' carry = failed

    ld b,a
    in a,(port.hmpr)
    ld (@+hmpr),a
    ld a,c
    out (port.hmpr),a
    ld a,b
    ld hl,0x8000
    rst 8
    defb @hook.read
    di
 @hmpr: equ $+1
    ld a,0
    out (port.hmpr),a
    ret

;-------------------------------------------------------------------------------
ib.xread:

 ; reads the open file into external memory: 16K at a time into the mod page
 ; (unused with external memory), then on to external memory 512 bytes at a
 ; time through the sector buffer. c = first external page, hl = 0x8000.
 ; f' carry = failed

    in a,(port.hmpr)
    ld (@+hmpr),a
    ld a,c
    ld (@+page),a
    ld (@+dest),hl

    @loop.read:

        ld a,page.mod
        out (port.hmpr),a
        ld a,1                      ; 16K
        ld de,0
        ld hl,0x8000
        rst 8
        defb @hook.read
        di                          ; (as the other loaders: the DOS turns them on)
        ex af,af'
        jr c,@+failed
        ex af,af'
        exx
        ld a,c                      ; c':de' = bytes read: 16K or the rest
        exx
        or a
        ld hl,0x4000
        jr nz,@+got
        exx
        push de
        exx
        pop hl
        ld a,h
        or l
        jr z,@+done

     @got:
        ld (@+left),hl
        ld hl,0x8000

        @loop.copy:

         @left: equ $+1
            ld bc,0
            ld a,b
            or c
            jr z,@+copied
            push bc
            ld a,b                  ; 512 at most
            cp 2
            jr c,@+small
            ld bc,512
         @small:
            ex (sp),hl              ; hl = left
            or a
            sbc hl,bc
            ld (@-left),hl
            pop hl                  ; hl = source in the mod page

            ld a,page.mod
            out (port.hmpr),a
            ld de,dos.sector
            push bc
            ldir
            pop bc
            push hl

            ld a,high.memory.external
            out (port.hmpr),a
         @page: equ $+1
            ld a,0
            out (port.xmpr.c),a
            inc a
            out (port.xmpr.d),a
            ld hl,dos.sector
         @dest: equ $+1
            ld de,0
            ldir
            bit 6,d
            jr z,@+same
            res 6,d
            ld a,(@-page)
            inc a
            ld (@-page),a
         @same:
            ld (@-dest),de
            pop hl
            jr @-loop.copy

     @copied:
        exx
        ld a,c                      ; a whole 16K: there may be more
        exx
        or a
        jr nz,@-loop.read

 @done:
    xor a                           ; (f' no carry)
    ex af,af'
    jr @+leave

 @failed:
    ex af,af'

 @leave:
 @hmpr: equ $+1
    ld a,0
    out (port.hmpr),a
    ret

@ib.len: equ $ - inst.buffer

    assert @ib.len <= 0x100         ; (inst.buffer to 0x4fff)

    org @ib.source + @ib.len

;===============================================================================
    assert $ <= mod.overlay.end
