; =============================================================================
; editor.asm -- the pattern editor loop: field-aware editing, cursor, rows,
; position navigation and the SYMBOL-SHIFT command set.
; =============================================================================

editor_loop:
        halt
        call    kb_scan
        call    kb_sym
        jp      nz,ed_sym
        call    kb_caps
        jp      nz,ed_caps
        call    kb_letter_edge
        or      a
        jr      z,editor_loop
        call    ed_plain
        jr      editor_loop

; ---------------------------------------------------------------------------
; CAPS + key: cursor (auto-repeat), CAPS+1 insert row, CAPS+0 delete row
; ---------------------------------------------------------------------------
ed_caps:
        ; (every handler clobbers A: reload the edge byte before each test)
        ld      a,(kb_edge+KR_12345)
        bit     4,a                     ; 5 = left
        call    nz,cursor_left
        ld      a,(kb_edge+KR_12345)
        bit     0,a                     ; 1 = EDIT -> insert row
        call    nz,row_insert
        ld      a,(kb_edge+KR_09876)
        bit     4,a                     ; 6 = down
        call    nz,cursor_down
        ld      a,(kb_edge+KR_09876)
        bit     3,a                     ; 7 = up
        call    nz,cursor_up
        ld      a,(kb_edge+KR_09876)
        bit     2,a                     ; 8 = right
        call    nz,cursor_right
        ld      a,(kb_edge+KR_09876)
        bit     0,a                     ; 0 = DELETE -> delete row
        call    nz,row_delete
        jp      editor_loop

cursor_up:
        ld      a,(cur_row)
        or      a
        ret     z
        dec     a
        ld      (cur_row),a
        jp      redraw_cursor
cursor_down:
        ld      a,(cur_row)
        inc     a
        ld      hl,wp_len
        cp      (hl)
        ret     nc
        ld      (cur_row),a
        jp      redraw_cursor
cursor_left:
        ld      a,(cur_field)
        or      a
        jr      z,.prev
        dec     a
        ld      (cur_field),a
        jp      redraw_cursor
.prev:  ld      a,(cur_chan)
        or      a
        ret     z
        dec     a
        ld      (cur_chan),a
        ld      a,5
        ld      (cur_field),a
        jp      redraw_cursor
cursor_right:
        ld      a,(cur_field)
        cp      5
        jr      z,.next
        inc     a
        ld      (cur_field),a
        jp      redraw_cursor
.next:  ld      a,(cur_chan)
        cp      2
        ret     z
        inc     a
        ld      (cur_chan),a
        xor     a
        ld      (cur_field),a
        jp      redraw_cursor

redraw_cursor:
        call    draw_grid
        jp      draw_detail

; ---------------------------------------------------------------------------
; Plain key (A = ASCII): field-aware entry
; ---------------------------------------------------------------------------
ed_plain:
        cp      13
        jp      z,ed_rest
        cp      32
        jp      z,ed_clear
        ld      c,a
        ld      a,(cur_field)
        or      a
        jr      z,ed_note_key
        cp      1
        jp      z,ed_sample_key
        cp      2
        jp      z,ed_env_key
        cp      3
        jp      z,ed_orn_key
        cp      4
        jp      z,ed_vol_key
        ; field 5 = command: parameters are edited in a later phase
        ld      hl,s_msg_later
        jp      flash_message

; --- note field: piano letters, digits 1..8 = octave -----------------------
ed_note_key:
        ld      a,c
        cp      '1'
        jr      c,.letter
        cp      '9'
        jr      nc,.letter
        sub     '0'
        ld      (octave),a
        call    cursor_cell
        ld      a,(hl)
        cp      96
        jr      nc,.oct_only            ; no real note under the cursor
        ; retune existing note to the new octave
        call    semitone_of
        call    note_from_semi
        ld      (hl),a
        call    mark_dirty
        call    draw_grid
.oct_only:
        jp      draw_info
.letter:
        ld      a,c
        sub     'A'
        cp      26
        ret     nc
        ld      hl,piano_map
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)
        cp      $FF
        ret     z                       ; not a piano key
        call    note_from_semi
        ld      (ed_val),a              ; (cursor_cell sets C = channel: keep the note elsewhere)
        call    cursor_cell
        ld      a,(ed_val)
        ld      (hl),a
        inc     hl
        ld      a,(hl)
        and     $1F
        jr      nz,.hassmp
        ld      a,(hl)
        and     $E0
        ld      c,a
        ld      a,(cur_sample)
        or      c
        ld      (hl),a                  ; give the new note the current sample
.hassmp:
        call    mark_dirty
        jp      ed_advance

; semitone_of: A = note 0..95 -> A = A mod 12
semitone_of:
        ld      c,0
.l:     cp      12
        ret     c
        sub     12
        jr      .l
; note_from_semi: A = semitone -> A = (octave-1)*12 + semitone
note_from_semi:
        ld      c,a
        ld      a,(octave)
        dec     a
        ld      b,a
        add     a,a
        add     a,b                     ; *3
        add     a,a                     ; *6
        add     a,a                     ; *12
        add     a,c
        ret

ed_rest:
        call    cursor_cell
        ld      (hl),NOTE_REST
        call    mark_dirty
        jp      ed_advance

; ed_advance: step the cursor one row down after a note/rest and redraw
ed_advance:
        ld      a,(cur_row)
        inc     a
        ld      hl,wp_len
        cp      (hl)
        jr      nc,.stay
        ld      (cur_row),a
.stay:  jp      redraw_edit

; --- SPACE: clear the cell (note field) or just the field --------------------
ed_clear:
        call    cursor_cell
        ld      a,(cur_field)
        or      a
        jr      nz,.field
        ld      (hl),NOTE_NONE
        inc     hl
        ld      b,6
        xor     a
.z:     ld      (hl),a
        inc     hl
        djnz    .z
        jr      .done
.field: cp      1
        jr      nz,.f2
        inc     hl
        ld      a,(hl)
        and     $E0
        ld      (hl),a
        jr      .norm
.f2:    cp      2
        jr      nz,.f3
        inc     hl
        inc     hl
        ld      a,(hl)
        and     $0F
        ld      (hl),a
        jr      .norm
.f3:    cp      3
        jr      nz,.f4
        inc     hl
        res     5,(hl)
        inc     hl
        ld      a,(hl)
        and     $F0
        ld      (hl),a
        jr      .norm
.f4:    cp      4
        jr      nz,.f5
        inc     hl
        inc     hl
        inc     hl
        ld      a,(hl)
        and     $0F
        ld      (hl),a
        jr      .norm
.f5:    inc     hl
        inc     hl
        inc     hl
        ld      a,(hl)
        and     $F0
        ld      (hl),a
        inc     hl
        xor     a
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a
.norm:  call    cell_normalise
.done:  call    mark_dirty
        jp      redraw_edit

; cell_normalise: an "empty event" with no fields left becomes "no event"
cell_normalise:
        call    cursor_cell
        ld      a,(hl)
        cp      NOTE_EMPTY
        ret     nz
        call    has_event_fields
        ret     nz
        ld      (hl),NOTE_NONE
        ret
; has_event_fields: HL -> cell; NZ if any field set (ignores the note byte)
has_event_fields:
        push    hl
        inc     hl
        ld      a,(hl)
        and     $3F
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        pop     hl
        ret

; cell_make_event: a field edit on a no-event row turns it into an empty event
cell_make_event:
        call    cursor_cell
        ld      a,(hl)
        cp      NOTE_NONE
        ret     nz
        ld      (hl),NOTE_EMPTY
        ret

; --- sample field: base-32 char -> 0..31 -----------------------------------
ed_sample_key:
        ld      a,c
        call    base32_value
        ret     c
        ld      (ed_val),a
        call    cell_make_event
        call    cursor_cell
        inc     hl
        ld      a,(hl)
        and     $E0
        ld      c,a
        ld      a,(ed_val)
        or      c
        ld      (hl),a
        ld      a,(ed_val)
        or      a
        jr      z,.nocur
        ld      (cur_sample),a
.nocur: call    cell_normalise
        call    mark_dirty
        jp      redraw_edit

; --- envelope field: 0 = off, 1..E = shape ----------------------------------
ed_env_key:
        ld      a,c
        call    hex_value
        ret     c
        cp      15
        ret     z                       ; F is not a PT3 envelope shape
        or      a
        jr      nz,.shape
        ld      a,ENV_OFF
.shape: rlca
        rlca
        rlca
        rlca
        ld      (ed_val),a
        call    cell_make_event
        call    cursor_cell
        inc     hl
        inc     hl
        ld      a,(hl)
        and     $0F
        ld      c,a
        ld      a,(ed_val)
        or      c
        ld      (hl),a
        call    mark_dirty
        jp      redraw_edit

; --- ornament field: hex 0..F --------------------------------------------------
ed_orn_key:
        ld      a,c
        call    hex_value
        ret     c
        ld      (ed_val),a
        call    cell_make_event
        call    cursor_cell
        inc     hl
        set     5,(hl)
        inc     hl
        ld      a,(hl)
        and     $F0
        ld      c,a
        ld      a,(ed_val)
        or      c
        ld      (hl),a
        call    mark_dirty
        jp      redraw_edit

; --- volume field: hex 1..F (0 clears) ----------------------------------------
ed_vol_key:
        ld      a,c
        call    hex_value
        ret     c
        rlca
        rlca
        rlca
        rlca
        ld      (ed_val),a
        call    cell_make_event
        call    cursor_cell
        inc     hl
        inc     hl
        inc     hl
        ld      a,(hl)
        and     $0F
        ld      c,a
        ld      a,(ed_val)
        or      c
        ld      (hl),a
        call    cell_normalise
        call    mark_dirty
        jp      redraw_edit

; hex_value: A = ASCII -> A = 0..15, CY set if not a hex digit
hex_value:
        sub     '0'
        cp      10
        jr      c,.ok
        sub     'A'-'0'
        cp      6
        jr      c,.let
        scf                             ; not 0-9 / A-F
        ret
.let:   add     a,10
.ok:    or      a                       ; CY clear = valid
        ret

; base32_value: A = ASCII -> A = 0..31, CY set if invalid
base32_value:
        sub     '0'
        cp      10
        jr      c,.ok
        sub     'A'-'0'
        cp      22
        jr      c,.let
        scf
        ret
.let:   add     a,10
.ok:    or      a
        ret

; ---------------------------------------------------------------------------
; Row insert / delete (all three channels + row globals)
; ---------------------------------------------------------------------------
row_insert:
        ld      a,(wp_len)
        ld      hl,cur_row
        sub     (hl)
        cp      2
        jr      c,.blankonly            ; inserting on the last row just blanks it
        dec     a                       ; rows to move = len-1-cur
        ld      l,a
        ld      h,0
        call    mul24                   ; HL = bytes to move
        push    hl
        ld      a,(wp_len)
        dec     a
        call    wp_row_addr             ; HL = last row (destroyed)
        ld      de,WP_ROWSZ-1
        add     hl,de
        ex      de,hl                   ; DE = dest = end of last row
        ld      hl,-WP_ROWSZ
        add     hl,de                   ; HL = source = end of second-to-last row
        pop     bc
        lddr
.blankonly:
        ld      a,(cur_row)
        call    wp_row_addr
        call    wp_blank_row
        call    mark_dirty
        jp      redraw_edit

row_delete:
        ld      a,(wp_len)
        ld      hl,cur_row
        sub     (hl)
        cp      2
        jr      c,.blanklast
        dec     a
        ld      l,a
        ld      h,0
        call    mul24
        push    hl
        ld      a,(cur_row)
        call    wp_row_addr
        ld      d,h
        ld      e,l                     ; DE = dest = cursor row
        ld      bc,WP_ROWSZ
        add     hl,bc                   ; HL = source = next row
        pop     bc
        ldir
.blanklast:
        ld      a,(wp_len)
        dec     a
        call    wp_row_addr
        call    wp_blank_row
        call    mark_dirty
        jp      redraw_edit

; mul24: HL = HL * 24 (HL < 64)
mul24:
        add     hl,hl                   ; *2
        add     hl,hl                   ; *4
        ld      d,h
        ld      e,l
        add     hl,hl                   ; *8
        add     hl,de                   ; *12
        add     hl,hl                   ; *24
        ret

; ---------------------------------------------------------------------------
; Bookkeeping after an edit
; ---------------------------------------------------------------------------
mark_dirty:
        ld      a,1
        ld      (wp_dirty),a
        ret

redraw_edit:
        call    update_free
        call    draw_grid
        call    draw_detail
        jp      draw_free_pos

; ---------------------------------------------------------------------------
; SYMBOL SHIFT + letter: the menu-strip commands
; ---------------------------------------------------------------------------
ed_sym:
        call    kb_letter_edge
        or      a
        jp      z,editor_loop
        cp      'A'
        jp      z,cmd_play
        cp      'L'
        jp      z,cmd_loop
        cp      'S'
        jp      z,cmd_save
        cp      'D'
        jp      z,cmd_load
        cp      'N'
        jp      z,cmd_new
        cp      'Q'
        jp      z,cmd_quit
        cp      'I'
        jp      z,cmd_insert
        cp      'X'
        jp      z,cmd_delete
        cp      'Z'
        jp      z,cmd_clear_chan
        cp      'O'
        jp      z,cmd_prev_pos
        cp      'P'
        jp      z,cmd_next_pos
        cp      'F'
        jp      z,cmd_arrange
        cp      'G'
        jp      z,cmd_info
        cp      'H'
        jp      z,cmd_help
        cp      'E'
        jp      z,cmd_sample
        cp      'R'
        jp      z,cmd_ornament
        ld      hl,s_msg_later
        call    flash_message
        jp      editor_loop

cmd_play:
        call    play_song
        call    redraw_dynamic
        jp      editor_loop
cmd_loop:
        call    play_loop_pattern
        call    redraw_dynamic
        jp      editor_loop
cmd_insert:
        call    row_insert
        jp      editor_loop
cmd_delete:
        call    row_delete
        jp      editor_loop
cmd_help:
        call    show_help
        call    redraw_all
        jp      editor_loop

cmd_new:
        ld      hl,s_msg_confirm_new
        call    confirm
        jr      nz,.no
        call    new_song
        call    redraw_all
.no:    ld      hl,s_hint_edit
        call    draw_hint
        jp      editor_loop

cmd_quit:
        ld      hl,s_msg_confirm_quit
        call    confirm
        jr      nz,.no
        jp      quit_to_basic
.no:    ld      hl,s_hint_edit
        call    draw_hint
        jp      editor_loop

cmd_clear_chan:
        ld      hl,s_msg_confirm_clr
        call    confirm
        jr      nz,.no
        ld      a,(cur_chan)
        ld      c,a
        xor     a
        ld      b,WP_ROWS
.l:     push    bc
        push    af
        call    wp_cell_addr
        ld      (hl),NOTE_NONE
        inc     hl
        xor     a
        ld      b,6
.z:     ld      (hl),a
        inc     hl
        djnz    .z
        pop     af
        pop     bc
        inc     a
        djnz    .l
        call    mark_dirty
        call    redraw_edit
.no:    ld      hl,s_hint_edit
        call    draw_hint
        jp      editor_loop

cmd_prev_pos:
        ld      a,(cur_pos)
        or      a
        jp      z,editor_loop
        dec     a
        jr      goto_pos
cmd_next_pos:
        ld      a,(cur_pos)
        inc     a
        ld      hl,SLOT_BASE+H_NPOS
        cp      (hl)
        jp      nc,editor_loop
goto_pos:
        push    af
        call    commit_pattern
        jr      nc,.ok
        pop     af
        call    commit_failed
        jp      editor_loop
.ok:    pop     af
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
        call    redraw_dynamic
        jp      editor_loop

; ---------------------------------------------------------------------------
; Prompts
; ---------------------------------------------------------------------------
; confirm: HL = question -> Z set if the user pressed Y
confirm:
        call    draw_message
        call    kb_wait_none
.w:     call    kb_wait_key
        call    kb_letter_edge
        cp      'Y'
        jr      z,.yes
        cp      'N'
        jr      z,.no
        cp      32
        jr      z,.no
        cp      13
        jr      z,.no
        jr      .w
.yes:   call    kb_wait_none
        xor     a
        ret
.no:    call    kb_wait_none
        or      1
        ret

; flash_message: HL = text; shows it until the next key press, then restores
flash_message:
        call    draw_message
        call    kb_wait_none
        call    kb_wait_key
        ld      hl,s_hint_edit
        jp      draw_hint

; ---------------------------------------------------------------------------
; Help page
; ---------------------------------------------------------------------------
show_help:
        call    cls
        ld      hl,help_text
        ld      b,0
.line:  ld      a,(hl)
        cp      $FF
        jr      z,.wait
        push    bc
        push    hl
        ld      c,0
        ld      a,A_MENU_TXT
        ld      (cur_attr),a
        ld      a,A_MENU_HOT
        ld      (hot_attr),a
        ld      a,(hl)
        cp      '*'
        ld      a,A_MENU_TXT
        jr      nz,.plain
        inc     hl
        ld      a,A_LABEL
.plain: call    print_at
        pop     hl
.skip:  ld      a,(hl)
        inc     hl
        or      a
        jr      nz,.skip
        pop     bc
        inc     b
        jr      .line
.wait:  call    kb_wait_none
        call    kb_wait_key
        jp      kb_wait_none
