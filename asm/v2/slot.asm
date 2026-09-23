; =============================================================================
; slot.asm -- the song slot is the model: measure, splice, commit, load
;
; The PT3 at SLOT_BASE is the source of truth. One pattern at a time is decoded
; into WP for editing; leaving it (or playing/saving) re-encodes and splices
; the new streams into the slot in place, fixing every pointer that moves:
; pattern-table entries, sample pointers, ornament pointers.
; =============================================================================

; ---- song_init: (re)derive num_pats, song_len; load position 0 ---------------
song_init:
        call    calc_num_pats
        call    slot_measure
        xor     a
        ld      (cur_pos),a
        ld      (cur_row),a
        ld      (cur_chan),a
        ld      (cur_field),a
        ld      (play_mute),a
        ld      (copy_src),a
        dec     a
        ld      (copy_src),a            ; $FF = nothing copied
        xor     a
        inc     a
        ld      (cur_sample),a          ; a new/loaded song starts on sample 1 / ornament 1
        ld      (se_sel_smp),a
        ld      (se_sel_orn),a
        call    pos_pattern             ; A = pattern at cur_pos
        call    wp_load
        jp      update_free

; calc_num_pats: max(position bytes)/3 + 1 -> num_pats (>= 1)
calc_num_pats:
        ld      a,(SLOT_BASE+H_NPOS)
        or      a
        jr      nz,.ok
        ld      a,1
        ld      (num_pats),a
        ret
.ok:    ld      b,a
        ld      hl,SLOT_BASE+H_POSLIST
        xor     a
.l:     cp      (hl)
        jr      nc,.n
        ld      a,(hl)
.n:     inc     hl
        djnz    .l
        call    div3
        inc     a
        ld      (num_pats),a
        ret

; pos_pattern: A = pattern index at position (cur_pos)
pos_pattern:
        ld      a,(cur_pos)
        ld      hl,SLOT_BASE+H_POSLIST
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)
        jp      div3

; ---- slot_measure: song_len = end of the furthest referenced block ----------
slot_measure:
        ld      hl,SLOT_END
        ld      (stream_limit),hl
        ; header end: 201 + npos + 1
        ld      a,(SLOT_BASE+H_NPOS)
        ld      l,a
        ld      h,0
        ld      de,H_POSLIST+1
        add     hl,de
        ld      (song_len),hl
        ; pattern streams
        ld      a,(num_pats)
        ld      b,a
        xor     a
.pat:   push    bc
        push    af
        call    pat_entry_addr
        ld      b,3
.ch:    push    bc
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        push    hl
        ld      hl,SLOT_BASE
        add     hl,de
        call    stream_end              ; HL = end address
        ld      de,SLOT_BASE
        or      a
        sbc     hl,de
        call    measure_max
        pop     hl
        pop     bc
        djnz    .ch
        pop     af
        pop     bc
        inc     a
        djnz    .pat
        ; samples: ptr + 2 + len*4
        ld      hl,SLOT_BASE+H_SMPPTRS
        ld      b,32
.smp:   push    bc
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      a,d
        or      e
        jr      z,.smpn
        push    hl
        ld      hl,SLOT_BASE
        add     hl,de
        inc     hl
        ld      a,(hl)                  ; len
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl                   ; *4
        add     hl,de
        inc     hl
        inc     hl
        call    measure_max
        pop     hl
.smpn:  pop     bc
        djnz    .smp
        ; ornaments: ptr + 2 + len
        ld      hl,SLOT_BASE+H_ORNPTRS
        ld      b,16
.orn:   push    bc
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      a,d
        or      e
        jr      z,.ornn
        push    hl
        ld      hl,SLOT_BASE
        add     hl,de
        inc     hl
        ld      a,(hl)
        ld      l,a
        ld      h,0
        add     hl,de
        inc     hl
        inc     hl
        call    measure_max
        pop     hl
.ornn:  pop     bc
        djnz    .orn
        ; clamp
        ld      hl,(song_len)
        ld      de,SONG_BUDGET
        or      a
        sbc     hl,de
        ret     c
        ld      hl,SONG_BUDGET
        ld      (song_len),hl
        ret

; measure_max: song_len = max(song_len, HL)
measure_max:
        ld      de,(song_len)
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        ret     c
        ret     z
        ld      (song_len),hl
        ret

; ---- pointer fix-ups --------------------------------------------------------
; fx_mode 0 = insert: ptr >= fx_off            -> ptr += fx_cnt
; fx_mode 1 = delete: ptr >= fx_off+fx_cnt     -> ptr -= fx_cnt
;                     fx_off <= ptr < fx_off+cnt -> ptr = fx_off
fix_all:
        ld      hl,SLOT_BASE+H_PATPTR   ; the table pointer itself (position-list edits
        ld      b,1                     ; insert bytes below the table)
        call    fix_run
        ld      a,(num_pats)
        ld      b,a
        add     a,a
        add     a,b                     ; *3 words
        ld      b,a
        ld      hl,(SLOT_BASE+H_PATPTR)
        ld      de,SLOT_BASE
        add     hl,de
        call    fix_run
        ld      hl,SLOT_BASE+H_SMPPTRS
        ld      b,32
        call    fix_run
        ld      hl,SLOT_BASE+H_ORNPTRS
        ld      b,16
        ; fallthrough
fix_run:                                ; B words at HL (zero words untouched)
.l:     push    bc
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      a,d
        or      e
        jr      z,.skip
        push    hl
        ex      de,hl
        call    fix_one                 ; HL = fixed pointer
        ex      de,hl
        pop     hl
        ld      (hl),d
        dec     hl
        ld      (hl),e
        inc     hl
.skip:  inc     hl
        pop     bc
        djnz    .l
        ret

fix_one:                                ; HL = pointer value -> fixed
        ld      a,(fx_mode)
        or      a
        jr      nz,.del
        ld      de,(fx_off)
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        ret     c                       ; ptr < off: untouched
        ld      de,(fx_cnt)
        add     hl,de
        ret
.del:   ld      de,(fx_off)
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        ret     c                       ; ptr < off
        ld      de,(fx_end)
        push    hl
        or      a
        sbc     hl,de
        pop     hl
        jr      c,.inside
        ld      de,(fx_cnt)
        or      a
        sbc     hl,de
        ret
.inside: ld     hl,(fx_off)
        ret

; ---- slot_insert: HL = address in slot, BC = byte count ----------------------
; Opens a gap (contents undefined). CY set if it does not fit.
slot_insert:
        push    hl
        push    bc
        ld      hl,(song_len)
        add     hl,bc
        ld      de,SONG_BUDGET+1
        or      a
        sbc     hl,de
        pop     bc
        pop     hl
        jr      c,.fits
        scf
        ret
.fits:  push    hl                      ; [insert]
        push    bc                      ; [insert, count]
        ; bytes to move = (SLOT_BASE + song_len) - insert
        ex      de,hl                   ; DE = insert
        ld      hl,(song_len)
        ld      bc,SLOT_BASE
        add     hl,bc                   ; HL = end (exclusive)
        or      a
        sbc     hl,de                   ; HL = bytes to move
        ld      a,h
        or      l
        jr      z,.nomove
        push    hl
        pop     bc                      ; BC = bytes to move
        ld      hl,(song_len)
        ld      de,SLOT_BASE
        add     hl,de
        dec     hl                      ; HL = source = last byte
        pop     de                      ; DE = count
        push    de
        push    hl
        add     hl,de                   ; HL = dest = last byte + count
        ex      de,hl                   ; DE = dest
        pop     hl                      ; HL = source
        lddr
.nomove:
        pop     bc                      ; count
        pop     hl                      ; insert address
        ld      de,SLOT_BASE
        or      a
        sbc     hl,de
        ld      (fx_off),hl
        ld      (fx_cnt),bc
        xor     a
        ld      (fx_mode),a
        call    fix_all
        ld      hl,(song_len)
        add     hl,bc
        ld      (song_len),hl
        or      a
        ret

; ---- slot_delete: HL = address in slot, BC = byte count ----------------------
slot_delete:
        push    hl
        push    bc
        ; move [HL+BC, end) down to HL
        push    hl
        add     hl,bc                   ; HL = source
        ex      de,hl                   ; DE = source
        ld      hl,(song_len)
        push    de
        ld      de,SLOT_BASE
        add     hl,de                   ; HL = end
        pop     de
        or      a
        sbc     hl,de                   ; HL = bytes to move
        ld      b,h
        ld      c,l
        pop     hl                      ; HL = dest
        ld      a,b
        or      c
        jr      z,.nomove
        ex      de,hl                   ; HL = source, DE = dest
        ldir
.nomove:
        pop     bc
        pop     hl
        ld      de,SLOT_BASE
        or      a
        sbc     hl,de
        ld      (fx_off),hl
        ld      (fx_cnt),bc
        add     hl,bc
        ld      (fx_end),hl
        ld      a,1
        ld      (fx_mode),a
        call    fix_all
        ld      hl,(song_len)
        or      a
        sbc     hl,bc
        ld      (song_len),hl
        ret

; ---- stream_shared: A = pattern, C = channel, DE = offset -> NZ if any OTHER
;      table entry points at the same offset --------------------------------
stream_shared:
        ld      (ss_pat),a
        ld      a,c
        ld      (ss_ch),a
        ld      (ss_off),de
        ld      a,(num_pats)
        ld      b,a
        xor     a
        ld      (ss_p),a
        ld      hl,(SLOT_BASE+H_PATPTR)
        ld      de,SLOT_BASE
        add     hl,de
.pat:   push    bc
        xor     a
.ch:    push    af
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ; same (pat,ch)? skip
        ld      a,(ss_p)
        ld      c,a
        ld      a,(ss_pat)
        cp      c
        jr      nz,.cmp
        pop     af
        push    af
        ld      c,a
        ld      a,(ss_ch)
        cp      c
        jr      z,.next
.cmp:   push    hl
        ld      hl,(ss_off)
        or      a
        sbc     hl,de
        pop     hl
        jr      nz,.next
        pop     af
        pop     bc
        ld      a,1                     ; shared
        or      a
        ret
.next:  pop     af
        inc     a
        cp      3
        jr      nz,.ch
        ld      a,(ss_p)
        inc     a
        ld      (ss_p),a
        pop     bc
        djnz    .pat
        xor     a                       ; not shared (Z)
        ret

; ---- wp_load: A = pattern -> decode into WP, compute wp_old_bytes -------------
wp_load:
        ld      (wp_pat),a
        call    dec_pattern
        xor     a
        ld      (wp_dirty),a
        ld      hl,0
        ld      (wp_old_bytes),hl
        ld      a,(wp_pat)
        call    pat_entry_addr
        ld      c,0
.ch:    push    bc
        push    hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      a,(wp_pat)
        call    stream_shared
        jr      nz,.shared
        ld      hl,(song_len)
        ld      de,SLOT_BASE
        add     hl,de
        ld      (stream_limit),hl
        pop     hl
        push    hl
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,SLOT_BASE
        add     hl,de
        push    hl
        call    stream_end
        pop     de
        or      a
        sbc     hl,de                   ; HL = stream length
        ld      de,(wp_old_bytes)
        add     hl,de
        ld      (wp_old_bytes),hl
.shared:
        pop     hl
        inc     hl
        inc     hl
        pop     bc
        inc     c
        ld      a,c
        cp      3
        jr      nz,.ch
        ret

; ---- update_free: free_bytes = budget - song_len (+ old - projected if dirty)
update_free:
        ld      hl,SONG_BUDGET
        ld      de,(song_len)
        or      a
        sbc     hl,de
        ld      a,(wp_dirty)
        or      a
        jr      z,.store
        push    hl
        call    enc_pattern
        pop     hl
        jr      c,.zero
        ld      de,(wp_old_bytes)
        add     hl,de
        ld      de,(enc_total)
        or      a
        sbc     hl,de
        jr      c,.zero
        jr      .store
.zero:  ld      hl,0
.store: ld      (free_bytes),hl
        ret

; ---- commit_pattern: splice the (dirty) working pattern into the slot -------
; Returns CY set on failure (no room / too complex); the WP stays dirty.
commit_pattern:
        ld      a,(wp_dirty)
        or      a
        ret     z                       ; clean: nothing to do (CY clear)
        call    enc_pattern
        ret     c                       ; too complex for the staging area
        ; budget: song_len - old + new <= SONG_BUDGET
        ld      hl,(song_len)
        ld      de,(wp_old_bytes)
        or      a
        sbc     hl,de
        ld      de,(enc_total)
        add     hl,de
        ld      de,SONG_BUDGET+1
        or      a
        sbc     hl,de
        jr      c,.go
        scf
        ret
.go:    ld      c,0
.ch:    push    bc
        ld      a,(wp_pat)
        call    pat_entry_addr
        ld      a,c
        add     a,a
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    push    hl                      ; HL -> this channel's table entry
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      (cm_off),de
        ld      a,(wp_pat)
        call    stream_shared
        jr      nz,.insert
        ; unshared: delete the old stream first
        ld      hl,(song_len)
        ld      de,SLOT_BASE
        add     hl,de
        ld      (stream_limit),hl
        ld      hl,(cm_off)
        ld      de,SLOT_BASE
        add     hl,de
        push    hl
        call    stream_end
        pop     de
        or      a
        sbc     hl,de
        ld      b,h
        ld      c,l
        ex      de,hl
        call    slot_delete
.insert:
        pop     hl
        pop     bc
        push    bc
        push    hl
        ; new stream length / source
        ld      a,c
        add     a,a
        ld      e,a
        ld      d,0
        ld      ix,enc_off
        add     ix,de
        ld      c,(ix+6)
        ld      b,(ix+7)                ; BC = new length
        ld      hl,(cm_off)
        ld      de,SLOT_BASE
        add     hl,de
        push    bc
        call    slot_insert
        pop     bc
        jr      c,.fail
        ld      hl,(cm_off)
        ld      de,SLOT_BASE
        add     hl,de
        ex      de,hl                   ; DE = destination
        ld      l,(ix+0)
        ld      h,(ix+1)                ; HL = staging source
        ld      a,b
        or      c
        jr      z,.copied
        ldir
.copied:
        pop     hl                      ; table entry
        ld      de,(cm_off)
        ld      (hl),e
        inc     hl
        ld      (hl),d
        pop     bc
        inc     c
        ld      a,c
        cp      3
        jp      nz,.ch
        xor     a
        ld      (wp_dirty),a
        ld      hl,(enc_total)
        ld      (wp_old_bytes),hl
        call    update_free
        or      a
        ret
.fail:  pop     hl
        pop     bc
        scf
        ret

; ---- dedup_streams: make identical channel streams shared ---------------------
; Pass 1 caches every stream's length (a word per table entry at STAGE_BASE,
; index pattern*3+channel). Pass 2 looks, for each entry, for an EARLIER entry
; of the same length at a different offset with identical bytes; relinks to it
; and deletes the orphaned stream if nothing still points at it (fix_all keeps
; the table and instrument pointers right). Call with the WP committed (STAGE
; is scratch here) and reload the WP afterwards (wp_old_bytes may change).
DD_LEN      EQU STAGE_BASE
dedup_streams:
        ld      hl,(song_len)
        ld      de,SLOT_BASE
        add     hl,de
        ld      (stream_limit),hl
        ld      a,(num_pats)
        ld      b,a
        add     a,a
        add     a,b
        ld      (dd_n),a                ; entries (<= 255: at most 85 patterns)
        ; pass 1: lengths
        xor     a
        ld      (dd_i),a
.p1:    ld      a,(dd_i)
        call    dd_entry
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ld      hl,SLOT_BASE
        add     hl,de
        push    hl
        call    stream_end              ; (uses IX and the decoder scratch)
        pop     de
        or      a
        sbc     hl,de                   ; HL = length
        push    hl
        ld      a,(dd_i)
        call    dd_len                  ; HL -> cache word (uses DE)
        pop     de
        ld      (hl),e
        inc     hl
        ld      (hl),d
        ld      hl,dd_i
        inc     (hl)
        ld      a,(dd_n)
        cp      (hl)
        jr      nz,.p1
        ; pass 2
        ld      a,1
        ld      (dd_i),a
.i:     ld      a,(dd_i)
        ld      hl,dd_n
        cp      (hl)
        ret     nc
        xor     a
        ld      (dd_j),a
.j:     ld      a,(dd_i)
        call    dd_lenv                 ; HL = length of i
        push    hl
        ld      a,(dd_j)
        call    dd_lenv
        pop     de
        or      a
        sbc     hl,de                   ; same length?
        jp      nz,.nextj
        ld      a,(dd_i)
        call    dd_entry
        ld      e,(hl)
        inc     hl
        ld      d,(hl)                  ; DE = offset i
        push    de
        ld      a,(dd_j)
        call    dd_entry
        ld      c,(hl)
        inc     hl
        ld      b,(hl)                  ; BC = offset j
        pop     de
        ld      h,d
        ld      l,e
        or      a
        sbc     hl,bc
        jp      z,.nextj                ; already the same stream
        push    de                      ; [off_i]
        push    bc                      ; [off_i, off_j]
        ld      a,(dd_i)
        call    dd_lenv
        ld      b,h
        ld      c,l                     ; BC = length
        pop     de                      ; off_j
        pop     hl                      ; off_i
        push    hl
        push    de                      ; [off_i, off_j] again
        push    bc
        ld      bc,SLOT_BASE
        add     hl,bc                   ; HL = stream i
        ex      de,hl
        add     hl,bc                   ; HL = stream j
        ex      de,hl                   ; HL = i, DE = j
        pop     bc
.cmp:   ld      a,(de)
        cp      (hl)
        jr      nz,.diff
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.cmp
        ; identical: entry i -> offset j
        pop     bc                      ; off_j
        pop     de                      ; off_i
        push    de
        ld      a,(dd_i)
        call    dd_entry
        ld      (hl),c
        inc     hl
        ld      (hl),b
        ; does anything still use stream i?  (pattern = i/3, channel = i mod 3)
        ld      a,(dd_i)
        call    div3
        ld      b,a                     ; pattern
        add     a,a
        add     a,b
        ld      c,a
        ld      a,(dd_i)
        sub     c
        ld      c,a                     ; channel
        ld      a,b
        pop     de
        push    de
        call    stream_shared
        pop     de
        jr      nz,.nexti
        push    de
        ld      a,(dd_i)
        call    dd_lenv
        ld      b,h
        ld      c,l
        pop     de
        ld      hl,SLOT_BASE
        add     hl,de
        call    slot_delete             ; fix_all moves every table entry / instrument pointer
        jr      .nexti
.diff:  pop     bc
        pop     de
.nextj: ld      hl,dd_j
        inc     (hl)
        ld      a,(dd_i)
        cp      (hl)
        jp      nz,.j
.nexti: ld      hl,dd_i
        inc     (hl)
        jp      .i

dd_lenv:                                ; A = entry index -> HL = cached length value
        call    dd_len
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a
        ret
dd_len:                                 ; A = entry index -> HL -> cached length word
        ld      l,a
        ld      h,0
        add     hl,hl
        ld      de,DD_LEN
        add     hl,de
        ret
dd_entry:                               ; A = entry index -> HL -> its table word
        ld      l,a
        ld      h,0
        add     hl,hl
        ld      de,(SLOT_BASE+H_PATPTR)
        add     hl,de
        ld      de,SLOT_BASE
        add     hl,de
        ret

; ---- new_song: copy the template into the slot and initialise -----------------
new_song:
        ld      hl,template_pt3
        ld      de,SLOT_BASE
        ld      bc,template_end-template_pt3
        ldir
        ld      hl,template_end-template_pt3
        ld      (song_len),hl
        jp      song_init

; ---- slot_has_song: Z set if the slot starts with "ProTracker 3." -------------
slot_has_song:
        ld      de,sig_pt3
        ld      b,13
        call    .cmp
        ret     z
        ld      de,sig_vt2
        ld      b,14
.cmp:   ld      hl,SLOT_BASE
.l:     ld      a,(de)
        cp      (hl)
        ret     nz
        inc     hl
        inc     de
        djnz    .l
        xor     a
        ret
