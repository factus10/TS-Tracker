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

/* Set the TS2068 border colour (bits 0-2 of port $FE). */
static void set_border(unsigned char c) __naked __z88dk_fastcall
{
    (void)c;
__asm
    ld   a,l
    and  #0x07
    out  (#0xFE),a
    ret
__endasm;
}

/* Force AY amplitude register 8/9/10 to zero for a given channel (0..2),
   silencing it without touching PTxPlay's AYREGS shadow. Called every
   frame after PTx_play for muted channels. */
static void silence_channel(unsigned char ch) __naked __z88dk_fastcall
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
   reserved on the Spectrum for the system-variable pointer.

   Addresses come from build/ptxplay_addrs.h (auto-generated from sjasmplus's
   .sym output); the C preprocessor substitutes them into the asm before SDCC
   sees the block. Hardcoding numeric literals here breaks silently the
   moment PTxPlay's layout shifts (e.g., enabling LoopChecker). */
static void PTx_init(unsigned int song_addr) __naked __z88dk_fastcall
{
    (void)song_addr;
__asm
    push ix
    call INIT_ADDR        ; HL holds song address by fastcall
    pop  ix
    ret
__endasm;
}

static void PTx_play(void) __naked
{
__asm
    push ix
    call PLAY_ADDR
    pop  ix
    ret
__endasm;
}

static void PTx_mute(void) __naked
{
__asm
    push ix
    call MUTE_ADDR
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
    /* Static labels for the live readout. The bars themselves get drawn each
       frame by draw_live_bars(). */
    at(8,  2); puts_str("A: ");
    at(9,  2); puts_str("B: ");
    at(10, 2); puts_str("C: ");
    at(21, 0); puts_str("1-3 mute   SPACE stop");
}

/* Spectrum attribute layout: bit 7 FLASH, bit 6 BRIGHT, bits 5-3 PAPER,
   bits 2-0 INK. Colors: 0 black 1 blue 2 red 3 magenta 4 green 5 cyan
   6 yellow 7 white. */
#define ATTR(paper, ink, bright)  (((paper) << 3) | (ink) | ((bright) ? 0x40 : 0))

static void write_attr(unsigned char row, unsigned char col, unsigned char attr)
{
    *(unsigned char *)(0x5800 + row * 32 + col) = attr;
}

/* Volume-bar colors per cell index. First six cells green, next five
   yellow, last five red -- loud channels light up red at the right end. */
static const unsigned char bar_color[16] = {
    ATTR(0, 4, 1), ATTR(0, 4, 1), ATTR(0, 4, 1),
    ATTR(0, 4, 1), ATTR(0, 4, 1), ATTR(0, 4, 1),
    ATTR(0, 6, 1), ATTR(0, 6, 1), ATTR(0, 6, 1),
    ATTR(0, 6, 1), ATTR(0, 6, 1),
    ATTR(0, 2, 1), ATTR(0, 2, 1), ATTR(0, 2, 1),
    ATTR(0, 2, 1), ATTR(0, 2, 1),
};

/* Channel-mute state. Bit 0 = mute A, bit 1 = mute B, bit 2 = mute C.
   Persists across songs so the user doesn't have to re-mute each track. */
static unsigned char mute_mask;

/* Per-channel state cache for the bars. We only redraw a channel when its
   state actually changes -- by far the common case is "no change" since PT3
   note durations span many frames. Even when state changes by one volume
   step, we only repaint the single cell that flipped on or off.

   Encoding: 0..15 = normal volume, 0x80|ENV = envelope mode, 0x40|MUTE.
   Sentinel 0xFF means "force a full redraw on the next visit" (e.g. when
   draw_now_playing has just cleared the screen). */
#define BAR_NORMAL(level)  (level)
#define BAR_ENV            0x80
#define BAR_MUTE           0x40
#define BAR_FORCE          0xFF

static unsigned char prev_bar[3];

static void bar_full_normal(unsigned char row, unsigned char level)
{
    unsigned char i;
    at(row, 5);
    for (i = 0; i < 16; i++) {
        putch(i < level ? 0x8F : ' ');
        write_attr(row, 5 + i, i < level ? bar_color[i] : ATTR(0, 0, 0));
    }
}

static void bar_full_env(unsigned char row)
{
    unsigned char i;
    at(row, 5);
    putch('E'); putch('N'); putch('V');
    for (i = 3; i < 16; i++) putch(' ');
    for (i = 0; i < 16; i++) write_attr(row, 5 + i, ATTR(0, 5, 1));
}

static void bar_full_mute(unsigned char row)
{
    unsigned char i;
    at(row, 5);
    putch('M'); putch('U'); putch('T'); putch('E');
    for (i = 4; i < 16; i++) putch(' ');
    for (i = 0; i < 16; i++) write_attr(row, 5 + i, ATTR(0, 1, 0));
}

/* Diff-redraw: only touch the cells that flipped on or off between two
   plain-volume states. About 50x faster than a full redraw at steady
   state, and avoids the flicker from rewriting unchanged cells. */
static void bar_diff_normal(unsigned char row, unsigned char old_lvl, unsigned char new_lvl)
{
    unsigned char i;
    if (new_lvl > old_lvl) {
        at(row, 5 + old_lvl);
        for (i = old_lvl; i < new_lvl; i++) {
            putch(0x8F);
            write_attr(row, 5 + i, bar_color[i]);
        }
    } else {
        at(row, 5 + new_lvl);
        for (i = new_lvl; i < old_lvl; i++) {
            putch(' ');
            write_attr(row, 5 + i, ATTR(0, 0, 0));
        }
    }
}

static void draw_live_bars(void)
{
    const unsigned char *regs = (const unsigned char *)AYREGS_ADDR;
    unsigned char ch;
    for (ch = 0; ch < 3; ch++) {
        unsigned char row   = 8 + ch;
        unsigned char muted = (mute_mask >> ch) & 1;
        unsigned char amp   = regs[8 + ch];

        unsigned char now;
        if (muted)            now = BAR_MUTE;
        else if (amp & 0x10)  now = BAR_ENV;
        else                  now = amp & 0x0F;

        unsigned char prev = prev_bar[ch];
        if (now == prev) continue;

        /* Anything except a normal-to-normal level change forces a full
           repaint; the cells changing layout (text vs blocks, attributes)
           don't lend themselves to a tidy diff. */
        if (prev > 0x0F || now > 0x0F) {
            switch (now) {
                case BAR_MUTE: bar_full_mute(row); break;
                case BAR_ENV:  bar_full_env(row);  break;
                default:       bar_full_normal(row, now); break;
            }
        } else {
            bar_diff_normal(row, prev, now);
        }
        prev_bar[ch] = now;
    }
}

/* (Background colour wave removed -- too expensive per frame and a separate
   visualisation pass deserves its own design. We'll come back to it once
   we have a faster screen-write path than ROM PRINT.) */

/* ---- play loop -------------------------------------------------------------- */

static void play_song(unsigned char start_idx)
{
    unsigned char idx = start_idx;
    unsigned char divider = 0;
    unsigned char prev_mute_keys = 0;
    unsigned char restart;

    set_border(1);                /* solid blue border for the whole session */

    do {
        const struct song_entry *e = &song_table[idx];
        restart = 0;

        /* PTxPlay takes the raw module start for both PT2 and PT3. The PT3
           path internally ADDS 100 to find the speed byte; the PT2 path
           reads directly from the start. The format selector lives in
           bit 1 of SETUP. We also clear bit 7 (loop-passed) here so the
           auto-advance check below only fires on the *new* song's loop. */
        PTx_setup = e->fmt ? 0x02 : 0x00;
        PTx_init((unsigned int)e->data);

        draw_now_playing(idx);
        /* cls() in draw_now_playing wiped the bars; force a full redraw
           on the first frame by invalidating the cache. */
        prev_bar[0] = prev_bar[1] = prev_bar[2] = BAR_FORCE;

        for (;;) {
            intrinsic_halt();
            if (++divider == 6) {
                divider = 0;
            } else {
                PTx_play();
                /* Override muted channels' AY amp registers AFTER PTxPlay
                   wrote its output. AYREGS in PTxPlay still reflects the
                   "would-be" volume so the bar logic can show MUTE
                   regardless of actual playback. */
                if (mute_mask & 0x01) silence_channel(0);
                if (mute_mask & 0x02) silence_channel(1);
                if (mute_mask & 0x04) silence_channel(2);
                draw_live_bars();
            }

            /* Mute toggle on rising edge of keys 1/2/3 (row $F7 bits 0/1/2).
               Debounced by tracking the previous frame's bit pattern. */
            {
                unsigned char keys = read_row(0xF7) & 0x07;
                unsigned char pressed = keys & ~prev_mute_keys;
                prev_mute_keys = keys;
                if (pressed) mute_mask ^= pressed;
            }

            /* Auto-advance: PTxPlay sets bit 7 of SETUP whenever the song
               loops back to its start (LoopChecker=1 in our build). On
               first wrap, advance to the next song. Wraps to 0 at end. */
            if (PTx_setup & 0x80) {
                idx++;
                if (idx >= song_count) idx = 0;
                restart = 1;
                break;
            }

            if (key_space()) break;
        }
    } while (restart);

    set_border(7);

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
