; =============================================================================
; pico.asm -- TS-PICO support: detect Gus Pane's TPI ROM, send "TPI:" commands,
; browse the SD card as a tape of raw .pt3 files
;
; The TPI EXROM intercepts W_TAPE ($0068) and R_TAPE ($00FC): while TP_MODE
; bit 1 is set, the tape routines we already call (tape.asm) talk to the Pico
; instead of the cassette port, so scan / load / save work unchanged on a
; mounted .tap. What is ours:
;   * the 16K EXROM needs chunks 0 AND 1 paged (tp_hsr = 3), and its intercepts
;     read T_ADDR / TP_BANK / TP_SID -- tape.asm sets them;
;   * "TPI:" commands (FMODE=RAW, REWIND, ...) are the "B" + "D" frames the ROM
;     sends for SAVE "TPI:xxx" (EXROM $1B8D), rebuilt here byte for byte through
;     the BIOS entries TX_A / RX_A / WF_NPH;
;   * skipping a block means simply asking for the next header (tape_consume).
; Frames (TS-PICO TPI protocol 2.4):
;   42 taddr FF pmr1(2) pmr2(2) len(2) crc   -> status 01 -> continue flag
;   44 len(2) "TPI:...." crc                 -> continue flag -> status 01
; where crc is the XOR of the frame's bytes and status codes are 1 = OK,
; 0/2-9 = BASIC reports, >= $80 = "print this" functions (not used by us).
; =============================================================================

; tpi_detect: page the EXROM in and look for the TPI BIOS jump table at $1840.
; Sets tpi_ok, tpi_vers (G_VERS), tp_hsr (3 / 1) and sd_mode from TP_MODE.
tpi_detect:
        di
        ld      a,DECR_NORMAL
        out     ($FF),a
        ld      a,1
        out     ($F4),a                 ; chunk 0 = EXROM
        ld      hl,tpi_sig
        ld      b,TPI_SIGN
.chk:   ld      e,(hl)
        inc     hl
        ld      d,$18                   ; DE = $18xx
        ld      a,(de)
        cp      (hl)
        jr      nz,.no
        inc     hl
        djnz    .chk
        call    TPI_G_VERS              ; BC = BIOS version
        ld      (tpi_vers),bc
        ld      a,3
        ld      (tp_hsr),a
        ld      a,1
        ld      (tpi_ok),a
        ld      a,(TP_MODE)
        and     2
        rrca                            ; bit 1 -> 1
        ld      (sd_mode),a
.out:   xor     a
        out     ($F4),a                 ; all chunks HOME again
        ret
.no:    ld      a,1
        ld      (tp_hsr),a
        xor     a
        ld      (tpi_ok),a
        ld      (sd_mode),a
        jr      .out

; (low address byte, value) pairs at $18xx: the JR/JP shape of the jump table
; and G_VERS's LD BC,nn / RET
tpi_sig:
        db      $40,$18, $42,$18, $44,$18, $46,$18, $48,$18, $4A,$18
        db      $4C,$C3, $4F,$C3, $52,$01, $55,$C9
TPI_SIGN EQU 10

; ---- "TPI:" commands ------------------------------------------------------------
; tpi_save / tpi_load: HL -> length-prefixed "TPI:..." string; sends the frames
; of SAVE "TPI:..." / LOAD "TPI:..." (T_ADDR 0 / 1, no CODE parameters).
; A = 1 ok (NZ) / 0 failed (Z); (tpi_err) = the status byte, $FF for a timeout
; or BREAK in the wait, $FE when there is no TPI BIOS.
tpi_load:
        ld      a,1
        jr      tpi_cmd
tpi_save:
        xor     a
tpi_cmd:
        ld      (tpi_taddr),a
        ld      a,$FE
        ld      (tpi_err),a
        ld      a,(tpi_ok)
        or      a
        ret     z
        ld      c,(hl)                  ; C = command length
        inc     hl
        ld      (tp_sp),sp
        push    hl
        call    tape_enter              ; DI, ERRSP hooked, EXROM paged
        pop     hl
        ld      d,0                     ; D = running XOR
        ld      a,$42                   ; "B": a BASIC command block
        call    tpi_txc
        ld      a,(tpi_taddr)
        call    tpi_txc
        ld      a,$FF                   ; bank: HOME
        call    tpi_txc
        ld      b,4                     ; PMR1, PMR2 = 0 (no CODE a,b)
.zero:  xor     a
        call    tpi_txc
        djnz    .zero
        ld      a,c
        call    tpi_txc                 ; command length lo
        xor     a
        call    tpi_txc                 ; hi
        ld      a,d
        call    tpi_tx                  ; CRC
        call    tpi_rx
        call    tpi_status
        jr      nz,.fail
        call    tpi_wait
        jr      c,.timeout
        ld      d,0
        ld      a,$44                   ; "D": the command string
        call    tpi_txc
        ld      a,c
        call    tpi_txc
        xor     a
        call    tpi_txc
.str:   ld      a,(hl)
        call    tpi_txc
        inc     hl
        dec     c
        jr      nz,.str
        ld      a,d
        call    tpi_tx                  ; CRC
        call    tpi_wait
        jr      c,.timeout
        call    tpi_rx
        call    tpi_status
        jr      nz,.fail
        ld      a,1
        jr      .done
.timeout:
        ld      a,$FF
        ld      (tpi_err),a
.fail:  xor     a
.done:  push    af
        call    tape_leave
        pop     af
        or      a
        ret

tpi_status:                             ; A = status byte -> (tpi_err); Z when it is 1 (OK)
        ld      (tpi_err),a
        dec     a
        ret

tpi_txc:                                ; send A and fold it into the CRC in D
        call    tpi_tx
        xor     d
        ld      d,a
        ret

; the three BIOS calls, one place each (the emulator harness redirects these)
tpi_tx:   jp    TPI_TX_A
tpi_rx:   jp    TPI_RX_A
tpi_wait: jp    TPI_WF_NPH

; ---- the SD-card flow -----------------------------------------------------------
; sd_begin: the user chose the SD card: SD mode on (TP_MODE remembered for quit)
; and raw files instead of a .tap. A = 1 ok.
sd_begin:
        ld      a,(sd_changed)
        or      a
        jr      nz,.on
        ld      a,(TP_MODE)
        ld      (sd_saved),a
        ld      a,1
        ld      (sd_changed),a
.on:    ld      a,(TP_MODE)
        or      2
        ld      (TP_MODE),a
        ld      a,1
        ld      (sd_mode),a
        ld      (sd_raw),a
        ; fallthrough
; sd_raw_on: FMODE=RAW -- whole files, no header, long names (also the re-entry
; after a load or a save has put the Pico back on .tap files)
sd_raw_on:
        ld      hl,s_tpi_raw
        jp      tpi_save

; sd_rewind: the Pico's block pointer back to the start (of the .tap, or of the
; raw files); every SD scan and load starts with it, so the two see the same
; sequence of blocks and a load can pick its entry by position
sd_rewind:
        ld      hl,s_tpi_rewind
        jp      tpi_save

; sd_end: back to .tap files (the Pico's default) once a raw-file operation is over
sd_end:
        ld      a,(sd_raw)
        or      a
        ret     z
        ld      hl,s_tpi_tap
        jp      tpi_save

; sd_fail: "Pico error nn" on the hint row (nn = tpi_err), wait for a key
sd_fail:
        ld      hl,s_msg_tpi
        call    draw_message
        ld      a,R_HINT
        ld      c,11
        call    scr_addr
        ld      a,(tpi_err)
        call    put_hex2
        call    kb_wait_none
        call    kb_wait_key
        jp      kb_wait_none

s_tpi_raw:    db 13,"TPI:FMODE=RAW"
s_tpi_tap:    db 13,"TPI:FMODE=TAP"
s_tpi_rewind: db 10,"TPI:REWIND"
