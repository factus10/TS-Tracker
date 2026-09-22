; =============================================================================
; songinfo.asm -- song info screen (SYM+G): title, author, speed, counts
;
; Title = header bytes 30..61 (32 chars), author = 66..97 (32 of the 33), speed
; = byte 100. Text edits go straight into the slot header (no pattern commit
; involved); speed changes take effect on the next play.
; =============================================================================

cmd_info:
        call    si_draw
.loop:  halt
        call    kb_scan
        call    kb_caps
        jr      z,.plain
        ld      a,(kb_edge+KR_09876)
        bit     3,a                     ; 7 = speed up
        jr      z,.n7
        ld      a,(SLOT_BASE+H_SPEED)
        cp      31
        jr      nc,.loop
        inc     a
        ld      (SLOT_BASE+H_SPEED),a
        call    si_speed
        jr      .loop
.n7:    bit     4,a                     ; 6 = speed down
        jr      z,.loop
        ld      a,(SLOT_BASE+H_SPEED)
        cp      2
        jr      c,.loop
        dec     a
        ld      (SLOT_BASE+H_SPEED),a
        call    si_speed
        jr      .loop
.plain: call    kb_letter_edge
        or      a
        jr      z,.loop
        cp      13
        jr      z,.leave
        cp      'Q'
        jr      z,.leave
        cp      'T'
        jr      z,.title
        cp      'A'
        jr      nz,.loop
        ld      hl,SLOT_BASE+66
        ld      a,7
        jr      .edit
.title: ld      hl,SLOT_BASE+30
        ld      a,4
.edit:  ld      (pt_row),a
        xor     a
        ld      (pt_col),a
        ld      b,32
        call    prompt_text
        call    si_draw
        jr      .loop
.leave: call    kb_wait_none
        call    redraw_all
        jp      editor_loop

si_draw:
        call    cls
        ld      bc,(1<<8)|0
        ld      hl,s_si_title
        ld      a,A_VALUE
        call    print_at
        ld      bc,(3<<8)|0
        ld      hl,s_si_l_title
        ld      a,A_LABEL
        call    print_at
        ld      bc,(6<<8)|0
        ld      hl,s_si_l_author
        ld      a,A_LABEL
        call    print_at
        ; title / author text (32 chars each) in bright white
        ld      a,4
        ld      c,0
        call    scr_addr
        ld      hl,SLOT_BASE+30
        ld      b,32
        call    si_text
        ld      bc,(4<<8)|0
        ld      e,32
        ld      a,A_VALUE
        call    fill_attr
        ld      a,7
        ld      c,0
        call    scr_addr
        ld      hl,SLOT_BASE+66
        ld      b,32
        call    si_text
        ld      bc,(7<<8)|0
        ld      e,32
        ld      a,A_VALUE
        call    fill_attr
        ld      bc,(9<<8)|0
        ld      hl,s_si_l_speed
        ld      a,A_LABEL
        call    print_at
        call    si_speed
        ld      bc,(11<<8)|0
        ld      hl,s_si_l_counts
        ld      a,A_LABEL
        call    print_at
        ld      a,11
        ld      c,10
        call    scr_addr
        ld      a,(SLOT_BASE+H_NPOS)
        call    put_dec2
        ld      a,11
        ld      c,18
        call    scr_addr
        ld      a,(SLOT_BASE+H_LOOP)
        call    put_dec2
        ld      a,11
        ld      c,28
        call    scr_addr
        ld      a,(num_pats)
        call    put_dec2
        ld      bc,(11<<8)|0
        ld      e,32
        ld      a,A_VALUE
        call    fill_attr
        ld      bc,(13<<8)|0
        ld      hl,s_si_l_bytes
        ld      a,A_LABEL
        call    print_at
        ld      a,13
        ld      c,5
        call    scr_addr
        ld      hl,(song_len)
        call    put_dec5
        ld      hl,SONG_BUDGET
        ld      de,(song_len)
        or      a
        sbc     hl,de                   ; (compute first: loading DE would clobber the pixel pointer)
        push    hl
        ld      a,13
        ld      c,23
        call    scr_addr
        pop     hl
        call    put_dec5
        ld      bc,(13<<8)|0
        ld      e,32
        ld      a,A_VALUE
        call    fill_attr
        ld      hl,s_hint_si
        jp      draw_hint

; si_text: B chars from (HL) at DE, non-printables as '.'
si_text:
        ld      a,(hl)
        cp      32
        jr      c,.q
        cp      127
        jr      c,.ok
.q:     ld      a,'.'
.ok:    call    put_char_adv
        inc     hl
        djnz    si_text
        ret

si_speed:
        ld      a,9
        ld      c,6
        call    scr_addr
        ld      a,(SLOT_BASE+H_SPEED)
        call    put_dec2
        ld      bc,(9<<8)|6
        ld      e,2
        ld      a,A_VALUE
        jp      fill_attr
