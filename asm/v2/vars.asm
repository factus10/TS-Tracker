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
edit_step:     db 1                     ; rows the cursor advances after a note
copy_src:      db $FF                   ; pattern copied with SYM+C ($FF none)
copy_chan:     db 0                     ; channel copied with CAPS+SYM+C
copy_kind:     db 0                     ; 0 = a pattern is on the clipboard, 1 = a channel
undo_valid:    db 0                     ; UNDO_BUF holds the WP as it was before the last edit
pc_row:        db 0                     ; channel paste: row counter
pc_src:        db 0                     ; channel paste: source cell offset in the row
pc_dst:        db 0                     ; channel paste: target cell offset in the row
ed_buf:        ds 6                     ; hex prompt buffer
ed_n:          db 0
cur_sample:    db 1
ed_val:        db 0

; ---- song / working pattern ----
num_pats:      db 1
song_len:      dw 0
wp_pat:        db 0
wp_len:        db 64
wp_dirty:      db 0
song_mod:      db 0                     ; 1 = unsaved changes ('*' on the SONG tag)
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
dec_fmt:       db 0                     ; 0 = PT3 grammar, 1 = PT2 (import)
dec_base:      dw 0                     ; the address stream offsets are relative to
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
dd_n:          db 0                     ; de-dup: entries, outer, inner index
dd_i:          db 0
dd_j:          db 0

; ---- player ----
play_div:      db 0
play_follow:   db 0
play_lastpos:  db 0
play_hold:     db 0                     ; 1 = play while a key is held (preview)
play_min:      db 0                     ; preview: frames still to play even if released
play_mute:     db 0                     ; bits 0-2: channel muted
play_row:      db 0                     ; row being played (follow)
play_shownrow: db 0
play_posdirty: db 0
play_loopmode: db 0                     ; 1 = looping one pattern (private list)
play_lastframe: db 0
vu_ch:         db 0

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
dir_top:       db 0                     ; first directory entry on screen
dir_cur:       db 0                     ; selected entry
ld_tries:      db 0                     ; headers still allowed while looking for the song

; ---- TS-PICO ----
tpi_ok:        db 0                     ; 1 = TPI BIOS found in the EXROM
tpi_vers:      dw 0                     ; its version (G_VERS)
tpi_err:       db 0                     ; last status byte ($FF = timeout or BREAK, $FE = no BIOS)
tpi_taddr:     db 0                     ; 0 SAVE / 1 LOAD flavour of the command being sent
sd_mode:       db 0                     ; 1 = TP_MODE says SD card: the tape calls reach the Pico
sd_raw:        db 0                     ; 1 = browsing / saving raw .pt3 files (FMODE=RAW)
sd_changed:    db 0                     ; 1 = we switched TP_MODE; restore sd_saved at quit
sd_saved:      db 0

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

; ---- instrument editor ----
se_kind:       db 0                     ; 0 = sample, 1 = ornament
se_sel:        db 1
se_sel_smp:    db 1
se_sel_orn:    db 1
se_line:       db 0
se_field:      db 0
se_top:        db 0
se_len:        db 0
se_rep:        db 0                     ; loop (repeat) line
se_blk:        dw 0                     ; block address, 0 = none
se_tmp:        db 0
se_row:        db 0
pv_smp:        db 0
pv_orn:        db 0
pv_note:       db 0
pv_shape:      db 0                     ; 0 auto (8 if the sample uses the envelope), 1-14 shape, 15 none
pv_per:        dw 0                     ; envelope period, 0 = auto (tone period / 16)

; ---- PT2 import ----
pt2_src:       dw 0                     ; the PT2 module (moved to the top of the slot)
pt2_len:       dw 0
pt2_out:       dw 0                     ; where the next PT3 bytes go
pt2_npats:     db 0
pt2_i:         db 0
pt2_tmp:       dw 0

; ---- test harness ----
t_arg:         db 0
