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
sig_vt2: db     "Vortex Tracker"

; ---- menu strips ----------------------------------------------------------
s_tag_song:  db " SONG",0
s_tag_edit:  db " EDIT",0
s_tag_goto:  db " GOTO",0
s_menu_song: db "^A Play ^L Loop ^S Save ^D Load",0
s_menu_edit: db "^I^X Row ^Z Clr ^E Smp ^R Orn",0
s_menu_goto: db "^O^P Pos ^F Arr ^G Info ^Q Quit",0
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
s_hint_edit: db " SYM+H help    CAPS+5678 cursor ",0
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
s_start_keys:  db "^S  scan a song tape",0
s_start_keys2: db "^N  new song     ^Q  quit",0

; ---- tape directory / load / save ----------------------------------------------
s_dir_title:  db "TAPE DIRECTORY",0
s_dir_sub:    db "#  T  name        bytes",0
s_dir_none:   db "(no songs found on the tape)",0
s_scan_hint:  db "Scanning...",0
s_hint_scan:  db " Play the tape. SPACE when it ends",0
s_hint_dir:   db " 1-9 load  R rescan  N new  Q back",0
s_hint_loading: db " Loading... SPACE aborts         ",0
s_msg_rewind:   db "Rewind tape, then any key (Q=no)",0
s_msg_loadfail: db "Load failed or stopped -- any key",0
s_msg_notpt3:   db "Not a PT3 song (PT2?) -- any key ",0
s_msg_confirm_load: db "Load from tape? Song is lost Y/N",0
s_save_title: db "SAVE TO TAPE",0
s_save_l1:    db "Filename (8 chars) + version",0
s_save_l2:    db "Letters, digits, space.",0
s_save_l3:    db "Bytes:",0
s_hint_text:  db " type  DEL erase  ENTER ok  BREAK",0
s_msg_record: db "Start recording, then any key   ",0
s_hint_saving: db " Writing tape...                 ",0
s_msg_saved:  db "Saved -- any key                ",0
s_msg_savefail: db "Save failed (BREAK?) -- any key ",0

; ---- arrangement editor ---------------------------------------------------------
s_ar_title:   db "ARRANGEMENT (position list)",0
s_ar_info:    db "Pos   /   Pat     of    Loop",0
s_hint_ar:    db " CAPS+5678 move  0-9 pattern  Q ",0
s_hint_ar2:   db "I ins X del L loop N new E len",0
s_msg_length: db "Pattern length (1-64):        ",0

; ---- song info ------------------------------------------------------------------
s_si_title:    db "SONG INFO",0
s_si_l_title:  db "Title",0
s_si_l_author: db "Author",0
s_si_l_speed:  db "Speed     CAPS+7 up  CAPS+6 down",0
s_si_l_counts: db "Positions    loop     patts",0
s_si_l_bytes:  db "Song       bytes  free",0
s_hint_si:     db " T title  A author  ENTER/Q back ",0

; ---- instrument editors -----------------------------------------------------------
s_se_smp:     db "SAMPLE ",0
s_se_orn:     db "ORNAMENT ",0
s_se_len:     db "Len ",0
s_se_rep:     db "  Rep ",0
s_se_empty:   db "(no data -- L creates it)",0
s_se_menu:    db "^O^P sel ^L len ^R rep ^I^X ln ^Q",0
s_se_head_s:  db "Ln  TNE  Tone ^^  Ns ^^  V  A",0   ; ^^ = a literal caret (print_at markup)
s_se_head_o:  db "Ln  Semi",0
s_hint_se:    db " SPACE toggle ENTER play Q back ",0
s_hint_se2_s: db "CAPS+5678 move  0-9 A-F type",0
s_hint_se2_o: db "CAPS+6/7 line  0-9 type  SPC +/-",0
s_msg_selen:  db "Length (1-64):",0
s_msg_serep:  db "Repeat line (0-63):",0

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
        db      "A play  L loop  S save  D load",0
        db      "O/P position  F arrangement",0
        db      "G song info  N new  Q quit",0
        db      "E samples  R ornaments",0
        db      "I/X ins/del row  Z clear chan",0
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
