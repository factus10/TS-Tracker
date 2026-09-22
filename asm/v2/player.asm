; =============================================================================
; player.asm -- PTxPlay glue: play song from the current position, loop the
; current pattern. PTxPlay is assembled into this binary (ptxplay.inc), so its
; labels (INIT, PLAY, MUTE, CrPsPtr, LPosPtr, CurPos) are referenced directly.
;
; TS2068 vsync is 60 Hz; PT3 tunes are 50 Hz: PLAY runs 5 frames out of 6.
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

; play_song: commit, then play from cur_pos until a key is pressed
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
        xor     a
        ld      (play_follow),a
        call    play_until_key
        ld      hl,s_hint_edit
        jp      draw_hint

; play_until_key: run PLAY at 50 Hz until any key press; mutes on exit
play_until_key:
        xor     a
        ld      (play_hold),a
        call    kb_wait_none
        jr      play_run
; play_hold_enter: run PLAY while ENTER stays down (instrument preview)
play_hold_enter:
        ld      a,1
        ld      (play_hold),a
play_run:
        xor     a
        ld      (play_div),a
        ld      a,$FF
        ld      (play_lastpos),a
        ld      a,5
        out     ($FE),a                 ; cyan border while playing
.loop:  halt
        ld      hl,play_div
        inc     (hl)
        ld      a,(hl)
        cp      6
        jr      nz,.tick
        ld      (hl),0
        jr      .keys
.tick:  push    ix
        push    iy
        call    PLAY
        pop     iy
        pop     ix
        ld      a,(play_follow)
        or      a
        jr      z,.keys
        ld      a,(CurPos)
        ld      hl,play_lastpos
        cp      (hl)
        jr      z,.keys
        ld      (hl),a
        ld      c,a
        ld      a,(SLOT_BASE+H_NPOS)
        cp      c
        jr      c,.keys
        jr      z,.keys
        ld      a,c
        ld      (cur_pos),a
        call    draw_free_pos
        ld      a,R_INFO
        ld      c,4
        call    scr_addr
        ld      a,(cur_pos)
        call    put_dec2
.keys:  call    kb_scan
        ld      a,(play_hold)
        or      a
        jr      nz,.hold
        call    kb_any_now
        jr      z,.loop
        jr      .stop
.hold:  ld      a,(kb_now+KR_ENTER)
        and     1
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

; commit_failed: report and stay in the editor
commit_failed:
        ld      hl,s_msg_noroom
        call    draw_message
        call    kb_wait_none
        call    kb_wait_key
        ld      hl,s_hint_edit
        jp      draw_hint
