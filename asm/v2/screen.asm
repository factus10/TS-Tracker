; =============================================================================
; screen.asm -- direct display-file text renderer (ROM font + custom glyphs)
;
; Conventions: every put_* routine draws at pixel address DE and leaves DE on
; the NEXT column (put_char itself does not advance; put_char_adv does).
; A/BC/HL are preserved by put_char so callers can keep an attribute pointer
; in HL and loop counters in BC across glyph draws.
; =============================================================================

; Clear pixels + paint every attribute black-on-black.
cls:
        ld      hl,SCREEN
        ld      de,SCREEN+1
        ld      bc,6143
        ld      (hl),0
        ldir
        ld      hl,ATTRS
        ld      de,ATTRS+1
        ld      bc,767
        ld      (hl),A_BLACK
        ldir
        ret

; A=row, C=col -> DE = pixel address (top scanline), HL = attribute address.
scr_addr:
        push    af
        and     $18
        or      $40
        ld      d,a
        pop     af
        push    af
        and     7
        rrca
        rrca
        rrca
        or      c
        ld      e,a
        pop     af
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,c
        or      l
        ld      l,a
        ld      a,h
        or      $58
        ld      h,a
        ret

; Draw glyph A at pixel address DE. Preserves AF, BC, DE, HL.
put_char:
        push    af
        push    de
        push    hl
        push    bc
        cp      128
        jr      c,.rom
        sub     128
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      bc,custom_font
        add     hl,bc
        jr      .draw
.rom:   ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      bc,ROMFONT
        add     hl,bc
.draw:
        DUP 7
        ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     d
        EDUP
        ld      a,(hl)
        ld      (de),a
        pop     bc
        pop     hl
        pop     de
        pop     af
        ret

put_char_adv:                           ; draw A, advance DE one column
        call    put_char
        inc     e
        ret

put_spaces:                             ; B spaces at DE
        ld      a,' '
.l:     call    put_char_adv
        djnz    .l
        ret

; print_at: B=row, C=col, HL=0-terminated string, A=attr for every char.
; Markup: '^' gives the NEXT char the attribute in (hot_attr).
print_at:
        ld      (cur_attr),a
        ld      a,b
        push    hl
        call    scr_addr                ; DE=pixels, HL=attrs
        pop     ix                      ; IX = string
.loop:
        ld      a,(ix)
        or      a
        ret     z
        inc     ix
        cp      '^'
        jr      nz,.normal
        ld      a,(ix)
        inc     ix
        call    put_char
        ld      a,(hot_attr)
        ld      (hl),a
        inc     hl
        inc     e
        jr      .loop
.normal:
        call    put_char
        ld      a,(cur_attr)
        ld      (hl),a
        inc     hl
        inc     e
        jr      .loop

; print_str: HL = string, DE = pixels, IX unused. Draws glyphs only (no attrs).
print_str:
        ld      a,(hl)
        or      a
        ret     z
        call    put_char_adv
        inc     hl
        jr      print_str

; fill_attr: B=row, C=col, E=count, A=attr
fill_attr:
        ld      d,a
        ld      a,b
        push    de
        call    scr_addr
        pop     de
        ld      a,d
.l:     ld      (hl),a
        inc     hl
        dec     e
        jr      nz,.l
        ret

; clear_row: B=row -> 32 spaces + attr A on that row
clear_row:
        push    af
        ld      a,b
        ld      c,0
        call    scr_addr
        pop     af
        push    hl
        ld      b,32
        call    put_spaces
        pop     hl
        ld      b,32
.a:     ld      (hl),a
        inc     hl
        djnz    .a
        ret

; ---- numeric glyphs -------------------------------------------------------
put_hex1:                               ; A = 0..15
        and     $0F
        cp      10
        jr      c,.d
        add     a,'A'-10
        jr      put_char_adv
.d:     add     a,'0'
        jr      put_char_adv

put_hex2:                               ; A = byte -> 2 hex digits
        push    af
        rrca
        rrca
        rrca
        rrca
        call    put_hex1
        pop     af
        jr      put_hex1

put_dot_or_hex1:                        ; 0 -> '.', else hex digit
        or      a
        jr      nz,put_hex1
        ld      a,'.'
        jp      put_char_adv

put_dec2:                               ; A = 0..99 -> 2 digits
        ld      b,'0'-1
.tens:  inc     b
        sub     10
        jr      nc,.tens
        add     a,10
        ld      c,a
        ld      a,b
        call    put_char_adv
        ld      a,c
        add     a,'0'
        jp      put_char_adv

put_dec3:                               ; A = 0..255 -> 3 digits
        ld      b,'0'-1
.h:     inc     b
        sub     100
        jr      nc,.h
        add     a,100
        push    af
        ld      a,b
        call    put_char_adv
        pop     af
        jr      put_dec2

put_dec5:                               ; HL = 0..65535 -> 5 digits, zero padded
        ld      bc,-10000
        call    dec_digit
put_dec4:                               ; HL = 0..9999 -> 4 digits, zero padded
        ld      bc,-1000
        call    dec_digit
        ld      bc,-100
        call    dec_digit
        ld      bc,-10
        call    dec_digit
        ld      a,l
        add     a,'0'
        jp      put_char_adv
dec_digit:                              ; one digit of HL for the power in BC (negative)
        ld      a,'0'-1
.sub:   inc     a
        add     hl,bc
        jr      c,.sub
        sbc     hl,bc
        jp      put_char_adv

; put_note: A = note byte -> 3 glyphs. Preserves HL (callers keep the cell pointer).
put_note:
        push    hl
        call    put_note_
        pop     hl
        ret
put_note_:
        cp      NOTE_NONE
        jr      z,.dash
        cp      NOTE_EMPTY
        jr      z,.dash
        cp      NOTE_REST
        jr      z,.rest
        ld      c,0
.div:   cp      12
        jr      c,.ok
        sub     12
        inc     c
        jr      .div
.ok:    push    bc
        add     a,a
        ld      hl,note_names
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)
        call    put_char_adv
        inc     hl
        ld      a,(hl)
        call    put_char_adv
        pop     bc
        ld      a,c
        inc     a
        add     a,'0'
        jp      put_char_adv
.dash:  ld      a,'-'
        call    put_char_adv
        call    put_char_adv
        jp      put_char_adv
.rest:  ld      a,'R'
        call    put_char_adv
        ld      a,'-'
        call    put_char_adv
        jp      put_char_adv

; put_cell: HL -> 7-byte cell, DE = pixels. Emits "NNN SEOVC" (9 glyphs).
; Advances HL past the cell.
put_cell:
        ld      a,(hl)
        call    put_note
        ld      a,' '
        call    put_char_adv
        inc     hl
        ld      a,(hl)                  ; smp | flags
        and     $1F
        jr      z,.nosmp
        push    hl
        ld      hl,base32
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)
        pop     hl
        call    put_char_adv
        jr      .env
.nosmp: ld      a,'.'
        call    put_char_adv
.env:   ld      a,(hl)
        ld      c,a                     ; keep flags
        inc     hl
        ld      a,(hl)                  ; env<<4 | orn
        rrca
        rrca
        rrca
        rrca
        and     $0F
        jr      z,.envdot
        cp      ENV_OFF
        jr      nz,.envhex
        ld      a,'0'                   ; envelope OFF shows as 0
        call    put_char_adv
        jr      .orn
.envhex: call   put_hex1
        jr      .orn
.envdot: ld     a,'.'
        call    put_char_adv
.orn:   bit     5,c
        jr      z,.orndot
        ld      a,(hl)
        call    put_hex1
        jr      .vol
.orndot: ld     a,'.'
        call    put_char_adv
.vol:   inc     hl
        ld      a,(hl)                  ; vol<<4 | cmd
        rrca
        rrca
        rrca
        rrca
        call    put_dot_or_hex1
        ld      a,(hl)
        and     $0F
        call    put_dot_or_hex1
        inc     hl
        inc     hl
        inc     hl
        inc     hl                      ; skip params -> next cell
        ret

; =============================================================================
; Static chrome
; =============================================================================
draw_chrome:
        ld      a,A_MENU_HOT
        ld      (hot_attr),a
        ld      bc,(R_MENU0<<8)|0
        ld      hl,s_tag_song
        ld      a,A_MENU_SONG
        call    print_at
        ld      bc,(R_MENU0<<8)|6
        ld      hl,s_menu_song
        ld      a,A_MENU_TXT
        call    print_at
        ld      bc,((R_MENU0+1)<<8)|0
        ld      hl,s_tag_edit
        ld      a,A_MENU_EDIT
        call    print_at
        ld      bc,((R_MENU0+1)<<8)|6
        ld      hl,s_menu_edit
        ld      a,A_MENU_TXT
        call    print_at
        ld      bc,((R_MENU0+2)<<8)|0
        ld      hl,s_tag_goto
        ld      a,A_MENU_GOTO
        call    print_at
        ld      bc,((R_MENU0+2)<<8)|6
        ld      hl,s_menu_goto
        ld      a,A_MENU_TXT
        call    print_at
        ld      bc,(R_INFO<<8)|0
        ld      hl,s_info
        ld      a,A_LABEL
        call    print_at
        ld      bc,(R_HEAD<<8)|0
        ld      hl,s_head
        ld      a,A_LABEL
        call    print_at
        ld      bc,(R_HEAD<<8)|2
        ld      e,1
        ld      a,A_RULE
        call    fill_attr
        ld      bc,(R_HEAD<<8)|12
        ld      e,1
        ld      a,A_RULE
        call    fill_attr
        ld      bc,(R_HEAD<<8)|22
        ld      e,1
        ld      a,A_RULE
        call    fill_attr
        ld      bc,(R_RULE<<8)|0
        ld      hl,s_rule
        ld      a,A_RULE
        call    print_at
        ld      bc,(R_DETAIL<<8)|0
        ld      hl,s_detail
        ld      a,A_LABEL
        call    print_at
        ld      bc,(R_FREE<<8)|0
        ld      hl,s_free
        ld      a,A_LABEL
        call    print_at
        ld      hl,s_hint_edit
        jp      draw_hint

; draw_hint: HL = 32-char string -> hint row (inverse cyan)
draw_hint:
        ld      bc,(R_HINT<<8)|0
        ld      a,A_HINT
        jp      print_at

; draw_message: HL = string -> hint row in error colours (caller repaints later)
draw_message:
        push    hl
        ld      b,R_HINT
        ld      a,A_ERROR
        call    clear_row
        pop     hl
        ld      bc,(R_HINT<<8)|0
        ld      a,A_ERROR
        jp      print_at

; =============================================================================
; Info line values: Pos xx/yy Pat xx/yy Spd xx Oct x
; =============================================================================
draw_info:
        ld      a,R_INFO
        ld      c,4
        call    scr_addr
        ld      a,(cur_pos)
        call    put_dec2
        inc     e
        ld      a,(SLOT_BASE+H_NPOS)
        call    put_dec2
        ld      a,R_INFO
        ld      c,14
        call    scr_addr
        ld      a,(wp_pat)
        call    put_dec2
        inc     e
        ld      a,(num_pats)
        call    put_dec2
        ld      a,R_INFO
        ld      c,24
        call    scr_addr
        ld      a,(SLOT_BASE+H_SPEED)
        call    put_dec2
        ld      a,R_INFO
        ld      c,31
        call    scr_addr
        ld      a,(octave)
        add     a,'0'
        jp      put_char

; =============================================================================
; Grid: 15 rows, cursor row pinned at screen row 12. Full redraw.
; =============================================================================
draw_grid:
        ld      a,(cur_row)
        sub     CUR_OFS
        ld      (grid_top),a
        ld      b,R_GRID
.row:
        push    bc
        ld      a,(grid_top)
        ld      c,a
        ld      a,b
        sub     R_GRID
        add     a,c
        ld      (cur_prow),a            ; pattern row for this screen row (may be out of range)
        ld      a,b
        ld      c,0
        call    scr_addr
        ld      a,(cur_prow)
        cp      WP_ROWS
        jr      c,.in_range
        call    blank_row
        jr      .next
.in_range:
        call    draw_row
.next:
        pop     bc
        inc     b
        ld      a,b
        cp      R_GRID+GRID_ROWS
        jr      nz,.row
        ret

; Row outside 0..63: blank glyphs, separators only.
blank_row:
        push    hl
        ld      b,2
        call    put_spaces
        ld      a,G_VBAR
        call    put_char_adv
        ld      b,9
        call    put_spaces
        ld      a,G_VBAR
        call    put_char_adv
        ld      b,9
        call    put_spaces
        ld      a,G_VBAR
        call    put_char_adv
        ld      b,9
        call    put_spaces
        pop     hl
        ld      a,A_BLACK
        ; fallthrough: paint_row_plain

; paint_row_plain: HL = attrs col 0, A = attr for everything except separators
paint_row_plain:
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),A_RULE
        inc     hl
        jp      paint_cells

; paint_cells: A = attr; HL = attrs at col 3; paints 9,sep,9,sep,9
paint_cells:
        ld      b,3
.c:     ld      c,9
.k:     ld      (hl),a
        inc     hl
        dec     c
        jr      nz,.k
        dec     b
        ret     z
        ld      (hl),A_RULE
        inc     hl
        jr      .c

; draw_row: (cur_prow) = pattern row 0..63, DE = pixels col 0, HL = attrs col 0
draw_row:
        push    hl
        ld      a,(cur_prow)
        ld      c,a
        ld      a,(wp_len)
        cp      c
        jr      z,.beyond
        jr      c,.beyond
        ; --- row number (decimal, SQ style) + separator
        ld      a,c
        call    put_dec2
        ld      a,G_VBAR
        call    put_char_adv
        ; --- HL -> row in WP (put_dec2 clobbered C: reload the row index;
        ;     wp_row_addr clobbers DE, the pixel pointer: keep it)
        push    de
        ld      a,(cur_prow)
        call    wp_row_addr             ; HL = WP row
        pop     de
        inc     hl
        inc     hl
        inc     hl                      ; skip env/noise globals -> cell A
        call    put_cell
        ld      a,G_VBAR
        call    put_char_adv
        call    put_cell
        ld      a,G_VBAR
        call    put_char_adv
        call    put_cell
        ; --- attributes
        pop     hl
        ld      a,(cur_prow)
        ld      c,a
        ld      a,(cur_row)
        cp      c
        jr      z,.cursor_row
        ld      a,c
        and     3
        ld      a,A_ROWNUM
        ld      b,A_CELL
        jr      nz,.paint
        ld      a,A_ROWNUM_B
        ld      b,A_CELL_B
.paint:
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),A_RULE
        inc     hl
        ld      a,b
        jp      paint_cells
.beyond:
        ; rows past the pattern length: dim row number, nothing else
        ld      a,c
        call    put_dec2
        ld      a,G_VBAR
        call    put_char_adv
        ld      b,9
        call    put_spaces
        ld      a,G_VBAR
        call    put_char_adv
        ld      b,9
        call    put_spaces
        ld      a,G_VBAR
        call    put_char_adv
        ld      b,9
        call    put_spaces
        pop     hl
        ld      a,A_DIM
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),A_RULE
        inc     hl
        ld      a,A_BLACK
        jp      paint_cells
.cursor_row:
        ld      a,A_CURROW
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),A_RULE
        inc     hl
        push    hl
        ld      a,A_CURROW
        call    paint_cells
        pop     hl                      ; HL = attrs col 3
        ld      a,(cur_chan)
        ld      b,a
        add     a,a
        add     a,a
        add     a,a
        add     a,b
        add     a,b                     ; chan*10
        ld      c,a
        ld      a,(cur_field)
        push    hl
        ld      hl,field_ofs
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)
        pop     hl
        add     a,c
        ld      c,a
        ld      b,0
        add     hl,bc
        ld      a,(cur_field)
        or      a
        ld      a,A_FIELD
        ld      (hl),a
        ret     nz
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
        ret

; wp_row_addr: A = row -> HL = WP_BASE + row*24
wp_row_addr:
        ld      l,a
        ld      h,0
        add     hl,hl                   ; *2
        add     hl,hl                   ; *4
        ld      d,h
        ld      e,l
        add     hl,hl                   ; *8
        add     hl,de                   ; *12
        add     hl,hl                   ; *24
        ld      de,WP_BASE
        add     hl,de
        ret

; wp_cell_addr: A = row, C = chan -> HL = cell address
wp_cell_addr:
        call    wp_row_addr
        inc     hl
        inc     hl
        inc     hl
        ld      a,c
        add     a,a
        add     a,a
        add     a,a                     ; *8
        sub     c                       ; *7
        ld      e,a
        ld      d,0
        add     hl,de
        ret

; cursor_cell: HL -> cell under the cursor
cursor_cell:
        ld      a,(cur_chan)
        ld      c,a
        ld      a,(cur_row)
        jr      wp_cell_addr

; =============================================================================
; Detail row 21:  Sm.. Or. Vl. En. EP.... Nz.. L..
; =============================================================================
draw_detail:
        call    cursor_cell
        push    hl
        ld      a,R_DETAIL
        ld      c,2
        call    scr_addr
        pop     hl
        inc     hl
        ld      a,(hl)                  ; smp|flags
        ld      c,a
        and     $1F
        jr      z,.smpdots
        call    put_hex2
        jr      .orn
.smpdots:
        ld      a,'.'
        call    put_char_adv
        call    put_char_adv
.orn:   inc     hl
        ld      a,R_DETAIL
        push    hl
        push    bc
        ld      c,7
        call    scr_addr
        pop     bc
        pop     hl
        bit     5,c
        ld      a,(hl)
        and     $0F
        jr      nz,.ornhex
        bit     5,c
        jr      nz,.ornhex
        ld      a,'.'
        call    put_char_adv
        jr      .env
.ornhex: call   put_hex1
.env:   ld      a,R_DETAIL
        push    hl
        ld      c,15
        call    scr_addr
        pop     hl
        ld      a,(hl)                  ; env<<4|orn
        rrca
        rrca
        rrca
        rrca
        and     $0F
        jr      z,.envdot
        cp      ENV_OFF
        jr      nz,.envhex
        ld      a,'0'
        call    put_char_adv
        jr      .vol
.envhex: call   put_hex1
        jr      .vol
.envdot: ld     a,'.'
        call    put_char_adv
.vol:   inc     hl
        ld      a,R_DETAIL
        push    hl
        ld      c,11
        call    scr_addr
        pop     hl
        ld      a,(hl)
        rrca
        rrca
        rrca
        rrca
        call    put_dot_or_hex1
        ; row globals: EP at col 20 (4 hex), Nz at col 27 (2), L at col 30 (2)
        ld      a,(cur_row)
        call    wp_row_addr
        push    hl
        ld      a,R_DETAIL
        ld      c,19
        call    scr_addr
        pop     hl
        ld      a,(hl)
        inc     hl
        or      (hl)
        jr      z,.epdots
        dec     hl
        ld      a,(hl)
        call    put_hex2
        inc     hl
        ld      a,(hl)
        call    put_hex2
        jr      .nz
.epdots:
        ld      a,'.'
        call    put_char_adv
        call    put_char_adv
        call    put_char_adv
        call    put_char_adv
.nz:    inc     hl
        ld      a,R_DETAIL
        push    hl
        ld      c,26
        call    scr_addr
        pop     hl
        ld      a,(hl)
        cp      NZ_NONE
        jr      z,.nzdots
        call    put_hex2
        jr      .len
.nzdots:
        ld      a,'.'
        call    put_char_adv
        call    put_char_adv
.len:   ld      a,R_DETAIL
        ld      c,30
        call    scr_addr
        ld      a,(wp_len)
        jp      put_dec2

; =============================================================================
; Row 22: Free nnnnn  Pos p0 p1 [p2] p3 p4   (window of 5 positions)
; =============================================================================
draw_free_pos:
        ld      a,R_FREE
        ld      c,5
        call    scr_addr
        ld      hl,(free_bytes)
        call    put_dec5
        ; position window: start = cur_pos-2 clamped to 0
        ld      a,(cur_pos)
        sub     2
        jr      nc,.ok
        xor     a
.ok:    ld      (pos_win),a
        ld      a,R_FREE
        ld      c,17
        call    scr_addr
        ld      a,(pos_win)
        ld      b,5
.p:     push    bc
        push    af
        ld      c,a
        ld      a,(SLOT_BASE+H_NPOS)
        cp      c
        jr      z,.blank
        jr      c,.blank
        ld      hl,SLOT_BASE+H_POSLIST
        ld      b,0
        add     hl,bc
        ld      a,(hl)
        call    div3
        call    put_dec2
        jr      .sp
.blank: ld      a,' '
        call    put_char_adv
        call    put_char_adv
.sp:    inc     e
        pop     af
        inc     a
        pop     bc
        djnz    .p
        ; attributes: labels cyan, current position highlighted
        ld      bc,(R_FREE<<8)|17
        ld      e,15
        ld      a,A_LABEL
        call    fill_attr
        ld      a,(cur_pos)
        ld      hl,pos_win
        sub     (hl)                    ; index within window 0..4
        cp      5
        ret     nc
        add     a,a
        ld      c,a
        add     a,a
        add     a,c                     ; *6? no: each slot is 3 cols -> *3
        srl     a                       ; (a*2*2 + a*2)/2 = a*3
        add     a,17
        ld      c,a
        ld      b,R_FREE
        ld      e,2
        ld      a,A_POSCUR
        jp      fill_attr

; div3: A = A / 3 (0..255)
div3:
        ld      c,0
.l:     cp      3
        jr      c,.done
        sub     3
        inc     c
        jr      .l
.done:  ld      a,c
        ret

; Repaint everything from the model
redraw_all:
        call    cls
        call    draw_chrome
redraw_dynamic:
        call    draw_info
        call    draw_grid
        call    draw_detail
        jp      draw_free_pos
