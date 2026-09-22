; =============================================================================
; pt3dec.asm -- PT3 pattern decoder (PTxPlay PD_LP2 grammar) -> working pattern
;
; Reference implementation: tools/pt3codec.py (decode_pattern / decode_event).
; The Z80 decoder must produce a byte-identical WP buffer; the test harness
; (tools/v2_codec_test.py) checks that against every bundled song.
;
; Channel state block (5 bytes), pointed to by IX:
;   +0/+1 stream pointer   +2 skip (NNtSkp)   +3 count (NtSkCn)   +4 ended
;
; dec_warn bits: 0 = a channel set skip 0 (stalls), 1 = B/C ended before A,
;                2 = >1 command on one event, 3 = explicit sample 0
; =============================================================================

; ---- dec_pattern: A = pattern index -> WP filled, wp_len set ---------------
dec_pattern:
        push    af
        call    wp_blank
        xor     a
        ld      (dec_warn),a
        pop     af
        call    pat_entry_addr          ; HL -> 6-byte table entry
        ld      ix,dec_ch
        ld      b,3
.init:  ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        push    hl
        ld      hl,SLOT_BASE
        add     hl,de
        ld      (ix+0),l
        ld      (ix+1),h
        ld      (ix+2),0                ; skip = 0 (PTxPlay INIT zeroes NNtSkp)
        ld      (ix+3),1                ; count = 1 (row 0 decodes)
        ld      (ix+4),0
        pop     hl
        ld      de,5
        add     ix,de
        djnz    .init
        xor     a
        ld      (dec_row),a
        ld      a,WP_ROWS
        ld      (wp_len),a
        ld      hl,WP_BASE
        ld      (dec_rowptr),hl
.row:
        ; ---- channel A decides the pattern length
        ld      ix,dec_ch
        ld      a,(ix+4)
        or      a
        jr      nz,.chb
        dec     (ix+3)
        jr      nz,.chb
        ld      hl,(dec_rowptr)
        ld      d,h
        ld      e,l                     ; DE = row globals
        inc     hl
        inc     hl
        inc     hl                      ; HL = cell A
        call    dec_event
        jr      nc,.a_ok
        ld      a,(dec_row)
        ld      (wp_len),a              ; 0x00 -> pattern ends at this row
        jr      .done
.a_ok:  call    dec_reload
.chb:   ld      ix,dec_ch+5
        ld      bc,3+WP_CELLSZ
        call    dec_side
        ld      ix,dec_ch+10
        ld      bc,3+2*WP_CELLSZ
        call    dec_side
        ld      hl,(dec_rowptr)
        ld      de,WP_ROWSZ
        add     hl,de
        ld      (dec_rowptr),hl
        ld      hl,dec_row
        inc     (hl)
        ld      a,(hl)
        cp      WP_ROWS
        jr      nz,.row
.done:
        ; blank rows >= wp_len (B/C may have written cells past A's end)
        ld      a,(wp_len)
        cp      WP_ROWS
        ret     z
        ld      b,a
        call    wp_row_addr             ; HL = first row past the end
        ld      a,WP_ROWS
        sub     b
        ld      b,a
.bl:    push    bc
        call    wp_blank_row
        pop     bc
        djnz    .bl
        ret

; dec_reload: count = skip; skip 0 stalls the channel (PTxPlay would wait 256 rows)
dec_reload:
        ld      a,(ix+2)
        ld      (ix+3),a
        or      a
        ret     nz
        ld      (ix+4),1
        ld      hl,dec_warn
        set     0,(hl)
        ret

; dec_side: IX = channel state (B or C), BC = cell offset within the row
dec_side:
        ld      a,(ix+4)
        or      a
        ret     nz
        dec     (ix+3)
        ret     nz
        ld      hl,(dec_rowptr)
        ld      d,h
        ld      e,l
        add     hl,bc
        call    dec_event
        jr      nc,dec_reload
        ld      (ix+4),1                ; ended before channel A
        ld      hl,dec_warn
        set     1,(hl)
        ret

; ---- dec_event -------------------------------------------------------------
; IX = channel state, HL = cell (7 bytes, pre-blanked), DE = row globals.
; Parses one event through its terminator and any command parameters.
; Returns CY set if the stream ended (0x00). Preserves IX, HL, DE.
dec_event:
        push    iy                      ; the ROM ISR needs IY=$5C3A: restore it on exit
        push    hl
        push    de
        ld      (dec_glob),de
        push    hl
        pop     iy                      ; IY = cell
        ld      c,(ix+0)
        ld      b,(ix+1)                ; BC = stream pointer
        xor     a
        ld      (dec_ncmd),a
.loop:
        ld      a,(bc)
        inc     bc
        or      a
        jp      z,.end
        cp      $F0
        jr      nc,.orsm
        cp      $D0
        jp      z,.empty
        jr      nc,.sample
        cp      $C0
        jp      z,.rel
        jr      nc,.vol
        cp      $B0
        jr      z,.eoff
        cp      $B1
        jr      z,.skip
        jr      nc,.envshape
        cp      $50
        jp      nc,.note
        cp      $40
        jr      nc,.orn
        cp      $20
        jr      nc,.noise
        cp      $10
        jr      nc,.esam
        ; 01..0F: special command -- remember it, parameters follow the terminator
        ld      hl,dec_ncmd
        ld      e,(hl)
        inc     (hl)
        ld      d,0
        ld      hl,dec_cmds
        add     hl,de
        ld      (hl),a
        jr      .loop

.orsm:  sub     $F0
        call    cell_set_orn
        ld      a,ENV_OFF
        call    cell_set_env
        jr      .sample_byte
.esam:  sub     $10
        jr      z,.esam_off
        call    cell_set_env
        call    read_envper
        jr      .sample_byte
.esam_off:
        ld      a,ENV_OFF
        call    cell_set_env
.sample_byte:
        ld      a,(bc)
        inc     bc
        srl     a
        call    cell_set_sample
        jr      .loop
.sample: sub    $D0
        call    cell_set_sample
        jr      .loop
.vol:   sub     $C0
        rlca
        rlca
        rlca
        rlca
        ld      e,a
        ld      a,(iy+3)
        and     $0F
        or      e
        ld      (iy+3),a
        jr      .loop
.eoff:  ld      a,ENV_OFF
        call    cell_set_env
        jp      .loop
.skip:  ld      a,(bc)
        inc     bc
        ld      (ix+2),a
        jp      .loop
.envshape:
        sub     $B1
        call    cell_set_env
        call    read_envper
        jp      .loop
.orn:   sub     $40
        call    cell_set_orn
        jp      .loop
.noise: sub     $20
        ld      hl,(dec_glob)
        inc     hl
        inc     hl
        ld      (hl),a
        jp      .loop

.note:  sub     $50
        ld      (iy+0),a
        jr      .term
.rel:   ld      (iy+0),NOTE_REST
        jr      .term
.empty: ld      (iy+0),NOTE_EMPTY
.term:
        ; command parameters: the LAST listed command runs first and owns the cell
        ld      a,(dec_ncmd)
        or      a
        jr      z,.fin
        cp      2
        jr      c,.one
        ld      hl,dec_warn
        set     2,(hl)
.one:   ld      d,a                     ; D = commands left to process
        ld      hl,dec_cmds
        dec     a
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)                  ; owner = last listed
        call    cmd_owner_params
.more:  dec     d
        jr      z,.fin
        dec     hl
        ld      a,(hl)
        call    cmd_skip_params
        jr      .more

.fin:   ld      (ix+0),c
        ld      (ix+1),b
        pop     de
        pop     hl
        pop     iy
        or      a                       ; CY clear
        ret
.end:   ld      (ix+0),c
        ld      (ix+1),b
        pop     de
        pop     hl
        pop     iy
        scf
        ret

; read_envper: (BC) hi, lo -> row globals +0,+1
read_envper:
        ld      hl,(dec_glob)
        ld      a,(bc)
        inc     bc
        ld      (hl),a
        inc     hl
        ld      a,(bc)
        inc     bc
        ld      (hl),a
        ret

; cmd_owner_params: A = cmd byte, IY = cell, BC = stream. Stores the cmd nibble
; and copies its parameters into p0..p2 (portamento: delay, step lo, step hi).
; Preserves HL, D.
cmd_owner_params:
        push    hl
        push    de
        ld      e,a
        ld      a,(iy+3)
        and     $F0
        or      e
        ld      (iy+3),a
        ld      a,e
        cp      2
        jr      z,.portm
        call    param_count_of          ; A = 0..3
        or      a
        jr      z,.done
        push    iy
        pop     hl
        inc     hl
        inc     hl
        inc     hl
        inc     hl                      ; HL -> p0
        ld      e,a
.cp:    ld      a,(bc)
        inc     bc
        ld      (hl),a
        inc     hl
        dec     e
        jr      nz,.cp
        jr      .done
.portm: ld      a,(bc)
        inc     bc
        ld      (iy+4),a                ; delay
        inc     bc
        inc     bc                      ; precalculated delta (ignored, regenerated as 0)
        ld      a,(bc)
        inc     bc
        ld      (iy+5),a                ; step lo
        ld      a,(bc)
        inc     bc
        ld      (iy+6),a                ; step hi
.done:  pop     de
        pop     hl
        ret

; cmd_skip_params: A = cmd byte -> BC += parameter count. Preserves HL, D.
cmd_skip_params:
        call    param_count_of
        add     a,c
        ld      c,a
        ret     nc
        inc     b
        ret

; param_count_of: A = cmd 0..15 -> A = raw parameter byte count (cmd 2 = 5)
param_count_of:
        push    hl
        and     $0F
        ld      hl,param_count
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)
        pop     hl
        ret

param_count:
        db      0,3,5,1,1,2,0,0,3,1,0,0,0,0,0,0

; ---- cell setters (IY = cell, A = value) -----------------------------------
cell_set_orn:                           ; A = 0..15
        ld      e,a
        ld      a,(iy+2)
        and     $F0
        or      e
        ld      (iy+2),a
        set     5,(iy+1)
        ret
cell_set_env:                           ; A = 1..15
        rlca
        rlca
        rlca
        rlca
        and     $F0
        ld      e,a
        ld      a,(iy+2)
        and     $0F
        or      e
        ld      (iy+2),a
        ret
cell_set_sample:                        ; A = 0..31 (0 is flagged)
        and     $1F
        jr      nz,.ok
        ld      hl,dec_warn
        set     3,(hl)
.ok:    ld      e,a
        ld      a,(iy+1)
        and     $E0
        or      e
        ld      (iy+1),a
        ret

; ---- pattern table helper --------------------------------------------------
; pat_entry_addr: A = pattern -> HL = SLOT_BASE + pattable + A*6
pat_entry_addr:
        ld      l,a
        ld      h,0
        add     hl,hl
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,de                   ; *6
        ld      de,(SLOT_BASE+H_PATPTR)
        add     hl,de
        ld      de,SLOT_BASE
        add     hl,de
        ret

; ---- working pattern blanking ----------------------------------------------
wp_blank:
        ld      hl,WP_BASE
        ld      b,WP_ROWS
.l:     push    bc
        call    wp_blank_row
        pop     bc
        djnz    .l
        ret

; wp_blank_row: HL -> row; blanks it; HL advances to the next row
wp_blank_row:
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),NZ_NONE
        inc     hl
        ld      b,3
.c:     ld      (hl),NOTE_NONE
        inc     hl
        push    bc
        ld      b,6
.z:     ld      (hl),a
        inc     hl
        djnz    .z
        pop     bc
        djnz    .c
        ret

; ---- skip-decode (no store): used to measure stream extents -----------------
; stream_end: HL = stream start address -> HL = address just past its 0x00.
; Stops early at (stream_limit) to survive malformed data. Preserves dec_warn.
stream_end:
        ld      a,(dec_warn)
        push    af
        ld      (dec_tmp+0),hl
        ld      ix,dec_tmp
        ld      (ix+2),0
        ld      (ix+3),1
        ld      (ix+4),0
.ev:    ld      hl,SCRATCH_ROW+3
        ld      de,SCRATCH_ROW
        call    dec_event
        jr      c,.done
        ld      hl,(dec_tmp+0)
        ld      de,(stream_limit)
        or      a
        sbc     hl,de
        jr      c,.ev
        ld      hl,(stream_limit)
        jr      .out
.done:  ld      hl,(dec_tmp+0)
.out:   pop     af
        ld      (dec_warn),a
        ret
