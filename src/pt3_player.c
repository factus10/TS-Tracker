/* =============================================================================
   pt3_player.c -- TS Tracker song picker, universal PT2/PT3 build.

   Replaces the C-only mvac7 PT3 player with Bulba's PTxPlay (universal
   PT1/PT2/PT3 driver, asm-only). PTxPlay is assembled separately to a flat
   binary (build/ptxplay.bin), embedded here as a const array, and memcpy'd
   to its build address ($C000) at startup. We call entry points via
   inline-asm thunks to fixed addresses defined in build/ptxplay_blob.c.

   PTxPlay format byte at SETUP_ADDR ($C00A):
     bit 0 = no-loop (set to play once)
     bit 1 = format: 0 = PT3, 1 = PT2
     bits 2-3 = channel allocation (0 = ABC stereo, 1 = ACB)
     bit 7 = (read-only) set when loop point passed
============================================================================= */
#include <intrinsic.h>

#include "ay_ts2068.h"
#include "ptxplay_addrs.h"  /* START_ADDR, SETUP_ADDR, MUTE_ADDR, INIT_ADDR, PLAY_ADDR */

/* PTxPlay is shipped as a separate CODE block on the same tape; the TS2068
   tape loader puts it at its assembled origin ($C000). No runtime copy. */

/* Provided by build/song_bundle.c (auto-generated): */
struct song_entry {
    const unsigned char *data;
    const char          *title;
    const char          *author;
    unsigned char        fmt;     /* 0 = PT3, 1 = PT2 */
};
extern const struct song_entry song_table[];
extern const unsigned char     song_count;

/* ---- PTxPlay thunks (call into the memcpy'd blob at fixed addresses) -------- */

/* PTxPlay's INIT/PLAY/MUTE clobber IX (which z88dk SDCC uses as the C frame
   pointer). If we just JP into them, the RET returns to our caller with IX
   garbaged -- subsequent local-variable access reads random memory. Save
   and restore IX around each call. PTxPlay does not touch IY, which is
   reserved on the Spectrum for the system-variable pointer. */
static void PTx_init(unsigned int song_addr) __naked __z88dk_fastcall
{
    (void)song_addr;
__asm
    push ix
    call 0xC017          ; INIT_ADDR; HL holds song address by fastcall
    pop  ix
    ret
__endasm;
}

static void PTx_play(void) __naked
{
__asm
    push ix
    call 0xC623          ; PLAY_ADDR
    pop  ix
    ret
__endasm;
}

static void PTx_mute(void) __naked
{
__asm
    push ix
    call 0xC00B          ; MUTE_ADDR
    pop  ix
    ret
__endasm;
}

#define PTx_setup (*(volatile unsigned char *)0xC00A)

/* ---- ROM character output (RST $10 = PRINT-A, identical on ZX48/TS2068) ---- */

static void putch(unsigned char c) __naked __z88dk_fastcall
{
    (void)c;
__asm
    ld   a,l
    rst  #0x10
    ret
__endasm;
}

static void puts_str(const char *s)
{
    while (*s) putch((unsigned char)*s++);
}

static void puts_str_n(const char *s, unsigned char n)
{
    while (*s && n--) putch((unsigned char)*s++);
}

static void at(unsigned char row, unsigned char col)
{
    putch(0x16);
    putch(row);
    putch(col);
}

static void cls(void)
{
    unsigned int i;
    at(0, 0);
    for (i = 0; i < 22u * 32u - 1u; i++) putch(' ');
    at(0, 0);
}

/* ---- keyboard polling ------------------------------------------------------- */

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

/* Sinclair keyboard matrix:
     row $F7: 1, 2, 3, 4, 5  (bits 0..4)
     row $EF: 0, 9, 8, 7, 6  (bits 0..4)
   Some ZX/TS-2068 references mislabel the second row as $FB; $FB is
   actually Q-W-E-R-T. Reading the wrong row makes 6-9 silently dead. */
static unsigned char key_digit(void)
{
    unsigned char a = read_row(0xF7);
    unsigned char b = read_row(0xEF);
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
    at(0, 4);  puts_str("TS Tracker -- PT2/PT3 player");
    at(2, 0);  puts_str("Songs:");

    /* Each menu row: "[N] (PT3) <title>" -- 10 chars of prefix at col 2,
       leaving 32-2-10 = 20 chars for the title before column 31. */
    for (i = 0; i < song_count; i++) {
        at(4 + i, 2);
        putch('[');
        put_dec(i + 1);
        putch(']');
        putch(' ');
        puts_str(song_table[i].fmt ? "(PT2) " : "(PT3) ");
        puts_str_n(song_table[i].title, 20);
    }

    at(21, 0); puts_str("1-9: play   ENTER: quit");
}

static void draw_now_playing(unsigned char idx)
{
    cls();
    at(0, 4);  puts_str("Now playing:");
    at(2, 2);
    puts_str(song_table[idx].fmt ? "(PT2) " : "(PT3) ");
    /* row 2 col 8 -- 24 chars left before col 31, wrap to row 3 col 2
       for the remainder. Walk the string char-by-char so we stop cleanly
       at the null terminator instead of reading past short titles. */
    {
        const char *t = song_table[idx].title;
        unsigned char i = 0;
        while (i < 24 && t[i]) { putch((unsigned char)t[i]); i++; }
        if (t[i]) {
            at(3, 2);
            while (i < 24 + 30 && t[i]) { putch((unsigned char)t[i]); i++; }
        }
    }
    if (song_table[idx].author[0]) {
        at(5, 2); puts_str("by ");
        puts_str_n(song_table[idx].author, 25);
    }
    at(21, 0); puts_str("SPACE: stop");
}

/* ---- play loop -------------------------------------------------------------- */

static void play_song(unsigned char idx)
{
    unsigned char divider = 0;
    const struct song_entry *e = &song_table[idx];

    /* PTxPlay takes the raw module start for both PT2 and PT3. The PT3
       path internally ADDS 100 to find the speed byte (file offset 100);
       the PT2 path reads directly from the start. (Note: mvac7's PT3
       player used the opposite convention -- it subtracted 100.) */
    PTx_setup = e->fmt ? 0x02 : 0x00;     /* bit 1: 1 = PT2, 0 = PT3 */
    PTx_init((unsigned int)e->data);

    draw_now_playing(idx);

    for (;;) {
        intrinsic_halt();
        if (++divider == 6) divider = 0;
        else PTx_play();

        if (key_space()) break;
    }

    PTx_mute();
    while (key_space()) intrinsic_halt();
}

/* ---- main ------------------------------------------------------------------ */

void main(void)
{
    unsigned char d;

    intrinsic_ei();

    AY_Init();
    PTx_mute();   /* sane initial state */

    for (;;) {
        draw_menu();

        while (key_digit() || key_enter()) intrinsic_halt();

        for (;;) {
            intrinsic_halt();

            if (key_enter()) goto quit;

            d = key_digit();
            if (d >= 1 && d <= song_count) { play_song(d - 1); break; }
        }
    }

quit:
    PTx_mute();
    AY_Init();
    PlayAY();
    cls();
    intrinsic_di();
}
