; =============================================================================
; tracker2.asm -- TS Tracker v2 (all-assembly), Phase 1: in-memory editor
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
        INCLUDE "data.asm"
        INCLUDE "vars.asm"
        INCLUDE "test.asm"

code_end:
; ---- PTxPlay (PT3-only, CurPos enabled), generated into build/v2 ---------------
        INCLUDE "../../build/v2/ptxplay.inc"
ptx_end:

        ASSERT ptx_end <= SLOT_BASE
        DISPLAY "tracker2: code+data ", /D, code_end-start, " B, PTxPlay ", /D, ptx_end-code_end, " B, total ", /D, ptx_end-start, " B, free to SLOT_BASE ", /D, SLOT_BASE-ptx_end
