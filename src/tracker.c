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

/* Tape-loaded song lives in the same memory region as the bundled high
   group; loading from tape DESTROYS the bundled songs in slots 4-6 until
   the user reloads the .tap. The C const arrays in low memory survive. */
#define TAPE_SONG_BASE  0xCB00

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
        tape_song_fmt = (d[0] == 'P' && d[1] == 'r' && d[2] == 'o') ? 0 : 1;
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

/* Sinclair cursor keys: CAPS-SHIFT + 5/6/7/8 = LEFT / DOWN / UP / RIGHT.
   '5' is on row $F7 bit 4; '6' '7' '8' are on row $EF bits 4/3/2. */
static unsigned char caps(void) { return read_row(0xFE) & 0x01; }
static unsigned char key_left(void)  { return caps() && (read_row(0xF7) & 0x10); }
static unsigned char key_down(void)  { return caps() && (read_row(0xEF) & 0x10); }
static unsigned char key_up(void)    { return caps() && (read_row(0xEF) & 0x08); }
static unsigned char key_right(void) { return caps() && (read_row(0xEF) & 0x04); }

/* Read AY register 14 (TS2068 onboard joystick port).
   Returns the raw byte; bits are active-low (0 = pressed). The exact
   direction-bit mapping depends on the TS2068's joystick wiring; we
   normalise it through joy_*() helpers below. */
static unsigned char read_joystick(void) __naked
{
__asm
    ld   a,#14
    out  (#0xF5),a
    in   a,(#0xF6)
    ld   l,a
    ret
__endasm;
}

/* TS2068 joystick: bits 0..3 are directions (active low), bit 4 is fire.
   The exact direction-to-bit mapping follows the Sinclair Interface 2
   convention reproduced on the TS2068 STICK lookup. We invert and re-test
   so the helpers behave like keyboard pressed / not-pressed. */
static unsigned char joy_right(void) { return !(read_joystick() & 0x01); }
static unsigned char joy_left(void)  { return !(read_joystick() & 0x02); }
static unsigned char joy_down(void)  { return !(read_joystick() & 0x04); }
static unsigned char joy_up(void)    { return !(read_joystick() & 0x08); }
static unsigned char joy_fire(void)  { return !(read_joystick() & 0x10); }

/* Combined "any UP signal" / "any DOWN signal" / etc. — saves the rest of
   the code from caring whether the user has a joystick plugged in. */
static unsigned char nav_up(void)    { return key_up()    || joy_up();    }
static unsigned char nav_down(void)  { return key_down()  || joy_down();  }
static unsigned char nav_left(void)  { return key_left()  || joy_left();  }
static unsigned char nav_right(void) { return key_right() || joy_right(); }
static unsigned char nav_fire(void)  { return key_space() || joy_fire();  }

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
    puts_str("    PT3 Tracker    ");  /* 19 chars */
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
    draw_menu_item(15, 'R', "escan");
    draw_menu_item(16, 'Q', "uit");

    at(21, 0); puts_str("1-9 to edit a song");
}

/* Spectrum attribute layout: bit 7 FLASH, bit 6 BRIGHT, bits 5-3 PAPER,
   bits 2-0 INK. Colors: 0 black 1 blue 2 red 3 magenta 4 green 5 cyan
   6 yellow 7 white. */
#define ATTR(paper, ink, bright)  (((paper) << 3) | (ink) | ((bright) ? 0x40 : 0))

static void write_attr(unsigned char row, unsigned char col, unsigned char attr)
{
    *(unsigned char *)(0x5800 + row * 32 + col) = attr;
}

/* (Player's volume-bar viz isn't part of the tracker yet; if/when we want
   live preview here we can lift it from src/pt3_player.c.) */


/* ---- tape helpers ---------------------------------------------------------- */

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
                e->fmt = (d[0] == 'P' && d[1] == 'r' && d[2] == 'o') ? 0 : 1;
            }

            at(4 + dir_count, 2);
            putch('['); put_dec(dir_count + 1); putch(']'); putch(' ');
            puts_str(e->fmt ? "(PT2) " : "(PT3) ");
            puts_str(e->name);

            dir_count++;
        }
    }
}

/* Read tape forward, counting CODE blocks; play the (target+1)-th one. */
/* ---- song-into-edit-slot ---------------------------------------------------
   Read tape forward, count CODE blocks, leave the (target+1)-th in the
   TAPE_SONG_BASE slot. Returns 1 on success, 0 on tape error / BREAK. */
static unsigned char load_song_to_edit(unsigned char target)
{
    unsigned char code_n = 0;

    cls();
    draw_banner();
    draw_status(2, "-- Loading --");
    at(5, 4);  puts_str("Loading song ");
    put_dec(target + 1);
    puts_str("...");
    at(7, 4);  puts_str("(rewind tape if needed)");
    at(21, 0); puts_str("CAPS+SPACE abort");

    while (1) {
        if (!tape_load_one_song()) return 0;

        if (tape_header[0] == 3) {
            if (code_n == target) {
                tape_extract_title();
                return 1;
            }
            code_n++;
        }
    }
}

/* ---- tracker views --------------------------------------------------------- */

/* Decode a 16-bit LE word from a PT3-format buffer at a given offset. */
static unsigned int word_at(const unsigned char *p, unsigned int off)
{
    return ((unsigned int)p[off]) | (((unsigned int)p[off + 1]) << 8);
}

static void put_hex2(unsigned char n)
{
    unsigned char hi = n >> 4, lo = n & 0x0F;
    putch(hi < 10 ? '0' + hi : 'A' + hi - 10);
    putch(lo < 10 ? '0' + lo : 'A' + lo - 10);
}

/* Show the song's PT3 header metadata + position list. This is read-only;
   it's the foundation for the upcoming pattern view, and useful on its own
   for confirming a load worked. */
static void show_song_info(unsigned char idx)
{
    const unsigned char *song = (const unsigned char *)TAPE_SONG_BASE;
    unsigned char  speed     = song[100];
    unsigned char  num_pos   = song[101];
    unsigned char  loop_pos  = song[102];
    unsigned int   pat_off   = word_at(song, 103);
    unsigned char  i;
    unsigned char  max_pat   = 0;
    const unsigned char *positions = song + 201;

    cls();
    draw_banner();
    draw_status(2, "-- Song info --");

    at(4, 0);  puts_str("File: ");
    puts_str(directory[idx].name);
    at(5, 0);  puts_str("Type: ");
    puts_str(directory[idx].fmt ? "PT2" : "PT3");

    /* Quick PT3-only summary. PT2 has a different layout; we'll add a
       parallel summary once the pattern decoder gets there. */
    if (directory[idx].fmt == 0) {
        at(7, 0);  puts_str("Speed:     ");  put_dec(speed);
        at(8, 0);  puts_str("Positions: ");  put_dec(num_pos);
                   puts_str(" (loop @ ");    put_dec(loop_pos); putch(')');
        at(9, 0);  puts_str("PatTbl:   $"); put_hex2(pat_off >> 8); put_hex2(pat_off & 0xFF);

        /* Position list: each byte is pattern_index*3. We scan to find the
           highest pattern index so we can show "patterns: N". */
        for (i = 0; i < num_pos; i++) {
            unsigned char p = positions[i] / 3;
            if (p > max_pat) max_pat = p;
        }
        at(10, 0); puts_str("Patterns:  "); put_dec(max_pat + 1);

        /* First 12 positions, in two columns of 6 each. */
        at(12, 0); puts_str("Positions:");
        for (i = 0; i < num_pos && i < 12; i++) {
            at(13 + (i / 6), (i % 6) * 5 + 1);
            put_hex2(i);
            putch(':');
            put_dec(positions[i] / 3);
        }
        if (num_pos > 12) { at(15, 0); puts_str("..."); }
    } else {
        at(8, 0);  puts_str("(PT2 metadata not yet");
        at(9, 0);  puts_str(" decoded -- coming soon)");
    }

    at(21, 0); puts_str("V view pattern  Q back");
}

/* Stub for the pattern view -- the decoder lands in the next session. */
static void show_pattern_stub(unsigned char idx)
{
    (void)idx;
    cls();
    draw_banner();
    draw_status(2, "-- Pattern view --");
    at(5, 0);  puts_str("Pattern decoder lands");
    at(6, 0);  puts_str("in the next session.");
    at(8, 0);  puts_str("This screen will show");
    at(9, 0);  puts_str("notes per channel,");
    at(10, 0); puts_str("scrollable with cursor");
    at(11, 0); puts_str("keys (CAPS+5/6/7/8) or");
    at(12, 0); puts_str("the 2068 joystick.");
    at(21, 0); puts_str("any key returns");

    while (!nav_fire() && !key_enter() && !key_Q() && !key_break()
        && !nav_up() && !nav_down() && !nav_left() && !nav_right()
        && !key_digit() && !key_space())
        intrinsic_halt();
    while (nav_fire() || key_enter() || key_Q() || key_break()
        || nav_up() || nav_down() || nav_left() || nav_right()
        || key_digit() || key_space())
        intrinsic_halt();
}

static void edit_song(unsigned char idx)
{
    for (;;) {
        show_song_info(idx);
        while (key_enter() || key_Q() || nav_fire()) intrinsic_halt();
        for (;;) {
            intrinsic_halt();
            if (key_enter() || key_Q()) return;
            /* 'V' is on row $FB bit 4 (Q W E R T -- wait, that's T). Actually
               $FE row Z X C V = bits 1..4, so V = $FE bit 4. */
            if (read_row(0xFE) & 0x10) {
                while (read_row(0xFE) & 0x10) intrinsic_halt();
                show_pattern_stub(idx);
                break;
            }
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
            while (key_digit() || key_enter() || key_R() || key_Q())
                intrinsic_halt();
            for (;;) {
                intrinsic_halt();
                if (key_enter() || key_Q()) goto quit;
                if (key_R()) {
                    while (key_R()) intrinsic_halt();
                    scan_tape();
                    break;
                }
                d = key_digit();
                if (d >= 1 && d <= dir_count) {
                    while (key_digit()) intrinsic_halt();
                    if (load_song_to_edit(d - 1)) edit_song(d - 1);
                    /* If load failed we just fall through and redraw the
                       directory; the tape may be at a weird position. */
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
