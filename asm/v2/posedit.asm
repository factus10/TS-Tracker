; =============================================================================
; posedit.asm -- the arrangement (position list) editor, SYM+F from the editor
;
; Shows the PT3 position list as "pp:PP" cells (position:pattern), 5 per row,
; 60 per page. Keys: CAPS+5/6/7/8 move, 0-9 type a pattern number, I insert
; (duplicate) before the cursor, X delete, L set the loop point here, N create
; a new empty pattern and put it here, E change that pattern's length,
; ENTER/Q back to the pattern editor at the cursor position.
; All list edits are splices in the slot (slot_insert/slot_delete), so the
; pattern table, instrument pointers and the table pointer move with them.
; =============================================================================

AR_ROW0     EQU 4
AR_ROWS     EQU 12
AR_COLS     EQU 5
AR_PAGE     EQU AR_ROWS*AR_COLS

cmd_arrange:
        call    commit_pattern
        jp      c,commit_failed_loop
        ld      a,(cur_pos)
        ld      (ar_cur),a
        xor     a
        ld      (ar_typed),a
        call    ar_draw_all
.loop:  halt
        call    kb_scan
        call    kb_caps
        jr      z,.plain
        ld      a,(kb_edge+KR_12345)
        bit     4,a
        jr      z,.n5
        ld      a,-1
        call    ar_move
.n5:    ld      a,(kb_edge+KR_09876)
        bit     2,a                     ; 8 right
        jr      z,.n8
        ld      a,1
        call    ar_move
.n8:    ld      a,(kb_edge+KR_09876)
        bit     3,a                     ; 7 up
        jr      z,.n7
        ld      a,-AR_COLS
        call    ar_move
.n7:    ld      a,(kb_edge+KR_09876)
        bit     4,a                     ; 6 down
        jr      z,.loop
        ld      a,AR_COLS
        call    ar_move
        jr      .loop
.plain: call    kb_letter_edge
        or      a
        jr      z,.loop
        cp      13
        jr      z,.leave
        cp      'Q'
        jr      z,.leave
        cp      'I'
        jp      z,ar_insert
        cp      'X'
        jp      z,ar_delete
        cp      'L'
        jp      z,ar_loop_here
        cp      'N'
        jp      z,ar_newpat
        cp      'E'
        jp      z,ar_length
        sub     '0'
        cp      10
        jr      nc,.loop
        call    ar_digit
        jr      .loop
.leave: call    kb_wait_none
        ld      a,(ar_cur)
        ld      (cur_pos),a
        call    pos_pattern
        call    wp_load
        ld      a,(cur_row)
        ld      hl,wp_len
        cp      (hl)
        jr      c,.rowok
        ld      a,(hl)
        dec     a
        jp      p,.clamp
        xor     a
.clamp: ld      (cur_row),a
.rowok: call    update_free
        call    redraw_all
        jp      editor_loop

; ar_move: A = signed delta -> clamp to 0..npos-1, redraw
ar_move:
        ld      hl,ar_cur
        bit     7,a
        jr      z,.fwd
        neg                             ; A = |delta|
        ld      c,a
        ld      a,(hl)
        sub     c
        jr      nc,.set
        xor     a
        jr      .set
.fwd:   add     a,(hl)
        jr      c,.max
        ld      c,a
        ld      a,(SLOT_BASE+H_NPOS)
        dec     a
        cp      c
        jr      c,.set                  ; clamp to npos-1
        ld      a,c
        jr      .set
.max:   ld      a,(SLOT_BASE+H_NPOS)
        dec     a
.set:   ld      (hl),a
        xor     a
        ld      (ar_typed),a
        jp      ar_draw_all

; ar_pos_addr: HL -> position byte at (ar_cur). Preserves A (callers hold a value in it).
ar_pos_addr:
        push    af
        ld      a,(ar_cur)
        ld      hl,SLOT_BASE+H_POSLIST
        add     a,l
        ld      l,a
        jr      nc,.n
        inc     h
.n:     pop     af
        ret

; ar_digit: A = 0..9 typed -> rolling 2-digit pattern number at the cursor
ar_digit:
        ld      c,a
        ld      a,(ar_typed)
        add     a,a
        ld      b,a
        add     a,a
        add     a,a
        add     a,b                     ; *10
        add     a,c
        ld      hl,num_pats
        cp      (hl)
        jr      c,.ok
        ld      a,c                     ; start over with the digit
        cp      (hl)
        ret     nc
.ok:    ld      (ar_typed),a
        ld      b,a
        add     a,a
        add     a,b                     ; *3
        call    ar_pos_addr
        ld      (hl),a
        jp      ar_draw_all

ar_loop_here:
        ld      a,(ar_cur)
        ld      (SLOT_BASE+H_LOOP),a
        call    ar_draw_all
        jp      cmd_arrange.loop

ar_insert:
        ld      a,(SLOT_BASE+H_NPOS)
        cp      200
        jp      nc,ar_noroom
        call    ar_pos_addr
        ld      bc,1
        call    slot_insert
        jp      c,ar_noroom
        call    ar_pos_addr
        inc     hl
        ld      a,(hl)                  ; the entry that was here (now shifted)
        dec     hl
        ld      (hl),a
        ld      hl,SLOT_BASE+H_NPOS
        inc     (hl)
        ld      a,(SLOT_BASE+H_LOOP)
        ld      hl,ar_cur
        cp      (hl)
        jr      c,.nl
        inc     a
        ld      (SLOT_BASE+H_LOOP),a
.nl:    call    ar_draw_all
        jp      cmd_arrange.loop

ar_delete:
        ld      a,(SLOT_BASE+H_NPOS)
        cp      2
        jp      c,cmd_arrange.loop      ; keep at least one position
        call    ar_pos_addr
        ld      bc,1
        call    slot_delete
        ld      hl,SLOT_BASE+H_NPOS
        dec     (hl)
        ld      a,(SLOT_BASE+H_LOOP)
        ld      hl,ar_cur
        cp      (hl)
        jr      z,.chk
        jr      c,.chk
        dec     a
.chk:   ld      hl,SLOT_BASE+H_NPOS
        cp      (hl)
        jr      c,.lok
        ld      a,(hl)
        dec     a
.lok:   ld      (SLOT_BASE+H_LOOP),a
        ld      a,(ar_cur)
        ld      hl,SLOT_BASE+H_NPOS
        cp      (hl)
        jr      c,.cok
        ld      a,(hl)
        dec     a
        ld      (ar_cur),a
.cok:   call    calc_num_pats
        call    ar_draw_all
        jp      cmd_arrange.loop

; ar_newpat: append a 6-byte table entry + an empty 64-row stream, point the
; cursor position at the new pattern.
ar_newpat:
        ld      a,(num_pats)
        cp      85                      ; position byte = pattern*3 must fit a byte
        jp      nc,ar_noroom
        ; table_end = patptr + 6*num_pats
        ld      l,a
        ld      h,0
        add     hl,hl
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,de                   ; *6
        ld      de,(SLOT_BASE+H_PATPTR)
        add     hl,de
        ld      (ar_tmp),hl             ; table_end (offset)
        ld      de,SLOT_BASE
        add     hl,de
        ld      bc,10
        call    slot_insert
        jp      c,ar_noroom
        ld      hl,(ar_tmp)
        ld      de,SLOT_BASE
        add     hl,de                   ; HL -> new entry
        ld      de,(ar_tmp)
        inc     de
        inc     de
        inc     de
        inc     de
        inc     de
        inc     de                      ; DE = stream offset = table_end + 6
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl                      ; HL -> stream
        ld      (hl),$B1
        inc     hl
        ld      (hl),64
        inc     hl
        ld      (hl),$D0
        inc     hl
        ld      (hl),$00
        ld      hl,num_pats
        inc     (hl)
        ld      a,(hl)
        dec     a
        ld      b,a
        add     a,a
        add     a,b                     ; *3
        call    ar_pos_addr
        ld      (hl),a
        call    ar_draw_all
        jp      cmd_arrange.loop

ar_noroom:
        ld      hl,s_msg_noroom
        call    flash_message
        call    ar_draw_all
        jp      cmd_arrange.loop

; ar_length: prompt for the pattern length (1..64) of the pattern at the cursor
ar_length:
        ; current length: load that pattern first (WP is clean here)
        call    ar_cur_pattern
        ld      hl,wp_pat
        cp      (hl)
        jr      z,.have
        call    wp_load
.have:  ld      a,(wp_len)
        ld      hl,ar_lenbuf
        call    dec2_to_buf
        ld      hl,s_msg_length
        call    draw_message
        ld      hl,ar_lenbuf
        ld      b,2
        ld      a,R_HINT
        ld      (pt_row),a
        ld      a,29
        ld      (pt_col),a
        call    prompt_text
        jr      c,.out
        ld      hl,ar_lenbuf
        call    buf_to_dec2             ; A = value, CY if not a number
        jr      c,.out
        or      a
        jr      z,.out
        cp      65
        jr      nc,.out
        ld      hl,wp_len
        cp      (hl)
        jr      z,.out
        jr      nc,.grow
        ; shrink: blank rows >= new length
        push    af
        ld      b,a
        call    wp_row_addr
        ld      a,WP_ROWS
        sub     b
        ld      b,a
.bl:    push    bc
        call    wp_blank_row
        pop     bc
        djnz    .bl
        pop     af
.grow:  ld      (wp_len),a
        call    mark_dirty
        call    commit_pattern
        jp      c,ar_noroom
.out:   call    ar_draw_all
        jp      cmd_arrange.loop

; ar_cur_pattern: A = pattern index at the cursor position
ar_cur_pattern:
        call    ar_pos_addr
        ld      a,(hl)
        jp      div3

; dec2_to_buf: A = 0..99 -> two ASCII digits at (HL)
dec2_to_buf:
        ld      b,'0'-1
.t:     inc     b
        sub     10
        jr      nc,.t
        add     a,10
        add     a,'0'
        ld      (hl),b
        inc     hl
        ld      (hl),a
        ret

; buf_to_dec2: two chars at (HL) -> A (spaces count as 0); CY if not digits
buf_to_dec2:
        ld      a,(hl)
        call    .dig
        ret     c
        ld      b,a
        add     a,a
        add     a,a
        add     a,a
        add     a,b
        add     a,b                     ; *10
        ld      c,a
        inc     hl
        ld      a,(hl)
        call    .dig
        ret     c
        add     a,c
        or      a
        ret
.dig:   cp      ' '
        jr      nz,.d
        xor     a
        ret
.d:     sub     '0'
        cp      10
        ccf
        ret

; ---- drawing -------------------------------------------------------------------
ar_draw_all:
        call    cls
        ld      bc,(1<<8)|0
        ld      hl,s_ar_title
        ld      a,A_VALUE
        call    print_at
        ld      hl,s_hint_ar
        call    draw_hint
        ld      bc,(R_FREE<<8)|0
        ld      hl,s_hint_ar2
        ld      a,A_LABEL
        call    print_at
        ; info line
        ld      bc,(2<<8)|0
        ld      hl,s_ar_info
        ld      a,A_LABEL
        call    print_at
        ld      a,2
        ld      c,4
        call    scr_addr
        ld      a,(ar_cur)
        call    put_dec2
        inc     e
        ld      a,(SLOT_BASE+H_NPOS)
        call    put_dec2
        ld      a,2
        ld      c,14
        call    scr_addr
        call    ar_cur_pattern
        call    put_dec2
        ld      a,2
        ld      c,21
        call    scr_addr
        ld      a,(num_pats)
        call    put_dec2
        ld      a,2
        ld      c,29
        call    scr_addr
        ld      a,(SLOT_BASE+H_LOOP)
        call    put_dec2
        ld      bc,(2<<8)|0
        ld      e,32
        ld      a,A_VALUE
        call    fill_attr
        ; page: top = (ar_cur / 60) * 60
        ld      a,(ar_cur)
        ld      c,0
.t2:    cp      AR_PAGE
        jr      c,.t3
        sub     AR_PAGE
        push    af
        ld      a,c
        add     a,AR_PAGE
        ld      c,a
        pop     af
        jr      .t2
.t3:    ld      a,c
        ld      (ar_top),a
        ; cells: index B = 0..59 -> row B/5, col B%5 -> screen (AR_ROW0+row, 1+col*6)
        ld      b,0
.cell:  push    bc
        ld      a,(ar_top)
        add     a,b
        ld      (ar_tmp2),a             ; position index (may be >= npos)
        ld      a,b
        ld      c,0
.rc:    cp      AR_COLS
        jr      c,.rcok
        sub     AR_COLS
        inc     c
        jr      .rc
.rcok:  ld      e,a                     ; A = col, C = row
        add     a,a
        add     a,a
        add     a,e
        add     a,e                     ; col*6
        inc     a                       ; left margin
        ld      e,a
        ld      a,c
        add     a,AR_ROW0
        ld      c,e
        call    scr_addr                ; DE = pixels, HL = attrs
        push    hl
        ld      a,(ar_tmp2)
        ld      hl,SLOT_BASE+H_NPOS
        cp      (hl)
        jr      nc,.blank
        call    put_dec2
        ld      a,':'
        call    put_char_adv
        ld      a,(ar_tmp2)
        ld      hl,SLOT_BASE+H_POSLIST
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)
        call    div3
        call    put_dec2
        pop     hl                      ; attrs at the cell start
        ld      a,(ar_tmp2)
        ld      c,a
        ld      a,(ar_cur)
        cp      c
        ld      a,A_MENU_TXT
        jr      nz,.paint
        ld      a,A_FIELD
.paint: ld      b,5
.pa:    ld      (hl),a
        inc     hl
        djnz    .pa
        ; loop marker: the ':' of the loop position in bright yellow
        ld      a,(ar_tmp2)
        ld      c,a
        ld      a,(SLOT_BASE+H_LOOP)
        cp      c
        jr      nz,.next
        dec     hl
        dec     hl
        dec     hl
        ld      (hl),A_MENU_HOT
        jr      .next
.blank: pop     hl
.next:  pop     bc
        inc     b
        ld      a,b
        cp      AR_PAGE
        jp      nz,.cell
        ret
