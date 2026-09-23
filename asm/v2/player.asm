; =============================================================================
; player.asm -- PTxPlay glue: play the song from the current position (the
; editor follows the playing row and position), loop the current pattern,
; preview a note; 1/2/3 mute channels and a VU runs on the detail row.
; PTxPlay is assembled into this binary (ptxplay.inc), so its labels (INIT,
; PLAY, MUTE, CrPsPtr, LPosPtr, PatsPtr, CurPos, Delay, DelyCnt, AYREGS, NT_)
; are referenced directly.
;
; TS2068 vsync is 60 Hz; PT3 tunes are 50 Hz: PLAY runs 5 ticks out of 6.
; Ticks are counted from FRAMES (the ROM's frame counter), so a grid redraw
; that overruns a frame is caught up with two ticks in the next one instead of
; slowing the song down.
; =============================================================================

ay_silence:
        ld      a,7
        out     (AY_REG),a
        ld      a,$3F
        out     (AY_DAT),a
        ld      a,8
.l:     out     (AY_REG),a
        push    af
        xor     a
        out     (AY_DAT),a
        pop     af
        inc     a
        cp      11
        jr      nz,.l
        ret

; play_song: commit, then play from cur_pos until a key is pressed; the editor
; follows (cur_pos / the WP / cur_row end up where playback stopped)
play_song:
        call    commit_pattern
        jp      c,commit_failed
        ld      hl,s_hint_play
        call    draw_hint
        ld      hl,SLOT_BASE
        call    INIT
        ; start at cur_pos: PLAY does LD HL,(CrPsPtr) / INC HL / LD A,(HL)
        ld      a,(cur_pos)
        ld      hl,SLOT_BASE+200
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      (CrPsPtr),hl
        ld      a,1
        ld      (play_follow),a
        xor     a
        ld      (play_loopmode),a
        call    play_until_key
        ld      hl,s_hint_edit
        jp      draw_hint

; play_loop_pattern: loop the working pattern via a private 1-entry list
play_loop_pattern:
        call    commit_pattern
        jp      c,commit_failed
        ld      hl,s_hint_loop
        call    draw_hint
        ld      hl,SLOT_BASE
        call    INIT
        ld      a,(wp_pat)
        ld      b,a
        add     a,a
        add     a,b                     ; pattern*3
        ld      hl,LOOP_LIST
        ld      (hl),a
        inc     hl
        ld      (hl),$FF
        ld      hl,LOOP_LIST
        ld      (LPosPtr),hl
        dec     hl
        ld      (CrPsPtr),hl
        ld      a,1
        ld      (play_follow),a
        ld      (play_loopmode),a
        call    play_until_key
        ld      hl,s_hint_edit
        jp      draw_hint

; ---------------------------------------------------------------------------
; play_until_key: run until a key (other than 1/2/3) is pressed
; play_hold_key:  run while any key stays down, at least (play_min) frames
; ---------------------------------------------------------------------------
play_until_key:
        xor     a
        ld      (play_hold),a
        call    kb_wait_none
        ld      a,5
        out     ($FE),a                 ; cyan border while playing
        jr      play_run
play_hold_key:
        ld      a,1
        ld      (play_hold),a
        ld      a,8
        ld      (play_min),a
play_run:
        xor     a
        ld      (play_div),a
        ld      (play_posdirty),a
        ld      a,$FF
        ld      (play_lastpos),a
        ld      (play_row),a            ; the first decode makes it row 0
        ld      (play_shownrow),a
        ld      a,(FRAMES)
        ld      (play_lastframe),a
.loop:  halt
        ld      a,(FRAMES)
        ld      hl,play_lastframe
        ld      c,a
        sub     (hl)
        ld      (hl),c                  ; A = frames since the last pass
        cp      4
        jr      c,.n
        ld      a,3                     ; a long stall is not worth a burst
.n:     or      a
        jr      z,.ui
        ld      b,a
.tick:  push    bc
        call    play_tick
        pop     bc
        djnz    .tick
.ui:    ld      a,(play_hold)
        or      a
        jr      nz,.keys
        call    play_vu
        call    play_follow_update
.keys:  call    kb_scan
        ld      a,(play_hold)
        or      a
        jr      nz,.hold
        ; 1 2 3 toggle the channel mutes; any other key stops
        ld      a,(kb_edge+KR_12345)
        and     7
        ld      hl,play_mute
        xor     (hl)
        ld      (hl),a
        ld      hl,kb_now
        ld      a,(hl)
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        inc     hl
        ld      c,(hl)                  ; row 1 2 3 4 5
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        ld      b,a
        ld      a,c
        and     $18                     ; 4 and 5 count, the mute keys do not
        or      b
        jr      z,.loop
        jr      .stop
.hold:  ld      hl,play_min
        ld      a,(hl)
        or      a
        jr      z,.chk
        dec     (hl)
        jr      .loop
.chk:   call    kb_any_now
        jr      nz,.loop
.stop:  push    ix
        push    iy
        call    MUTE
        pop     iy
        pop     ix
        call    ay_silence
        xor     a
        out     ($FE),a
        jp      kb_wait_none

; play_tick: one 60 Hz tick -> PLAY on 5 of 6, mutes, row/position tracking
play_tick:
        ld      hl,play_div
        inc     (hl)
        ld      a,(hl)
        cp      6
        jr      nz,.go
        ld      (hl),0
        ret
.go:    push    ix
        push    iy
        call    PLAY
        pop     iy
        pop     ix
        ; muted channels: amplitude 0 after PTxPlay's register dump
        ld      a,(play_mute)
        ld      c,a
        ld      b,8                     ; register 8 = amplitude A
.m:     rr      c
        jr      nc,.nm
        ld      a,b
        out     (AY_REG),a
        xor     a
        out     (AY_DAT),a
.nm:    inc     b
        ld      a,b
        cp      11
        jr      nz,.m
        ld      a,(play_hold)
        or      a
        ret     nz
        ; position change?  (meaningless with the private loop list)
        ld      a,(CurPos)
        ld      hl,play_lastpos
        cp      (hl)
        jr      z,.samepos
        ld      (hl),a
        ld      a,(play_loopmode)
        or      a
        jr      nz,.samepos
        xor     a
        ld      (play_row),a
        ld      a,1
        ld      (play_posdirty),a
        ret
.samepos:
        ld      a,(DelyCnt)             ; == Delay right after a row was decoded
        ld      hl,Delay
        cp      (hl)
        ret     nz
        ld      hl,play_row
        inc     (hl)
        ld      a,(play_loopmode)
        or      a
        ret     z
        ld      a,(hl)
        ld      hl,wp_len
        cp      (hl)
        ret     c
        xor     a
        ld      (play_row),a            ; the looped pattern started again
        ret

; play_follow_update: after a position change load and show the new pattern;
; after a row change move the cursor row (the grid scrolls under it)
play_follow_update:
        ld      a,(play_follow)
        or      a
        ret     z
        ld      a,(play_posdirty)
        or      a
        jr      z,.rows
        xor     a
        ld      (play_posdirty),a
        ld      a,(play_lastpos)
        ld      c,a
        ld      a,(SLOT_BASE+H_NPOS)
        cp      c
        ret     c
        ret     z                       ; not a real position
        ld      a,c
        ld      (cur_pos),a
        call    pos_pattern
        ld      hl,wp_pat
        cp      (hl)
        jr      z,.same
        call    wp_load                 ; the WP was committed before play
.same:  call    draw_info
        call    draw_free_pos
        ld      a,$FF
        ld      (play_shownrow),a
.rows:  ld      a,(play_row)
        ld      hl,play_shownrow
        cp      (hl)
        ret     z
        ld      (hl),a
        ld      hl,wp_len
        cp      (hl)
        ret     nc
        ld      (cur_row),a
        jp      draw_grid

; play_vu: "A ######## B ######## C ########" on the detail row from AYREGS
play_vu:
        ld      a,R_DETAIL
        ld      c,0
        call    scr_addr
        push    hl
        xor     a
.ch:    ld      (vu_ch),a
        add     a,'A'
        call    put_char_adv
        ld      a,' '                   ; (draw the gaps: the detail row was here)
        call    put_char_adv
        ld      a,(vu_ch)
        ld      hl,AYREGS+8
        add     a,l
        ld      l,a
        jr      nc,.n1
        inc     h
.n1:    ld      c,(hl)                  ; amplitude (bit 4 = envelope)
        ld      a,(vu_ch)
        ld      b,a
        inc     b
        ld      a,(play_mute)
.sh:    rra
        djnz    .sh                     ; CY = this channel muted
        ld      a,c
        jr      nc,.nomute
        xor     a
.nomute:
        bit     4,a
        jr      z,.lvl
        ld      a,15
.lvl:   and     $0F
        inc     a
        srl     a                       ; 0..8 cells
        ld      c,a
        ld      b,8
.bar:   ld      a,' '
        inc     c
        dec     c
        jr      z,.put
        dec     c
        ld      a,G_BLOCK
.put:   call    put_char_adv
        djnz    .bar
        ld      a,(vu_ch)
        inc     a
        cp      3
        jr      z,.attrs                ; no gap after C: 32 columns exactly
        push    af
        ld      a,' '
        call    put_char_adv
        pop     af
        jr      .ch
.attrs:
        pop     hl
        push    hl
        ld      b,32
        ld      a,A_CELL_B
.pa:    ld      (hl),a
        inc     hl
        djnz    .pa
        pop     hl
        ld      a,(play_mute)
        ld      c,a
        ld      b,3
.lt:    rr      c
        ld      a,A_LABEL
        jr      nc,.ok
        ld      a,A_ERROR
.ok:    ld      (hl),a
        ld      de,11
        add     hl,de
        djnz    .lt
        ret

; ---------------------------------------------------------------------------
; pv_play: preview one note while a key is held. Inputs: pv_note, pv_smp,
; pv_orn, pv_shape (0 = auto: envelope shape 8 if any line of the sample
; enables the envelope, else none; 1-14 = that shape; 15 = none), pv_per
; (envelope period, 0 = auto: the note's tone period / 16).
; PTxPlay is initialised on the real song (note table, speed), then pointed at
; a private one-position song: pattern table PV_TABLE, channel A stream PV_A
; (skip 64, ornament, envelope/sample, note), channels B/C the empty PV_BC.
; The pattern is 64 rows, so a held note retriggers every 64 rows.
; ---------------------------------------------------------------------------
pv_play:
        ld      a,(pv_smp)
        add     a,a
        ld      hl,SLOT_BASE+H_SMPPTRS
        add     a,l
        ld      l,a
        jr      nc,.n1
        inc     h
.n1:    ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      a,d
        or      e
        ret     z                       ; that sample has no data
        ld      a,(pv_shape)
        or      a
        jr      nz,.shaped
        ld      hl,SLOT_BASE
        add     hl,de
        inc     hl
        ld      b,(hl)                  ; lines
        inc     hl
        ld      a,15                    ; none unless a line enables the envelope
.scan:  bit     0,(hl)
        jr      nz,.nx
        ld      a,8
.nx:    inc     hl
        inc     hl
        inc     hl
        inc     hl
        djnz    .scan
        ld      (pv_shape),a
.shaped:
        ld      hl,SLOT_BASE
        call    INIT
        ld      hl,PV_TABLE
        ld      (PatsPtr),hl
        ld      de,PV_A-SLOT_BASE
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      de,PV_BC-SLOT_BASE
        ld      (hl),e
        inc     hl
        ld      (hl),d
        inc     hl
        ld      (hl),e
        inc     hl
        ld      (hl),d
        ld      hl,PV_BC
        ld      (hl),$B1
        inc     hl
        ld      (hl),$40
        inc     hl
        ld      (hl),$D0
        inc     hl
        ld      (hl),$00
        ld      hl,PV_A
        ld      (hl),$B1
        inc     hl
        ld      (hl),$40
        inc     hl
        ld      a,(pv_orn)
        or      $40
        ld      (hl),a
        inc     hl
        ld      a,(pv_shape)
        cp      15
        jr      z,.noenv
        add     a,$10                   ; envelope shape + period + sample
        ld      (hl),a
        inc     hl
        ld      de,(pv_per)
        ld      a,d
        or      e
        jr      nz,.per
        ld      a,(pv_note)             ; auto period: tone period / 16 (shape 8 at pitch)
        add     a,a
        ld      e,a
        ld      d,0
        push    hl
        ld      hl,NT_
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        pop     hl
        srl     d
        rr      e
        srl     d
        rr      e
        srl     d
        rr      e
        srl     d
        rr      e
        ld      a,d
        or      e
        jr      nz,.per
        inc     e
.per:   ld      (hl),d
        inc     hl
        ld      (hl),e
        inc     hl
        jr      .smp
.noenv: ld      (hl),$10                ; sample, envelope off
        inc     hl
.smp:   ld      a,(pv_smp)
        add     a,a
        ld      (hl),a
        inc     hl
        ld      a,(pv_note)
        add     a,$50
        ld      (hl),a
        inc     hl
        ld      (hl),0
        ld      hl,LOOP_LIST
        ld      (hl),0
        inc     hl
        ld      (hl),$FF
        ld      hl,LOOP_LIST
        ld      (LPosPtr),hl
        dec     hl
        ld      (CrPsPtr),hl
        xor     a
        ld      (play_follow),a
        jp      play_hold_key

; commit_failed: report and stay in the editor
commit_failed:
        ld      hl,s_msg_noroom
        call    draw_message
        call    kb_wait_none
        call    kb_wait_key
        ld      hl,s_hint_edit
        jp      draw_hint
