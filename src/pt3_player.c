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

/* ---- Tape loading ----------------------------------------------------------
   The TS2068 keeps its tape routines in the EXROM, which we have to page in
   manually before calling. The standard LD-BYTES entry is at $00FC (in the
   EXROM bank); our trampoline saves DECR/HSR, switches chunk 0 to DOCK so
   $00FC actually reaches EXROM, runs LD-BYTES, and restores the page state
   on return. The flag/dest/length args go through fixed globals because
   SDCC's z88dk_fastcall only carries one arg in HL.

   This reads any block: pass flag=0x00 for a 17-byte header or flag=0xFF
   for the data block that follows it on the tape. */
static unsigned char tape_arg_flag;
static unsigned int  tape_arg_dest;
static unsigned int  tape_arg_len;
static unsigned char saved_decr;
static unsigned char saved_hsr;

static unsigned char tape_read_block(void) __naked
{
__asm
    push ix
    di

    ; preserve current page state
    in   a,(#0xFF)
    ld   (_saved_decr),a
    set  7,a              ; ensure EXROM enable bit is set
    out  (#0xFF),a

    in   a,(#0xF4)
    ld   (_saved_hsr),a
    ld   a,#1             ; HSR = 01: chunk 0 from DOCK = EXROM at $0000-$1FFF
    out  (#0xF4),a

    ; load LD-BYTES inputs
    ld   a,(_tape_arg_flag)
    ld   ix,(_tape_arg_dest)
    ld   de,(_tape_arg_len)
    scf                    ; CY = 1 -> LOAD mode (vs VERIFY)
    call #0x00FC           ; EXROM LD-BYTES

    ; capture result (CY = 1 success, CY = 0 fail) without disturbing it
    ld   a,#0
    rla
    push af

    ; restore page state
    ld   a,(_saved_hsr)
    out  (#0xF4),a
    ld   a,(_saved_decr)
    out  (#0xFF),a
    ei

    pop  af
    ld   l,a               ; SDCC return value goes in L
    pop  ix
    ret
__endasm;
}

/* TAPE_SONG_BASE is normally provided by the Makefile via -D so it stays in
   sync with PTxPlay's origin. Fall back to a sane default if this file is
   read by an IDE / standalone clang that doesn't see the Make recipe.
   Tape-loaded song lives in the same memory region as the bundled high
   group; loading from tape DESTROYS the bundled songs in slots 4-6 until
   the user reloads the .tap. The C const arrays in low memory survive. */
#ifndef TAPE_SONG_BASE
#define TAPE_SONG_BASE  0xC000
#endif

static unsigned char tape_header[17];
static unsigned char tape_song_loaded;
static unsigned char tape_song_fmt;

static unsigned char load_song_from_tape(void)
{
    unsigned int length;

    /* 1) Read a 17-byte header. */
    tape_arg_flag = 0x00;
    tape_arg_dest = (unsigned int)tape_header;
    tape_arg_len  = 17;
    if (!tape_read_block()) return 0;

    /* Only CODE blocks (type 3) carry song data. */
    if (tape_header[0] != 3) return 0;

    length = tape_header[11] | ((unsigned int)tape_header[12] << 8);
    if (length == 0 || length > 0x3000) return 0;   /* sanity cap ~12 KB */

    /* 2) Read the data block that follows. */
    tape_arg_flag = 0xFF;
    tape_arg_dest = TAPE_SONG_BASE;
    tape_arg_len  = length;
    if (!tape_read_block()) return 0;

    /* 3) Detect format. PT3 files start with "ProTracker 3"; anything else
       we treat as PT2. (PT2 has no fixed magic.) */
    {
        const unsigned char *d = (const unsigned char *)TAPE_SONG_BASE;
        tape_song_fmt = (d[0] == 'P' && d[1] == 'r' && d[2] == 'o' && d[11] == '3') ? 0 : 1;
    }
    tape_song_loaded = 1;
    return 1;
}

/* Convert tape header bytes 1..10 into a null-terminated displayable
   filename. Non-printable bytes become '?'; trailing spaces get trimmed. */
static char tape_title[12];

static void tape_extract_title(void)
{
    unsigned char i, last = 0;
    for (i = 0; i < 10; i++) {
        unsigned char c = tape_header[1 + i];
        tape_title[i] = (c >= 32 && c < 127) ? c : '?';
        if (tape_title[i] != ' ') last = i + 1;
    }
    tape_title[last] = 0;
}

/* Compare the tape header's 10-byte filename against a directory entry's
   null-terminated name (space-padded out to 10). Returns 1 on full match.
   Mirror of the helper in src/tracker.c so play_index can do name-matched
   loading like ROM LOAD "name"CODE -- tape-position-independent. */
static unsigned char header_name_matches(const char *target_name)
{
    unsigned char i;
    unsigned char past_null = 0;
    for (i = 0; i < 10; i++) {
        unsigned char hc = tape_header[1 + i];
        unsigned char tc;
        if (past_null || target_name[i] == 0) {
            past_null = 1;
            tc = ' ';
        } else {
            tc = (unsigned char)target_name[i];
        }
        if (hc != tc) return 0;
    }
    return 1;
}

/* ---- In-memory tape directory ---------------------------------------------
   Built by scan_tape() on user request, lives until rescan or quit. We keep
   only what's needed to *list* the song; the actual data isn't preserved
   across the whole tape -- only the most recently loaded song occupies
   TAPE_SONG_BASE at any one time. */
#define DIR_MAX  9   /* keys 1..9 select; one screen of entries fits cleanly */

struct dir_entry {
    char           name[11];   /* 10-char tape filename, null-terminated */
    unsigned int   length;     /* data block size in bytes */
    unsigned char  fmt;        /* 0 = PT3, 1 = PT2 */
};

static struct dir_entry directory[DIR_MAX];
static unsigned char    dir_count;

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
    /* Reset PRINT colour state so spaces pick up the default attribute and
       the banner from the previous screen doesn't bleed through. */
    putch(0x10); putch(0);   /* INK 0 (black) */
    putch(0x11); putch(7);   /* PAPER 7 (white) */
    putch(0x13); putch(0);   /* BRIGHT 0 */
    putch(0x14); putch(0);   /* INVERSE 0 */
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
/* Row $BF = ENTER L K J H ; bit 1 = L. */
static unsigned char key_L(void)     { return read_row(0xBF) & 0x02; }
/* Row $FD = A S D F G ; bit 0 = A, bit 1 = S. */
static unsigned char key_A(void)     { return read_row(0xFD) & 0x01; }
static unsigned char key_S(void)     { return read_row(0xFD) & 0x02; }
/* Row $FB = Q W E R T ; bit 0 = Q, bit 3 = R. */
static unsigned char key_Q(void)     { return read_row(0xFB) & 0x01; }
static unsigned char key_R(void)     { return read_row(0xFB) & 0x08; }
/* TS2068 BREAK = CAPS-SHIFT (row $FE bit 0) + SPACE (row $7F bit 0). */
static unsigned char key_break(void) {
    return (read_row(0xFE) & 0x01) && (read_row(0x7F) & 0x01);
}

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

/* Set the next-print colour state. ROM PRINT honours INK ($10), PAPER ($11),
   BRIGHT ($13), and INVERSE ($14) control codes inline in the byte stream. */
static void set_attr(unsigned char ink, unsigned char paper, unsigned char bright)
{
    putch(0x10); putch(ink);
    putch(0x11); putch(paper);
    putch(0x13); putch(bright);
}

static void set_inverse(unsigned char on)
{
    putch(0x14); putch(on);
}

/* Draw the nofile.tap-style banner at row 0:
     " TIMEX " in cyan-on-black, a bright white band centred on the project
     name, " 2068 " in cyan-on-black on the right. Always reset to default
     ink/paper after so subsequent rows don't inherit the band's BRIGHT. */
static void draw_banner(void)
{
    at(0, 0);
    set_attr(5, 0, 0);                /* cyan ink, black paper, no bright */
    puts_str(" TIMEX ");
    set_attr(0, 7, 1);                /* black ink, white paper, BRIGHT */
    puts_str("  PT2/PT3 Player   ");  /* 19 chars */
    set_attr(5, 0, 0);
    puts_str(" 2068 ");
    set_attr(0, 7, 0);                /* reset to default */
}

/* White-on-red status banner across all 32 cols of a single row, mirroring
   the "-- No file mounted! --" line in nofile.tap. The text is centred. */
static void draw_status(unsigned char row, const char *text)
{
    unsigned char len = 0;
    unsigned char pad, i;
    while (text[len]) len++;
    pad = (32 - len) / 2;

    at(row, 0);
    set_attr(7, 2, 0);                /* white ink, red paper */
    for (i = 0; i < pad; i++) putch(' ');
    puts_str(text);
    for (i = pad + len; i < 32; i++) putch(' ');
    set_attr(0, 7, 0);
}

/* Render a menu line: indent, INVERSE hotkey, then label, with no auto-space
   between -- the caller spells the label such that the hotkey reads as the
   first letter of a word ("S" + "can tape" -> "Scan tape") or includes any
   wanted separator itself (" play all" -> "A play all"). */
static void draw_menu_item(unsigned char row, char hotkey, const char *label)
{
    at(row, 4);
    set_inverse(1);
    putch(hotkey);
    set_inverse(0);
    puts_str(label);
}

static void show_scan_prompt(void)
{
    cls();
    draw_banner();
    draw_status(2, "-- No tape loaded --");

    at(5, 0);  puts_str("Insert a tape (or .tap in");
    at(6, 0);  puts_str("an emulator), then:");

    draw_menu_item(9,  'S', "can tape");
    draw_menu_item(10, 'Q', "uit");

    at(13, 0); puts_str("After the last song plays,");
    at(14, 0); puts_str("press CAPS+SPACE to stop");
    at(15, 0); puts_str("scanning.");
}

static void show_directory(void)
{
    unsigned char i;
    char buf[16];
    cls();
    draw_banner();

    /* Status line includes the song count: "-- N songs found --" */
    {
        unsigned char j = 0;
        const char *prefix = "-- ";
        const char *suffix;
        suffix = (dir_count == 1) ? " song found --" : " songs found --";
        while (*prefix)  buf[j++] = *prefix++;
        if (dir_count >= 10) buf[j++] = '0' + dir_count / 10;
        buf[j++] = '0' + dir_count % 10;
        while (*suffix)  buf[j++] = *suffix++;
        buf[j] = 0;
    }
    draw_status(2, buf);

    for (i = 0; i < dir_count; i++) {
        struct dir_entry *e = &directory[i];
        at(4 + i, 4);
        set_inverse(1);
        putch('1' + i);
        set_inverse(0);
        putch(' ');
        puts_str(e->fmt ? "(PT2) " : "(PT3) ");
        puts_str(e->name);
    }

    /* Action menu lives below the directory; row 15 onward leaves room for
       up to nine entries (rows 4-12). */
    draw_menu_item(15, 'A', " play all");
    draw_menu_item(16, 'R', "escan");
    draw_menu_item(17, 'Q', "uit");

    at(21, 0); puts_str("rewind tape before playing");
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

/* Play whatever's currently loaded at TAPE_SONG_BASE, with the given title
   and format. Returns 0 if user hit SPACE, 1 if PTxPlay's loop-end flag
   tripped (song looped), 2 if user hit BREAK (CAPS+SPACE). */
#define PLAY_STOP    0
#define PLAY_LOOPED  1
#define PLAY_BREAK   2

static unsigned char play_buffer(const char *title, unsigned char fmt)
{
    unsigned char divider = 0;
    unsigned char prev_mute_keys = 0;
    unsigned char ret = PLAY_STOP;

    set_border(1);
    PTx_setup = fmt ? 0x02 : 0x00;
    PTx_init((unsigned int)TAPE_SONG_BASE);

    cls();
    draw_banner();
    draw_status(2, "-- Now playing --");
    at(4, 2);
    puts_str(fmt ? "(PT2) " : "(PT3) ");
    puts_str_n(title, 24);
    at(8,  2); puts_str("A: ");
    at(9,  2); puts_str("B: ");
    at(10, 2); puts_str("C: ");
    at(21, 0); puts_str("1-3 mute   SPACE stop");
    prev_bar[0] = prev_bar[1] = prev_bar[2] = BAR_FORCE;

    for (;;) {
        intrinsic_halt();
        if (++divider == 6) {
            divider = 0;
        } else {
            PTx_play();
            if (mute_mask & 0x01) silence_channel(0);
            if (mute_mask & 0x02) silence_channel(1);
            if (mute_mask & 0x04) silence_channel(2);
            draw_live_bars();
        }

        {
            unsigned char keys = read_row(0xF7) & 0x07;
            unsigned char pressed = keys & ~prev_mute_keys;
            prev_mute_keys = keys;
            if (pressed) mute_mask ^= pressed;
        }

        if (PTx_setup & 0x80) { ret = PLAY_LOOPED; break; }
        if (key_break())      { ret = PLAY_BREAK;  break; }
        if (key_space())      { ret = PLAY_STOP;   break; }
    }

    PTx_mute();
    set_border(7);
    while (key_space()) intrinsic_halt();
    return ret;
}

/* Walk one tape header + data block into TAPE_SONG_BASE. Returns 1 on
   success, 0 on tape error / BREAK / end of tape. */
static unsigned char tape_load_one_song(void)
{
    unsigned int length;

    tape_arg_flag = 0x00;
    tape_arg_dest = (unsigned int)tape_header;
    tape_arg_len  = 17;
    if (!tape_read_block()) return 0;

    length = tape_header[11] | ((unsigned int)tape_header[12] << 8);
    if (length == 0 || length > 0x4000) return 0;

    tape_arg_flag = 0xFF;
    tape_arg_dest = TAPE_SONG_BASE;
    tape_arg_len  = length;
    if (!tape_read_block()) return 0;
    return 1;
}

/* Build the in-memory directory by reading every header (and skipping the
   following data block) until we hit DIR_MAX, end of tape, or BREAK.
   Each found CODE block is shown live as it's discovered. */
static void scan_tape(void)
{
    cls();
    draw_banner();
    draw_status(2, "-- Scanning tape --");
    at(21, 0); puts_str("CAPS+SPACE when tape ends");

    dir_count = 0;
    while (dir_count < DIR_MAX) {
        if (!tape_load_one_song()) break;
        if (tape_header[0] != 3) continue;

        /* Trim the 10-byte tape filename into a null-terminated string. */
        char trimmed[11];
        unsigned char i, last = 0;
        for (i = 0; i < 10; i++) {
            unsigned char c = tape_header[1 + i];
            trimmed[i] = (c >= 32 && c < 127) ? c : '?';
            if (trimmed[i] != ' ') last = i + 1;
        }
        trimmed[last] = 0;

        /* Detect tape-loop: if this filename is already in the directory,
           we've wrapped around (common in emulators that loop the .tap).
           Stop scanning so we don't list the same songs N times. */
        {
            unsigned char j, dup = 0;
            for (j = 0; j < dir_count && !dup; j++) {
                unsigned char k;
                for (k = 0; ; k++) {
                    if (directory[j].name[k] != trimmed[k]) break;
                    if (trimmed[k] == 0) { dup = 1; break; }
                }
            }
            if (dup) break;
        }

        {
            struct dir_entry *e = &directory[dir_count];
            for (i = 0; i <= last; i++) e->name[i] = trimmed[i];
            e->length = tape_header[11] | ((unsigned int)tape_header[12] << 8);
            {
                const unsigned char *d = (const unsigned char *)TAPE_SONG_BASE;
                e->fmt = (d[0] == 'P' && d[1] == 'r' && d[2] == 'o' && d[11] == '3') ? 0 : 1;
            }

            at(4 + dir_count, 2);
            putch('['); put_dec(dir_count + 1); putch(']'); putch(' ');
            puts_str(e->fmt ? "(PT2) " : "(PT3) ");
            puts_str(e->name);

            dir_count++;
        }
    }
}

/* Name-matched load (like ROM LOAD "name"CODE). Reads each tape header
   in turn until the filename matches the chosen directory entry, loads
   that one's data, and plays it. Tape-position-independent on emulators;
   on real cassette the user still has to physically rewind to ensure the
   matching header is ahead of the tape head. */
static unsigned char play_index(unsigned char target)
{
    cls();
    draw_banner();
    draw_status(2, "-- Loading --");
    at(5, 4);  puts_str("Loading ");
    puts_str(directory[target].name);
    puts_str("...");
    at(21, 0); puts_str("CAPS+SPACE abort");

    while (1) {
        if (!tape_load_one_song()) {
            cls();
            at(10, 4); puts_str("LOAD ABORTED");
            at(12, 4); puts_str("Press any key");
            while (!key_digit() && !key_space() && !key_enter() &&
                   !key_R()    && !key_A())
                intrinsic_halt();
            while (key_digit() || key_space() || key_enter() ||
                   key_R()    || key_A())
                intrinsic_halt();
            return 0;
        }

        if (tape_header[0] == 3
         && header_name_matches(directory[target].name)) {
            tape_extract_title();
            {
                const unsigned char *d = (const unsigned char *)TAPE_SONG_BASE;
                unsigned char fmt = (d[0] == 'P' && d[1] == 'r' && d[2] == 'o' && d[11] == '3') ? 0 : 1;
                play_buffer(directory[target].name, fmt);
            }
            return 1;
        }
        /* Not the right song; loop. tape_load_one_song already loaded the
           data block as a side-effect (overwriting TAPE_SONG_BASE), but
           the next iteration will overwrite it again with the next song. */
    }
}

/* Read every CODE block off the tape and play them in turn. SPACE skips to
   the next song; CAPS+SPACE quits back to the directory. */
static void play_all(void)
{
    cls();
    draw_banner();
    draw_status(2, "-- Play all --");
    at(5, 4);  puts_str("Reading every song.");
    at(7, 4);  puts_str("(rewind tape first)");
    at(21, 0); puts_str("SPACE next   CAPS+SPC quit");

    while (1) {
        if (!tape_load_one_song()) return;

        if (tape_header[0] == 3) {
            const unsigned char *d = (const unsigned char *)TAPE_SONG_BASE;
            unsigned char fmt = (d[0] == 'P' && d[1] == 'r' && d[2] == 'o' && d[11] == '3') ? 0 : 1;
            tape_extract_title();
            if (play_buffer(tape_title, fmt) == PLAY_BREAK) return;
        }
    }
}

/* ---- main ------------------------------------------------------------------ */

void main(void)
{
    unsigned char d;

    intrinsic_ei();
    AY_Init();
    PTx_mute();
    set_border(7);

    for (;;) {
        if (dir_count == 0) {
            show_scan_prompt();
            while (key_space() || key_S() || key_enter() || key_Q())
                intrinsic_halt();
            for (;;) {
                intrinsic_halt();
                if (key_enter() || key_Q()) goto quit;
                if (key_space() || key_S()) {
                    while (key_space() || key_S()) intrinsic_halt();
                    scan_tape();
                    break;
                }
            }
        } else {
            show_directory();
            while (key_digit() || key_enter() || key_A() ||
                   key_R()    || key_Q())
                intrinsic_halt();
            for (;;) {
                intrinsic_halt();
                if (key_enter() || key_Q()) goto quit;
                if (key_R()) {
                    while (key_R()) intrinsic_halt();
                    /* Rescan immediately rather than dropping back to the
                       scan-prompt screen and waiting for SPACE again. */
                    scan_tape();
                    break;
                }
                if (key_A()) {
                    while (key_A()) intrinsic_halt();
                    play_all();
                    break;
                }
                d = key_digit();
                if (d >= 1 && d <= dir_count) {
                    while (key_digit()) intrinsic_halt();
                    play_index(d - 1);
                    break;
                }
            }
        }
    }

quit:
    PTx_mute();
    AY_Init();
    PlayAY();
    cls();
    set_border(7);
    intrinsic_di();
}
