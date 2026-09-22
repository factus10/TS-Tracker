; =============================================================================
; test.asm -- entry points for tools/v2_codec_test.py (called via ZRCP with a
; trap return address; see the harness). Each does one thing and returns.
; =============================================================================

t_init:                                 ; song in slot -> num_pats, song_len
        call    calc_num_pats
        jp      slot_measure

t_decode:                               ; (t_arg) = pattern -> WP, wp_len, dec_warn
        ld      a,(t_arg)
        jp      dec_pattern

t_encode:                               ; WP -> STAGE, enc_off/len/total, enc_err
        jp      enc_pattern

t_load:                                 ; (t_arg) = pattern -> wp_load (also wp_old_bytes)
        ld      a,(t_arg)
        jp      wp_load

t_commit:                               ; mark dirty and commit the WP into the slot
        ld      a,1
        ld      (wp_dirty),a
        jp      commit_pattern
