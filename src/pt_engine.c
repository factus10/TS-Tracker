/* =============================================================================
   pt_engine.c -- shared PTxPlay engine implementation. See pt_engine.h.

   The asm thunks must be in a .c (not inline-static in the header) because
   SDCC's __naked functions emit a real symbol; both apps link against this
   single object so we don't multiply-define them.

   The PTxPlay symbol addresses (INIT_ADDR, PLAY_ADDR, MUTE_ADDR) are pulled
   in via ptxplay_addrs.h, which build/bin_to_c.py regenerates whenever
   PTxPlay.asm is reassembled at a new origin. The C preprocessor substitutes
   the literal addresses into the asm before SDCC compiles the block, so a
   PTX_ORIGIN_HEX bump in the Makefile flows through without any code edit.
============================================================================= */
#include "pt_engine.h"

void PTx_init(unsigned int song_addr) __naked __z88dk_fastcall
{
    (void)song_addr;
__asm
    push ix
    call INIT_ADDR        ; HL holds song address by fastcall
    pop  ix
    ret
__endasm;
}

void PTx_play(void) __naked
{
__asm
    push ix
    call PLAY_ADDR
    pop  ix
    ret
__endasm;
}

void PTx_mute(void) __naked
{
__asm
    push ix
    call MUTE_ADDR
    pop  ix
    ret
__endasm;
}

void silence_channel(unsigned char ch) __naked __z88dk_fastcall
{
    (void)ch;
__asm
    ld   a,l
    add  a,#8
    out  (#0xF5),a
    xor  a
    out  (#0xF6),a
    ret
__endasm;
}

unsigned char pt_play_60to50(unsigned char *divider)
{
    if (++(*divider) == 6) {
        *divider = 0;
        return 0;
    }
    PTx_play();
    return 1;
}
