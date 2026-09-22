; =============================================================================
; layout.inc -- TS Tracker v2: memory map + shared constants (Plan A)
;
;   $4000-$5AFF  display file + attributes
;   $5C00-$69FF  system variables, BASIC machine stack ($6000-$61FF), dispatcher,
;                the tiny BASIC loader -- untouched, so Quit returns to BASIC
;   $6A00-$6FFF  WP:    working pattern (the ONE decoded pattern being edited)
;   $7000-$7BFF  STAGE: encoder output / commit staging (3 KB)
;   $7C00-$7FFF  MISC:  scratch (encoder event lists, noise carriers, later the
;                tape directory)
;   $8000-$B7FF  this program + PTxPlay (one CODE block, 14 KB)
;   $B800-$FAFF  SLOT:  the PT3 song itself = the source of truth (16.75 KB)
;   $FB00-$FEFF  our stack (grows down from $FF00); $FF58+ UDGs (BASIC's)
; =============================================================================

SCREEN      EQU $4000
ATTRS       EQU $5800
ROMFONT     EQU $3C00           ; ROM charset is at $3D00 = $3C00 + 32*8
FRAMES      EQU $5C78           ; 60 Hz frame counter, bumped by the ROM ISR

KBD_PORT    EQU $FE
AY_REG      EQU $F5
AY_DAT      EQU $F6

CODE_BASE   EQU $8000
SLOT_BASE   EQU $B800            ; Phase 2: moved up from $AB00 for the tape/arrangement code
SLOT_END    EQU $FB00
SONG_BUDGET EQU SLOT_END-SLOT_BASE      ; 17152

WP_BASE     EQU $6A00
WP_ROWS     EQU 64
WP_ROWSZ    EQU 24              ; envper hi, envper lo, noise, 3 x 7-byte cells
WP_CELLSZ   EQU 7               ; note, smp|flags, env<<4|orn, vol<<4|cmd, p0, p1, p2
WP_SIZE     EQU WP_ROWS*WP_ROWSZ         ; 1536
WP_END      EQU WP_BASE+WP_SIZE          ; $7000

STAGE_BASE  EQU $7000
STAGE_END   EQU $7C00

MISC_BASE   EQU $7C00
EV_ROWS     EQU MISC_BASE               ; 64 B  encoder: rows carrying an event (one channel)
NZ_CARRIER  EQU MISC_BASE+64            ; 64 B  encoder: channel carrying the row's noise ($FF none)
SCRATCH_ROW EQU MISC_BASE+128           ; 24 B  dummy row for skip-decoding
LOOP_LIST   EQU MISC_BASE+160           ; 2 B   private position list for "loop pattern"
TAPE_HDR    EQU MISC_BASE+176           ; 17 B  tape header (type, name10, len, p1, p2)
DIR_BUF     EQU MISC_BASE+208           ; 9 x 14 B tape directory
DIR_MAX     EQU 9
DIR_ENTSZ   EQU 14
MISC_FREE   EQU MISC_BASE+336

STACK_TOP   EQU $FF00

; ---- PT3 header offsets ----
H_SPEED     EQU 100
H_NPOS      EQU 101
H_LOOP      EQU 102
H_PATPTR    EQU 103
H_SMPPTRS   EQU 105             ; 32 words
H_ORNPTRS   EQU 169             ; 16 words
H_POSLIST   EQU 201             ; bytes = pattern*3, $FF terminated

; ---- cell encoding ----
NOTE_NONE   EQU $FF             ; no event this row
NOTE_REST   EQU $FE             ; release (R--)
NOTE_EMPTY  EQU $FD             ; event without a new note (params only)
ENV_OFF     EQU 15
CF_ORNSET   EQU $20             ; byte1 bit5: ornament field is set
NZ_NONE     EQU $FF

; ---- screen layout (rows) ----
R_MENU0     EQU 0
R_INFO      EQU 3
R_HEAD      EQU 4
R_GRID      EQU 5
GRID_ROWS   EQU 15
R_CURSOR    EQU 12
R_RULE      EQU 20
R_DETAIL    EQU 21
R_FREE      EQU 22
R_HINT      EQU 23
CUR_OFS     EQU R_CURSOR-R_GRID

; ---- attributes (bright=$40, paper<<3, ink) ----
A_BLACK     EQU $00
A_MENU_SONG EQU $40|(1<<3)|7
A_MENU_EDIT EQU $40|(2<<3)|7
A_MENU_GOTO EQU $40|(3<<3)|7
A_MENU_TXT  EQU $07
A_MENU_HOT  EQU $46
A_LABEL     EQU $05
A_VALUE     EQU $47
A_RULE      EQU $07
A_ROWNUM    EQU $06
A_ROWNUM_B  EQU $46
A_CELL      EQU $04
A_CELL_B    EQU $44
A_CURROW    EQU $47
A_FIELD     EQU $40|(7<<3)|0
A_HINT      EQU (5<<3)|0
A_POSCUR    EQU $40|(5<<3)|0
A_ERROR     EQU $40|(2<<3)|7
A_DIM       EQU $01             ; dark blue-ish "beyond pattern end"

; custom glyphs (>=128 index custom_font)
G_VBAR      EQU 128
G_HBAR      EQU 129
G_TDOWN     EQU 130
G_TUP       EQU 131
G_CROSS     EQU 132

REPEAT_DELAY EQU 18
REPEAT_RATE  EQU 3

; ---- key bitmap: kb_now/kb_edge are 8 bytes, one per half-row ($FE..$7F) ----
; row index 0..7 = port high byte $FE,$FD,$FB,$F7,$EF,$DF,$BF,$7F
KR_CAPS EQU 0
KR_ASDFG EQU 1
KR_QWERT EQU 2
KR_12345 EQU 3
KR_09876 EQU 4
KR_POIUY EQU 5
KR_ENTER EQU 6
KR_SPACE EQU 7
