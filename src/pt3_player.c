/* =============================================================================
   pt3_player.c -- TS Tracker song picker (Phase 2)

   Bundles N .pt3 files; on boot, shows a numbered list, plays the chosen
   song until SPACE, then returns to the list. ENTER quits to BASIC.

   No external graphics lib: we PRINT through ROM RST $10 (identical on
   ZX48/TS2068) so all the Spectrum control codes -- AT row/col, INK,
   PAPER, INVERSE -- just work.
============================================================================= */
#include <intrinsic.h>

#include "ay_ts2068.h"
#include "PT3player.h"
#include "PT3player_NoteTable1.h"      /* NT1[96] -- Vortex tone table 1 */

struct song_entry {
    const unsigned char *data;
    const char          *title;
    const char          *author;
};
extern const struct song_entry song_table[];
extern const unsigned char     song_count;

/* ---- ROM character output (RST $10 = PRINT-A, identical on ZX48/TS2068) ---- */

static void putch(unsigned char c) __naked __z88dk_fastcall
{
    (void)c;
__asm
    ld   a,l            ; __z88dk_fastcall passes the byte arg in L
    rst  #0x10
    ret
__endasm;
}

static void puts_str(const char *s)
{
    while (*s) putch((unsigned char)*s++);
}

static void at(unsigned char row, unsigned char col)
{
    putch(0x16);                         /* AT control code */
    putch(row);
    putch(col);
}

static void cls(void)
{
    /* Clear only the upper screen (rows 0..21). Row 22+ is the lower-screen
       area for stream K; printing there via stream S yields Error 5 ("Out of
       screen"). 22 rows * 32 cols = 704 chars, but writing the 704th char
       advances the cursor to (22, 0) which the ROM treats as off-screen on
       the next print, so we stop one short and leave (21, 31) blank. */
    unsigned int i;
    at(0, 0);
    for (i = 0; i < 22u * 32u - 1u; i++) putch(' ');
    at(0, 0);
}

/* ---- keyboard polling ------------------------------------------------------- */

/* Read a Spectrum keyboard half-row. Returns bits 0..4 inverted, so a 1 bit
   means the corresponding key is currently held. rowsel is the high byte
   used to drive port $xxFE. */
static unsigned char read_row(unsigned char rowsel) __naked __z88dk_fastcall
{
    (void)rowsel;
__asm
    ld   a,l
    ld   c,#0xFE
    ld   b,a
    in   a,(c)
    cpl
    and  #0x1F
    ld   l,a
    ret
__endasm;
}

static unsigned char key_space(void) { return read_row(0x7F) & 0x01; }
static unsigned char key_enter(void) { return read_row(0xBF) & 0x01; }

/* Returns 1..9 if a digit key is held, 0 otherwise. Row $F7 carries 1..5
   in bits 0..4; row $FB carries 0,9,8,7,6 in bits 0..4. */
static unsigned char key_digit(void)
{
    unsigned char a = read_row(0xF7);
    unsigned char b = read_row(0xFB);
    if (a & 0x01) return 1;
    if (a & 0x02) return 2;
    if (a & 0x04) return 3;
    if (a & 0x08) return 4;
    if (a & 0x10) return 5;
    if (b & 0x10) return 6;
    if (b & 0x08) return 7;
    if (b & 0x04) return 8;
    if (b & 0x02) return 9;
    return 0;
}

/* ---- screen helpers --------------------------------------------------------- */

static void put_dec(unsigned char n)
{
    if (n >= 10) { putch('0' + n / 10); n %= 10; }
    putch('0' + n);
}

static void draw_menu(void)
{
    unsigned char i;
    cls();
    at(0, 4);  puts_str("TS Tracker -- PT3 player");
    at(2, 0);  puts_str("Songs:");

    for (i = 0; i < song_count; i++) {
        at(4 + i, 2);
        putch('[');
        put_dec(i + 1);
        putch(']');
        putch(' ');
        puts_str(song_table[i].title);
    }

    at(21, 0); puts_str("1-9: play   ENTER: quit");
}

static void draw_now_playing(unsigned char idx)
{
    cls();
    at(0, 4);  puts_str("Now playing:");
    at(2, 2);  puts_str(song_table[idx].title);
    at(3, 2);  puts_str("by ");
    puts_str(song_table[idx].author);
    at(21, 0); puts_str("SPACE: stop");
}

/* ---- play loop -------------------------------------------------------------- */

static void play_song(unsigned char idx)
{
    unsigned char divider = 0;

    Player_InitSong((unsigned int)(song_table[idx].data + 100),
                    (unsigned int)NT1, /*loop=*/1);

    draw_now_playing(idx);

    for (;;) {
        intrinsic_halt();
        if (++divider == 6) divider = 0;
        else { Player_Decode(); PlayAY(); }

        if (key_space()) break;
    }

    AY_Init();
    PlayAY();

    /* Debounce: wait for SPACE to be released before returning to menu. */
    while (key_space()) intrinsic_halt();
}

/* ---- main ------------------------------------------------------------------ */

void main(void)
{
    unsigned char d;

    intrinsic_ei();
    AY_Init();
    Player_Init();

    for (;;) {
        draw_menu();

        /* Wait for any key release first so a held key from the previous
           song does not immediately retrigger. */
        while (key_digit() || key_enter()) intrinsic_halt();

        for (;;) {
            intrinsic_halt();

            if (key_enter()) goto quit;

            d = key_digit();
            if (d >= 1 && d <= song_count) { play_song(d - 1); break; }
        }
    }

quit:
    AY_Init();
    PlayAY();
    cls();
    intrinsic_di();
}
