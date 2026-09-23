; =============================================================================
; dir.asm -- start screen, tape scan + directory, load, save, text prompt
;
; Directory entry (DIR_ENTSZ = 14 bytes): name[10], len(2), fmt(1), pad(1)
; fmt: 3 = PT3 (ProTracker 3.x / Vortex Tracker export), 2 = PT2, 0 = other
; The directory lives in STAGE (DIR_MAX entries); DIR_VIS rows of it are on
; screen from dir_top, the selected entry (dir_cur) inverted.
; With a TS-PICO (pico.asm) the same scan reads a mounted .tap, or -- after P
; on the start screen -- the SD card's raw .pt3 files served as a tape.
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
        ld      a,(tpi_ok)
        or      a
        jr      z,.keys
        ld      bc,(14<<8)|3
        ld      hl,s_start_keys3
        ld      a,A_MENU_TXT
        call    print_at
        ld      bc,(15<<8)|7
        ld      hl,s_start_bios
        ld      a,A_LABEL
        call    print_at
        ld      a,15
        ld      c,7+17
        call    scr_addr
        ld      a,(tpi_vers)
        call    put_dec2
        ld      bc,(15<<8)|(7+17)
        ld      e,2
        ld      a,A_LABEL
        call    fill_attr
.keys:  call    kb_wait_none
.w:     call    kb_wait_key
        call    kb_letter_edge
        cp      'N'
        jp      z,new_song              ; (returns after song_init)
        cp      'Q'
        jp      z,quit_to_basic
        cp      'P'
        jr      z,.pico
        cp      'S'
        jr      nz,.w
        call    kb_wait_none
        xor     a
        ld      (sd_raw),a              ; a tape (or a .tap on the Pico), not raw files
.scan:  call    scan_tape
        call    screen_directory        ; returns only when a song is loaded
        ret
.pico:  ld      a,(tpi_ok)
        or      a
        jr      z,.w
        call    kb_wait_none
        call    sd_begin                ; SD mode, raw files, first file
        jr      nz,.scan
        call    sd_fail
        jp      screen_start

; ---- tape scan -----------------------------------------------------------------
scan_tape:
        call    cls
        ld      bc,(1<<8)|0
        ld      hl,s_dir_title
        ld      a,(sd_raw)
        or      a
        jr      z,.title
        ld      hl,s_sd_title
.title: ld      a,A_VALUE
        call    print_at
        ld      bc,(2<<8)|0
        ld      hl,s_scan_hint
        ld      a,A_LABEL
        call    print_at
        ld      hl,s_hint_scan
        ld      a,(sd_mode)
        or      a
        jr      z,.hint
        ld      hl,s_hint_scan_sd
.hint:  call    draw_hint
        xor     a
        ld      (dir_count),a
        ld      (dir_top),a
        ld      (dir_cur),a
        ld      a,(sd_mode)
        or      a
        call    nz,sd_rewind            ; the Pico: always from the first block
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
        jp      .done
.loaded:
        ; duplicate name = the tape looped (emulators) -> stop. Not on the Pico: its
        ; sequence ends by itself, and two long file names may share their first
        ; ten characters
        ld      a,(sd_mode)
        or      a
        jr      nz,.add
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
        ld      a,3
        jr      z,.fmt
        call    pt2_detect
        ld      a,2
        jr      z,.fmt
        xor     a
.fmt:   pop     hl
        ld      (hl),a                  ; 3 PT3, 2 PT2, 0 something else
        ld      a,(dir_count)
        cp      DIR_VIS
        call    c,draw_dir_slot         ; (dir_top is 0 while scanning)
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

; draw_dir_list: the DIR_VIS rows from dir_top
draw_dir_list:
        xor     a
.l:     call    draw_dir_slot
        ld      a,(de_idx)
        inc     a
        cp      DIR_VIS
        jr      nz,.l
        ret

; draw_dir_slot: A = screen slot 0..DIR_VIS-1 -> row 4+slot shows entry dir_top+slot
; as "n  T  NAME......  nnnnn" (n = 1-9 on the first nine rows); the selected
; entry's row is inverted; rows past the end are cleared.
draw_dir_slot:
        ld      (de_idx),a
        add     a,4
        ld      b,a
        xor     a
        call    clear_row               ; (rows are redrawn in place while scrolling)
        ld      a,(de_idx)
        ld      hl,dir_top
        add     a,(hl)
        ld      hl,dir_count
        cp      (hl)
        ret     nc                      ; past the end: stays blank
        call    dir_entry_addr
        ld      (de_ent),hl
        ld      a,(de_idx)
        add     a,4
        ld      c,1
        call    scr_addr                ; DE = pixels at col 1
        ld      a,(de_idx)
        cp      9
        ld      a,' '
        jr      nc,.num
        ld      a,(de_idx)
        add     a,'1'
.num:   call    put_char_adv
        inc     e
        inc     e                       ; col 4
        ld      hl,(de_ent)
        push    hl
        ld      bc,12
        add     hl,bc
        ld      a,(hl)                  ; fmt: 3 PT3, 2 PT2, 0 other
        ld      c,a
        ld      a,'?'
        dec     c
        dec     c
        jr      nz,.n2
        ld      a,'2'
.n2:    dec     c
        jr      nz,.f
        ld      a,'3'
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
        ld      hl,dir_top
        add     a,(hl)
        ld      hl,dir_cur
        cp      (hl)
        ld      a,A_MENU_TXT
        jr      nz,.attr
        ld      a,A_FIELD               ; the selected entry
.attr:  ld      c,0
        ld      e,32
        call    .row
        ld      a,A_MENU_HOT
        ld      c,1
        ld      e,1
.row:   push    af
        ld      a,(de_idx)
        add     a,4
        ld      b,a
        pop     af
        jp      fill_attr

; ---- directory screen ------------------------------------------------------------
; Keys: CAPS+6/7 move, ENTER loads the selected entry, 1-9 load a row directly,
; R rescan, N new song, Q back to the start screen.
; Returns when a song is in the slot (song_init done).
screen_directory:
        ld      bc,(2<<8)|0
        ld      hl,s_dir_sub
        ld      a,A_LABEL
        call    print_at
        ld      a,(dir_count)
        or      a
        jr      nz,.list
        ld      bc,(4<<8)|1
        ld      hl,s_dir_none
        ld      a,A_MENU_TXT
        call    print_at
        jr      .hint
.list:  call    draw_dir_list
.hint:  ld      hl,s_hint_dir
        call    draw_hint
        call    kb_wait_none
.w:     call    kb_wait_key
        call    kb_caps
        jr      z,.plain
        ld      a,(kb_edge+KR_09876)
        bit     4,a                     ; 6 = down
        jr      nz,.down
        bit     3,a                     ; 7 = up
        jr      z,.w
        ld      a,(dir_cur)
        or      a
        jr      z,.w
        dec     a
        jr      .move
.down:  ld      a,(dir_cur)
        inc     a
        ld      hl,dir_count
        cp      (hl)
        jr      nc,.w
.move:  ld      (dir_cur),a
        ld      hl,dir_top              ; keep it inside the window
        cp      (hl)
        jr      nc,.below
        ld      (hl),a
        jr      .redraw
.below: sub     (hl)
        cp      DIR_VIS
        jr      c,.redraw
        ld      a,(dir_cur)
        sub     DIR_VIS-1
        ld      (hl),a
.redraw:
        call    draw_dir_list
        jr      .w
.plain: call    kb_letter_edge
        cp      13
        jr      z,.enter
        cp      'R'
        jr      z,.rescan
        cp      'N'
        jr      z,.new
        cp      'Q'
        jr      z,.back
        sub     '1'
        cp      9
        jr      nc,.w
        ld      hl,dir_top
        add     a,(hl)
        jr      .pick
.enter: ld      a,(dir_cur)
.pick:  ld      hl,dir_count
        cp      (hl)
        jr      nc,.w
        ld      (dir_cur),a
        call    load_entry
        ret     nz                      ; loaded
        ld      a,(dir_count)
        or      a
        jr      z,.rescan               ; a failed PT2 conversion overwrote the directory (STAGE)
        jp      .hint                   ; failed: message already shown, stay
.rescan:
        call    kb_wait_none
        call    scan_tape
        jp      screen_directory
.new:   call    sd_end
        jp      new_song
.back:  call    kb_wait_none
        call    sd_end
        jp      screen_start

; load_entry: A = directory index. Prompts to rewind (or rewinds the Pico), then
; reads headers until the song is found -- at most 128 of them, so a looping
; tape without the song cannot hang. A tape is matched by name; the Pico by
; position in its block sequence (the scan and the load both start from a
; REWIND and list the same blocks), because the header of a raw file carries
; only the first ten characters of its name. On success song_init runs, NZ.
load_entry:
        ld      (ld_idx),a
        call    dir_entry_addr
        ld      (ld_entry),hl
        ld      a,(sd_mode)
        or      a
        jr      nz,.sd
        ld      hl,s_msg_rewind
        call    draw_message
        call    kb_wait_none
        call    kb_wait_key
        call    kb_letter_edge
        cp      'Q'
        jp      z,.cancel
        jr      .go
.sd:    call    sd_rewind               ; (if the Pico refuses, the search below just fails)
.go:    ld      hl,s_hint_loading
        call    draw_hint
        call    kb_wait_none
        ld      a,128
        ld      (ld_tries),a
.loop:  ld      hl,ld_tries
        dec     (hl)
        jr      z,.fail
        call    tape_read_header
        jr      z,.fail
        ld      a,(TAPE_HDR)
        cp      3
        jr      nz,.skip
        ld      a,(sd_mode)
        or      a
        jr      z,.byname
        call    tape_hdr_len            ; the Pico: the n-th CODE block that fits the slot
        ld      de,SONG_BUDGET+1
        or      a
        sbc     hl,de
        jr      nc,.skip                ; (too big: the scan did not list it)
        ld      hl,ld_idx
        ld      a,(hl)
        dec     (hl)
        or      a
        jr      nz,.skip
        jr      .take
.byname:
        ld      hl,(ld_entry)
        call    tape_hdr_name_eq
        jr      nz,.skip
.take:  call    tape_read_song
        cp      1
        jr      nz,.fail
        call    slot_has_song           ; PT3 (or Vortex export): edit it as it is
        jr      z,.ok
        call    pt2_detect              ; PT2: convert it in place first
        jr      nz,.notpt3
        ld      hl,s_hint_convert
        call    draw_hint
        call    pt2_import
        jr      c,.toobig
.ok:    ; remember the name for Save (first 8 chars)
        ld      hl,(ld_entry)
        ld      de,save_name
        ld      bc,8
        ldir
        call    sd_end                  ; raw files: the Pico back on .tap files
        call    song_init
        ld      a,1
        or      a
        ret
.skip:  call    tape_consume
        jr      .loop
.notpt3: ld     hl,s_msg_notpt3
        jr      .msg
.toobig: xor    a
        ld      (dir_count),a           ; the conversion used STAGE = the directory: rescan
        ld      hl,s_msg_pt2big
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
        ld      a,(sd_raw)
        or      a
        call    nz,sd_raw_on            ; SD card: raw files again (the scan rewinds)
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
        ld      a,(sd_raw)
        or      a
        jr      z,.title
        ld      hl,s_save_title_sd
.title: ld      a,A_VALUE
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
        ld      a,(sd_mode)
        or      a
        jr      nz,.write               ; the Pico needs no "press record"
        ld      hl,s_msg_record
        call    draw_message
        call    kb_wait_none
        call    kb_wait_key
        call    kb_letter_edge
        cp      'Q'
        jr      z,.done
.write: ld      hl,s_hint_saving
        call    draw_hint
        call    kb_wait_none
        ld      a,(sd_raw)
        or      a
        call    nz,sd_raw_on            ; SD card: a raw file named like the header
        ld      a,2
        out     ($FE),a                 ; red border while writing
        call    tape_save_song
        push    af
        xor     a
        out     ($FE),a
        call    sd_end                  ; (raw files only) the Pico back on .tap files
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
