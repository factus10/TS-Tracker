; =============================================================================
; data.asm -- tables, strings, glyphs, the new-song template
; =============================================================================

note_names:
        db      "C-C#D-D#E-F-F#G-G#A-A#B-"
base32: db      "0123456789ABCDEFGHIJKLMNOPQRSTUV"
field_ofs:
        db      0,4,5,6,7,8             ; note, smp, env, orn, vol, cmd (column within the cell)

; piano_map: 'A'..'Z' -> semitone, $FF = not a piano key
;            Z S X D C V G B H N J M  =  C C# D D# E F F# G G# A A# B
piano_map:
        db      $FF,7,4,3,$FF,$FF,6,8,$FF,10,$FF,$FF,11     ; A B C D E F G H I J K L M
        db      9,$FF,$FF,$FF,$FF,1,$FF,$FF,5,$FF,2,$FF,0   ; N O P Q R S T U V W X Y Z

sig_pt3: db     "ProTracker 3."

; ---- menu strips ----------------------------------------------------------
s_tag_song:  db " SONG",0
s_tag_edit:  db " EDIT",0
s_tag_goto:  db " GOTO",0
s_menu_song: db "^A Play ^L Loop ^N New ^Q Quit",0
s_menu_edit: db "^I Ins ^X Del ^Z Clear chan",0
s_menu_goto: db "^O Prev ^P Next pos  ^H Help",0
s_info:      db "Pos   /   Pat   /   Spd    Oct  ",0
s_head:      db "Rw",G_VBAR,"A   seovc",G_VBAR,"B   seovc",G_VBAR,"C   seovc",0
s_rule:      db G_HBAR,G_HBAR,G_TUP
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
s_detail:    db "Sm   Or  Vl  En  EP     Nz   L  ",0
s_free:      db "Free        Pos                 ",0
s_hint_edit: db " SYM+key=menu  CAPS+5678=cursor ",0
s_hint_play: db " Playing song -- any key stops  ",0
s_hint_loop: db " Looping pattern -- any key stops",0

; ---- messages (hint row, error colours) ------------------------------------
s_msg_noroom:       db "No room in song for this pattern",0
s_msg_later:        db "Not in this phase yet (see plan)",0
s_msg_confirm_new:  db "New song? All edits lost. Y/N   ",0
s_msg_confirm_quit: db "Quit to BASIC? Y/N              ",0
s_msg_confirm_clr:  db "Clear this channel? Y/N         ",0

; ---- splash --------------------------------------------------------------------
s_splash1: db "TS TRACKER 2",0
s_splash2: db "PT3 editor for the TS-2068",0
s_splash3: db "Phase 1 -- in-memory editing",0
s_splash4: db "^N new song    ^Q quit",0

; ---- help page (lines, '*' prefix = label colour, $FF ends) -------------------
help_text:
        db      "*TS TRACKER 2 -- KEYS",0
        db      0
        db      "*Cursor",0
        db      "CAPS+5/6/7/8 or stick  move",0
        db      "CAPS+1 insert row  CAPS+0 delete",0
        db      0
        db      "*Note field",0
        db      "Z S X D C V G B H N J M  piano",0
        db      "1-8 octave  ENTER rest  SPC clr",0
        db      0
        db      "*Other fields",0
        db      "s sample 1-9,A-V  e env 0=off",0
        db      "o ornament 0-F    v volume 1-F",0
        db      "SPACE clears the field",0
        db      0
        db      "*SYMBOL SHIFT + letter",0
        db      "A play  L loop pattern  N new",0
        db      "O/P prev/next position  Q quit",0
        db      "I insert row  X delete row",0
        db      "Z clear channel  H this page",0
        db      0
        db      "Any key returns to the editor.",0
        db      $FF

; ---- custom glyphs (>=128) ----------------------------------------------------
custom_font:
        db      $18,$18,$18,$18,$18,$18,$18,$18   ; 128 vertical bar
        db      $00,$00,$00,$FF,$FF,$00,$00,$00   ; 129 horizontal rule
        db      $00,$00,$00,$FF,$FF,$18,$18,$18   ; 130 T down
        db      $18,$18,$18,$FF,$FF,$00,$00,$00   ; 131 T up
        db      $18,$18,$18,$FF,$FF,$18,$18,$18   ; 132 cross

; ---- new-song template ------------------------------------------------------------
        INCLUDE "template.inc"
