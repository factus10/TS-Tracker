; =============================================================================
; tape.asm -- cassette I/O through the TS2068 EXROM tape routines
;
; The 2068 keeps LD-BYTES/SA-BYTES in the EXROM, so we page chunk 0 to the
; DOCK/EXROM bank (HSR bit 0) with DECR bit 7 set, call in, and page back.
; Same trampolines v1 used (src/tracker.c), plus one improvement: BREAK.
;
; R_TAPE ($00FC) returns through W_BORD, which raises error D (BREAK) via RST 8
; if SPACE is down. The HOME ROM error handler does LD SP,(ERRSP) / RET, so
; while a tape call is in progress ERRSP points at our own word -> a BREAK
; lands in tape_break, which restores our stack and paging and returns to the
; caller as a failed read. This is how a scan ends when the tape runs out.
;
; W_TAPE is entered at its real start ($0068); its W_BORD epilogue is fine now
; that a BREAK there lands in tape_break instead of BASIC (v1 skipped it).
;
; Inputs via variables (SDCC-style fastcall carried one arg; this is simpler):
;   tp_flag  0 = header, $FF = data      tp_dest  address      tp_len  bytes
; All three return A = 1 (ok) / 0 (failed or BREAK), with Z set on failure.
; =============================================================================

ERRSP       EQU $5C3D
EXROM_LDBYTES EQU $00FC
EXROM_SABYTES EQU $0068           ; W_TAPE proper (returns via W_BORD; BREAK -> tape_break)

tape_read:                              ; LOAD (CY set on entry to R_TAPE)
        ld      (tp_sp),sp
        call    tape_enter
        ld      a,1                     ; T_ADDR: LOAD (the TPI intercepts send it to the Pico)
        ld      (T_ADDR),a
        ld      a,(tp_flag)
        ld      ix,(tp_dest)
        ld      de,(tp_len)
        scf
        call    EXROM_LDBYTES
        jr      tape_result

tape_verify:                            ; VERIFY: consumes a block without storing it
        ld      (tp_sp),sp
        call    tape_enter
        ld      a,1
        ld      (T_ADDR),a
        ld      a,(tp_flag)
        ld      ix,(tp_dest)
        ld      de,(tp_len)
        and     a                       ; CY clear = verify
        call    EXROM_LDBYTES
        jr      tape_result

tape_write:                             ; SAVE
        ld      (tp_sp),sp
        call    tape_enter
        xor     a                       ; T_ADDR: SAVE
        ld      (T_ADDR),a
        ld      a,(tp_flag)
        ld      ix,(tp_dest)
        ld      de,(tp_len)
        scf
        call    EXROM_SABYTES
        ; fallthrough
tape_result:
        ld      a,0
        rla                             ; A = CY (1 = ok)
        push    af
        call    tape_leave
        pop     af
        or      a                       ; Z on failure
        ret

; page the EXROM in, hook ERRSP. DECR ($FF) and HSR ($F4) are WRITE-ONLY on
; the 2068 (reading them returns the floating bus), so never read-modify-write
; them: we run in the standard state (DECR $80 = EXROM enabled, interrupts on,
; normal video; HSR $00 = all chunks HOME) and only flip HSR bits 0 (and 1).
; tp_hsr is 1 for the stock 8K EXROM; 3 for the TS-PICO's 16K TPI EXROM, whose
; tape intercepts run code in chunk 1 ($2000-$3FFF) and read TP_BANK / TP_SID.
DECR_NORMAL EQU $80
tape_enter:
        di
        ld      hl,(ERRSP)
        ld      (tp_errsp),hl
        ld      hl,tp_errword
        ld      (ERRSP),hl
        ld      a,DECR_NORMAL
        out     ($FF),a
        ld      a,(tp_hsr)              ; chunk 0 (and 1) from DOCK = EXROM
        out     ($F4),a
        cp      3
        ret     nz
        ld      a,$FF                   ; TPI: home bank, no BASIC session
        ld      (TP_BANK),a
        ld      hl,0
        ld      (TP_SID),hl
        ret

; page back, unhook ERRSP, border black, interrupts on
tape_leave:
        di
        xor     a
        out     ($F4),a                 ; all chunks from HOME
        ld      a,DECR_NORMAL
        out     ($FF),a
        ld      hl,(tp_errsp)
        ld      (ERRSP),hl
        xor     a
        out     ($FE),a
        ei
        ret

; Reached through ERRSP after a BREAK error inside a tape call: the ROM has
; already paged the HOME bank back and reset its calculator pointers.
tape_break:
        di
        ld      sp,(tp_sp)
        call    tape_leave
        xor     a                       ; A = 0, Z set: "failed"
        ret                             ; to tape_read/verify's caller

; ---- convenience wrappers ---------------------------------------------------
; tape_read_header: 17-byte header into TAPE_HDR (type, name10, len, p1, p2)
tape_read_header:
        xor     a
        ld      (tp_flag),a
        ld      hl,TAPE_HDR
        ld      (tp_dest),hl
        ld      hl,17
        ld      (tp_len),hl
        jp      tape_read

; tape_hdr_len: HL = data length from the header
tape_hdr_len:
        ld      hl,(TAPE_HDR+11)
        ret

; tape_read_song: load the data block described by TAPE_HDR into the slot.
; Blocks that do not fit are consumed in verify mode (skipped). Returns
; A=1 only when the song is now in the slot (song_len set).
tape_read_song:
        call    tape_hdr_len
        ld      a,h
        or      l
        jr      z,.skip
        ld      de,SONG_BUDGET+1
        or      a
        sbc     hl,de
        jr      nc,.skip                ; too big
        call    tape_hdr_len
        ld      (tp_len),hl
        ld      hl,SLOT_BASE
        ld      (tp_dest),hl
        ld      a,$FF
        ld      (tp_flag),a
        call    tape_read
        jr      z,.err
        call    tape_hdr_len
        ld      (song_len),hl
        ld      a,1
        or      a
        ret
.skip:  call    tape_consume
        xor     a                       ; skipped
        ret
.err:   ld      a,$FF
        or      a
        ret

; tape_consume: skip the data block described by TAPE_HDR. Blocks that fit are
; simply loaded into the slot (the slot is scratch while scanning/loading);
; bigger ones are read in VERIFY mode. VERIFY "fails" on the first differing
; byte -- which is every byte of a different song -- so the result is ignored.
; A BREAK here shows up on the NEXT header read (the leader wait sees SPACE).
; On the TS-PICO there is nothing to wait through: the next header request
; skips the data block by itself, and a VERIFY that stops on the first byte
; would leave the Pico half way through sending the block.
tape_consume:
        ld      a,(sd_mode)
        or      a
        jr      nz,.sd
        call    tape_hdr_len
        ld      (tp_len),hl
        ld      de,SONG_BUDGET+1
        or      a
        sbc     hl,de
        ld      hl,SLOT_BASE
        ld      (tp_dest),hl
        ld      a,$FF
        ld      (tp_flag),a
        jr      nc,.big
        call    tape_read
        jr      .done
.big:   call    tape_verify
.done:
.sd:    ld      a,1
        or      a
        ret

; tape_hdr_name_eq: compare TAPE_HDR name (10 bytes) with (HL). Z if equal.
tape_hdr_name_eq:
        ld      de,TAPE_HDR+1
        ld      b,10
.l:     ld      a,(de)
        cp      (hl)
        ret     nz
        inc     hl
        inc     de
        djnz    .l
        ret

; ---- save ------------------------------------------------------------------
; tape_save_song: header (save_name 8 chars + 2-hex version) + data from the
; slot. A=1 ok. Bumps save_version on success.
tape_save_song:
        ld      hl,TAPE_HDR
        ld      (hl),3                  ; CODE
        inc     hl
        ex      de,hl
        ld      hl,save_name
        ld      bc,8
        ldir                            ; name[0..7]
        ld      a,(save_version)
        rrca
        rrca
        rrca
        rrca
        call    hex_char
        ld      (de),a
        inc     de
        ld      a,(save_version)
        call    hex_char
        ld      (de),a
        inc     de
        ld      hl,(song_len)
        ex      de,hl
        ld      (hl),e
        inc     hl
        ld      (hl),d                  ; length
        inc     hl
        ld      (hl),SLOT_BASE&$FF      ; p1 = load address
        inc     hl
        ld      (hl),SLOT_BASE>>8
        inc     hl
        ld      (hl),0                  ; p2 = $8000 (CODE convention)
        inc     hl
        ld      (hl),$80
        ; header block
        xor     a
        ld      (tp_flag),a
        ld      hl,TAPE_HDR
        ld      (tp_dest),hl
        ld      hl,17
        ld      (tp_len),hl
        call    tape_write
        ret     z
        ; data block
        ld      a,$FF
        ld      (tp_flag),a
        ld      hl,SLOT_BASE
        ld      (tp_dest),hl
        ld      hl,(song_len)
        ld      (tp_len),hl
        call    tape_write
        ret     z
        ld      hl,save_version
        inc     (hl)
        ld      a,1
        or      a
        ret

; hex_char: A low nibble -> ASCII
hex_char:
        and     $0F
        cp      10
        jr      c,.d
        add     a,'A'-10
        ret
.d:     add     a,'0'
        ret

; ---- error-return mini stack (the ROM's RESET may push before it RETs) ------
        ds      16
tp_errword:
        dw      tape_break
