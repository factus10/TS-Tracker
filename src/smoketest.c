/* =============================================================================
   smoketest.c -- minimal "does the AY make noise on the TS2068" sanity check.

   Plays a low note for ~1 second on channel A, then a high note for ~1 s,
   then silences and returns to BASIC. If you hear two distinct pitches,
   the toolchain, the AY library, and ports $F5/$F6 are all wired correctly.

   Build: see Makefile. Target: zcc +ts2068, SDCC.
============================================================================= */
#include <intrinsic.h>
#include "ay_ts2068.h"

static void wait_frames(unsigned char n)
{
    while (n--) intrinsic_halt();   /* HALT until next frame interrupt */
}

void main(void)
{
    /* z88dk's newlib CRT0 leaves interrupts disabled by default
       (__crt_enable_eidi = 0). Without this, intrinsic_halt() never wakes. */
    intrinsic_ei();

    AY_Init();

    /* AY clock on TS2068 ~ 1.7625 MHz; tone period = clock / (16 * Hz).
       Period 0x200 ~ 215 Hz; period 0x100 ~ 430 Hz. Pitch is approximate. */
    SetVolume(AY_Channel_A, 12);
    SetChannel(AY_Channel_A, ON, OFF);

    SetTonePeriod(AY_Channel_A, 0x200);
    PlayAY();
    wait_frames(60);                /* ~1 second at 60 Hz */

    SetTonePeriod(AY_Channel_A, 0x100);
    PlayAY();
    wait_frames(60);

    AY_Init();                      /* clears all volumes -> silence */
    PlayAY();

    intrinsic_di();                 /* match BASIC's expected return state */
}
