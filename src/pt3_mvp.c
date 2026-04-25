/* =============================================================================
   pt3_mvp.c -- play one bundled .pt3 song through the AY-3-8912 on a TS2068.

   Build artifact is a +zx tape that the TS2068 loads and runs. The PT3
   player core is the unmodified mvac7/SapphiRe/Bulba lib in PT3player.c;
   our ay_ts2068.c provides the AY backend with ports $F5/$F6.

   Flow:
     - enable IRQs (z88dk newlib CRT0 leaves them off by default)
     - init AY + player
     - on every frame: divide 6:5 to convert 60 Hz frames into 50 Hz player
       ticks, run Player_Decode() + PlayAY(); poll keyboard for SPACE
     - on exit: silence AY, return to BASIC
============================================================================= */
#include <intrinsic.h>

#include "ay_ts2068.h"
#include "PT3player.h"
#include "PT3player_NoteTable1.h"   /* defines const unsigned int NT1[96] */

extern const unsigned char song[];   /* defined in build/song.c */

/* SPACE is the rightmost key on row $7F (bit 0 = pressed when 0). Inline
   asm so we hit the port directly without dragging in z88dk's input lib. */
static unsigned char space_pressed(void) __naked
{
__asm
    ld   bc,#0x7FFE
    in   a,(c)
    cpl
    and  #0x01           ; bit 0 = SPACE
    ld   l,a
    ret
__endasm;
}

void main(void)
{
    unsigned char divider = 0;

    intrinsic_ei();

    AY_Init();
    Player_Init();
    /* Pass songADDR = file_start + 100. The player subtracts 100 to derive
       MODADDR, then dereferences MODADDR+100 for the speed byte; that
       byte sits at file offset 100 in a full PT3 file. NT1 is the
       Vortex Tracker II tone table (matches our bundled .pt3 files). */
    Player_InitSong((unsigned int)(song + 100), (unsigned int)NT1, /*loop=*/1);

    for (;;) {
        intrinsic_halt();           /* wait for next frame interrupt (60 Hz) */

        /* 60 Hz -> 50 Hz: skip 1 of every 6 frames. */
        if (++divider == 6) { divider = 0; }
        else                { Player_Decode(); PlayAY(); }

        if (space_pressed()) break;
    }

    AY_Init();
    PlayAY();                       /* silence */
    intrinsic_di();
}
