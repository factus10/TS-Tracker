; =============================================================================
; vars.asm -- program variables (live in the code image)
; =============================================================================

saved_sp:      dw 0

; ---- keyboard ----
kb_now:        ds 8
kb_prev:       ds 8
kb_edge:       ds 8
kb_lastcur:    db 0
kb_reptimer:   db 0
kb_lastframe:  db 0

; ---- screen ----
cur_attr:      db 0
hot_attr:      db 0
grid_top:      db 0
cur_prow:      db 0
pos_win:       db 0

; ---- editor state ----
cur_pos:       db 0
cur_row:       db 0
cur_chan:      db 0
cur_field:     db 0
octave:        db 4
cur_sample:    db 1
ed_val:        db 0

; ---- song / working pattern ----
num_pats:      db 1
song_len:      dw 0
wp_pat:        db 0
wp_len:        db 64
wp_dirty:      db 0
wp_old_bytes:  dw 0
free_bytes:    dw 0

; ---- decoder ----
dec_ch:        ds 15                    ; 3 x 5-byte channel states
dec_tmp:       ds 5                     ; state block for stream_end
dec_row:       db 0
dec_rowptr:    dw 0
dec_glob:      dw 0
dec_ncmd:      db 0
dec_cmds:      ds 16
dec_warn:      db 0
stream_limit:  dw 0

; ---- encoder ----
enc_out:       dw 0
enc_err:       db 0
enc_ch:        db 0
enc_n:         db 0
enc_i:         db 0
enc_row:       db 0
enc_nxt:       db 0
enc_skip:      db 0
enc_cell:      dw 0
enc_glob:      dw 0
enc_off:       ds 6                     ; 3 words
enc_len:       ds 6                     ; 3 words (must directly follow enc_off)
enc_total:     dw 0

; ---- slot / commit ----
fx_mode:       db 0
fx_off:        dw 0
fx_cnt:        dw 0
fx_end:        dw 0
ss_pat:        db 0
ss_ch:         db 0
ss_p:          db 0
ss_off:        dw 0
cm_off:        dw 0

; ---- player ----
play_div:      db 0
play_follow:   db 0
play_lastpos:  db 0

; ---- tape ----
tp_flag:       db 0
tp_dest:       dw 0
tp_len:        dw 0
tp_sp:         dw 0
tp_errsp:      dw 0
tp_decr:       db 0
tp_hsr:        db 0
dir_count:     db 0
ld_idx:        db 0
ld_entry:      dw 0
de_idx:        db 0
de_ent:        dw 0
save_name:     db "SONG    "
save_version:  db 1

; ---- text prompt ----
pt_buf:        dw 0
pt_len:        db 0
pt_pos:        db 0
pt_row:        db 0
pt_col:        db 0

; ---- arrangement editor ----
ar_cur:        db 0
ar_typed:      db 0
ar_top:        db 0
ar_tmp:        dw 0
ar_tmp2:       db 0
ar_lenbuf:     db "64"

; ---- test harness ----
t_arg:         db 0
