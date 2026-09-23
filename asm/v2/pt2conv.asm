; =============================================================================
; pt2conv.asm -- PT2 import: recognise a ProTracker 2 module and convert it to
; the PT3 the editor works on. Byte for byte the same output as
; tools/pt2conv.py (tools/v2_pt2_test.py compares the two).
;
; PT2 layout (PTxPlay's INITPT2): 0 delay, 1 positions, 2 loop, 3..66 sample
; pointers ([length, loop] + 3-byte lines), 67..98 ornament pointers
; ([length, loop] + bytes), 99..100 pattern table pointer (3 words per
; pattern), 101..130 name, 131.. positions (pattern numbers, $FF ends).
;
; The module is moved to the top of the slot and the PT3 built from
; SLOT_BASE upwards: header (from the new-song template: version '5' and tone
; table 1 are what PTxPlay uses for PT2), positions (pattern*3), pattern
; table, samples (shared pointers stay shared), ornaments (an empty ornament 0
; if PT2 had none), then each pattern decoded with the PT2 grammar into the WP
; and re-encoded canonically (pt3enc). Everything must stay below the module:
; CY set on failure.
;
; Sample lines follow PTxPlay's SamCnv exactly: PT2 b0 bit0 = noise off, bit1
; = tone off, bit2 = tone offset positive, bits 3-7 = noise value; b1 high
; nibble = volume, low nibble + b2 = tone offset. The envelope bit of every
; converted line is "on": in PT2 the envelope is switched per channel by the
; pattern, which the converted patterns still do.
; =============================================================================

; pt2_detect: Z set if the block at SLOT_BASE (length (TAPE_HDR+11)) looks like
; PT2: sane position count/loop, pattern table pointer inside the block after
; the position list, and the list closed by $FF.
pt2_detect:
        ld      hl,(TAPE_HDR+11)
        ld      (pt2_len),hl
        ld      de,140
        or      a
        sbc     hl,de
        jr      c,.no
        ld      a,(SLOT_BASE+1)
        or      a
        jr      z,.no
        ld      b,a                     ; positions
        ld      a,(SLOT_BASE+2)
        cp      b
        jr      nc,.no                  ; loop >= positions
        ld      hl,(SLOT_BASE+99)
        ld      de,(pt2_len)
        or      a
        sbc     hl,de
        jr      nc,.no                  ; table pointer beyond the block
        ld      hl,(SLOT_BASE+99)
        ld      a,b
        add     a,132                   ; 131 + positions + 1
        ld      e,a
        ld      d,0
        jr      nc,.n1
        inc     d
.n1:    or      a
        sbc     hl,de
        jr      c,.no                   ; table pointer inside the position list
        ld      hl,SLOT_BASE+131
        ld      a,b
        add     a,l
        ld      l,a
        jr      nc,.n2
        inc     h
.n2:    ld      a,(hl)
        cp      $FF                     ; Z = PT2
        ret
.no:    or      1
        ret

; pt2_import: the PT2 just loaded at SLOT_BASE ((pt2_len) bytes) -> PT3 at
; SLOT_BASE. Moves the module to the top of the slot first. CY = no room.
pt2_import:
        ld      de,(pt2_len)
        ld      hl,SLOT_END
        or      a
        sbc     hl,de
        ld      (pt2_src),hl            ; destination = SLOT_END - length
        ld      hl,SLOT_BASE
        add     hl,de
        dec     hl                      ; last source byte
        ld      b,d
        ld      c,e
        ld      de,SLOT_END-1
        lddr                            ; (overlap-safe: copies from the end)
        ; fallthrough

; pt2_convert: (pt2_src)/(pt2_len) = the module -> PT3 at SLOT_BASE; sets
; song_len and num_pats. CY = it would not fit below the module.
pt2_convert:
        ; ---- 1. header
        ld      hl,template_pt3
        ld      de,SLOT_BASE
        ld      bc,201
        ldir
        ld      a,'5'
        ld      (SLOT_BASE+13),a        ; 3.5 semantics (PT2 portamento)
        ld      hl,(pt2_src)
        ld      de,101
        add     hl,de
        ld      de,SLOT_BASE+30
        ld      bc,30
        ldir                            ; name -> title
        ld      a,' '
        ld      (de),a
        inc     de
        ld      (de),a
        ld      hl,SLOT_BASE+66
        ld      b,33
.sp:    ld      (hl),a
        inc     hl
        djnz    .sp                     ; author blank
        ld      a,1
        ld      (SLOT_BASE+99),a        ; tone table 1
        ld      hl,(pt2_src)
        ld      a,(hl)
        ld      (SLOT_BASE+H_SPEED),a
        inc     hl
        ld      a,(hl)
        ld      (SLOT_BASE+H_NPOS),a
        inc     hl
        ld      a,(hl)
        ld      (SLOT_BASE+H_LOOP),a
        ; ---- 2. positions * 3, count the patterns
        ld      hl,(pt2_src)
        ld      de,131
        add     hl,de
        ld      de,SLOT_BASE+H_POSLIST
        ld      a,(SLOT_BASE+H_NPOS)
        ld      b,a
        ld      c,0                     ; highest pattern number
.pos:   ld      a,(hl)
        inc     hl
        cp      c
        jr      c,.nm
        ld      c,a
.nm:    push    bc
        ld      b,a
        add     a,a
        add     a,b
        pop     bc
        ld      (de),a
        inc     de
        djnz    .pos
        ld      a,$FF
        ld      (de),a
        inc     de                      ; DE = pattern table
        inc     c
        ld      a,c
        cp      86
        jp      nc,.fail                ; position bytes are pattern*3
        ld      (pt2_npats),a
        ld      (num_pats),a
        ld      h,d
        ld      l,e
        ld      bc,SLOT_BASE
        or      a
        sbc     hl,bc
        ld      (SLOT_BASE+H_PATPTR),hl
        ; ---- 3. an all-zero table, 6 bytes a pattern
        ld      l,a
        ld      h,0
        add     hl,hl
        ld      b,h
        ld      c,l
        add     hl,hl
        add     hl,bc                   ; *6
        ld      b,h
        ld      c,l
        ex      de,hl                   ; HL = table
.zt:    ld      (hl),0
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.zt
        ld      (pt2_out),hl
        ; ---- 4. samples (32 pointers at 3 / 105)
        xor     a
.smp:   ld      (pt2_i),a
        add     a,a
        ld      hl,(pt2_src)
        add     a,3
        ld      e,a
        ld      d,0
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)                  ; DE = PT2 pointer
        ld      a,(pt2_i)
        add     a,a
        ld      hl,SLOT_BASE+H_SMPPTRS
        add     a,l
        ld      l,a
        jr      nc,.s1
        inc     h
.s1:    ld      a,d
        or      e
        jr      nz,.s2
        ld      (hl),a                  ; unused: pointer 0
        inc     hl
        ld      (hl),a
        jr      .snext
.s2:    push    hl                      ; -> PT3 pointer word
        ld      hl,(pt2_src)
        ld      bc,3
        add     hl,bc
        ld      bc,SLOT_BASE+H_SMPPTRS
        ld      a,(pt2_i)
        call    pt2_shared              ; Z: HL = the earlier PT3 word to copy
        jr      nz,.sconv
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        pop     de
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        jr      .snext
.sconv: ld      de,(pt2_tmp)
        ld      hl,(pt2_src)
        add     hl,de                   ; HL -> PT2 sample
        ld      a,(hl)                  ; lines
        ld      c,a
        ld      b,0
        sla     c
        rl      b
        sla     c
        rl      b
        inc     bc
        inc     bc                      ; 2 + 4*lines
        push    hl
        call    pt2_room
        pop     hl
        jp      c,.fail1
        pop     de                      ; PT3 pointer word
        push    hl
        ld      hl,(pt2_out)
        ld      bc,SLOT_BASE
        or      a
        sbc     hl,bc
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        pop     hl
        ld      de,(pt2_out)
        call    pt2_samcnv
        ld      (pt2_out),de
.snext: ld      a,(pt2_i)
        inc     a
        cp      32
        jp      nz,.smp
        ; ---- 5. ornaments (16 pointers at 67 / 169)
        xor     a
.orn:   ld      (pt2_i),a
        add     a,a
        ld      hl,(pt2_src)
        add     a,67
        ld      e,a
        ld      d,0
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      a,(pt2_i)
        add     a,a
        ld      hl,SLOT_BASE+H_ORNPTRS
        add     a,l
        ld      l,a
        jr      nc,.o1
        inc     h
.o1:    ld      a,d
        or      e
        jr      nz,.o2
        ld      a,(pt2_i)
        or      a
        jr      nz,.ozero
        ; PT3 needs an ornament 0: an empty one
        push    hl
        ld      bc,3
        call    pt2_room
        pop     hl
        jp      c,.fail
        push    hl
        ld      hl,(pt2_out)
        ld      (hl),0
        inc     hl
        ld      (hl),1
        inc     hl
        ld      (hl),0
        inc     hl
        ld      (pt2_out),hl
        ld      de,3
        or      a
        sbc     hl,de
        ld      de,SLOT_BASE
        or      a
        sbc     hl,de
        pop     de
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        jr      .onext
.ozero: xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        jr      .onext
.o2:    push    hl
        ld      hl,(pt2_src)
        ld      bc,67
        add     hl,bc
        ld      bc,SLOT_BASE+H_ORNPTRS
        ld      a,(pt2_i)
        call    pt2_shared
        jr      nz,.oconv
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        pop     de
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        jr      .onext
.oconv: ld      de,(pt2_tmp)
        ld      hl,(pt2_src)
        add     hl,de                   ; HL -> PT2 ornament
        ld      c,(hl)
        ld      b,0
        inc     bc
        inc     bc                      ; 2 + lines
        push    hl
        call    pt2_room
        pop     hl
        jp      c,.fail1
        pop     de
        push    hl
        ld      hl,(pt2_out)
        ld      bc,SLOT_BASE
        or      a
        sbc     hl,bc
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        pop     hl
        ld      de,(pt2_out)
        call    pt2_orncnv
        ld      (pt2_out),de
.onext: ld      a,(pt2_i)
        inc     a
        cp      16
        jp      nz,.orn
        ; ---- 6. patterns: PT2 streams -> WP -> canonical PT3 streams
        xor     a
.pat:   ld      (pt2_i),a
        ld      hl,(pt2_src)
        ld      de,99
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,(pt2_src)
        add     hl,de                   ; HL = PT2 pattern table
        ld      a,(pt2_i)
        ld      e,a
        ld      d,0
        add     hl,de
        add     hl,de
        add     hl,de
        add     hl,de
        add     hl,de
        add     hl,de                   ; + pattern*6
        ld      de,(pt2_src)
        ld      a,1
        ld      (dec_fmt),a
        call    dec_pattern_hl
        xor     a
        ld      (dec_fmt),a
        call    enc_pattern
        jp      c,.fail
        ld      bc,(enc_total)
        call    pt2_room
        jp      c,.fail
        ; table entry for this pattern
        ld      hl,(SLOT_BASE+H_PATPTR)
        ld      de,SLOT_BASE
        add     hl,de
        ld      a,(pt2_i)
        ld      e,a
        ld      d,0
        add     hl,de
        add     hl,de
        add     hl,de
        add     hl,de
        add     hl,de
        add     hl,de
        ld      (pt2_tmp),hl            ; -> 3 words
        ld      ix,enc_off
        ld      b,3
.ch:    push    bc
        ld      hl,(pt2_out)
        ld      de,SLOT_BASE
        or      a
        sbc     hl,de
        ex      de,hl                   ; DE = offset
        ld      hl,(pt2_tmp)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      (pt2_tmp),hl
        ld      l,(ix+0)
        ld      h,(ix+1)                ; stream in STAGE
        ld      c,(ix+6)
        ld      b,(ix+7)                ; its length
        ld      de,(pt2_out)
        ld      a,b
        or      c
        jr      z,.empty
        ldir
.empty: ld      (pt2_out),de
        inc     ix
        inc     ix
        pop     bc
        djnz    .ch
        ld      a,(pt2_i)
        inc     a
        ld      hl,pt2_npats
        cp      (hl)
        jp      nz,.pat
        ; ---- 7. done
        ld      hl,(pt2_out)
        ld      de,SLOT_BASE
        or      a
        sbc     hl,de
        ld      (song_len),hl
        or      a
        ret
.fail1: pop     hl                      ; (a pointer-word address was still pushed)
.fail:  xor     a
        ld      (dec_fmt),a
        scf
        ret

; pt2_shared: HL -> PT2 pointer table, BC -> PT3 pointer table, A = index,
; DE = this entry's PT2 pointer. Z set if an earlier entry has the same PT2
; pointer, with HL -> that entry's PT3 word.
pt2_shared:
        ld      (pt2_tmp),de            ; (the search clobbers DE: callers reload it from here)
        or      a
        jr      z,.none
        push    bc
        ld      b,a                     ; entries to look at
.l:     ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ex      (sp),hl                 ; HL = PT3 word, stack = PT2 pointer position
        push    hl
        ld      hl,(pt2_tmp)
        or      a
        sbc     hl,de
        pop     hl
        jr      z,.hit
        inc     hl
        inc     hl
        ex      (sp),hl
        djnz    .l
        pop     bc
.none:  or      1
        ret
.hit:   pop     de                      ; drop the PT2 position; HL = PT3 word
        xor     a
        ret

; pt2_room: BC = bytes wanted at (pt2_out) -> CY if they would reach the module
pt2_room:
        ld      hl,(pt2_src)
        ld      de,(pt2_out)
        or      a
        sbc     hl,de                   ; free
        sbc     hl,bc
        ret

; pt2_samcnv: HL -> PT2 sample ([length, loop] + 3-byte lines), DE -> output.
; Leaves DE past the output.
pt2_samcnv:
        ld      a,(hl)
        inc     hl
        ld      c,(hl)
        inc     hl
        ex      de,hl
        ld      (hl),c                  ; loop
        inc     hl
        ld      (hl),a                  ; length
        inc     hl
        ex      de,hl
        or      a
        ret     z
        ld      b,a
.line:  push    bc
        ld      c,(hl)                  ; b0
        inc     hl
        ld      b,(hl)                  ; b1
        inc     hl
        ld      a,c
        bit     0,c
        jr      nz,.z0
        rra
        rra
        and     $3E                     ; noise value -> PT3 Ns bits (envelope bit 0 = on)
        jr      .w0
.z0:    xor     a
.w0:    ld      (de),a
        inc     de
        ld      a,b
        rra
        rra
        rra
        rra
        and     $0F                     ; volume
        bit     0,c
        jr      z,.n7
        or      $80                     ; noise off
.n7:    bit     1,c
        jr      z,.n4
        or      $10                     ; tone off
.n4:    ld      (de),a
        inc     de
        ld      a,b
        and     $0F
        ld      b,a                     ; B = tone hi
        ld      a,(hl)                  ; A = tone lo
        inc     hl
        bit     2,c
        jr      nz,.pos
        ld      c,a
        xor     a
        sub     c
        ld      c,a                     ; -lo
        sbc     a,a
        sub     b
        ld      b,a                     ; -hi - borrow
        ld      a,c
.pos:   ld      (de),a
        inc     de
        ld      a,b
        ld      (de),a
        inc     de
        pop     bc
        djnz    .line
        ret

; pt2_orncnv: HL -> PT2 ornament ([length, loop] + bytes), DE -> output
pt2_orncnv:
        ld      a,(hl)
        inc     hl
        ld      c,(hl)
        inc     hl
        ex      de,hl
        ld      (hl),c
        inc     hl
        ld      (hl),a
        inc     hl
        ex      de,hl
        or      a
        ret     z
        ld      c,a
        ld      b,0
        ldir
        ret

; ---------------------------------------------------------------------------
; dec_event_pt2: the PT2 event grammar, entered from dec_event after its
; prologue (IY = cell, BC = stream, IX = channel state, (dec_glob) = row
; globals). Exits through dec_event's .fin.
; ---------------------------------------------------------------------------
dec_event_pt2:
.lp:    ld      a,(bc)
        inc     bc
        cp      $E1
        jr      nc,.sam
        cp      $E0
        jr      z,.rel
        cp      $80
        jr      nc,.note
        cp      $7F
        jr      z,.eoff
        cp      $71
        jr      nc,.env
        cp      $70
        jr      z,.empty
        cp      $60
        jr      nc,.orn
        cp      $20
        jr      nc,.skip
        cp      $10
        jr      nc,.vol
        cp      $0F
        jp      z,.delay
        cp      $0E
        jp      z,.glis
        cp      $0D
        jp      z,.port
        cp      $0C
        jr      z,.lp                   ; stop slide: no PT3 form
        ld      a,(bc)                  ; 00..0B: noise value follows
        inc     bc
        and     $1F
        ld      hl,(dec_glob)
        inc     hl
        inc     hl
        ld      (hl),a
        jr      .lp
.sam:   sub     $E0
        call    cell_set_sample
        jr      .lp
.rel:   ld      (iy+0),NOTE_REST
        jp      dec_event.fin
.note:  sub     $80
        ld      (iy+0),a
        jp      dec_event.fin
.empty: ld      a,(iy+0)
        cp      NOTE_NONE
        jr      nz,.e2
        ld      (iy+0),NOTE_EMPTY
.e2:    jp      dec_event.fin
.eoff:  ld      a,ENV_OFF
        call    cell_set_env
        jr      .lp
.env:   sub     $70
        call    cell_set_env
        ld      hl,(dec_glob)
        inc     hl
        ld      a,(bc)                  ; PT2: period lo, hi
        inc     bc
        ld      (hl),a                  ; row globals keep hi at +0, lo at +1
        dec     hl
        ld      a,(bc)
        inc     bc
        ld      (hl),a
        jp      .lp
.orn:   sub     $60
        call    cell_set_orn
        jp      .lp
.skip:  sub     $20-1                   ; n+1 rows to the next event
        ld      (ix+2),a
        jp      .lp
.vol:   sub     $10
        jr      nz,.v1
        inc     a                       ; PT3 has no volume 0: use 1
        ld      hl,dec_warn
        set     4,(hl)
.v1:    rlca
        rlca
        rlca
        rlca
        ld      e,a
        ld      a,(iy+3)
        and     $0F
        or      e
        ld      (iy+3),a
        jp      .lp
.delay: ld      a,9
        call    .cmd
        ld      a,(bc)
        inc     bc
        ld      (iy+4),a
        jp      .lp
.glis:  ld      a,1
        call    .cmd
        ld      (iy+4),1
        ld      a,(bc)
        inc     bc
        ld      (iy+5),a
        add     a,a
        sbc     a,a                     ; sign-extend the step
        ld      (iy+6),a
        jp      .lp
.port:  ld      a,2
        call    .cmd
        ld      (iy+4),1
        ld      a,(bc)
        inc     bc
        ld      (iy+5),a
        ld      (iy+6),0
        inc     bc
        inc     bc                      ; precalculated delta: ignored
        jp      .lp
.cmd:   ld      e,a                     ; A = command -> nibble set, params cleared
        ld      a,(iy+3)
        and     $F0
        or      e
        ld      (iy+3),a
        xor     a
        ld      (iy+4),a
        ld      (iy+5),a
        ld      (iy+6),a
        ret
