; =============================================================================
; keys.asm -- keyboard matrix scan with edge detection + cursor auto-repeat
;
; kb_now[8]  : pressed bits (1 = down) per half-row, row index 0..7 = $FE..$7F
; kb_edge[8] : bits that went down THIS frame (press edges)
; kb_rep[8]  : like kb_edge, but for CAPS+cursor keys it also fires on
;              auto-repeat while held
; Call kb_scan once per frame (after HALT).
; =============================================================================

kb_scan:
        ; copy now -> prev
        ld      hl,kb_now
        ld      de,kb_prev
        ld      bc,8
        ldir
        ; read the 8 half-rows
        ld      hl,kb_now
        ld      bc,$FEFE
.row:   in      a,(c)
        cpl
        and     $1F
        ld      (hl),a
        inc     hl
        rlc     b                       ; $FE -> $FD -> $FB ... -> $7F -> $FF(stop)
        jr      c,.row
        ; joystick (AY reg 14, active low: b0 R b1 L b2 D b3 U b4 fire) -> fold into
        ; CAPS+5/6/7/8 and SPACE so the rest of the program only sees keys
        ld      a,14
        out     (AY_REG),a
        in      a,(AY_DAT)
        cpl
        and     $1F
        jr      z,.edges
        ; sanity: a real stick cannot press everything, or left+right, or up+down
        ; at once -- an unplugged/undriven port (or an emulator returning 0 after
        ; the player touched the AY) must not read as "all keys held"
        cp      $1F
        jr      z,.edges
        ld      c,a
        and     $03
        cp      $03
        jr      z,.edges
        ld      a,c
        and     $0C
        cp      $0C
        jr      z,.edges
        ld      a,c
        ld      hl,kb_now
        set     0,(hl)                  ; CAPS
        ld      c,a
        bit     0,c
        jr      z,.j1
        ld      hl,kb_now+KR_09876
        set     2,(hl)                  ; 8 = right
.j1:    bit     1,c
        jr      z,.j2
        ld      hl,kb_now+KR_12345
        set     4,(hl)                  ; 5 = left
.j2:    bit     2,c
        jr      z,.j3
        ld      hl,kb_now+KR_09876
        set     4,(hl)                  ; 6 = down
.j3:    bit     3,c
        jr      z,.j4
        ld      hl,kb_now+KR_09876
        set     3,(hl)                  ; 7 = up
.j4:    bit     4,c
        jr      z,.edges
        ld      hl,kb_now+KR_SPACE
        set     0,(hl)
.edges:
        ; edge = now & ~prev
        ld      hl,kb_now
        ld      de,kb_prev
        ld      ix,kb_edge
        ld      b,8
.e:     ld      a,(de)
        cpl
        and     (hl)
        ld      (ix),a
        inc     hl
        inc     de
        inc     ix
        djnz    .e
        ; auto-repeat for the cursor cluster (CAPS + 5/6/7/8), timed in FRAMES so a
        ; slow redraw between scans does not slow the repeat rate
        ld      a,(FRAMES)
        ld      hl,kb_lastframe
        ld      e,a
        sub     (hl)
        ld      (hl),e
        ld      e,a                     ; E = frames since the last scan
        ld      a,(kb_now+KR_12345)
        and     $10
        rlca                            ; key 5 -> bit 5
        ld      c,a
        ld      a,(kb_now+KR_09876)
        and     $1C                     ; 8 7 6 -> bits 2..4
        or      c
        ld      c,a
        ld      a,(kb_now+KR_CAPS)
        and     1
        jr      z,.norep
        ld      a,c
        or      a
        jr      z,.norep
        ld      hl,kb_lastcur
        cp      (hl)
        jr      z,.held
        ld      (hl),a
        ld      a,REPEAT_DELAY
        ld      (kb_reptimer),a
        ret                             ; the press edge already fired this frame
.held:  ld      hl,kb_reptimer
        ld      a,(hl)
        sub     e
        jr      c,.fire
        jr      z,.fire
        ld      (hl),a
        ret
.fire:  ld      (hl),REPEAT_RATE
        ld      a,(kb_now+KR_12345)
        and     $10
        ld      hl,kb_edge+KR_12345
        or      (hl)
        ld      (hl),a
        ld      a,(kb_now+KR_09876)
        and     $1C
        ld      hl,kb_edge+KR_09876
        or      (hl)
        ld      (hl),a
        ret
.norep: xor     a
        ld      (kb_lastcur),a
        ret

; ---- modifier state --------------------------------------------------------
kb_caps:                                ; Z flag clear if CAPS held
        ld      a,(kb_now+KR_CAPS)
        and     1
        ret
kb_sym:                                 ; Z flag clear if SYMBOL SHIFT held
        ld      a,(kb_now+KR_SPACE)
        and     2
        ret

; kb_edge_test: B = row index, C = bit mask -> NZ if that key's edge is set
kb_edge_test:
        ld      hl,kb_edge
        ld      a,b
        add     a,l
        ld      l,a
        ld      a,(hl)
        and     c
        ret

; kb_any_now: NZ if any key is down
kb_any_now:
        ld      hl,kb_now
        ld      b,8
        xor     a
.l:     or      (hl)
        inc     hl
        djnz    .l
        ret

; kb_wait_none: wait until every key is released (drains a trigger key)
kb_wait_none:
        halt
        call    kb_scan
        call    kb_any_now
        jr      nz,kb_wait_none
        ret

; kb_wait_key: wait for any press edge, return with kb_edge valid
kb_wait_key:
        halt
        call    kb_scan
        ld      hl,kb_edge
        ld      b,8
        xor     a
.l:     or      (hl)
        inc     hl
        djnz    .l
        jr      z,kb_wait_key
        ret

; ---- letter lookup ---------------------------------------------------------
; kb_letter_edge: first letter/digit key with a press edge -> A = ASCII
; ('0'..'9','A'..'Z', 13 ENTER, 32 SPACE) or 0. Modifier keys map to 0.
kb_letter_edge:
        ld      hl,kb_edge
        ld      de,key_ascii            ; 8 rows x 5 chars
        ld      b,8
.row:   ld      a,(hl)
        and     $1F
        jr      z,.next
        ld      c,a
        push    hl
        push    de
        ex      de,hl                   ; HL = ascii row
.bit:   rr      c
        jr      nc,.nxbit
        ld      a,(hl)
        or      a
        jr      nz,.found               ; modifiers map to 0: keep scanning the row
.nxbit: inc     hl
        ld      a,c
        or      a
        jr      nz,.bit
        pop     de
        pop     hl
.next:  inc     hl
        inc     de
        inc     de
        inc     de
        inc     de
        inc     de
        djnz    .row
        xor     a
        ret
.found: pop     de
        pop     hl
        or      a
        ret

; key_ascii: row-major (row 0..7), bit 0..4 -> ASCII, 0 for modifiers
key_ascii:
        db      0,   'Z', 'X', 'C', 'V'         ; $FE: CAPS Z X C V
        db      'A', 'S', 'D', 'F', 'G'         ; $FD
        db      'Q', 'W', 'E', 'R', 'T'         ; $FB
        db      '1', '2', '3', '4', '5'         ; $F7
        db      '0', '9', '8', '7', '6'         ; $EF
        db      'P', 'O', 'I', 'U', 'Y'         ; $DF
        db      13,  'L', 'K', 'J', 'H'         ; $BF: ENTER L K J H
        db      32,  0,   'M', 'N', 'B'         ; $7F: SPACE SYM M N B
