; =============================================================================
; pt3enc.asm -- canonical PT3 pattern encoder: working pattern -> STAGE
;
; Byte-for-byte the same rules as tools/pt3codec.py encode_pattern(), so the
; host harness can diff the two outputs directly.
;
; Outputs: enc_off[3] (word, STAGE address of each stream), enc_len[3] (word),
;          enc_total (word). CY set on overflow (enc_err <> 0).
; =============================================================================

enc_pattern:
        xor     a
        ld      (enc_err),a
        call    enc_carriers
        ld      hl,STAGE_BASE
        ld      (enc_out),hl
        xor     a
.ch:    ld      (enc_ch),a
        ld      hl,(enc_out)
        push    af
        add     a,a
        ld      e,a
        ld      d,0
        ld      ix,enc_off
        add     ix,de
        ld      (ix+0),l
        ld      (ix+1),h
        push    ix                      ; enc_channel uses IX for NZ_CARRIER
        call    enc_channel
        pop     ix
        ld      hl,(enc_out)
        ld      e,(ix+0)
        ld      d,(ix+1)
        or      a
        sbc     hl,de
        ld      (ix+6),l                ; enc_len is 6 bytes after enc_off
        ld      (ix+7),h
        pop     af
        inc     a
        cp      3
        jr      nz,.ch
        ld      hl,(enc_out)
        ld      de,STAGE_BASE
        or      a
        sbc     hl,de
        ld      (enc_total),hl
        ld      a,(enc_err)
        or      a
        ret     z
        scf
        ret

; ---- emit: A -> (enc_out)++ with overflow guard ------------------------------
emit:
        push    hl
        push    de
        ld      hl,(enc_out)
        ld      de,STAGE_END
        or      a
        sbc     hl,de
        add     hl,de
        jr      nc,.ovf
        ld      (hl),a
        inc     hl
        ld      (enc_out),hl
        pop     de
        pop     hl
        ret
.ovf:   ld      a,1
        ld      (enc_err),a
        pop     de
        pop     hl
        ret

; ---- has_event: HL -> cell. NZ if the cell carries an event/fields. Preserves HL, BC, DE.
has_event:
        ld      a,(hl)
        inc     a                       ; note != $FF ?
        ret     nz
        push    hl
        inc     hl
        ld      a,(hl)
        and     $3F                     ; sample | orn flag
        inc     hl
        or      (hl)                    ; env | orn
        inc     hl
        or      (hl)                    ; vol | cmd
        pop     hl
        ret

; ---- enc_carriers: NZ_CARRIER[row] = channel carrying the row's noise ($FF none)
enc_carriers:
        ld      hl,NZ_CARRIER
        ld      (hl),NZ_NONE
        ld      d,h
        ld      e,l
        inc     de
        ld      bc,WP_ROWS-1
        ldir
        ld      a,(wp_len)
        or      a
        ret     z
        ld      b,a
        ld      hl,WP_BASE
        ld      ix,NZ_CARRIER
.row:   inc     hl
        inc     hl
        ld      a,(hl)                  ; noise
        inc     hl                      ; HL -> cell A
        cp      NZ_NONE
        jr      z,.none
        push    hl
        ld      c,0
.find:  call    has_event
        jr      nz,.hit
        ld      de,WP_CELLSZ
        add     hl,de
        inc     c
        ld      a,c
        cp      3
        jr      nz,.find
        ld      c,0                     ; nobody: synthesise an empty event on A
.hit:   pop     hl
        ld      (ix+0),c
.none:  ld      de,3*WP_CELLSZ
        add     hl,de
        inc     ix
        djnz    .row
        ret

; ---- enc_channel: channel (enc_ch) -> stream at (enc_out) --------------------
enc_channel:
        ; pass 1: EV_ROWS = rows with an event on this channel
        xor     a
        ld      (enc_n),a
        ld      a,(wp_len)
        or      a
        jr      z,.p2
        ld      b,a
        ld      c,0                     ; row
        ld      a,(enc_ch)
        ld      e,a
        call    cell_ofs                ; DE = 3 + ch*7
        ld      hl,WP_BASE
        add     hl,de
        ld      ix,NZ_CARRIER
.p1:    call    has_event
        jr      nz,.ev
        ld      a,(enc_ch)
        cp      (ix+0)
        jr      nz,.noev
.ev:    push    hl
        ld      hl,enc_n
        ld      e,(hl)
        inc     (hl)
        ld      d,0
        ld      hl,EV_ROWS
        add     hl,de
        ld      (hl),c
        pop     hl
.noev:  ld      de,WP_ROWSZ
        add     hl,de
        inc     ix
        inc     c
        djnz    .p1
.p2:    ; pass 2: emit
        xor     a
        ld      (enc_skip),a            ; cur_skip = 0 -> first event always sets B1
        ld      a,(enc_n)
        or      a
        jr      z,.lead
        ld      a,(EV_ROWS)
        or      a
        jr      z,.events
.lead:  ; leading gap: empty event at row 0 skipping to the first event / end
        ld      a,(enc_n)
        or      a
        ld      a,(wp_len)
        jr      z,.lead1
        ld      a,(EV_ROWS)
.lead1: call    emit_skip_if
        ld      a,$D0
        call    emit
.events:
        xor     a
        ld      (enc_i),a
.evloop:
        ld      a,(enc_i)
        ld      hl,enc_n
        cp      (hl)
        jp      z,.fin
        ld      hl,EV_ROWS
        add     a,l
        ld      l,a
        jr      nc,.nc1
        inc     h
.nc1:   ld      a,(hl)
        ld      (enc_row),a
        inc     hl
        ld      a,(enc_i)
        inc     a
        ld      c,a
        ld      a,(enc_n)
        cp      c
        ld      a,(wp_len)
        jr      z,.lastev
        ld      a,(hl)
.lastev: ld     (enc_nxt),a
        ; cell + row pointers
        ld      a,(enc_row)
        call    wp_row_addr
        ld      (enc_glob),hl
        ld      a,(enc_ch)
        ld      e,a
        call    cell_ofs
        add     hl,de
        ld      (enc_cell),hl
        push    hl
        pop     iy                      ; IY = cell
        ; --- ornament / sample / envelope group
        ld      a,(iy+2)
        rrca
        rrca
        rrca
        rrca
        and     $0F                     ; env
        ld      c,a
        ld      a,(iy+1)
        and     $1F                     ; sample
        ld      b,a
        ld      a,c
        cp      ENV_OFF
        jr      z,.g_off
        or      a
        jr      nz,.g_shape
        ; env unset
        call    emit_orn_if
        ld      a,b
        or      a
        jr      z,.g_done
        add     a,$D0
        call    emit
        jr      .g_done
.g_off: ld      a,b
        or      a
        jr      z,.g_off_nosmp
        bit     5,(iy+1)
        jr      z,.g_off_smp
        ld      a,(iy+2)
        and     $0F
        add     a,$F0                   ; F0+orn
        call    emit
        ld      a,b
        add     a,a
        call    emit
        jr      .g_done
.g_off_smp:
        ld      a,$10
        call    emit
        ld      a,b
        add     a,a
        call    emit
        jr      .g_done
.g_off_nosmp:
        call    emit_orn_if
        ld      a,$B0
        call    emit
        jr      .g_done
.g_shape:
        call    emit_orn_if
        ld      a,b
        or      a
        jr      z,.g_shape_nosmp
        ld      a,c
        add     a,$10                   ; 10+shape
        call    emit
        call    emit_envper
        ld      a,b
        add     a,a
        call    emit
        jr      .g_done
.g_shape_nosmp:
        ld      a,c
        add     a,$B1                   ; B1+shape
        call    emit
        call    emit_envper
.g_done:
        ; --- volume
        ld      a,(iy+3)
        and     $F0
        jr      z,.novol
        rrca
        rrca
        rrca
        rrca
        add     a,$C0
        call    emit
.novol: ; --- noise (row-global, one carrier)
        ld      a,(enc_row)
        ld      hl,NZ_CARRIER
        add     a,l
        ld      l,a
        jr      nc,.nc2
        inc     h
.nc2:   ld      a,(enc_ch)
        cp      (hl)
        jr      nz,.nonoise
        ld      hl,(enc_glob)
        inc     hl
        inc     hl
        ld      a,(hl)
        add     a,$20
        call    emit
.nonoise:
        ; --- command byte
        ld      a,(iy+3)
        and     $0F
        jr      z,.nocmd
        call    emit
.nocmd: ; --- skip
        ld      a,(enc_nxt)
        ld      hl,enc_row
        sub     (hl)
        call    emit_skip_if
        ; --- terminator
        ld      a,(iy+0)
        cp      NOTE_REST
        jr      z,.t_rel
        cp      NOTE_EMPTY
        jr      z,.t_empty
        cp      NOTE_NONE
        jr      z,.t_empty
        add     a,$50
        call    emit
        jr      .params
.t_rel: ld      a,$C0
        call    emit
        jr      .params
.t_empty:
        ld      a,$D0
        call    emit
.params:
        ld      a,(iy+3)
        and     $0F
        jr      z,.next
        cp      2
        jr      z,.portm
        call    param_count_of
        or      a
        jr      z,.next
        ld      b,a
        push    iy
        pop     hl
        inc     hl
        inc     hl
        inc     hl
        inc     hl
.pp:    ld      a,(hl)
        call    emit
        inc     hl
        djnz    .pp
        jr      .next
.portm: ld      a,(iy+4)
        call    emit
        xor     a
        call    emit
        call    emit
        ld      a,(iy+5)
        call    emit
        ld      a,(iy+6)
        call    emit
.next:  ld      hl,enc_i
        inc     (hl)
        jp      .evloop
.fin:   xor     a
        jp      emit                    ; 0x00 end of pattern

; emit_orn_if: emit 40+orn when the cell's ornament flag is set (IY = cell)
emit_orn_if:
        bit     5,(iy+1)
        ret     z
        ld      a,(iy+2)
        and     $0F
        add     a,$40
        jp      emit

; emit_envper: row's envelope period hi, lo
emit_envper:
        ld      hl,(enc_glob)
        ld      a,(hl)
        call    emit
        inc     hl
        ld      a,(hl)
        jp      emit

; emit_skip_if: A = needed skip; emits B1,A when it differs from enc_skip
emit_skip_if:
        ld      hl,enc_skip
        cp      (hl)
        ret     z
        ld      (hl),a
        push    af
        ld      a,$B1
        call    emit
        pop     af
        jp      emit

; cell_ofs: E = channel -> DE = 3 + ch*7
cell_ofs:
        ld      a,e
        add     a,a
        add     a,a
        add     a,a
        sub     e                       ; *7
        add     a,3
        ld      e,a
        ld      d,0
        ret
