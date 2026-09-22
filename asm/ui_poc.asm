; =============================================================================
; ui_poc.asm -- TS Tracker v2 UI renderer: PROOF OF CONCEPT (sjasmplus)
;
; Purpose: measure what a hand-written Z80 editor front-end buys us on the
; TS2068 before committing to a full rewrite. It draws the proposed
; SQ-Tracker-style screen (menu bars, boxed 3-channel grid with a centred
; cursor row, detail panel), renders straight into the display file with the
; ROM font at $3C00 (CHARS convention, glyph = $3C00 + code*8), and drives a
; cursor over a dummy 64-row pattern with keyboard auto-repeat.
;
; NOT a tracker yet: no PT3 codec, no PTxPlay, dummy pattern data. The point is
; the rendering/input feel and the code size. Build: `make asm-poc`.
;
; Keys:  CAPS+5/6/7/8 (or Kempston/2068 stick) = move cursor (auto-repeats)
;        SPACE = put a C-4 in the note field   ENTER = rest   DELETE = clear
;        1..8 = octave           Q = quit to BASIC
;        B / N = timing aids: 60 asm repaints / 10 ROM RST $10 repaints, in frames
; =============================================================================
        DEVICE NONE
        ORG     $8000
        OUTPUT  "build/asm/ui_poc.bin"

; ---- hardware / ROM ---------------------------------------------------------
SCREEN      EQU $4000
ATTRS       EQU $5800
ROMFONT     EQU $3C00           ; ROM char set is at $3D00 = $3C00 + 32*8
KBD_PORT    EQU $FE
AY_REG      EQU $F5
AY_DAT      EQU $F6

; ---- screen layout (rows) ---------------------------------------------------
R_MENU0     EQU 0
R_INFO      EQU 3
R_HEAD      EQU 4
R_GRID      EQU 5               ; first grid row
GRID_ROWS   EQU 15              ; rows 5..19
R_CURSOR    EQU 12              ; screen row that always holds the cursor
R_RULE      EQU 20
R_DETAIL    EQU 21
R_POSN      EQU 22
R_HINT      EQU 23
CUR_OFS     EQU R_CURSOR-R_GRID ; 7 rows above the cursor

PAT_ROWS    EQU 64
CELL_SIZE   EQU 4               ; note, sample, env<<4|orn, vol<<4|cmd
ROW_SIZE    EQU CELL_SIZE*3
NOTE_EMPTY  EQU $FF
NOTE_REST   EQU $FE

; ---- attributes (bright=0x40, paper<<3, ink) --------------------------------
A_BLACK     EQU $00
A_MENU_SONG EQU $40|(1<<3)|7    ; white on blue, bright
A_MENU_EDIT EQU $40|(2<<3)|7    ; white on red
A_MENU_GOTO EQU $40|(3<<3)|7    ; white on magenta
A_MENU_TXT  EQU $07             ; white on black
A_MENU_HOT  EQU $46             ; bright yellow on black
A_LABEL     EQU $05             ; cyan on black
A_VALUE     EQU $47             ; bright white on black
A_RULE      EQU $07
A_ROWNUM    EQU $06             ; yellow
A_ROWNUM_B  EQU $46             ; bright yellow (beat)
A_CELL      EQU $04             ; green
A_CELL_B    EQU $44             ; bright green (beat)
A_CURROW    EQU $47             ; bright white (cursor row)
A_FIELD     EQU $40|(7<<3)|0    ; black on bright white (cursor field)
A_HINT      EQU (5<<3)|0        ; black on cyan
A_POSCUR    EQU $40|(5<<3)|0    ; black on bright cyan

; custom glyph codes (>= 128 index custom_font)
G_VBAR      EQU 128
G_HBAR      EQU 129
G_TDOWN     EQU 130
G_TUP       EQU 131
G_CROSS     EQU 132

; key bits returned by read_keys
K_UP        EQU 0
K_DOWN      EQU 1
K_LEFT      EQU 2
K_RIGHT     EQU 3
K_SPACE     EQU 4
K_ENTER     EQU 5
K_DELETE    EQU 6
K_QUIT      EQU 7
FRAMES      EQU $5C78           ; ROM 60 Hz frame counter (low byte), bumped by the IM1 ISR

REPEAT_DELAY EQU 18             ; frames before auto-repeat starts (~0.3 s)
REPEAT_RATE  EQU 3              ; frames between repeats (20 rows/s)

; =============================================================================
start:
        di
        ld      (saved_sp),sp
        ld      sp,$FF00                ; own stack, clear of BASIC's ($61FE) and UDGs ($FF58)
        ld      a,0
        out     ($FE),a                 ; black border
        call    ay_silence
        call    build_dummy_pattern
        call    cls
        call    draw_static
        call    draw_grid
        call    draw_detail
        ei

main_loop:
        halt
        call    bench_key               ; B / N = PoC timing aids (see below)
        call    read_keys               ; A = key bits
        or      a
        jr      nz,.pressed
        xor     a
        ld      (last_keys),a
        jr      main_loop
.pressed:
        ld      hl,last_keys
        cp      (hl)
        jr      z,.held
        ld      (hl),a                  ; new combination: act now, arm delay
        ld      hl,repeat_timer
        ld      (hl),REPEAT_DELAY
        jr      .act
.held:
        ld      hl,repeat_timer
        dec     (hl)
        jr      nz,main_loop
        ld      (hl),REPEAT_RATE
.act:
        ld      (cur_keys),a
        bit     K_QUIT,a
        jr      nz,quit
        bit     K_UP,a
        call    nz,cursor_up
        ld      a,(cur_keys)
        bit     K_DOWN,a
        call    nz,cursor_down
        ld      a,(cur_keys)
        bit     K_LEFT,a
        call    nz,cursor_left
        ld      a,(cur_keys)
        bit     K_RIGHT,a
        call    nz,cursor_right
        ld      a,(cur_keys)
        bit     K_SPACE,a
        call    nz,edit_note
        ld      a,(cur_keys)
        bit     K_ENTER,a
        call    nz,edit_rest
        ld      a,(cur_keys)
        bit     K_DELETE,a
        call    nz,edit_clear
        call    read_octave_key
        call    draw_grid
        call    draw_detail
        jr      main_loop

quit:
        di
        call    ay_silence
        ld      sp,(saved_sp)
        ld      a,7
        out     ($FE),a
        ei
        ret

; =============================================================================
; Benchmark aids (PoC only).
;   B = repaint the grid 60 times with the asm renderer  -> frames/60 repaints
;   N = paint the same 15x32 area 10 times via the ROM's RST $10 (AT + PAPER
;       codes + 32 chars per row, i.e. the v1 tracker's print path)
;       -> frames/10 repaints
; Both use the ROM's 60 Hz FRAMES counter, so no emulator tricks are needed.
; Results are shown on the hint row and kept in bench_asm / bench_rom.
; =============================================================================
bench_key:
        ld      bc,$7FFE
        in      a,(c)
        bit     4,a                     ; B
        jr      z,.asm
        bit     3,a                     ; N
        ret     nz
        ; ---- N: ROM print path, 10 repaints ----
        ld      a,(FRAMES)
        ld      (bench_t0),a
        ld      b,10
.rom_rep:
        push    bc
        ld      b,R_GRID
.rom_row:
        push    bc
        ld      a,$16                   ; AT row,0
        rst     $10
        ld      a,b
        rst     $10
        xor     a
        rst     $10
        ld      a,$11                   ; PAPER 0 (v1 sets PAPER per row)
        rst     $10
        xor     a
        rst     $10
        ld      b,32
.rom_ch:
        ld      a,'X'
        rst     $10
        djnz    .rom_ch
        pop     bc
        inc     b
        ld      a,b
        cp      R_GRID+GRID_ROWS
        jr      nz,.rom_row
        pop     bc
        djnz    .rom_rep
        ld      a,(FRAMES)
        ld      hl,bench_t0
        sub     (hl)
        ld      (bench_rom),a
        call    cls                     ; ROM print trashed attrs: rebuild everything
        call    draw_static
        call    draw_grid
        call    draw_detail
        jr      .show
.asm:   ; ---- B: asm renderer, 60 repaints ----
        ld      a,(FRAMES)
        ld      (bench_t0),a
        ld      b,60
.loop:  push    bc
        call    draw_grid
        pop     bc
        djnz    .loop
        ld      a,(FRAMES)
        ld      hl,bench_t0
        sub     (hl)                    ; wraps correctly for < 256 frames
        ld      (bench_asm),a
.show:
        ld      bc,(R_HINT<<8)|0
        ld      hl,s_bench
        ld      a,A_HINT
        call    print_at
        ld      a,R_HINT
        ld      c,8
        call    scr_addr
        ld      a,(bench_asm)
        call    put_dec3
        ld      a,R_HINT
        ld      c,23
        call    scr_addr
        ld      a,(bench_rom)
        call    put_dec3
        ld      bc,$7FFE
.wait:  in      a,(c)
        and     $18
        cp      $18
        jr      nz,.wait                ; wait for B and N release
        ret

; put_dec3: A = 0..255 as 3 decimal digits at DE
put_dec3:
        ld      b,'0'-1
.h:     inc     b
        sub     100
        jr      nc,.h
        add     a,100
        push    af
        ld      a,b
        call    put_char_adv
        pop     af
        jp      put_dec2

; =============================================================================
; Cursor movement
; =============================================================================
cursor_up:
        ld      a,(cur_row)
        or      a
        ret     z
        dec     a
        ld      (cur_row),a
        ret
cursor_down:
        ld      a,(cur_row)
        cp      PAT_ROWS-1
        ret     z
        inc     a
        ld      (cur_row),a
        ret
cursor_left:
        ld      a,(cur_field)
        or      a
        jr      z,.prev_chan
        dec     a
        ld      (cur_field),a
        ret
.prev_chan:
        ld      a,(cur_chan)
        or      a
        ret     z
        dec     a
        ld      (cur_chan),a
        ld      a,5
        ld      (cur_field),a
        ret
cursor_right:
        ld      a,(cur_field)
        cp      5
        jr      z,.next_chan
        inc     a
        ld      (cur_field),a
        ret
.next_chan:
        ld      a,(cur_chan)
        cp      2
        ret     z
        inc     a
        ld      (cur_chan),a
        xor     a
        ld      (cur_field),a
        ret

; HL -> cursor cell (pattern + row*12 + chan*4)
cursor_cell:
        ld      a,(cur_row)
        ld      l,a
        ld      h,0
        add     hl,hl                   ; *2
        ld      d,h
        ld      e,l
        add     hl,hl                   ; *4
        add     hl,de                   ; *6
        add     hl,hl                   ; *12
        ld      a,(cur_chan)
        add     a,a
        add     a,a                     ; chan*4
        ld      e,a
        ld      d,0
        add     hl,de
        ld      de,pattern
        add     hl,de
        ret

; SPACE: write note C at the current octave, sample 1, vol F (so the cell shows)
edit_note:
        call    cursor_cell
        ld      a,(octave)
        dec     a
        ld      b,a
        add     a,a                     ; *2
        add     a,a                     ; *4
        add     a,b                     ; *5
        add     a,a                     ; *10
        add     a,b                     ; *11
        add     a,b                     ; *12  -> (oct-1)*12 = C of that octave
        ld      (hl),a
        inc     hl
        ld      (hl),1                  ; sample 1
        inc     hl
        ld      (hl),0                  ; env/orn none
        inc     hl
        ld      (hl),$F0                ; vol F, no cmd
        ret
edit_rest:
        call    cursor_cell
        ld      (hl),NOTE_REST
        ret
edit_clear:
        call    cursor_cell
        ld      (hl),NOTE_EMPTY
        inc     hl
        ld      (hl),0
        inc     hl
        ld      (hl),0
        inc     hl
        ld      (hl),0
        ret

; 1..8 sets the octave (no auto-repeat needed; cheap to poll each tick).
; Ignored while CAPS is held -- CAPS+5..8 are the cursor keys.
read_octave_key:
        ld      bc,$FEFE
        in      a,(c)
        and     1
        ret     z                       ; CAPS down -> not an octave key
        ld      bc,$F7FE                ; 1 2 3 4 5
        in      a,(c)
        cpl
        and     $0F                     ; 1..4 (bit4 = 5 is a cursor key with CAPS)
        ld      e,1
        call    .scan
        ld      bc,$EFFE                ; 0 9 8 7 6  (bit4 = 6)
        in      a,(c)
        cpl
        and     $10
        ret     z
        ld      a,6
        ld      (octave),a
        ret
.scan:  or      a
        ret     z
.loop:  rra
        jr      c,.hit
        inc     e
        jr      .loop
.hit:   ld      a,e
        ld      (octave),a
        ret

; =============================================================================
; Keyboard: A = bitmask of K_* (see EQUs). Cursor keys = CAPS + 5/6/7/8.
; =============================================================================
read_keys:
        ld      d,0
        ld      bc,$FEFE                ; CAPS Z X C V
        in      a,(c)
        cpl
        and     1
        ld      e,a                     ; E = CAPS held
        ; Q (row $FB bit0)
        ld      b,$FB
        in      a,(c)
        cpl
        and     1
        jr      z,.no_q
        set     K_QUIT,d
.no_q:
        ; SPACE (row $7F bit0)
        ld      b,$7F
        in      a,(c)
        cpl
        and     1
        jr      z,.no_sp
        ld      a,e
        or      a
        jr      nz,.no_sp               ; CAPS+SPACE = BREAK, ignore
        set     K_SPACE,d
.no_sp:
        ; ENTER (row $BF bit0)
        ld      b,$BF
        in      a,(c)
        cpl
        and     1
        jr      z,.no_en
        set     K_ENTER,d
.no_en:
        ld      a,e
        or      a
        jr      z,.no_caps
        ; CAPS held: 5 (row $F7 bit4) = left; 6/7/8 (row $EF bits 4/3/2); 0 (row $EF bit0) = DELETE
        ld      b,$F7
        in      a,(c)
        cpl
        bit     4,a
        jr      z,.n5
        set     K_LEFT,d
.n5:    ld      b,$EF
        in      a,(c)
        cpl
        bit     4,a
        jr      z,.n6
        set     K_DOWN,d
.n6:    bit     3,a
        jr      z,.n7
        set     K_UP,d
.n7:    bit     2,a
        jr      z,.n8
        set     K_RIGHT,d
.n8:    bit     0,a
        jr      z,.no_caps
        set     K_DELETE,d
.no_caps:
        ; TS2068 joystick via AY reg 14 (active low): bit0 R, bit1 L, bit2 D, bit3 U, bit4 fire
        ld      a,14
        out     (AY_REG),a
        in      a,(AY_DAT)
        cpl
        and     $1F
        jr      z,.done
        bit     3,a
        jr      z,.ju
        set     K_UP,d
.ju:    bit     2,a
        jr      z,.jd
        set     K_DOWN,d
.jd:    bit     1,a
        jr      z,.jl
        set     K_LEFT,d
.jl:    bit     0,a
        jr      z,.jr
        set     K_RIGHT,d
.jr:    bit     4,a
        jr      z,.done
        set     K_SPACE,d
.done:
        ld      a,d
        ret

ay_silence:
        ld      a,7
        out     (AY_REG),a
        ld      a,$3F                   ; all tone+noise off, I/O ports input
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

; =============================================================================
; Screen primitives
; =============================================================================
; Clear pixels + set every attribute to black-on-black
cls:
        ld      hl,SCREEN
        ld      de,SCREEN+1
        ld      bc,6143
        ld      (hl),0
        ldir
        ld      hl,ATTRS
        ld      de,ATTRS+1
        ld      bc,767
        ld      (hl),A_BLACK
        ldir
        ret

; A=row, C=col -> DE = pixel address (top scanline), HL = attribute address
; row addr = $4000 | (row&$18)<<8 | (row&7)<<5 | col
scr_addr:
        push    af
        and     $18
        or      $40
        ld      d,a
        pop     af
        push    af
        and     7
        rrca
        rrca
        rrca                            ; (row&7)<<5
        or      c
        ld      e,a
        pop     af                      ; attr = $5800 + row*32 + col
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,c
        or      l
        ld      l,a
        ld      a,h
        or      $58
        ld      h,a
        ret

; Draw glyph A at pixel address DE. Preserves DE, HL, BC (callers keep the
; attribute pointer in HL and loop counters in BC across calls).
put_char:
        push    af
        push    de
        push    hl
        push    bc
        cp      128
        jr      c,.rom
        sub     128
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      bc,custom_font
        add     hl,bc
        jr      .draw
.rom:   ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      bc,ROMFONT
        add     hl,bc
.draw:
        DUP 7
        ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     d
        EDUP
        ld      a,(hl)
        ld      (de),a
        pop     bc
        pop     hl
        pop     de
        pop     af
        ret

; print_at: B=row, C=col, HL=0-terminated string, A=attr for every char.
; Markup: '^' makes the NEXT char use the attribute in (hot_attr) instead.
print_at:
        ld      (cur_attr),a
        ld      a,b
        push    hl
        call    scr_addr                ; DE=pixels, HL=attrs
        pop     ix                      ; IX = string  (pop into IX via stack trick)
        ; ...sjasmplus: POP IX is legal (DD E1)
.loop:
        ld      a,(ix)
        or      a
        ret     z
        inc     ix
        cp      '^'
        jr      nz,.normal
        ld      a,(ix)
        inc     ix
        call    put_char
        ld      a,(hot_attr)
        ld      (hl),a
        inc     hl
        inc     e
        jr      .loop
.normal:
        call    put_char
        ld      a,(cur_attr)
        ld      (hl),a
        inc     hl
        inc     e
        jr      .loop

; fill_attr: B=row, C=col, E=count, A=attr
fill_attr:
        ld      d,a
        ld      a,b
        push    de
        call    scr_addr
        pop     de
        ld      a,d
.l:     ld      (hl),a
        inc     hl
        dec     e
        jr      nz,.l
        ret

; put_hex2 / put_dec2: A = value, DE = pixel addr -> advances DE by 2
put_dec2:
        ld      b,'0'-1
.tens:  inc     b
        sub     10
        jr      nc,.tens
        add     a,10
        ld      c,a
        ld      a,b
        call    put_char
        inc     e
        ld      a,c
        add     a,'0'
        call    put_char
        inc     e
        ret
put_hex1:                               ; A = 0..15 -> char
        cp      10
        jr      c,.d
        add     a,'A'-10
        jr      put_char_adv
.d:     add     a,'0'
put_char_adv:                           ; draw A, advance DE
        call    put_char
        inc     e
        ret
put_dot_or_hex1:                        ; 0 -> '.', else hex digit
        or      a
        jr      nz,put_hex1
        ld      a,'.'
        jr      put_char_adv

; =============================================================================
; Static chrome: menus, info line, header, rule, hint
; =============================================================================
draw_static:
        ld      a,A_MENU_HOT
        ld      (hot_attr),a
        ; menu bars: tag (inverse colour block) + items with ^hotkeys
        ld      bc,(R_MENU0<<8)|0
        ld      hl,s_tag_song
        ld      a,A_MENU_SONG
        call    print_at
        ld      bc,(R_MENU0<<8)|6
        ld      hl,s_menu_song
        ld      a,A_MENU_TXT
        call    print_at
        ld      bc,((R_MENU0+1)<<8)|0
        ld      hl,s_tag_edit
        ld      a,A_MENU_EDIT
        call    print_at
        ld      bc,((R_MENU0+1)<<8)|6
        ld      hl,s_menu_edit
        ld      a,A_MENU_TXT
        call    print_at
        ld      bc,((R_MENU0+2)<<8)|0
        ld      hl,s_tag_goto
        ld      a,A_MENU_GOTO
        call    print_at
        ld      bc,((R_MENU0+2)<<8)|6
        ld      hl,s_menu_goto
        ld      a,A_MENU_TXT
        call    print_at
        ; info line: labels cyan, values bright white via ^ markup
        ld      a,A_VALUE
        ld      (hot_attr),a
        ld      bc,(R_INFO<<8)|0
        ld      hl,s_info
        ld      a,A_LABEL
        call    print_at
        ; header
        ld      bc,(R_HEAD<<8)|0
        ld      hl,s_head
        ld      a,A_LABEL
        call    print_at
        ; header separators white
        ld      bc,(R_HEAD<<8)|2
        ld      e,1
        ld      a,A_RULE
        call    fill_attr
        ld      bc,(R_HEAD<<8)|12
        ld      e,1
        ld      a,A_RULE
        call    fill_attr
        ld      bc,(R_HEAD<<8)|22
        ld      e,1
        ld      a,A_RULE
        call    fill_attr
        ; bottom rule
        ld      bc,(R_RULE<<8)|0
        ld      hl,s_rule
        ld      a,A_RULE
        call    print_at
        ; detail labels
        ld      bc,(R_DETAIL<<8)|0
        ld      hl,s_detail
        ld      a,A_LABEL
        call    print_at
        ld      bc,(R_POSN<<8)|0
        ld      hl,s_posn
        ld      a,A_LABEL
        call    print_at
        ld      bc,(R_POSN<<8)|14
        ld      e,2
        ld      a,A_POSCUR
        call    fill_attr
        ; hint bar
        ld      bc,(R_HINT<<8)|0
        ld      hl,s_hint
        ld      a,A_HINT
        call    print_at
        ret

; =============================================================================
; Grid: 15 rows, cursor row fixed at screen row 12. Full redraw each call.
; =============================================================================
draw_grid:
        ld      a,(cur_row)
        sub     CUR_OFS                 ; top pattern row (may be negative)
        ld      (grid_top),a
        ld      b,R_GRID
.row:
        push    bc
        ld      a,(grid_top)
        ld      c,a                     ; C = pattern row for this screen row
        ld      a,b
        sub     R_GRID
        add     a,c                     ; A = prow (signed 8-bit)
        ld      (cur_prow),a
        ld      a,b
        ld      c,0
        call    scr_addr                ; DE pixels, HL attrs for (row,0)
        ld      a,(cur_prow)
        cp      PAT_ROWS
        jr      c,.in_range             ; 0..63 (negative wraps >= 192 -> blank)
        call    blank_row
        jr      .next
.in_range:
        call    draw_row
.next:
        pop     bc
        inc     b
        ld      a,b
        cp      R_GRID+GRID_ROWS
        jr      nz,.row
        ret

; Row out of range: two spaces, separators, blank cells
blank_row:
        push    hl
        ld      a,' '
        call    put_char_adv
        call    put_char_adv
        ld      a,G_VBAR
        call    put_char_adv
        ld      b,3
.cell:  push    bc
        ld      b,9
.sp:    ld      a,' '
        call    put_char_adv
        djnz    .sp
        pop     bc
        dec     b
        jr      z,.done
        ld      a,G_VBAR
        call    put_char_adv
        jr      .cell
.done:  pop     hl
        ld      a,A_RULE
        ld      (hl),a                  ; nothing else to colour on a blank row
        ret

; draw_row: (cur_prow) = pattern row, DE = pixels at col 0, HL = attrs at col 0
draw_row:
        push    hl                      ; keep attr pointer
        ; --- row number (decimal, SQ style) ---
        ld      a,(cur_prow)
        call    put_dec2
        ld      a,G_VBAR
        call    put_char_adv
        ; --- cell pointer: pattern + prow*12 ---
        ld      a,(cur_prow)
        ld      l,a
        ld      h,0
        add     hl,hl
        ld      b,h
        ld      c,l
        add     hl,hl
        add     hl,bc                   ; *6
        add     hl,hl                   ; *12
        ld      bc,pattern
        add     hl,bc
        ld      (cell_ptr),hl
        ld      b,0                     ; channel
.chan:
        push    bc
        ld      hl,(cell_ptr)
        call    draw_cell               ; advances DE by 9, HL by 4
        ld      (cell_ptr),hl
        pop     bc
        inc     b
        ld      a,b
        cp      3
        jr      z,.attrs
        ld      a,G_VBAR
        call    put_char_adv
        jr      .chan
.attrs:
        ; --- attributes for the whole row ---
        pop     hl                      ; HL = attrs at col 0
        ld      a,(cur_prow)
        ld      c,a
        ld      a,(cur_row)
        cp      c
        jr      z,.cursor_row
        ; normal / beat row
        ld      a,c
        and     3
        ld      a,A_ROWNUM
        ld      b,A_CELL
        jr      nz,.paint
        ld      a,A_ROWNUM_B
        ld      b,A_CELL_B
.paint:
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),A_RULE             ; separator
        inc     hl
        ld      a,b
        call    paint_cells
        ret
.cursor_row:
        ld      a,A_CURROW
        ld      (hl),a
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),A_RULE
        inc     hl
        push    hl
        ld      a,A_CURROW
        call    paint_cells
        pop     hl                      ; HL = attrs at col 3 (channel A cell start)
        ; field highlight: col = 3 + chan*10 + field_ofs, width 3 for note else 1
        ld      a,(cur_chan)
        ld      b,a
        add     a,a
        add     a,a
        add     a,a
        add     a,b
        add     a,b                     ; chan*10
        ld      c,a
        ld      a,(cur_field)
        push    hl
        ld      hl,field_ofs
        add     a,l
        ld      l,a
        jr      nc,.nc
        inc     h
.nc:    ld      a,(hl)
        pop     hl
        add     a,c
        ld      c,a
        ld      b,0
        add     hl,bc
        ld      a,(cur_field)
        or      a
        ld      a,A_FIELD
        ld      (hl),a
        ret     nz                      ; single-char field
        inc     hl
        ld      (hl),a
        inc     hl
        ld      (hl),a                  ; note field is 3 wide
        ret

; paint_cells: A = attr; HL = attrs at col 3; paints 9,sep,9,sep,9
paint_cells:
        ld      b,3
.c:     ld      c,9
.k:     ld      (hl),a
        inc     hl
        dec     c
        jr      nz,.k
        dec     b
        ret     z
        ld      (hl),A_RULE
        inc     hl
        jr      .c

; draw_cell: HL -> cell (4 bytes), DE = pixels. Emits 9 chars "NNN SEOVC".
draw_cell:
        push    hl
        ld      a,(hl)                  ; note
        cp      NOTE_EMPTY
        jr      z,.empty
        cp      NOTE_REST
        jr      z,.rest
        ; note name: semitone = note % 12, octave = note / 12 + 1
        ld      c,0
.div:   cp      12
        jr      c,.divdone
        sub     12
        inc     c
        jr      .div
.divdone:
        push    bc
        add     a,a                     ; *2 into note_names
        ld      hl,note_names
        add     a,l
        ld      l,a
        jr      nc,.nc1
        inc     h
.nc1:   ld      a,(hl)
        call    put_char_adv
        inc     hl
        ld      a,(hl)
        call    put_char_adv
        pop     bc
        ld      a,c
        inc     a
        add     a,'0'
        call    put_char_adv
        jr      .fields
.empty:
        ld      a,'-'
        call    put_char_adv
        call    put_char_adv
        call    put_char_adv
        jr      .fields
.rest:
        ld      a,'R'
        call    put_char_adv
        ld      a,'-'
        call    put_char_adv
        call    put_char_adv
.fields:
        ld      a,' '
        call    put_char_adv
        pop     hl
        inc     hl
        ld      a,(hl)                  ; sample 0..31 -> base32 char or '.'
        or      a
        jr      z,.nosmp
        push    hl
        ld      hl,base32
        add     a,l
        ld      l,a
        jr      nc,.nc2
        inc     h
.nc2:   ld      a,(hl)
        pop     hl
        call    put_char_adv
        jr      .env
.nosmp: ld      a,'.'
        call    put_char_adv
.env:   inc     hl
        ld      a,(hl)                  ; env<<4 | orn
        rrca
        rrca
        rrca
        rrca
        and     $0F
        call    put_dot_or_hex1
        ld      a,(hl)
        and     $0F
        call    put_dot_or_hex1
        inc     hl
        ld      a,(hl)                  ; vol<<4 | cmd
        rrca
        rrca
        rrca
        rrca
        and     $0F
        call    put_dot_or_hex1
        ld      a,(hl)
        and     $0F
        call    put_dot_or_hex1
        inc     hl                      ; HL -> next cell
        ret

; =============================================================================
; Detail panel: cursor cell's Smp/Orn/Vol/Env + octave + row/chan readout
; =============================================================================
draw_detail:
        call    cursor_cell
        push    hl
        ld      a,R_DETAIL
        ld      c,3
        call    scr_addr
        pop     hl
        inc     hl
        ld      a,(hl)                  ; sample -> 2 hex
        push    hl
        rrca
        rrca
        rrca
        rrca
        and     $0F
        call    put_hex1
        pop     hl
        ld      a,(hl)
        and     $0F
        call    put_hex1
        inc     hl
        ld      a,(hl)                  ; env/orn
        push    hl
        and     $0F
        ld      c,a                     ; orn
        ld      a,(hl)
        rrca
        rrca
        rrca
        rrca
        and     $0F
        ld      b,a                     ; env
        ; Orn at col 9
        ld      a,R_DETAIL
        push    bc
        ld      c,9
        call    scr_addr
        pop     bc
        ld      a,c
        call    put_dot_or_hex1
        ; Env at col 19
        push    bc
        ld      a,R_DETAIL
        ld      c,19
        call    scr_addr
        pop     bc
        ld      a,b
        call    put_dot_or_hex1
        pop     hl
        inc     hl
        ld      a,(hl)                  ; vol
        rrca
        rrca
        rrca
        rrca
        and     $0F
        push    af
        ld      a,R_DETAIL
        ld      c,14
        call    scr_addr
        pop     af
        call    put_dot_or_hex1
        ; octave value on the info line (col 27)
        ld      a,R_INFO
        ld      c,31
        call    scr_addr
        ld      a,(octave)
        add     a,'0'
        call    put_char
        ret

; =============================================================================
; Dummy pattern so the grid has something to show (a riff + bass + chords)
; =============================================================================
build_dummy_pattern:
        ld      hl,pattern
        ld      de,pattern+1
        ld      bc,PAT_ROWS*ROW_SIZE-1
        ld      (hl),0
        ldir
        ; clear notes to EMPTY
        ld      hl,pattern
        ld      b,PAT_ROWS*3
.clr:   ld      (hl),NOTE_EMPTY
        inc     hl
        inc     hl
        inc     hl
        inc     hl
        djnz    .clr
        ; channel A: arpeggio every 2 rows
        ld      hl,pattern
        ld      b,0
.a:     ld      a,b
        and     1
        jr      nz,.a_skip
        ld      a,b
        rrca
        and     7
        push    hl
        ld      hl,riff
        add     a,l
        ld      l,a
        ld      a,(hl)
        pop     hl
        ld      (hl),a
        inc     hl
        ld      (hl),1                  ; sample 1
        inc     hl
        ld      (hl),$00
        inc     hl
        ld      (hl),$F0                ; vol F
        dec     hl
        dec     hl
        dec     hl
.a_skip:
        ; channel B: bass C-2 every 4, rest on +2
        push    hl
        inc     hl
        inc     hl
        inc     hl
        inc     hl                      ; -> chan B
        ld      a,b
        and     3
        jr      nz,.b_not0
        ld      (hl),12                 ; C-2
        inc     hl
        ld      (hl),2
        inc     hl
        ld      (hl),$01                ; orn 1
        inc     hl
        ld      (hl),$A0
        jr      .b_done
.b_not0:
        cp      2
        jr      nz,.b_done
        ld      (hl),NOTE_REST
.b_done:
        pop     hl
        ; channel C: chord stab on rows 4,6 of each 8
        push    hl
        ld      de,8
        add     hl,de                   ; -> chan C
        ld      a,b
        and     7
        cp      4
        jr      z,.c_hit
        cp      6
        jr      nz,.c_done
        ld      a,43                    ; G-4
        jr      .c_put
.c_hit: ld      a,36                    ; C-4
.c_put: ld      (hl),a
        inc     hl
        ld      (hl),3
        inc     hl
        ld      (hl),$00
        inc     hl
        ld      (hl),$C0
.c_done:
        pop     hl
        ld      de,ROW_SIZE
        add     hl,de
        inc     b
        ld      a,b
        cp      PAT_ROWS
        jr      nz,.a
        ret

riff:   db      36, 40, 43, 48, 43, 40, 36, 31     ; C-4 E-4 G-4 C-5 G-4 E-4 C-4 G-3

; =============================================================================
; Data
; =============================================================================
note_names:
        db      "C-C#D-D#E-F-F#G-G#A-A#B-"
base32: db      "0123456789ABCDEFGHIJKLMNOPQRSTUV"
field_ofs:
        db      0,4,5,6,7,8             ; note, smp, env, orn, vol, cmd (col within cell)

s_tag_song: db  " SONG",0
s_tag_edit: db  " EDIT",0
s_tag_goto: db  " GOTO",0
s_menu_song: db "^Play ^Loop ^New ^Save ^Ld ^Quit",0
s_menu_edit: db "^Ins ^Del ^Copy ^Pste ^Trns ^Clr",0
s_menu_goto: db "^Pat ^Posn ^Smp ^Orn ^Help",0
s_info: db      "Pos ^0^3/^1^2 Pat ^0^5/^1^4 Spd ^0^6 Oct ^4",0
s_head: db      "Rw",G_VBAR,"A   seovc",G_VBAR,"B   seovc",G_VBAR,"C   seovc",0
s_rule: db      G_HBAR,G_HBAR,G_TUP
        DUP 9
        db      G_HBAR
        EDUP
        db      G_TUP
        DUP 9
        db      G_HBAR
        EDUP
        db      G_TUP
        DUP 9
        db      G_HBAR
        EDUP
        db      0
s_detail: db    "Sm    Or   Vl   En   Free ^1^2^3^4^5",0
s_posn: db      "Posn 00 01 02 03 04 05 ..  L=03",0
s_hint: db      " CAPS+arrows  SPC note  Q quit  ",0
s_bench: db     "asm x60=    fr  ROM x10=    fr  ",0

custom_font:
        db      $18,$18,$18,$18,$18,$18,$18,$18   ; 128 vertical bar
        db      $00,$00,$00,$FF,$FF,$00,$00,$00   ; 129 horizontal rule
        db      $00,$00,$00,$FF,$FF,$18,$18,$18   ; 130 T down
        db      $18,$18,$18,$FF,$FF,$00,$00,$00   ; 131 T up
        db      $18,$18,$18,$FF,$FF,$18,$18,$18   ; 132 cross

; ---- variables ---------------------------------------------------------------
saved_sp:     dw 0
last_keys:    db 0
cur_keys:     db 0
repeat_timer: db 0
cur_row:      db 21
cur_chan:     db 1
cur_field:    db 0
octave:       db 4
grid_top:     db 0
cur_prow:     db 0
cur_attr:     db 0
hot_attr:     db 0
cell_ptr:     dw 0
bench_t0:     db 0
bench_asm:    db 0
bench_rom:    db 0

code_end:
pattern:      ds PAT_ROWS*ROW_SIZE      ; 768 B dummy pattern (BSS, not in the tap? it IS emitted -- fine for a PoC)
end:
        DISPLAY "ui_poc code+data: ", /D, code_end-start, " bytes; with pattern: ", /D, end-start
