; =============================================================================
; dir.asm -- start screen, tape scan + directory, load, save, text prompt
;
; Directory entry (DIR_ENTSZ = 14 bytes): name[10], len(2), fmt(1), pad(1)
; fmt: 3 = PT3 (ProTracker 3.x / Vortex Tracker export), 2 = other (PT2?)
; =============================================================================

; ---- start screen (no song loaded): S scan / N new / Q quit -------------------
; Returns with a song in the slot and song_init done (via new_song or a load).
screen_start:
        call    cls
        ld      a,A_VALUE
        ld      (hot_attr),a
        ld      bc,(4<<8)|10
        ld      hl,s_splash1
        ld      a,A_VALUE
        call    print_at
        ld      bc,(6<<8)|3
        ld      hl,s_splash2
        ld      a,A_LABEL
        call    print_at
        ld      bc,(8<<8)|3
        ld      hl,s_splash3
        ld      a,A_MENU_TXT
        call    print_at
        ld      a,A_MENU_HOT
        ld      (hot_attr),a
        ld      bc,(10<<8)|3
        ld      hl,s_start_keys
        ld      a,A_MENU_TXT
        call    print_at
        ld      bc,(12<<8)|3
        ld      hl,s_start_keys2
        ld      a,A_MENU_TXT
        call    print_at
        call    kb_wait_none
.w:     call    kb_wait_key
        call    kb_letter_edge
        cp      'N'
        jp      z,new_song              ; (returns after song_init)
        cp      'Q'
        jp      z,quit_to_basic
        cp      'S'
        jr      nz,.w
        call    kb_wait_none
        call    scan_tape
        call    screen_directory        ; returns only when a song is loaded
        ret

; ---- tape scan -----------------------------------------------------------------
scan_tape:
        call    cls
        ld      bc,(1<<8)|0
        ld      hl,s_dir_title
        ld      a,A_VALUE
        call    print_at
        ld      bc,(2<<8)|0
        ld      hl,s_scan_hint
        ld      a,A_LABEL
        call    print_at
        ld      hl,s_hint_scan
        call    draw_hint
        xor     a
        ld      (dir_count),a
.loop:
        ld      a,(dir_count)
        cp      DIR_MAX
        jr      nc,.done
        call    tape_read_header
        jr      z,.done                 ; error / BREAK / tape ended
        ld      a,(TAPE_HDR)
        cp      3
        jr      z,.code
        call    tape_consume            ; not a CODE block: skip its data
        jr      .loop
.code:  call    tape_read_song          ; A: 1 loaded / 0 skipped (too big) / $FF error
        cp      1
        jr      z,.loaded
        or      a
        jr      z,.loop
        jr      .done
.loaded:
        ; duplicate name = the tape looped (emulators) -> stop
        ld      a,(dir_count)
        or      a
        jr      z,.add
        ld      b,a
        ld      hl,DIR_BUF
.dup:   push    bc
        push    hl
        call    tape_hdr_name_eq
        pop     hl
        pop     bc
        jr      z,.done
        ld      de,DIR_ENTSZ
        add     hl,de
        djnz    .dup
.add:   ld      a,(dir_count)
        call    dir_entry_addr          ; HL -> new entry
        ex      de,hl
        ld      hl,TAPE_HDR+1
        ld      bc,10
        ldir                            ; name
        ld      hl,(TAPE_HDR+11)
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; length
        inc     hl
        push    hl
        call    slot_has_song           ; (clobbers HL)
        pop     hl
        ld      a,3
        jr      z,.fmt
        ld      a,2
.fmt:   ld      (hl),a
        ld      a,(dir_count)
        call    draw_dir_entry
        ld      hl,dir_count
        inc     (hl)
        jr      .loop
.done:  ret

; dir_entry_addr: A = index -> HL = DIR_BUF + A*14
dir_entry_addr:
        ld      l,a
        ld      h,0
        add     hl,hl                   ; *2
        ld      d,h
        ld      e,l
        add     hl,hl                   ; *4
        add     hl,hl                   ; *8
        add     hl,de                   ; *10
        add     hl,de                   ; *12
        add     hl,de                   ; *14
        ld      de,DIR_BUF
        add     hl,de
        ret

; draw_dir_entry: A = index -> row 4+index: "n  T  NAME......  nnnnn"
draw_dir_entry:
        ld      (de_idx),a
        call    dir_entry_addr
        ld      (de_ent),hl
        ld      a,(de_idx)
        add     a,4
        ld      c,1
        call    scr_addr                ; DE = pixels at col 1
        ld      a,(de_idx)
        inc     a
        add     a,'0'
        call    put_char_adv
        inc     e
        inc     e                       ; col 4
        ld      hl,(de_ent)
        push    hl
        ld      bc,12
        add     hl,bc
        ld      a,(hl)                  ; fmt
        cp      3
        ld      a,'3'
        jr      z,.f
        ld      a,'?'
.f:     call    put_char_adv
        inc     e
        inc     e                       ; col 7
        pop     hl                      ; name
        ld      b,10
.nm:    ld      a,(hl)
        cp      32
        jr      c,.q
        cp      127
        jr      c,.ok
.q:     ld      a,'?'
.ok:    call    put_char_adv
        inc     hl
        djnz    .nm
        ld      c,(hl)
        inc     hl
        ld      b,(hl)                  ; BC = length
        ld      a,(de_idx)
        add     a,4
        push    bc
        ld      c,19
        call    scr_addr
        pop     hl
        call    put_dec5                ; cols 19-23
        ld      a,(de_idx)
        add     a,4
        ld      b,a
        ld      c,0
        ld      e,32
        ld      a,A_MENU_TXT
        call    fill_attr
        ld      a,(de_idx)
        add     a,4
        ld      b,a
        ld      c,1
        ld      e,1
        ld      a,A_MENU_HOT
        jp      fill_attr

; ---- directory screen ------------------------------------------------------------
; Keys: 1-9 load, R rescan, N new song, Q back to start screen.
; Returns when a song is in the slot (song_init done).
screen_directory:
        ld      bc,(2<<8)|0
        ld      hl,s_dir_sub
        ld      a,A_LABEL
        call    print_at
        ld      a,(dir_count)
        or      a
        jr      nz,.hint
        ld      bc,(4<<8)|1
        ld      hl,s_dir_none
        ld      a,A_MENU_TXT
        call    print_at
.hint:  ld      hl,s_hint_dir
        call    draw_hint
        call    kb_wait_none
.w:     call    kb_wait_key
        call    kb_letter_edge
        cp      'R'
        jr      z,.rescan
        cp      'N'
        jp      z,new_song
        cp      'Q'
        jr      z,.back
        sub     '1'
        cp      9
        jr      nc,.w
        ld      hl,dir_count
        cp      (hl)
        jr      nc,.w
        call    load_entry
        ret     nz                      ; loaded
        jr      .hint                   ; failed: message already shown, stay
.rescan:
        call    kb_wait_none
        call    scan_tape
        jr      screen_directory
.back:  call    kb_wait_none
        jp      screen_start

; load_entry: A = directory index. Prompts to rewind, then reads blocks until
; the name matches. On success song_init runs and NZ is returned.
load_entry:
        ld      (ld_idx),a
        call    dir_entry_addr
        ld      (ld_entry),hl
        ld      hl,s_msg_rewind
        call    draw_message
        call    kb_wait_none
        call    kb_wait_key
        call    kb_letter_edge
        cp      'Q'
        jr      z,.cancel
        ld      hl,s_hint_loading
        call    draw_hint
        call    kb_wait_none
.loop:  call    tape_read_header
        jr      z,.fail
        ld      a,(TAPE_HDR)
        cp      3
        jr      nz,.skip
        ld      hl,(ld_entry)
        call    tape_hdr_name_eq
        jr      nz,.skip
        call    tape_read_song
        cp      1
        jr      nz,.fail
        call    slot_has_song           ; PT3 (or Vortex export) only -- no PT2 decoder yet
        jr      nz,.notpt3
        ; remember the name for Save (first 8 chars)
        ld      hl,(ld_entry)
        ld      de,save_name
        ld      bc,8
        ldir
        call    song_init
        ld      a,1
        or      a
        ret
.skip:  call    tape_consume
        jr      .loop
.notpt3: ld     hl,s_msg_notpt3
        jr      .msg
.fail:  ld      hl,s_msg_loadfail
.msg:   call    draw_message
        call    kb_wait_none
        call    kb_wait_key
.cancel: call   kb_wait_none
        xor     a
        ret

; ---- editor commands: load (SYM+D) and save (SYM+S) ----------------------------
cmd_load:
        ld      hl,s_msg_confirm_load
        call    confirm
        jr      nz,.no
        call    scan_tape
        call    screen_directory
        call    redraw_all
        jp      editor_loop
.no:    ld      hl,s_hint_edit
        call    draw_hint
        jp      editor_loop

cmd_save:
        call    commit_pattern
        jp      c,commit_failed_loop
        call    dedup_streams           ; identical channel streams become shared
        ld      a,(wp_pat)
        call    wp_load
        call    update_free
        call    cls
        ld      bc,(1<<8)|0
        ld      hl,s_save_title
        ld      a,A_VALUE
        call    print_at
        ld      bc,(4<<8)|0
        ld      hl,s_save_l1
        ld      a,A_LABEL
        call    print_at
        ld      bc,(5<<8)|0
        ld      hl,s_save_l2
        ld      a,A_LABEL
        call    print_at
        ; version suffix shown after the name field
        ld      a,8
        ld      c,4+8+1
        call    scr_addr
        ld      a,(save_version)
        call    put_hex2
        ld      bc,(8<<8)|13
        ld      e,2
        ld      a,A_MENU_TXT
        call    fill_attr
        ld      bc,(11<<8)|0
        ld      hl,s_save_l3
        ld      a,A_LABEL
        call    print_at
        ld      a,11
        ld      c,7
        call    scr_addr
        ld      hl,(song_len)
        call    put_dec5
        ld      bc,(11<<8)|7
        ld      e,5
        ld      a,A_VALUE
        call    fill_attr
        ld      hl,s_hint_text
        call    draw_hint
        ; edit the 8-char name at row 8 col 4
        ld      hl,save_name
        ld      b,8
        ld      a,8
        ld      (pt_row),a
        ld      a,4
        ld      (pt_col),a
        call    prompt_text
        jr      c,.done                 ; cancelled
        ld      hl,s_msg_record
        call    draw_message
        call    kb_wait_none
        call    kb_wait_key
        call    kb_letter_edge
        cp      'Q'
        jr      z,.done
        ld      hl,s_hint_saving
        call    draw_hint
        call    kb_wait_none
        ld      a,2
        out     ($FE),a                 ; red border while writing
        call    tape_save_song
        push    af
        xor     a
        out     ($FE),a
        pop     af
        ld      hl,s_msg_savefail
        jr      z,.msg
        xor     a
        ld      (song_mod),a            ; on tape now
        ld      hl,s_msg_saved
.msg:   call    draw_message
        call    kb_wait_none
        call    kb_wait_key
.done:  call    kb_wait_none
        call    redraw_all
        jp      editor_loop

commit_failed_loop:
        call    commit_failed
        jp      editor_loop

; ---- prompt_text: in-place text field editor ------------------------------------
; HL = buffer (B chars, space padded), (pt_row)/(pt_col) = screen position.
; Letters/digits/space type and advance; CAPS+0 backspaces; CAPS+5/8 move;
; ENTER accepts (CY clear); CAPS+SPACE (BREAK) cancels (CY set).
prompt_text:
        ld      (pt_buf),hl
        ld      a,b
        ld      (pt_len),a
        ; cursor after the last non-space character (capped to the last cell)
        ld      c,0
        ld      e,0
.scan:  ld      a,(hl)
        cp      ' '
        jr      z,.sp
        ld      a,c
        inc     a
        ld      e,a
.sp:    inc     hl
        inc     c
        ld      a,c
        cp      b
        jr      nz,.scan
        ld      a,e
        cp      b
        jr      c,.cur
        dec     a
.cur:   ld      (pt_pos),a
        call    pt_draw
        call    kb_wait_none
.loop:  halt
        call    kb_scan
        call    kb_caps
        jr      z,.plain
        ld      a,(kb_edge+KR_SPACE)
        bit     0,a
        jr      nz,.cancel              ; BREAK
        ld      a,(kb_edge+KR_09876)
        bit     0,a                     ; DELETE
        jr      nz,.del
        bit     2,a                     ; 8 = right
        jr      nz,.right
        ld      a,(kb_edge+KR_12345)
        bit     4,a                     ; 5 = left
        jr      nz,.left
        jr      .loop
.plain: call    kb_letter_edge
        or      a
        jr      z,.loop
        cp      13
        jr      z,.accept
        ; type A at the cursor and advance
        ld      hl,(pt_buf)
        ld      c,a
        ld      a,(pt_pos)
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      (hl),c
        ld      a,(pt_pos)
        inc     a
        ld      hl,pt_len
        cp      (hl)
        jr      nc,.redraw
        ld      (pt_pos),a
.redraw: call   pt_draw
        jr      .loop
.del:   ld      hl,(pt_buf)
        ld      a,(pt_pos)
        add     a,l
        ld      l,a
        jr      nc,.nc2
        inc     h
.nc2:   ld      a,(hl)
        cp      ' '
        jr      nz,.clr                 ; clear the cell under the cursor
        ld      a,(pt_pos)
        or      a
        jr      z,.redraw
        dec     a
        ld      (pt_pos),a
        dec     hl
.clr:   ld      (hl),' '
        jr      .redraw
.right: ld      a,(pt_pos)
        inc     a
        ld      hl,pt_len
        cp      (hl)
        jr      nc,.loop
        ld      (pt_pos),a
        jr      .redraw
.left:  ld      a,(pt_pos)
        or      a
        jp      z,.loop
        dec     a
        ld      (pt_pos),a
        jr      .redraw
.accept: call   kb_wait_none
        or      a                       ; CY clear
        ret
.cancel: call   kb_wait_none
        scf
        ret

; pt_draw: draw the field with the cursor cell inverted
pt_draw:
        ld      a,(pt_row)
        ld      c,a
        ld      a,(pt_col)
        ld      c,a
        ld      a,(pt_row)
        call    scr_addr                ; DE pixels, HL attrs
        push    hl
        ld      hl,(pt_buf)
        ld      a,(pt_len)
        ld      b,a
.g:     ld      a,(hl)
        call    put_char_adv
        inc     hl
        djnz    .g
        pop     hl
        ld      a,(pt_len)
        ld      b,a
        ld      c,0
.a:     ld      a,(pt_pos)
        cp      c
        ld      a,A_VALUE
        jr      nz,.n
        ld      a,A_FIELD
.n:     ld      (hl),a
        inc     hl
        inc     c
        djnz    .a
        ret
