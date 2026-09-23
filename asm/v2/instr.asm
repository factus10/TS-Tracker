; =============================================================================
; instr.asm -- the sample (SYM+E) and ornament (SYM+R) editors
;
; Both instrument kinds share one on-tape shape: [loop, length] + `length`
; lines (4 bytes per sample line, one signed byte per ornament line), reached
; through a pointer word in the header (32 sample words at 105, 16 ornament
; words at 169; 0 = no block). The editor works directly on the block in the
; slot: a missing block is created (appended at the end of the song), a block
; shared with another instrument is forked to a private copy before the first
; edit, and length changes / line insert / line delete are slot splices
; (slot_insert / slot_delete fix every pointer in the song).
;
; Sample line bits (PTxPlay CHREGS): b0 bit0 = envelope OFF, bits1-5 = noise
; or envelope offset (signed 5-bit; goes to the envelope when noise is off),
; bit6 = amplitude slide up (else down), bit7 = amplitude slide on; b1 bits0-3
; = volume, bit4 = tone OFF, bit5 = accumulate the Ns offset, bit6 = accumulate
; the tone offset, bit7 = noise OFF; b2,b3 = signed tone offset.
;
; Screen: row 0 title (kind, number, Len/Rep), row 1 menu strip, row 2 column
; header, rows 3-18 sixteen lines (paged), rows 22/23 hints. Fields on a
; sample line: T N E, tone (+dddd), ^, Ns (+dd), ^, volume, amplitude slide.
; SPACE toggles the flag / sign under the cursor, digits type numbers (rolling
; in from the right), CAPS+0 zeroes a number, ENTER plays the instrument for as
; long as it is held (C of the current octave).
; =============================================================================

SE_ROW0     EQU 3
SE_ROWS     EQU 16
SE_MAXLEN   EQU 64

cmd_sample:
        xor     a
        jr      se_start
cmd_ornament:
        ld      a,1
se_start:
        ld      (se_kind),a
        or      a
        ld      a,(se_sel_smp)
        jr      z,.s
        ld      a,(se_sel_orn)
.s:     ld      (se_sel),a
        call    se_home
se_redraw_loop:
        call    se_draw_all
se_loop:
        halt
        call    kb_scan
        call    kb_caps
        jp      nz,se_caps
        call    kb_letter_edge
        or      a
        jr      z,se_loop
        cp      13
        jp      z,se_preview
        cp      'Q'
        jp      z,se_leave
        cp      'O'
        jr      z,se_prev
        cp      'P'
        jr      z,se_next
        cp      'L'
        jp      z,se_len_prompt
        cp      'R'
        jp      z,se_rep_prompt
        cp      'I'
        jp      z,se_ins_line
        cp      'X'
        jp      z,se_del_line
        cp      32
        jp      z,se_space
        call    hex_value               ; '0'-'9','A'-'F' -> 0..15, CY otherwise
        jr      c,se_loop
        jp      se_digit

se_home:
        xor     a
        ld      (se_line),a
        ld      (se_field),a
        ld      (se_top),a
        ret

se_prev:
        ld      hl,se_sel
        ld      a,(hl)
        cp      2
        jr      c,se_loop
        dec     (hl)
        jr      se_resel
se_next:
        call    se_maxsel
        ld      hl,se_sel
        cp      (hl)
        jr      z,se_loop
        inc     (hl)
se_resel:
        call    se_home
        jr      se_redraw_loop

se_maxsel:                              ; A = highest instrument number of this kind
        ld      a,(se_kind)
        or      a
        ld      a,31
        ret     z
        ld      a,15
        ret

se_leave:
        call    kb_wait_none
        ld      a,(se_sel)
        ld      hl,se_kind
        bit     0,(hl)
        jr      nz,.o
        ld      (se_sel_smp),a
        ld      a,(se_len)              ; the sample just edited becomes the one notes use
        or      a
        jr      z,.x
        ld      a,(se_sel)
        ld      (cur_sample),a
        jr      .x
.o:     ld      (se_sel_orn),a
.x:     call    update_free
        call    redraw_all
        jp      editor_loop

; ---------------------------------------------------------------------------
; CAPS + key: 5/8 field, 7/6 line, 0 = zero the number under the cursor
; ---------------------------------------------------------------------------
se_caps:
        ld      a,(kb_edge+KR_12345)
        bit     4,a                     ; 5 = field left
        call    nz,se_fleft
        ld      a,(kb_edge+KR_09876)
        bit     2,a                     ; 8 = field right
        call    nz,se_fright
        ld      a,(kb_edge+KR_09876)
        bit     3,a                     ; 7 = line up
        call    nz,se_up
        ld      a,(kb_edge+KR_09876)
        bit     4,a                     ; 6 = line down
        call    nz,se_down
        ld      a,(kb_edge+KR_09876)
        bit     0,a                     ; 0 = DELETE
        call    nz,se_zero
        jp      se_loop

se_fleft:
        ld      hl,se_field
        ld      a,(hl)
        or      a
        ret     z
        dec     (hl)
        jp      se_draw_all
se_fright:
        ld      a,(se_kind)
        or      a
        ret     nz                      ; ornaments: one field
        ld      hl,se_field
        ld      a,(hl)
        cp      8
        ret     nc
        inc     (hl)
        jp      se_draw_all
se_up:
        ld      hl,se_line
        ld      a,(hl)
        or      a
        ret     z
        dec     (hl)
        jp      se_draw_all
se_down:
        ld      a,(se_line)
        inc     a
        ld      hl,se_len
        cp      (hl)
        ret     nc
        ld      (se_line),a
        jp      se_draw_all

; se_zero: CAPS+0 -> the number under the cursor becomes 0
se_zero:
        call    se_refresh
        ld      a,(se_len)
        or      a
        ret     z
        call    se_ensure
        ret     c
        call    se_cur_addr
        ld      a,(se_kind)
        or      a
        jr      nz,.orn
        ld      a,(se_field)
        cp      3
        jr      z,.tone
        cp      5
        jr      z,.ns
        cp      7
        ret     nz
        inc     hl
        ld      a,(hl)
        and     $F0
        ld      (hl),a
        jp      se_draw_all
.ns:    ld      a,(hl)
        and     $C1
        ld      (hl),a
        jp      se_draw_all
.tone:  inc     hl
        inc     hl
        ld      (hl),0
        inc     hl
.orn:   ld      (hl),0
        jp      se_draw_all

; ---------------------------------------------------------------------------
; Block access
; ---------------------------------------------------------------------------
; se_tbl: HL -> this instrument's pointer word in the header
se_tbl:
        ld      a,(se_kind)
        or      a
        ld      hl,SLOT_BASE+H_SMPPTRS
        jr      z,.k
        ld      hl,SLOT_BASE+H_ORNPTRS
.k:     ld      a,(se_sel)
        add     a,a
        add     a,l
        ld      l,a
        ret     nc
        inc     h
        ret

; se_lsz: A = bytes per line
se_lsz:
        ld      a,(se_kind)
        or      a
        ld      a,4
        ret     z
        ld      a,1
        ret

; se_lines_bytes: A = lines -> BC = bytes
se_lines_bytes:
        ld      c,a
        ld      b,0
        ld      a,(se_kind)
        or      a
        ret     nz
        sla     c
        rl      b
        sla     c
        rl      b
        ret

; se_refresh: se_blk (0 = none), se_len, se_loop from the slot
se_refresh:
        call    se_tbl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,0
        ld      a,d
        or      e
        jr      z,.none
        ld      hl,SLOT_BASE
        add     hl,de
        ld      (se_blk),hl
        ld      a,(hl)
        ld      (se_rep),a
        inc     hl
        ld      a,(hl)
        ld      (se_len),a
        ret
.none:  ld      (se_blk),hl
        xor     a
        ld      (se_len),a
        ld      (se_rep),a
        ret

; se_line_addr: A = line -> HL = address of its first byte (block must exist)
se_line_addr:
        call    se_lines_bytes
        ld      hl,(se_blk)
        inc     hl
        inc     hl
        add     hl,bc
        ret
se_cur_addr:
        ld      a,(se_line)
        jr      se_line_addr

; se_append: BC = block size -> a block appended at the end of the song, this
; instrument's pointer set to it. HL = new block. CY set = no room.
se_append:
        call    set_modified
        ld      hl,(song_len)
        ld      de,SLOT_BASE
        add     hl,de
        push    hl
        call    slot_insert
        pop     hl
        ret     c
        push    hl
        ld      de,SLOT_BASE
        or      a
        sbc     hl,de
        ex      de,hl                   ; DE = offset
        call    se_tbl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        pop     hl
        or      a
        ret

; se_ensure: make sure this instrument has a block of its own: create a
; one-line block if there is none, fork a copy if the block is shared with
; another instrument of the same kind. CY set = no room.
se_ensure:
        call    set_modified
        call    se_refresh
        ld      hl,(se_blk)
        ld      a,h
        or      l
        jr      z,.create
        call    se_tbl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)                  ; DE = our offset
        ld      a,(se_kind)
        or      a
        ld      hl,SLOT_BASE+H_SMPPTRS
        ld      b,32
        jr      z,.scan
        ld      hl,SLOT_BASE+H_ORNPTRS
        ld      b,16
.scan:  ld      c,0
.s1:    ld      a,(se_sel)
        cp      c
        jr      z,.skip
        ld      a,(hl)
        cp      e
        jr      nz,.skip
        inc     hl
        ld      a,(hl)
        dec     hl
        cp      d
        jr      z,.copy
.skip:  inc     hl
        inc     hl
        inc     c
        djnz    .s1
        or      a
        ret
.copy:  ld      hl,(se_blk)
        push    hl                      ; old block
        ld      a,(se_len)
        call    se_lines_bytes
        inc     bc
        inc     bc
        push    bc
        call    se_append
        pop     bc
        pop     de
        ret     c
        ex      de,hl                   ; HL = old, DE = new
        ldir
        call    se_refresh
        or      a
        ret
.create:
        call    se_lsz
        add     a,2
        ld      c,a
        ld      b,0
        call    se_append
        ret     c
        ld      (hl),0                  ; loop
        inc     hl
        ld      (hl),1                  ; one line
        inc     hl
        call    se_lsz
        ld      b,a
.z:     ld      (hl),0
        inc     hl
        djnz    .z
        call    se_refresh
        or      a
        ret

; se_resize: A = new length (1..64). Creates the block if needed, else grows /
; shrinks it in place (a splice at the block end). CY set = no room.
se_resize:
        ld      (se_tmp),a
        call    se_refresh
        ld      hl,(se_blk)
        ld      a,h
        or      l
        jr      nz,.have
        ; no block yet: create one of the requested length
        ld      a,(se_tmp)
        call    se_lines_bytes
        inc     bc
        inc     bc
        push    bc
        call    se_append
        pop     bc
        ret     c
        push    hl
        ld      (hl),0                  ; loop 0, then zero the rest
        ld      d,h
        ld      e,l
        inc     de
        dec     bc
        ldir
        pop     hl
        inc     hl
        ld      a,(se_tmp)
        ld      (hl),a
        jr      .done
.have:  call    se_ensure
        ret     c
        ld      a,(se_len)
        ld      hl,se_tmp
        cp      (hl)
        jr      z,.done
        jr      c,.grow
        ; shrink: drop old-new lines at line `new` (address first: se_line_addr uses BC)
        ld      a,(se_tmp)
        call    se_line_addr
        ld      a,(se_tmp)
        ld      c,a
        ld      a,(se_len)
        sub     c
        call    se_lines_bytes
        call    slot_delete
        jr      .setlen
.grow:  ld      a,(se_len)
        call    se_line_addr            ; HL = old block end
        ld      a,(se_len)
        ld      c,a
        ld      a,(se_tmp)
        sub     c                       ; new-old lines
        call    se_lines_bytes
        push    hl
        push    bc
        call    slot_insert
        pop     bc
        pop     hl
        ret     c
        ld      (hl),0                  ; zero the new lines
        ld      d,h
        ld      e,l
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      z,.setlen
        ldir
.setlen:
        ld      hl,(se_blk)
        inc     hl
        ld      a,(se_tmp)
        ld      (hl),a
        dec     hl
        dec     a
        cp      (hl)                    ; loop must stay < length
        jr      nc,.done
        ld      (hl),a
.done:  call    se_refresh
        ld      a,(se_line)
        ld      hl,se_len
        cp      (hl)
        jr      c,.ok
        ld      a,(hl)
        dec     a
        ld      (se_line),a
.ok:    or      a
        ret

; ---------------------------------------------------------------------------
; Commands
; ---------------------------------------------------------------------------
se_noroom:
        ld      hl,s_msg_noroom
        call    flash_message
        jp      se_redraw_loop

; I: insert an empty line before the cursor line (the loop marker keeps its line)
se_ins_line:
        call    se_ensure
        jr      c,se_noroom
        ld      a,(se_len)
        cp      SE_MAXLEN
        jp      nc,se_loop
        call    se_lsz
        ld      c,a
        ld      b,0
        push    bc
        call    se_cur_addr
        pop     bc
        push    bc
        push    hl
        call    slot_insert
        pop     hl
        pop     bc
        jr      c,se_noroom
.z:     ld      (hl),0
        inc     hl
        dec     c
        jr      nz,.z
        ld      hl,(se_blk)
        inc     hl
        inc     (hl)                    ; length
        dec     hl
        ld      a,(hl)                  ; loop
        ld      c,a
        ld      a,(se_line)
        cp      c
        jr      z,.bump
        jr      nc,.nb
.bump:  inc     (hl)
.nb:    jp      se_redraw_loop

; X: delete the cursor line (a block keeps at least one line)
se_del_line:
        call    se_refresh
        ld      a,(se_len)
        cp      2
        jp      c,se_loop
        call    se_ensure
        jr      c,se_noroom
        call    se_cur_addr
        call    se_lsz
        ld      c,a
        ld      b,0
        call    slot_delete
        ld      hl,(se_blk)
        inc     hl
        dec     (hl)                    ; length
        ld      c,(hl)                  ; C = new length
        dec     hl
        ld      a,(se_line)
        cp      (hl)                    ; loop above the cursor moves up
        jr      nc,.nl
        dec     (hl)
.nl:    ld      a,(hl)
        cp      c
        jr      c,.lok
        ld      a,c
        dec     a
        ld      (hl),a
.lok:   ld      a,(se_line)
        cp      c
        jr      c,.cok
        ld      a,c
        dec     a
        ld      (se_line),a
.cok:   jp      se_redraw_loop

; L: length prompt (1-64) -> resize
se_len_prompt:
        call    se_refresh
        ld      a,(se_len)
        ld      hl,s_msg_selen
        call    se_prompt2
        jp      c,se_redraw_loop
        or      a
        jp      z,se_redraw_loop
        cp      SE_MAXLEN+1
        jp      nc,se_redraw_loop
        call    se_resize
        jp      c,se_noroom
        jp      se_redraw_loop

; R: repeat (loop) line prompt (0..length-1)
se_rep_prompt:
        call    se_refresh
        ld      a,(se_len)
        or      a
        jp      z,se_redraw_loop
        ld      a,(se_rep)
        ld      hl,s_msg_serep
        call    se_prompt2
        jp      c,se_redraw_loop
        ld      hl,se_len
        cp      (hl)
        jp      nc,se_redraw_loop
        push    af
        call    se_ensure
        pop     bc                      ; B = value
        jp      c,se_noroom
        ld      hl,(se_blk)
        ld      (hl),b
        jp      se_redraw_loop

; se_prompt2: A = current value, HL = message -> 2-digit prompt on the hint
; row. Returns A = value (CY clear) or CY set (cancelled / not a number).
se_prompt2:
        push    hl
        ld      hl,ar_lenbuf
        call    dec2_to_buf
        pop     hl
        call    draw_message
        ld      hl,ar_lenbuf
        ld      b,2
        ld      a,R_HINT
        ld      (pt_row),a
        ld      a,29
        ld      (pt_col),a
        call    prompt_text
        ret     c
        ld      hl,ar_lenbuf
        jp      buf_to_dec2

; SPACE: toggle the flag / sign under the cursor
se_space:
        call    se_ensure
        jp      c,se_noroom
        call    se_cur_addr             ; HL -> b0 (or the ornament byte)
        ld      a,(se_kind)
        or      a
        jr      nz,.negb
        ld      a,(se_field)
        or      a
        jr      z,.t
        dec     a
        jr      z,.n
        dec     a
        jr      z,.e
        dec     a
        jr      z,.tone
        dec     a
        jr      z,.tacc
        dec     a
        jr      z,.ns
        dec     a
        jr      z,.nacc
        dec     a
        jp      z,se_redraw_loop        ; volume: nothing to toggle
        ; amplitude slide: none -> up -> down -> none (b0 bit7 = on, bit6 = up)
        ld      a,(hl)
        bit     7,a
        jr      z,.up
        bit     6,a
        jr      z,.off
        and     $BF
        jr      .st
.off:   and     $3F
        jr      .st
.up:    or      $C0
.st:    ld      (hl),a
        jp      se_redraw_loop
.t:     inc     hl
        ld      a,(hl)
        xor     $10
        jr      .st
.n:     inc     hl
        ld      a,(hl)
        xor     $80
        jr      .st
.e:     ld      a,(hl)
        xor     $01
        jr      .st
.tacc:  inc     hl
        ld      a,(hl)
        xor     $40
        jr      .st
.nacc:  inc     hl
        ld      a,(hl)
        xor     $20
        jr      .st
.tone:  inc     hl
        inc     hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        call    neg_de
        ld      (hl),d
        dec     hl
        ld      (hl),e
        jp      se_redraw_loop
.ns:    ld      a,(hl)                  ; bits1-5 -> negate mod 32
        ld      c,a
        rra
        and     $1F
        neg
        and     $1F
        add     a,a
        ld      b,a
        ld      a,c
        and     $C1
        or      b
        jr      .st
.negb:  ld      a,(hl)
        neg
        jr      .st

neg_de:
        xor     a
        sub     e
        ld      e,a
        sbc     a,a
        sub     d
        ld      d,a
        ret

; digits: A = 0..15 -> type into the number under the cursor
se_digit:
        ld      (se_tmp),a
        call    se_ensure
        jp      c,se_noroom
        call    se_cur_addr
        ld      a,(se_kind)
        or      a
        jp      nz,.orn
        ld      a,(se_field)
        cp      7
        jr      z,.vol
        cp      3
        jr      z,.tone
        cp      5
        jp      nz,se_redraw_loop
        ; Ns: signed 5-bit, two rolling decimal digits
        ld      a,(se_tmp)
        cp      10
        jp      nc,se_redraw_loop
        ld      a,(hl)
        ld      c,a                     ; keep b0
        rra
        and     $1F
        ld      b,0                     ; B = negative
        cp      16
        jr      c,.pos
        ld      b,1
        neg
        and     $1F
.pos:   cp      10
        jr      c,.m1
        sub     10
.m1:    call    times10_plus            ; A = (A mod 10)*10 + digit
        ld      e,15
        inc     b
        dec     b
        jr      z,.cl
        ld      e,16
.cl:    cp      e
        jr      c,.ok
        ld      a,e
.ok:    inc     b
        dec     b
        jr      z,.enc
        neg
.enc:   and     $1F
        add     a,a
        ld      b,a
        ld      a,c
        and     $C1
        or      b
        ld      (hl),a
        jp      se_redraw_loop
.vol:   ld      a,(se_tmp)
        ld      c,a
        inc     hl
        ld      a,(hl)
        and     $F0
        or      c
        ld      (hl),a
        jp      se_redraw_loop
.tone:  ld      a,(se_tmp)
        cp      10
        jp      nc,se_redraw_loop
        inc     hl
        inc     hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        push    hl                      ; -> b3
        ld      b,0
        bit     7,d
        jr      z,.tp
        ld      b,1
        call    neg_de
.tp:    ex      de,hl                   ; HL = magnitude
        ld      de,-1000
.mod:   add     hl,de
        jr      c,.mod
        sbc     hl,de                   ; HL = magnitude mod 1000
        add     hl,hl
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,hl
        add     hl,de                   ; *10
        ld      a,(se_tmp)
        ld      e,a
        ld      d,0
        add     hl,de
        ex      de,hl                   ; DE = new magnitude
        inc     b
        dec     b
        jr      z,.tst
        call    neg_de
.tst:   pop     hl
        ld      (hl),d
        dec     hl
        ld      (hl),e
        jp      se_redraw_loop
.orn:   ld      a,(se_tmp)
        cp      10
        jp      nc,se_redraw_loop
        ld      a,(hl)
        ld      b,0
        bit     7,a
        jr      z,.om
        ld      b,1
        neg
.om:    cp      10
        jr      c,.om1
        sub     10
        jr      .om
.om1:   call    times10_plus            ; <= 99
        inc     b
        dec     b
        jr      z,.os
        neg
.os:    ld      (hl),a
        jp      se_redraw_loop

; times10_plus: A = A*10 + (se_tmp)
times10_plus:
        add     a,a
        ld      e,a
        add     a,a
        add     a,a
        add     a,e
        ld      e,a
        ld      a,(se_tmp)
        add     a,e
        ret

; ---------------------------------------------------------------------------
; ENTER: play the instrument while the key is held (pv_play in player.asm).
; The sample editor plays its sample with ornament 0; the ornament editor plays
; its ornament with the pattern editor's current sample. Envelope: automatic
; (shape 8 at the note's pitch when the sample uses the envelope).
; ---------------------------------------------------------------------------
se_preview:
        call    se_refresh
        ld      a,(se_kind)
        or      a
        jr      nz,.orn
        ld      a,(se_len)
        or      a
        jp      z,se_loop
        ld      a,(se_sel)
        ld      c,a
        ld      b,0
        jr      .go
.orn:   ld      a,(se_sel)
        ld      b,a
        ld      a,(cur_sample)
        ld      c,a
.go:    ld      a,b
        ld      (pv_orn),a
        ld      a,c
        ld      (pv_smp),a
        xor     a
        ld      (pv_shape),a
        ld      h,a
        ld      l,a
        ld      (pv_per),hl
        ld      a,(octave)
        dec     a
        ld      b,a
        add     a,a
        add     a,b
        add     a,a
        add     a,a                     ; (octave-1)*12 = C
        ld      (pv_note),a
        call    pv_play
        jp      se_loop

; ---------------------------------------------------------------------------
; Drawing
; ---------------------------------------------------------------------------
se_draw_all:
        call    se_refresh
        call    cls
        ; keep the cursor line on the page
        ld      a,(se_line)
        ld      hl,se_top
        cp      (hl)
        jr      nc,.t1
        ld      (hl),a
.t1:    ld      a,(hl)
        add     a,SE_ROWS-1
        ld      c,a
        ld      a,(se_line)
        cp      c
        jr      c,.t2
        jr      z,.t2
        sub     SE_ROWS-1
        ld      (hl),a
.t2:    ; row 0: kind + number, Len / Rep
        ld      a,(se_kind)
        or      a
        ld      hl,s_se_smp
        jr      z,.title
        ld      hl,s_se_orn
.title: ld      bc,(0<<8)|0
        ld      a,A_VALUE
        call    print_at                ; DE = pixels after the text
        ld      a,(se_sel)
        ld      hl,se_kind
        bit     0,(hl)
        jr      nz,.hex
        ld      hl,base32
        add     a,l
        ld      l,a
        jr      nc,.b
        inc     h
.b:     ld      a,(hl)
        call    put_char_adv
        ld      a,' '
        call    put_char_adv
        ld      a,'('
        call    put_char_adv
        ld      a,(se_sel)
        call    put_dec2
        ld      a,')'
        call    put_char_adv
        jr      .lenrep
.hex:   call    put_hex1
.lenrep:
        ld      a,(se_len)
        or      a
        jr      z,.empty
        ld      bc,(0<<8)|17
        ld      hl,s_se_len
        ld      a,A_VALUE
        call    print_at
        ld      a,(se_len)
        call    put_dec2
        ld      hl,s_se_rep
        call    print_str
        ld      a,(se_rep)
        call    put_dec2
        jr      .attr0
.empty: ld      bc,(SE_ROW0<<8)|0
        ld      hl,s_se_empty
        ld      a,A_LABEL
        call    print_at
.attr0: ld      bc,(0<<8)|0
        ld      e,32
        ld      a,A_VALUE
        call    fill_attr
        ; row 1: menu strip
        ld      a,A_MENU_HOT
        ld      (hot_attr),a
        ld      bc,(1<<8)|0
        ld      hl,s_se_menu
        ld      a,A_MENU_TXT
        call    print_at
        ; row 2: column header
        ld      a,(se_kind)
        or      a
        ld      hl,s_se_head_s
        jr      z,.hd
        ld      hl,s_se_head_o
.hd:    ld      bc,(2<<8)|0
        ld      a,A_LABEL
        ld      (hot_attr),a            ; the header's literal carets keep the label colour
        call    print_at
        ; the lines on this page
        ld      a,(se_top)
        ld      b,SE_ROWS
        ld      c,SE_ROW0
.lines: ld      hl,se_len
        cp      (hl)
        jr      nc,.hints
        push    bc
        push    af
        call    se_draw_line
        pop     af
        pop     bc
        inc     a
        inc     c
        djnz    .lines
.hints: ld      a,(se_kind)
        or      a
        ld      hl,s_hint_se2_s
        jr      z,.h2
        ld      hl,s_hint_se2_o
.h2:    ld      bc,(R_FREE<<8)|0
        ld      a,A_LABEL
        call    print_at
        ld      hl,s_hint_se
        jp      draw_hint

; se_draw_line: A = line index, C = screen row
se_draw_line:
        ld      (se_tmp),a
        ld      a,c
        ld      (se_row),a
        ld      c,0
        call    scr_addr                ; DE = pixels
        ld      a,(se_tmp)
        call    put_dec2
        inc     e
        inc     e
        ld      a,(se_tmp)
        call    se_line_addr            ; HL -> the line's bytes
        ld      a,(se_kind)
        or      a
        jr      nz,.orn
        inc     hl
        ld      a,(hl)                  ; b1
        ld      b,'T'
        ld      c,$10
        call    se_flag
        ld      a,(hl)
        ld      b,'N'
        ld      c,$80
        call    se_flag
        dec     hl
        ld      a,(hl)                  ; b0
        ld      b,'E'
        ld      c,$01
        call    se_flag
        inc     e
        inc     e
        push    hl
        inc     hl
        inc     hl
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a                     ; HL = tone offset
        call    put_signed4
        pop     hl
        inc     hl
        ld      a,(hl)                  ; b1
        ld      c,$40
        call    se_acc
        inc     e
        inc     e
        dec     hl
        ld      a,(hl)                  ; b0: Ns offset, signed 5-bit
        rra
        and     $1F
        cp      16
        jr      c,.nsp
        neg
        and     $1F
        ld      c,a
        ld      a,'-'
        jr      .nss
.nsp:   ld      c,a
        ld      a,'+'
.nss:   call    put_char_adv
        ld      a,c
        call    put_dec2
        inc     hl
        ld      a,(hl)                  ; b1
        ld      c,$20
        call    se_acc
        inc     e
        inc     e
        ld      a,(hl)
        call    put_hex1                ; volume
        inc     e
        inc     e
        dec     hl
        ld      a,(hl)                  ; b0: amplitude slide
        ld      c,'_'
        bit     7,a
        jr      z,.amp
        ld      c,'-'
        bit     6,a
        jr      z,.amp
        ld      c,'+'
.amp:   ld      a,c
        call    put_char_adv
        jr      .attrs
.orn:   ld      a,(hl)
        bit     7,a
        jr      z,.op
        neg
        ld      c,a
        ld      a,'-'
        jr      .os
.op:    ld      c,a
        ld      a,'+'
.os:    call    put_char_adv
        ld      a,c
        cp      100
        jr      c,.o99
        ld      a,99
.o99:   call    put_dec2
.attrs: ; text, loop marker on the line number, cursor field
        ld      a,(se_row)
        ld      b,a
        ld      c,0
        ld      e,28
        ld      a,A_MENU_TXT
        call    fill_attr
        ld      a,(se_tmp)
        ld      hl,se_rep
        cp      (hl)
        jr      nz,.nol
        ld      a,(se_row)
        ld      b,a
        ld      c,0
        ld      e,2
        ld      a,A_MENU_HOT
        call    fill_attr
.nol:   ld      a,(se_tmp)
        ld      hl,se_line
        cp      (hl)
        ret     nz
        ld      a,(se_kind)
        or      a
        ld      c,4
        ld      e,3
        jr      nz,.paint
        ld      a,(se_field)
        ld      hl,se_fcol
        add     a,l
        ld      l,a
        jr      nc,.f1
        inc     h
.f1:    ld      c,(hl)
        ld      de,se_fwid-se_fcol
        add     hl,de
        ld      e,(hl)
.paint: ld      a,(se_row)
        ld      b,a
        ld      a,A_FIELD
        jp      fill_attr

; se_flag: print B when (A & C) == 0, else '-'
se_flag:
        and     c
        ld      a,b
        jr      z,.p
        ld      a,'-'
.p:     jp      put_char_adv

; se_acc: print '^' when (A & C) != 0, else '_'
se_acc:
        and     c
        ld      a,'_'
        jr      z,.p
        ld      a,'^'
.p:     jp      put_char_adv

; put_signed4: HL = signed 16-bit -> sign + 4 digits (magnitude clamped to 9999)
put_signed4:
        ld      a,'+'
        bit     7,h
        jr      z,.p
        xor     a
        sub     l
        ld      l,a
        sbc     a,a
        sub     h
        ld      h,a
        ld      a,'-'
.p:     call    put_char_adv
        ld      bc,-10000
        add     hl,bc
        jr      nc,.ok
        ld      hl,9999
        jp      put_dec4
.ok:    sbc     hl,bc
        jp      put_dec4

; cursor field -> column / width on a sample line
se_fcol: db     4,5,6,9,14,17,20,23,26
se_fwid: db     1,1,1,5,1,3,1,1,1
