; =============================================================================
; tracker2.asm -- TS Tracker v2 (all-assembly): SQ-style PT3 editor
;
; Build: make tracker2          -> build/v2/tracker2.tap
;        make tracker2-demo SONG=songs/x.pt3 -> tape that boots straight into
;                                              the editor with that song
; Assembler: sjasmplus. See docs/redesign-plan.md and asm/v2/layout.inc.
; =============================================================================
        DEVICE NONE
        ORG     CODE_BASE
        OUTPUT  "build/v2/tracker2.bin"

        INCLUDE "layout.inc"

start:
        di
        ld      (saved_sp),sp
        ld      sp,STACK_TOP
        ; Our own interrupt handler (IM2). The ROM's IM1 handler writes system
        ; variables relative to IY on every key event, and the codec routines use
        ; IY as their cell pointer: with the ROM handler live, a key held while a
        ; pattern is decoded or encoded could corrupt the working pattern. The
        ; handler below only bumps FRAMES; the keyboard is scanned by kb_scan.
        ld      hl,IM2_TABLE
        ld      de,IM2_TABLE+1
        ld      bc,256
        ld      (hl),IM2_VEC>>8         ; every vector byte $7F -> $7F7F
        ldir
        ld      a,$C3                   ; JP isr_frames at $7F7F
        ld      (IM2_VEC),a
        ld      hl,isr_frames
        ld      (IM2_VEC+1),hl
        ld      a,IM2_TABLE>>8
        ld      i,a
        im      2
        xor     a
        out     ($FE),a
        call    ay_silence
        ei
        call    cls
        call    slot_has_song
        jr      nz,.no_song
        call    song_init
        jr      .go
.no_song:
        call    screen_start            ; S scan tape / N new song / Q quit
.go:    call    redraw_all
        jp      editor_loop

quit_to_basic:
        di
        im      1                       ; back to the ROM's handler
        ld      a,$3F
        ld      i,a
        push    ix
        push    iy
        call    MUTE
        pop     iy
        pop     ix
        call    ay_silence
        call    cls
        ld      a,7
        out     ($FE),a
        ld      sp,(saved_sp)
        ei
        ret

; isr_frames: the whole interrupt handler -- FRAMES (60 Hz) for key repeat and
; the player's tick catch-up. Nothing here depends on IY. EI comes first so
; that a debugger / test harness that stops the CPU inside the handler and
; moves PC elsewhere does not leave interrupts off (the next HALT would sleep
; forever); the handler is far too short to be re-entered.
isr_frames:
        ei
        push    af
        push    hl
        ld      hl,(FRAMES)
        inc     hl
        ld      (FRAMES),hl
        pop     hl
        pop     af
        reti
isr_frames_end:

        INCLUDE "screen.asm"
        INCLUDE "keys.asm"
        INCLUDE "pt3dec.asm"
        INCLUDE "pt3enc.asm"
        INCLUDE "slot.asm"
        INCLUDE "player.asm"
        INCLUDE "editor.asm"
        INCLUDE "tape.asm"
        INCLUDE "dir.asm"
        INCLUDE "posedit.asm"
        INCLUDE "songinfo.asm"
        INCLUDE "instr.asm"
        INCLUDE "pt2conv.asm"
        INCLUDE "data.asm"
        INCLUDE "vars.asm"
        INCLUDE "test.asm"

code_end:
; ---- PTxPlay (PT3-only, CurPos enabled), generated into build/v2 ---------------
        INCLUDE "../../build/v2/ptxplay.inc"
ptx_end:

        ASSERT ptx_end <= SLOT_BASE
        DISPLAY "tracker2: code+data ", /D, code_end-start, " B, PTxPlay ", /D, ptx_end-code_end, " B, total ", /D, ptx_end-start, " B, free to SLOT_BASE ", /D, SLOT_BASE-ptx_end
