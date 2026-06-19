/* =============================================================================
   tracker.c -- TS Tracker pattern editor, universal PT2/PT3 build.

   Companion to pt3_player.c (the playback-only picker). Both apps share
   the same PTxPlay engine wrapper: see src/pt_engine.[ch] for the asm
   thunks (PTx_init / PTx_play / PTx_mute), the AY-mute helper, and the
   60Hz->50Hz tempo divider. PTxPlay itself is assembled to a flat binary
   (build/ptxplay.bin), shipped as a separate CODE block on the same tape,
   and loaded by the TS2068 tape loader at PTX_ORIGIN_HEX from the Makefile.
============================================================================= */
#include <intrinsic.h>

#include "ay_ts2068.h"
#include "pt_engine.h"      /* PTx_*, silence_channel, pt_play_60to50, PTx_setup */
#include "ptxplay_addrs.h"  /* CurPos_ADDR (used directly by play_song_full) */

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
    call #0x00FC           ; EXROM R_TAPE (LD-BYTES) standard entry.
                           ; Side effect: BREAK during load drops to
                           ; BASIC via W_BORD; the bypass at 0x0108 was
                           ; flaky on second-block reads.

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

/* Tape WRITE: same shape as tape_read_block, but calls SA-BYTES at EXROM
   $006B instead of LD-BYTES. Inputs (via globals): flag, src, len. SA-BYTES
   convention: A = flag byte (0 for header, 0xFF for data), IX = source,
   DE = byte count. CY=1 on entry (some references; we set it for parity
   with LD-BYTES) and the routine handles the rest of the AY tone-out. */
static unsigned char tape_write_block(void) __naked
{
__asm
    push ix
    di

    in   a,(#0xFF)
    ld   (_saved_decr),a
    set  7,a
    out  (#0xFF),a

    in   a,(#0xF4)
    ld   (_saved_hsr),a
    ld   a,#1
    out  (#0xF4),a

    ld   a,(_tape_arg_flag)
    ld   ix,(_tape_arg_dest)
    ld   de,(_tape_arg_len)
    scf
    call #0x006C           ; EXROM W_TAPE past PUSH HL of W_BORD; this
                           ; bypasses the BREAK-trapping cleanup so that
                           ; CAPS+SHIFT during save just returns CY=0
                           ; instead of bouncing to BASIC.

    ld   a,#0
    rla
    push af

    ld   a,(_saved_hsr)
    out  (#0xF4),a
    ld   a,(_saved_decr)
    out  (#0xFF),a
    ei

    pop  af
    ld   l,a
    pop  ix
    ret
__endasm;
}

/* TAPE_SONG_BASE is normally provided by the Makefile via -D so it stays in
   sync with PTxPlay's origin. Fall back to a sane default if this file is
   read by an IDE / standalone clang that doesn't see the Make recipe. */
#ifndef TAPE_SONG_BASE
#define TAPE_SONG_BASE  0xC000
#endif

static unsigned char tape_header[17];
static unsigned char tape_song_loaded;
static unsigned char tape_song_fmt;

/* Minimal valid PT3 template baked into the binary. Used by the "New song"
   path on the scan-prompt screen so users can start composing without
   needing to load anything from tape first. Layout: standard PT3 header
   (offsets 0..200), one position list entry (pattern 0 + 0xFF terminator),
   a minimal sample/ornament definition, and -- crucially LAST -- the pattern
   table (@224) + three single-FIN channel streams (@230). Pattern table and
   data come after the instrument definitions so rebuild_song can overwrite
   them in place from base_pat_off (=$E0=224) without disturbing instruments.
   The pattptr at 103/104 points to 224; the old 203-211 table/streams that
   the original template carried are left as dead bytes (harmless). */
#define EMPTY_PT3_LEN 233
static const unsigned char empty_pt3[EMPTY_PT3_LEN] = {
    0x50, 0x72, 0x6F, 0x54, 0x72, 0x61, 0x63, 0x6B, 0x65, 0x72, 0x20, 0x33, 0x2E, 0x37, 0x20, 0x63,
    0x6F, 0x6D, 0x70, 0x69, 0x6C, 0x61, 0x74, 0x69, 0x6F, 0x6E, 0x20, 0x6F, 0x66, 0x20, 0x4E, 0x65,
    0x77, 0x20, 0x73, 0x6F, 0x6E, 0x67, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x62,
    0x79, 0x20, 0x54, 0x53, 0x20, 0x54, 0x72, 0x61, 0x63, 0x6B, 0x65, 0x72, 0x20, 0x20, 0x20, 0x20,
    0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20,
    0x20, 0x20, 0x00, 0x00, 0x06, 0x01, 0x00, 0xE0, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7,
    0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7,
    0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7,
    0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7,
    0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xD7, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD,
    0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD,
    0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0xDD, 0x00, 0x00, 0xFF, 0xD1, 0x00, 0xD2, 0x00, 0xD3,
    0x00, 0xD0, 0xD0, 0xD0, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    /* @224 pattern table (chA=$E6=230, chB=$E7=231, chC=$E8=232), @230 streams */
    0xE6, 0x00, 0xE7, 0x00, 0xE8, 0x00, 0xD0, 0xD0, 0xD0,
};

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
    unsigned char r, c;
    /* Reset PRINT colour state so spaces pick up the default attribute and
       the banner from the previous screen doesn't bleed through. */
    putch(0x10); putch(0);   /* INK 0 (black) */
    putch(0x11); putch(7);   /* PAPER 7 (white) */
    putch(0x13); putch(0);   /* BRIGHT 0 */
    putch(0x14); putch(0);   /* INVERSE 0 */
    /* Row-by-row to fill all 22 * 32 = 704 cells. A single 704-char loop
       would land the print position at "next char would scroll" and the
       cls's own AT-reset at the end clears that without a scroll prompt;
       row-by-row is just easier to reason about and equally fast. */
    for (r = 0; r < 22; r++) {
        at(r, 0);
        for (c = 0; c < 32; c++) putch(' ');
    }
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

/* Forward decl: key_any is defined later (down with the keyboard helpers
   that need it). show_splash needs it now, and without a prototype SDCC
   would assume `int key_any()` -- the real function returns the result
   in L with H undefined, which corrupts the boolean check. */
static unsigned char key_any(void);

/* Boot splash. Drawn once on startup, dismisses on any key. Reuses the
   TIMEX banner and the white-on-red status bar so it looks like a member
   of the same app rather than a separate intro. */
static void show_splash(void)
{
    cls();
    draw_banner();
    draw_status(1, "-- Welcome --");

    at(5,  11); puts_str("TS Tracker");
    at(7,  6);  puts_str("PT3 song editor for");
    at(8,  9);  puts_str("the TS-2068");

    at(12, 3);  puts_str("a 64K Software production");

    at(20, 5);  puts_str("Press any key to start.");

    while (key_any())  intrinsic_halt();
    while (!key_any()) intrinsic_halt();
    while (key_any())  intrinsic_halt();
}

static void show_scan_prompt(void)
{
    cls();
    draw_banner();
    draw_status(1, "-- No tape loaded --");

    at(4, 0);  puts_str("Insert a tape (or .tap in");
    at(5, 0);  puts_str("an emulator), then:");

    draw_menu_item(9,  'S', "can tape");
    draw_menu_item(10, 'N', "ew song (no tape needed)");
    draw_menu_item(11, 'Q', "uit");

    at(13, 0); puts_str("After the last song plays,");
    at(14, 0); puts_str("press CAPS+SPACE to stop");
    at(15, 0); puts_str("scanning.");
}

/* Decode every pattern into the editing model. Defined after the encoder
   (it normalises the slot via rebuild_song); declared here because the song
   load paths below call it right after populating TAPE_SONG_BASE. */
static void decode_all_patterns(void);

/* Initialise an empty PT3 song in the slot at TAPE_SONG_BASE and a
   single-entry directory pointing at it. Lets the user start composing
   without a tape mounted -- the alternative to scanning. After a New
   song session, dir_count is reset to 0 so the next outer iteration
   returns to the scan prompt rather than offering a "load NEW SONG"
   that would try to re-read it from a tape it was never on. */
static void start_new_song(void)
{
    unsigned char *song = (unsigned char *)TAPE_SONG_BASE;
    unsigned int   i;

    for (i = 0; i < EMPTY_PT3_LEN; i++) song[i] = empty_pt3[i];

    {
        struct dir_entry *e = &directory[0];
        const char *name = "NEW SONG";
        unsigned char j;
        for (j = 0; name[j] && j < 10; j++) e->name[j] = name[j];
        e->name[j] = 0;
        e->length = EMPTY_PT3_LEN;
        e->fmt    = 0;            /* PT3 */
    }
    dir_count = 1;
    /* save_version is a session-wide counter; we don't reset it here so
       multiple saves (across both tape-loaded and new songs in one
       session) stay distinct on the tape. */

    decode_all_patterns();      /* template -> model, normalise the slot */
}

/* Render one directory entry in its final display format (INVERSE hotkey,
   space, "(PTx)", name). Called both during scan and on full redraws. */
static void draw_dir_entry(unsigned char i)
{
    struct dir_entry *e = &directory[i];
    at(3 + i, 4);
    set_inverse(1);
    putch('1' + i);
    set_inverse(0);
    putch(' ');
    puts_str(e->fmt ? "(PT2) " : "(PT3) ");
    puts_str(e->name);
}

/* Write "-- N songs found --" (or "1 song found") to the status line. */
static void draw_dir_status(void)
{
    char buf[24];
    unsigned char j = 0;
    const char *prefix = "-- ";
    const char *suffix = (dir_count == 1) ? " song found --" : " songs found --";
    while (*prefix)  buf[j++] = *prefix++;
    if (dir_count >= 10) buf[j++] = '0' + dir_count / 10;
    buf[j++] = '0' + dir_count % 10;
    while (*suffix)  buf[j++] = *suffix++;
    buf[j] = 0;
    draw_status(1, buf);
}

/* Action menu + hint at the bottom of the directory. The hint is padded to
   32 chars so it cleanly overwrites scan_tape's longer "CAPS+SPACE when..."
   message when we transition to the directory in place. */
static void draw_dir_actions(void)
{
    draw_menu_item(15, 'R', "escan");
    draw_menu_item(16, 'Q', "uit");
    at(21, 0); puts_str("1-9 to edit a song              ");
}

static void show_directory(void)
{
    unsigned char i;
    cls();
    draw_banner();
    draw_dir_status();
    for (i = 0; i < dir_count; i++) draw_dir_entry(i);
    draw_dir_actions();
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
   Each found CODE block is rendered in its final directory format as it's
   discovered, and the whole screen transitions to the directory display
   in place when scanning completes -- so main() can skip a redundant
   show_directory() redraw on this path. */
static void scan_tape(void)
{
    cls();
    draw_banner();
    draw_status(1, "-- Scanning tape --");
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
                /* PT3's "ProTracker 3.X compilation of " puts '3' at offset
                   11; PT2 has '2' there. Just checking "Pro" at the start
                   isn't enough -- both formats begin that way. */
                const unsigned char *d = (const unsigned char *)TAPE_SONG_BASE;
                e->fmt = (d[0] == 'P' && d[1] == 'r' && d[2] == 'o'
                       && d[11] == '3') ? 0 : 1;
            }
            draw_dir_entry(dir_count);
            dir_count++;
        }
    }

    /* In-place transition to the directory screen: status + actions overwrite
       the "Scanning tape" / "CAPS+SPACE..." cells, leaving the song list
       intact. Caller must not redraw via show_directory after this. */
    draw_dir_status();
    draw_dir_actions();
}

/* Compare the tape header's 10-byte filename to a directory entry's name
   (null-terminated, space-padded by convention). Returns 1 on full match. */
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

/* ---- song-into-edit-slot ---------------------------------------------------
   Name-matched load (like ROM LOAD "name"). LD-BYTES requires reading
   each block in turn -- a flag mismatch is treated as a failure, not a
   skip -- so we read both header and data for every block on the tape
   and compare the header's filename. The data lands in TAPE_SONG_BASE
   either way; non-matching songs are overwritten on the next iteration,
   the matching one ends up there as the final result. Returns 1 on
   match found, 0 on tape error / BREAK / no matching block. */
static unsigned char load_song_to_edit(unsigned char target)
{
    cls();
    draw_banner();
    draw_status(1, "-- Loading --");
    at(4, 4);  puts_str("Loading ");
    puts_str(directory[target].name);
    puts_str("...");
    at(21, 0); puts_str("CAPS+SPACE abort");

    for (;;) {
        if (!tape_load_one_song()) return 0;
        if (tape_header[0] == 3
         && header_name_matches(directory[target].name)) {
            tape_extract_title();
            /* PT3 only: decode every pattern into the editing model now.
               PT2 has no decoder (show_song_info says as much), so leave the
               model untouched and let show_pattern refuse to edit it. */
            if (directory[target].fmt == 0) decode_all_patterns();
            return 1;
        }
        /* Not our song -- the data block was already loaded into
           TAPE_SONG_BASE as a side-effect, but we don't care; the next
           iteration's load will overwrite it. */
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
    draw_status(1, "-- Song info --");

    at(3, 0);  puts_str("File: ");
    puts_str(directory[idx].name);
    at(4, 0);  puts_str("Type: ");
    puts_str(directory[idx].fmt ? "PT2" : "PT3");

    /* Quick PT3-only summary. PT2 has a different layout; we'll add a
       parallel summary once the pattern decoder gets there. */
    if (directory[idx].fmt == 0) {
        at(6, 0);  puts_str("Speed:     ");  put_dec(speed);
        at(7, 0);  puts_str("Positions: ");  put_dec(num_pos);
                   puts_str(" (loop @ ");    put_dec(loop_pos); putch(')');
        at(8, 0);  puts_str("PatTbl:   $"); put_hex2(pat_off >> 8); put_hex2(pat_off & 0xFF);

        /* Position list: each byte is pattern_index*3. We scan to find the
           highest pattern index so we can show "patterns: N". */
        for (i = 0; i < num_pos; i++) {
            unsigned char p = positions[i] / 3;
            if (p > max_pat) max_pat = p;
        }
        at(9, 0); puts_str("Patterns:  "); put_dec(max_pat + 1);

        /* First 12 positions, in two columns of 6 each. */
        at(11, 0); puts_str("Positions:");
        for (i = 0; i < num_pos && i < 12; i++) {
            at(13 + (i / 6), (i % 6) * 5 + 1);
            put_hex2(i);
            putch(':');
            put_dec(positions[i] / 3);
        }
        if (num_pos > 12) { at(14, 0); puts_str("..."); }
    } else {
        at(7, 0);  puts_str("(PT2 metadata not yet");
        at(8, 0);  puts_str(" decoded -- coming soon)");
    }

    at(21, 0); puts_str("V view pattern  Q back");
}

/* ---- PT3 pattern decoder --------------------------------------------------
   PT3 patterns are three independent byte streams (one per AY channel),
   referenced by a pattern table. Each stream is a sequence of one-byte
   commands, some with parameters; rows end on FIN ($D0), NOTE ($50..$AF)
   or RELEASE ($C0). Between rows a per-channel "skip count" (NNtSkp /
   NtSkCn) holds a single decoded event for several rows -- the format's
   main compression trick. The dispatch ranges below come straight from
   PTxPlay.asm's PT3PD; SETENV / SPCCOMS parameter counts are read from
   PTxPlay's handlers (C_GLISS=3, C_PORTM=5, etc.). */

typedef struct {
    signed char    note;       /* -1 = no event, -2 = release, 0..95 = note */
    unsigned char  sample;     /* 0..31 */
    unsigned char  volume;     /* 0..15 */
} cell_t;

#define PV_ROWS_MAX 64
#define PAT_CELLS   (PV_ROWS_MAX * 3)        /* cells per pattern (64 rows x 3) */

/* ---- Decoded song model (source of truth while editing) -------------------
   Every pattern lives fully decoded in the free RAM gap below the C image, so
   edits are instant and lossless: switching patterns just repoints
   pattern_view, and the PT3 byte stream at TAPE_SONG_BASE is regenerated on
   demand (rebuild_song) only when we play or save -- there is no manual
   "commit" step. MODEL_BASE is a fixed address (like TAPE_SONG_BASE) in the
   ~$6000..$8000 gap; keep MAX_PATTERNS * PAT_CELLS * sizeof(cell_t) below
   ($8000 - MODEL_BASE). With cell_t = 3 bytes that's 576 B/pattern. */
#define MAX_PATTERNS 14
#define MODEL_BASE   0x6000u
#define MODEL(p)     ((cell_t *)(MODEL_BASE) + (unsigned int)(p) * PAT_CELLS)

/* pattern_view aliases the current pattern's PAT_CELLS cells (flat
   [row*3+ch]); repointed on every pattern switch. */
static cell_t      *pattern_view;
static unsigned char num_pat_total;   /* patterns decoded into the model */
static unsigned int  base_pat_off;    /* offset of pattern table = rebuild base */

typedef struct {
    const unsigned char *p;
    unsigned char ntskcn;      /* rows still to skip (no decode) */
    unsigned char ntskp;       /* skip-count to reload on row terminator */
    unsigned char sample;
    unsigned char ornament;
    unsigned char volume;
    signed char   note;        /* current row's emitted note */
    unsigned char done;        /* set when FIN encountered: emit empties only */
} chdec_t;

static const unsigned char spccoms_param[16] = {
    0, /* 00 NOP   */
    3, /* 01 GLISS  delay + 16-bit step */
    5, /* 02 PORTM  delay + 16-bit skip + 16-bit step */
    1, /* 03 SMPOS  position */
    1, /* 04 ORPOS  position */
    2, /* 05 VIBRT  on-delay + off-delay */
    0, /* 06 NOP   */
    0, /* 07 NOP   */
    3, /* 08 ENGLS  delay + 16-bit env-step */
    1, /* 09 DELAY  speed */
    0, 0, 0, 0, 0, 0 /* 0A..0F NOP */
};

static void decode_channel_row(chdec_t *c)
{
    /* After FIN, the stream pointer points past the channel's last byte;
       further reads would parse garbage. Just emit empties. */
    if (c->done)   { c->note = -1; return; }
    if (c->ntskcn) { c->ntskcn--; c->note = -1; return; }
    c->note = -1;
    for (;;) {
        unsigned char cmd = *c->p++;

        if (cmd == 0xD0) { c->done = 1; return; }                       /* FIN */
        if (cmd >= 0x50 && cmd <= 0xAF) {                               /* NOTE */
            c->note = (signed char)(cmd - 0x50);
            c->ntskcn = c->ntskp;
            return;
        }
        if (cmd == 0xC0) {                                              /* RELEASE */
            c->note = -2;
            c->ntskcn = c->ntskp;
            return;
        }

        if (cmd >= 0xC1 && cmd <= 0xCF) { c->volume = cmd & 0x0F; continue; }
        if (cmd >= 0x40 && cmd <= 0x4F) { c->ornament = cmd & 0x0F; continue; }
        if (cmd >= 0x20 && cmd <= 0x3F) { continue; }                   /* NOISE base */
        if (cmd >= 0xD1 && cmd <= 0xEF) { c->sample = cmd - 0xD0; continue; }
        if (cmd >= 0xF0) {                                              /* OrSm */
            c->ornament = cmd - 0xF0;
            c->sample = (*c->p++) >> 1;
            continue;
        }
        if (cmd >= 0x10 && cmd <= 0x1F) {                               /* ESAM */
            c->sample = (*c->p++) >> 1;
            continue;
        }
        if (cmd == 0xB0) continue;                                      /* EOff */
        if (cmd == 0xB1) { c->ntskp = *c->p++; continue; }              /* set skip */
        if (cmd >= 0xB2 && cmd <= 0xBF) { c->p += 2; continue; }        /* SETENV */
        c->p += spccoms_param[cmd & 0x0F];                              /* SPCCOMS */
    }
}

/* Decode three independent channel byte streams into pattern_view[].
   Anchored to the song's pattern table by decode_pattern; could also be
   pointed at a freshly-encoded buffer for testing. */
static void decode_pattern_streams(const unsigned char *p_a,
                                   const unsigned char *p_b,
                                   const unsigned char *p_c)
{
    chdec_t ch[3];
    const unsigned char *ps[3];
    unsigned char  c;
    unsigned int   row;

    ps[0] = p_a; ps[1] = p_b; ps[2] = p_c;
    for (c = 0; c < 3; c++) {
        ch[c].p = ps[c];
        ch[c].ntskcn = 0;
        ch[c].ntskp  = 0;
        ch[c].sample = 0;
        ch[c].ornament = 0;
        ch[c].volume = 15;
        ch[c].note = -1;
        ch[c].done = 0;
    }

    for (row = 0; row < PV_ROWS_MAX; row++) {
        if (ch[0].done && ch[1].done && ch[2].done) break;
        for (c = 0; c < 3; c++) {
            cell_t *cell = &pattern_view[row * 3 + c];
            decode_channel_row(&ch[c]);
            cell->note   = ch[c].note;
            cell->sample = ch[c].sample;
            cell->volume = ch[c].volume;
        }
    }
    for (; row < PV_ROWS_MAX; row++) {
        for (c = 0; c < 3; c++) {
            cell_t *cell = &pattern_view[row * 3 + c];
            cell->note   = -1;
            cell->sample = 0;
            cell->volume = 0;
        }
    }
}

static void decode_pattern(unsigned char pat_index)
{
    const unsigned char *song = (const unsigned char *)TAPE_SONG_BASE;
    unsigned int pat_tbl   = song[103] | ((unsigned int)song[104] << 8);
    unsigned int pat_entry = pat_tbl + (unsigned int)pat_index * 6;
    unsigned int off_a = song[pat_entry + 0] | ((unsigned int)song[pat_entry + 1] << 8);
    unsigned int off_b = song[pat_entry + 2] | ((unsigned int)song[pat_entry + 3] << 8);
    unsigned int off_c = song[pat_entry + 4] | ((unsigned int)song[pat_entry + 5] << 8);
    decode_pattern_streams(song + off_a, song + off_b, song + off_c);
}

/* ---- PT3 pattern encoder --------------------------------------------------
   Inverse of decode_pattern_streams: walks one channel of pattern_view[],
   tracks the same state the decoder would (current sample, volume, ntskp),
   and emits a minimal byte stream that round-trips back to the same cells.
   Returns bytes written, or 0xFFFF on error.

   Limitations:
   - Ornament info isn't preserved (cell_t doesn't carry it). Saved songs
     lose ornaments until we extend cell_t.
   - Empty row 0 of an active channel can't be a literal "nothing" in PT3, so
     it becomes a REST (see below). Fully silent channels emit just FIN.
   rebuild_song encodes straight into the song slot, so no staging buffer. */
static unsigned char  encode_event_rows[PV_ROWS_MAX];

static unsigned int encode_channel(unsigned char chan,
                                   unsigned char *out,
                                   unsigned int max_out)
{
    unsigned char cur_sample = 0;
    unsigned char cur_volume = 15;
    unsigned char cur_skip   = 0;
    unsigned int  pos = 0;
    unsigned char i, row, n_events = 0;

    /* Pass 1: collect rows that carry an event. */
    for (row = 0; row < PV_ROWS_MAX; row++) {
        if (pattern_view[row * 3 + chan].note != -1)
            encode_event_rows[n_events++] = row;
    }

    /* Fully silent channel: a single FIN makes the decoder mark `done`
       on row 0 and emit -1 for everything else. */
    if (n_events == 0) {
        if (max_out < 1) return 0xFFFFu;
        out[0] = 0xD0;
        return 1;
    }

    /* Active channel with no event on row 0: PT3 always decodes row 0, so a
       literally-empty row 0 isn't representable. Emit a REST at row 0
       (silence) and skip to the first real event. On reload row 0 shows as a
       rest rather than empty -- functionally identical (silent start), since
       this engine re-inits each channel per pattern (no cross-pattern hold). */
    if (encode_event_rows[0] != 0) {
        unsigned char lead = encode_event_rows[0] - 1;   /* rows after row 0 */
        if (pos + 3 > max_out) return 0xFFFFu;
        out[pos++] = 0xB1;            /* set skip count   */
        out[pos++] = lead;
        out[pos++] = 0xC0;            /* RELEASE at row 0 */
        cur_skip = lead;
    }

    /* Pass 2: emit per-event commands. The decoder reads NNtSkp + N at
       the SAME decode call as the following terminator, so we set ntskp
       *before* each event to control the gap that follows it. */
    for (i = 0; i < n_events; i++) {
        unsigned char r = encode_event_rows[i];
        cell_t *cell = &pattern_view[r * 3 + chan];
        unsigned char gap = (i + 1 < n_events)
                          ? (encode_event_rows[i + 1] - r - 1)
                          : 0;

        if (gap != cur_skip) {
            if (pos + 2 > max_out) return 0xFFFFu;
            out[pos++] = 0xB1;
            out[pos++] = gap;
            cur_skip = gap;
        }
        if (cell->sample != cur_sample) {
            /* Decoder accepts samples 1..31 via the short 0xD1..0xEF
               command, and 0..127 via ESAM (0x10..0x1F + byte where
               byte>>1 = sample). We use the short form when possible,
               and fall back to ESAM for sample 0 or 32+. Without the
               fallback, songs that explicitly set sample 0 (via ESAM)
               or 32+ silently drift our cur_sample out of sync. */
            if (cell->sample >= 1 && cell->sample <= 31) {
                if (pos + 1 > max_out) return 0xFFFFu;
                out[pos++] = 0xD0 + cell->sample;        /* 0xD1..0xEF */
            } else {
                if (pos + 2 > max_out) return 0xFFFFu;
                out[pos++] = 0x10;                       /* ESAM, env=0 */
                out[pos++] = (unsigned char)(cell->sample << 1);
            }
            cur_sample = cell->sample;
        }
        if (cell->volume >= 1 && cell->volume <= 15
            && cell->volume != cur_volume) {
            if (pos + 1 > max_out) return 0xFFFFu;
            out[pos++] = 0xC0 + cell->volume;     /* 0xC1..0xCF */
            cur_volume = cell->volume;
        }
        if (pos + 1 > max_out) return 0xFFFFu;
        if (cell->note == -2) {
            out[pos++] = 0xC0;                    /* RELEASE */
        } else {
            out[pos++] = 0x50 + (unsigned char)cell->note;
        }
    }

    if (pos + 1 > max_out) return 0xFFFFu;
    out[pos++] = 0xD0;                            /* FIN */
    return pos;
}

/* ---- Row insert / delete --------------------------------------------------
   Both ops affect all 3 channels at once: what the user sees as "the row at
   the cursor" is the visual stripe across channels A/B/C. Edits go straight
   into the model (pattern_view aliases model[cur_pat]) and persist across
   pattern switches; the PT3 stream is regenerated on play/save. */

/* Insert an empty row at `row`: shift rows row..PV_ROWS_MAX-2 down by 1
   (so what was at `row` is now at `row+1`), and clear the inserted slot.
   The last row (PV_ROWS_MAX-1) is overwritten / lost. */
static void insert_row(unsigned char row)
{
    unsigned char r;
    for (r = PV_ROWS_MAX - 1; r > row; r--) {
        cell_t *dst = &pattern_view[(unsigned int)r * 3];
        cell_t *src = &pattern_view[(unsigned int)(r - 1) * 3];
        dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
    }
    {
        cell_t *c = &pattern_view[(unsigned int)row * 3];
        c[0].note = -1; c[0].sample = 0; c[0].volume = 0;
        c[1] = c[0]; c[2] = c[0];
    }
}

/* Delete the row at `row`: shift rows row+1..PV_ROWS_MAX-1 up by 1, clear
   the now-vacated last row. The original `row` is lost. */
static void delete_row(unsigned char row)
{
    unsigned char r;
    for (r = row; r < PV_ROWS_MAX - 1; r++) {
        cell_t *dst = &pattern_view[(unsigned int)r * 3];
        cell_t *src = &pattern_view[(unsigned int)(r + 1) * 3];
        dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
    }
    {
        cell_t *c = &pattern_view[(unsigned int)(PV_ROWS_MAX - 1) * 3];
        c[0].note = -1; c[0].sample = 0; c[0].volume = 0;
        c[1] = c[0]; c[2] = c[0];
    }
}

/* ---- pattern view ---------------------------------------------------------- */

static const char note_names[12][2] = {
    {'C','-'}, {'C','#'}, {'D','-'}, {'D','#'}, {'E','-'}, {'F','-'},
    {'F','#'}, {'G','-'}, {'G','#'}, {'A','-'}, {'A','#'}, {'B','-'}
};

static void put_note(signed char note)
{
    if (note == -1) { putch('-'); putch('-'); putch('-'); return; }
    if (note == -2) { putch('-'); putch('='); putch('-'); return; }
    {
        unsigned char oct = (unsigned char)note / 12 + 1;
        unsigned char st  = (unsigned char)note % 12;
        putch(note_names[st][0]);
        putch(note_names[st][1]);
        putch('0' + oct);
    }
}

static void put_hex1(unsigned char n)
{
    n &= 0x0F;
    putch(n < 10 ? '0' + n : 'A' + n - 10);
}

#define VIEW_TOP_ROW   4    /* grid starts at row 4 (banner/status/info/header
                               occupy 0-3); reclaimed the old File + blank rows */
#define VIEW_HEIGHT    16   /* rows 4..19; row 20 = Free, row 21 = hint */

/* Crude budget for an edited song. The tape song slot starts at
   TAPE_SONG_BASE and we reserve room for the stack and ROM tape buffers
   above $FB00; the gap is the headroom for the song's encoded bytes. */
#define SONG_BUDGET    (0xFB00u - TAPE_SONG_BASE)

/* Two trackers for song bytes:
     song_size       -- exact size of the regenerated PT3 stream in the slot.
                        Set whenever rebuild_song runs (load, play, save).
     song_bytes_used -- the user-visible "Free:" estimate. Tracks song_size
                        plus a rough +/-2 per edit so the indicator moves as
                        you type; snapped back to the true size on each
                        rebuild. */
static unsigned int song_size;
static unsigned int song_bytes_used;

/* Right-aligned 5-digit decimal (leading-space-padded), suitable for the
   "Free: NNNNN" indicator that updates in place each edit. */
static void put_dec5_right(unsigned int n)
{
    putch(n >= 10000 ? '0' + (n / 10000) % 10 : ' ');
    putch(n >= 1000  ? '0' + (n / 1000)  % 10 : ' ');
    putch(n >= 100   ? '0' + (n / 100)   % 10 : ' ');
    putch(n >= 10    ? '0' + (n / 10)    % 10 : ' ');
    putch('0' + n % 10);
}

static void draw_free_mem(void)
{
    unsigned int free_bytes = (SONG_BUDGET > song_bytes_used)
                            ? SONG_BUDGET - song_bytes_used
                            : 0;
    at(20, 0);
    puts_str("Free: ");
    put_dec5_right(free_bytes);
    puts_str(" bytes");
}

/* Print one channel's "note sample" group with optional INVERSE highlight
   on just that group. Used by draw_pattern_row so that the cursor cell --
   not the whole row -- pops out visually. */
static void draw_channel_cell(const cell_t *c, unsigned char highlight)
{
    if (highlight) set_inverse(1);
    put_note(c->note);
    putch(' ');
    if (c->sample) put_hex1(c->sample); else putch('.');
    if (highlight) set_inverse(0);
}

/* Render one pattern row. `is_cursor_row` paints the row's leading hex in
   INVERSE (a horizontal "you are here" stripe); `active_ch` (0..2 or
   0xFF for none) paints just that channel cell in INVERSE. Together they
   place a unique cell-level cursor without obscuring neighbouring rows. */
static void draw_pattern_row(unsigned char screen_row, unsigned char prow,
                             unsigned char is_cursor_row,
                             unsigned char active_ch)
{
    cell_t *cells = &pattern_view[(unsigned int)prow * 3];
    unsigned char i;
    /* Beat lines: tint the whole row's PAPER so the grid reads like bars.
       Every 16th row (bar) is the strongest landmark, every 4th (beat) a
       lighter one, the rest plain white. INK stays black, so all stay
       readable; the cursor cell's INVERSE still pops on any background. */
    unsigned char paper = ((prow & 15) == 0) ? 6     /* bar  (every 16): yellow */
                        : ((prow & 3)  == 0) ? 5     /* beat (every 4):  cyan   */
                        : 7;                          /* normal:          white  */

    putch(0x11); putch(paper);            /* set PAPER for this row */
    at(screen_row, 0);
    if (is_cursor_row) set_inverse(1);
    put_hex2(prow);
    if (is_cursor_row) set_inverse(0);
    putch(' '); putch(' ');
    for (i = 0; i < 3; i++) {
        draw_channel_cell(&cells[i], is_cursor_row && active_ch == i);
        if (i < 2) { putch(' '); putch(' '); }
    }
    for (i = 23; i < 32; i++) putch(' ');  /* pad to full width so the band fills */
    putch(0x11); putch(7);                 /* reset PAPER to default white */
}

/* O / P keys = previous / next pattern. Easy reach on the Sinclair keyboard
   and don't conflict with anything else here. */
static unsigned char key_O(void) { return read_row(0xDF) & 0x02; }
static unsigned char key_P(void) { return read_row(0xDF) & 0x01; }
/* F = jump-to-pattern. Sits on row $FD between D and G; doesn't overlap
   the piano (D# is D, F# is G), so it stays free for a separate action. */
static unsigned char key_F(void) { return read_row(0xFD) & 0x08; }
/* T = save song slot to tape (writes a fresh CODE block via SA-BYTES).
   Row $FB bit 4; not on the piano. */
static unsigned char key_T(void) { return read_row(0xFB) & 0x10; }
/* Y / N for confirm modals. Y = row $DF bit 4 (P O I U Y). N = row $7F
   bit 3 (SPACE SYM M N B). */
static unsigned char key_Y(void) { return read_row(0xDF) & 0x10; }
static unsigned char key_N(void) { return read_row(0x7F) & 0x08; }
/* H = help page; row $BF bit 4 (ENTER L K J H). */
static unsigned char key_H(void) { return read_row(0xBF) & 0x10; }
/* I = insert row at cursor; U = toggle volume edit mode.
   Both live on row $DF (P O I U Y), bits 2 and 3. */
static unsigned char key_I(void) { return read_row(0xDF) & 0x04; }
static unsigned char key_U(void) { return read_row(0xDF) & 0x08; }

/* Returns nonzero if any key on the keyboard is pressed. Used for "press
   any key to continue" prompts after modal screens. */
static unsigned char key_any(void)
{
    if (read_row(0xFE)) return 1;
    if (read_row(0xFD)) return 1;
    if (read_row(0xFB)) return 1;
    if (read_row(0xF7)) return 1;
    if (read_row(0xEF)) return 1;
    if (read_row(0xDF)) return 1;
    if (read_row(0xBF)) return 1;
    if (read_row(0x7F)) return 1;
    return 0;
}

/* Read a hex-digit key (0..F) and return its value, or -1 if no hex key
   is pressed. Skips when CAPS-SHIFT is held so cursor-key chords (CAPS+5
   etc.) don't leak into the prompt as digit input. Letter rows that
   overlap piano keys still report A..F here -- the prompt is modal so
   we re-purpose those keys safely while it's open. */
static signed char read_hex_key(void)
{
    unsigned char r_fe = read_row(0xFE);   /* CAPS Z X C V       */
    unsigned char r_fd, r_fb, r_7f;
    unsigned char r_f7 = read_row(0xF7);   /* 1 2 3 4 5          */
    unsigned char r_ef = read_row(0xEF);   /* 0 9 8 7 6          */

    if (r_fe & 0x01) return -1;            /* CAPS held: not a hex digit */

    if (r_f7 & 0x01) return 1;
    if (r_f7 & 0x02) return 2;
    if (r_f7 & 0x04) return 3;
    if (r_f7 & 0x08) return 4;
    if (r_f7 & 0x10) return 5;
    if (r_ef & 0x10) return 6;
    if (r_ef & 0x08) return 7;
    if (r_ef & 0x04) return 8;
    if (r_ef & 0x02) return 9;
    if (r_ef & 0x01) return 0;

    r_fd = read_row(0xFD);                 /* A S D F G          */
    r_fb = read_row(0xFB);                 /* Q W E R T          */
    r_7f = read_row(0x7F);                 /* SPACE SYM M N B    */

    if (r_fd & 0x01) return 0xA;           /* A */
    if (r_7f & 0x10) return 0xB;           /* B */
    if (r_fe & 0x08) return 0xC;           /* C */
    if (r_fd & 0x04) return 0xD;           /* D */
    if (r_fb & 0x04) return 0xE;           /* E */
    if (r_fd & 0x08) return 0xF;           /* F */
    return -1;
}

/* Piano-style note entry, one octave at a time. The chromatic scale from
   C to B sits across two physical key rows: white keys Z X C V B N M,
   sharps S D _ G H J (FastTracker-style). The caller adds in the current
   base octave to turn the returned semitone into a PT3 note value.
   Returns -1 if no piano key is pressed, else semitone 0..11. */
static signed char read_piano(void)
{
    unsigned char r_fe = read_row(0xFE);   /* CAPS Z X C V       */
    unsigned char r_fd = read_row(0xFD);   /* A    S D F G       */
    unsigned char r_bf = read_row(0xBF);   /* ENTER L K J H      */
    unsigned char r_7f = read_row(0x7F);   /* SPACE SYM M N B    */

    if (r_fe & 0x02) return 0;    /* Z  = C  */
    if (r_fd & 0x02) return 1;    /* S  = C# */
    if (r_fe & 0x04) return 2;    /* X  = D  */
    if (r_fd & 0x04) return 3;    /* D  = D# */
    if (r_fe & 0x08) return 4;    /* C  = E  */
    if (r_fe & 0x10) return 5;    /* V  = F  */
    if (r_fd & 0x10) return 6;    /* G  = F# */
    if (r_7f & 0x10) return 7;    /* B  = G  */
    if (r_bf & 0x10) return 8;    /* H  = G# */
    if (r_7f & 0x08) return 9;    /* N  = A  */
    if (r_bf & 0x08) return 10;   /* J  = A# */
    if (r_7f & 0x04) return 11;   /* M  = B  */
    return -1;
}

static unsigned char top_for_cursor(unsigned char cursor)
{
    if (cursor < VIEW_HEIGHT / 2) return 0;
    if (cursor + VIEW_HEIGHT / 2 >= PV_ROWS_MAX)
        return PV_ROWS_MAX - VIEW_HEIGHT;
    return cursor - VIEW_HEIGHT / 2;
}

/* The "frame": banner, status, file row, status line, column header,
   bottom hint. Drawn once when entering the screen; while editing or
   switching patterns we only re-poke the small "indicator" cells.

   Row 2 layout (32-col wide):
       0   4 6 7  9    14 16   20  22    26
       Pat XX/YY Row XX  Ch:A  Oct:4
   The XX / YY / A / 4 cells are written by draw_*_indicator below.
   (idx is unused now that the filename row is gone; kept for call-site
   symmetry with repaint_pattern_view.) */
static void draw_pattern_frame(unsigned char idx, unsigned char num_pat)
{
    (void)idx;
    cls();
    draw_banner();
    draw_status(1, "-- Pattern view --");
    at(2, 0); puts_str("Pat   /");           /* pat XX placeholder at col 4 */
              put_hex2(num_pat - 1);         /* max-pat YY at cols 7-8 */
              puts_str(" Row    Ch:  Oct: ");/* row XX, ch, oct placeholders */
    at(VIEW_TOP_ROW - 1, 0);
    puts_str("RR  ChA s   ChB s   ChC s");
    at(21, 0); puts_str("H=help full keys  S=save A=play");
}

/* Two-hex pattern number at col 4. Only changes when the user steps O/P. */
static void draw_pat_indicator(unsigned char pat)
{
    at(2, 4);
    put_hex2(pat);
}

/* Two-hex cursor row at col 14. */
static void draw_row_indicator(unsigned char cursor)
{
    at(2, 14);
    put_hex2(cursor);
}

/* Single channel letter at col 20. */
static void draw_ch_indicator(unsigned char cursor_ch)
{
    at(2, 20);
    putch('A' + cursor_ch);
}

/* Single octave digit at col 26. PT3 octaves run 1..8. */
static void draw_oct_indicator(unsigned char octave)
{
    at(2, 26);
    putch('0' + octave);
}

/* Mode indicator label at col 22 ("Oct:" in default mode, "Vol:" in volume
   edit mode). The 4 chars overwrite whatever draw_pattern_frame painted. */
static void draw_mode_label(unsigned char vol_mode)
{
    at(2, 22);
    puts_str(vol_mode ? "Vol:" : "Oct:");
}

/* Single hex digit at col 26 -- used for the volume value in vol mode.
   Octave value uses draw_oct_indicator (decimal 1..8). */
static void draw_vol_value(unsigned char vol)
{
    at(2, 26);
    put_hex1(vol);
}

/* Redraw all VIEW_HEIGHT rows of the grid against pattern_view[] starting
   at window-top `top`. The (cursor row, cursor_ch) cell is the only one
   highlighted; the rest render plain. */
static void draw_pattern_grid(unsigned char top, unsigned char cursor,
                              unsigned char cursor_ch)
{
    unsigned char i;
    for (i = 0; i < VIEW_HEIGHT; i++) {
        unsigned char prow = top + i;
        if (prow < PV_ROWS_MAX)
            draw_pattern_row(VIEW_TOP_ROW + i, prow,
                             prow == cursor, cursor_ch);
    }
}

/* Move the cursor highlight from `old_cursor` to `new_cursor`. Caller has
   already verified that the window top didn't change, so we only need to
   un-highlight the leaving row and highlight the arriving row. */
static void move_cursor_in_window(unsigned char top,
                                  unsigned char old_cursor,
                                  unsigned char new_cursor,
                                  unsigned char cursor_ch)
{
    draw_pattern_row(VIEW_TOP_ROW + (old_cursor - top), old_cursor, 0, 0);
    draw_pattern_row(VIEW_TOP_ROW + (new_cursor - top), new_cursor,
                     1, cursor_ch);
    draw_row_indicator(new_cursor);
}

/* Redraw exactly the cursor's row in place (single line, includes the
   per-cell highlight). Used after channel switch or in-place edit. */
static void redraw_cursor_row(unsigned char top, unsigned char cursor,
                              unsigned char cursor_ch)
{
    draw_pattern_row(VIEW_TOP_ROW + (cursor - top), cursor, 1, cursor_ch);
}

static unsigned char key_dismiss(void)
{
    return key_space() || key_enter() || key_Q();
}

/* ---- In-editor playback ---------------------------------------------------
   PTxPlay is already loaded; PTx_init kicks it off against the song slot,
   pt_play_60to50 advances one frame at the correct 50Hz cadence (skipping
   1 vsync in 6 because TS2068 vsync is 60Hz NTSC but PT2/PT3 tunes are
   authored for 50Hz). Both play helpers stop on any keypress and restore
   the editor's status banner before returning. */
static void play_loop_until_key(void)
{
    unsigned char divider = 0;
    while (key_any())  intrinsic_halt();   /* drain trigger key */
    while (!key_any()) {
        intrinsic_halt();
        pt_play_60to50(&divider);
    }
    PTx_mute();
    while (key_any())  intrinsic_halt();   /* drain stop key */
}

/* Play the whole song from position 0. While playing, peek PTxPlay's
   CurPos byte each frame and update the row-4 pat indicator whenever
   the song advances to a new pattern, so the user sees the playhead
   walk the position list. user_pat is the pattern the editor was on
   before play started; we restore the indicator to it on stop. */
static void play_song_full(unsigned char user_pat)
{
    const unsigned char *song = (const unsigned char *)TAPE_SONG_BASE;
    unsigned char last_displayed_pat = 0xFF;
    unsigned char divider = 0;          /* 60Hz -> 50Hz, see pt_play_60to50 */

    set_border(5);
    draw_status(1, "-- Playing song --");
    PTx_init((unsigned int)TAPE_SONG_BASE);

    while (key_any()) intrinsic_halt();      /* drain trigger key */
    while (!key_any()) {
        unsigned char cur_pos;
        intrinsic_halt();
        pt_play_60to50(&divider);

        cur_pos = *((volatile const unsigned char *)CurPos_ADDR);
        if (cur_pos < song[101]) {
            unsigned char cur_pat = song[201 + cur_pos] / 3;
            if (cur_pat != last_displayed_pat) {
                draw_pat_indicator(cur_pat);
                last_displayed_pat = cur_pat;
            }
        }
    }
    PTx_mute();
    while (key_any()) intrinsic_halt();

    draw_status(1, "-- Pattern view --");
    draw_pat_indicator(user_pat);
    set_border(7);
}

/* "Loop the current pattern" by temporarily hacking the song's position
   list to a single entry pointing at this pattern (with loop point at 0,
   so it repeats). Restore the original bytes on exit so subsequent plays
   and saves see the unmodified song. */
static void play_current_pattern(unsigned char pat)
{
    unsigned char *song = (unsigned char *)TAPE_SONG_BASE;
    unsigned char saved_npos  = song[101];
    unsigned char saved_loop  = song[102];
    unsigned char saved_p0    = song[201];
    unsigned char saved_p1    = song[202];

    song[101] = 1;                    /* numPositions = 1     */
    song[102] = 0;                    /* loopPos      = 0     */
    song[201] = (unsigned char)(pat * 3);
    song[202] = 0xFF;                 /* terminator           */

    set_border(5);
    draw_status(1, "-- Playing pattern --");
    PTx_init((unsigned int)TAPE_SONG_BASE);
    play_loop_until_key();
    draw_status(1, "-- Pattern view --");
    set_border(7);

    song[101] = saved_npos;
    song[102] = saved_loop;
    song[201] = saved_p0;
    song[202] = saved_p1;
}

/* key_A and key_L are already defined among the keyboard helpers above;
   reused here as "A = play song" / "L = loop current pattern". */

/* ---- Note preview ----------------------------------------------------------
   Direct AY poke for "did I hit the right key" feedback while editing. We do
   NOT route this through PTxPlay -- PTxPlay is muted while the user is in
   the editor, and synthesising a one-row pattern would clobber its state.
   Instead we drive the AY hardware directly: tone period to regs 0/1 (Ch A),
   mixer reg 7 to enable Ch A tone, amplitude reg 8 = 12 (a moderate level).
   The tone holds for ~3 frames (~60 ms) then we silence Ch A. That's short
   enough to feel like a key click, not a sustained note.

   PT3 note range is 0..95 covering octaves 1..8. AY tone period = clock /
   (16 * freq); on TS2068 the AY clock is ~1.7724 MHz so period for C-5
   (523.25 Hz) is ~211. The table below is octave 5; lower octaves shift
   left, higher shift right. (Octave 1 hits ~3376, still within the AY's
   12-bit period register at 4095.) Off by a cent or two from PTxPlay's
   exact note table, but plenty close for ear-confirmation. */
static const unsigned int note_periods_o5[12] = {
    211, 199, 188, 178, 168, 159, 150, 141, 133, 126, 119, 112
};

static unsigned int note_to_period(unsigned char note)
{
    unsigned char oct_idx = note / 12;          /* 0..7, 4 = octave 5 */
    unsigned char st      = note % 12;
    unsigned int  p       = note_periods_o5[st];
    if (oct_idx < 4) return p << (4 - oct_idx);
    if (oct_idx > 4) return p >> (oct_idx - 4);
    return p;
}

static void preview_note(signed char note)
{
    unsigned int period;
    unsigned char i;

    if (note < 0) return;                       /* skip rest / empty */
    period = note_to_period((unsigned char)note);

    /* Stage AY regs through the existing AY shadow buffer, then flush.
       AYREGS[] is shared with PTxPlay -- which is muted while editing,
       so writing here is safe. */
    SOUND(0, (char)(period & 0xFF));         /* tone A lo */
    SOUND(1, (char)((period >> 8) & 0x0F));  /* tone A hi (4 bits) */
    SOUND(7, 0x3E);    /* mixer: A tone on, B/C off, all noise off */
    SOUND(8, 12);      /* Ch A amplitude (no envelope) */
    PlayAY();

    for (i = 0; i < 3; i++) intrinsic_halt(); /* hold ~60 ms at 50Hz */

    SOUND(8, 0);       /* silence Ch A */
    PlayAY();
}

/* ---- Whole-song rebuild (PT3 byte stream from the model) ------------------
   Regenerate the pattern table + all pattern data at TAPE_SONG_BASE from the
   decoded model, overwriting in place starting at base_pat_off (the song's
   original pattern-table offset). Everything below base_pat_off -- header,
   sample/ornament pointer tables, position list, and the sample/ornament
   DEFINITION blocks -- is preserved untouched, so instruments survive. The
   empty-song template and standard PT3 files both place the pattern table +
   pattern data last, after the instrument definitions, which is what makes
   the in-place overwrite safe. song_size is reset to the new tail each call,
   so repeated rebuilds never accumulate dead bytes. Called before play and
   before save. Returns 1 on success, 0 if the rebuilt song would exceed
   SONG_BUDGET or a channel can't be encoded. */
static unsigned char rebuild_song(void)
{
    unsigned char *song  = (unsigned char *)TAPE_SONG_BASE;
    unsigned int   table = base_pat_off;
    unsigned int   data  = base_pat_off + (unsigned int)num_pat_total * 6;
    cell_t        *saved = pattern_view;
    unsigned char  p, ch;

    for (p = 0; p < num_pat_total; p++) {
        pattern_view = MODEL(p);                 /* encode_channel reads this */
        for (ch = 0; ch < 3; ch++) {
            unsigned int n;
            if (data >= SONG_BUDGET) { pattern_view = saved; return 0; }
            n = encode_channel(ch, song + data, SONG_BUDGET - data);
            if (n == 0xFFFFu)        { pattern_view = saved; return 0; }
            song[table + (unsigned int)p * 6 + ch * 2 + 0] = (unsigned char)(data & 0xFF);
            song[table + (unsigned int)p * 6 + ch * 2 + 1] = (unsigned char)(data >> 8);
            data += n;
        }
    }
    pattern_view = saved;

    song[103] = (unsigned char)(base_pat_off & 0xFF);   /* pattern table ptr */
    song[104] = (unsigned char)(base_pat_off >> 8);
    song_size       = data;
    song_bytes_used = data;
    return 1;
}

/* Decode every pattern referenced by the position list into the model, then
   normalise the slot (rebuild) so song_size is accurate. Called once per song
   load. Caller gates on PT3 (no PT2 decoder exists). */
static void decode_all_patterns(void)
{
    const unsigned char *song = (const unsigned char *)TAPE_SONG_BASE;
    unsigned char num_pos = song[101];
    unsigned char np = 0, i, p;

    for (i = 0; i < num_pos; i++) {
        unsigned char pp = song[201 + i] / 3;
        if (pp > np) np = pp;
    }
    np++;
    if (np > MAX_PATTERNS) np = MAX_PATTERNS;       /* clamp: extra patterns dropped */

    for (p = 0; p < np; p++) {
        pattern_view = MODEL(p);
        decode_pattern(p);                          /* fills global pattern_view */
    }
    num_pat_total = np;
    base_pat_off  = song[103] | ((unsigned int)song[104] << 8);
    pattern_view  = MODEL(0);

    rebuild_song();                                 /* sync slot + song_size */
}

/* ---- Phase 3: tape SA-BYTES ----------------------------------------------
   Writes the song slot at TAPE_SONG_BASE to a fresh CODE block on tape.
   Filename is whatever's currently in `save_name` (8 chars, space-padded)
   plus a 2-hex-digit version suffix that auto-increments per save in the
   current session, giving a 10-char tape filename like "MYTUNE   01".
   Tap files are append-only, so each save just lays down another block;
   the user picks up the latest one on next load by name. */
static unsigned char save_version = 1;
static char save_name[9] = { 0 };   /* 8 chars + null; filled lazily */

/* Map of typeable Sinclair keys per row. Index = row; sub-index = bit
   position (0..4). NUL means "no character / modifier" (e.g. CAPS-SHIFT,
   ENTER, SYM-SHIFT). */
static const unsigned char text_key_rows[8] = {
    0xFE, 0xFD, 0xFB, 0xF7, 0xEF, 0xDF, 0xBF, 0x7F
};
static const char text_key_chars[8][5] = {
    {  0 , 'Z', 'X', 'C', 'V' },     /* CAPS Z X C V        */
    { 'A', 'S', 'D', 'F', 'G' },
    { 'Q', 'W', 'E', 'R', 'T' },
    { '1', '2', '3', '4', '5' },
    { '0', '9', '8', '7', '6' },
    { 'P', 'O', 'I', 'U', 'Y' },
    {  0 , 'L', 'K', 'J', 'H' },     /* ENTER L K J H       */
    { ' ',  0 , 'M', 'N', 'B' },     /* SPACE SYM M N B     */
};

/* Returns the ASCII char of a typeable key currently held, or -1 if
   none. Skips when CAPS-SHIFT is held so chord keys (DELETE, BREAK,
   cursor arrows) don't leak through as character input. */
static signed char read_text_key(void)
{
    unsigned char i, j, r;
    if (caps()) return -1;
    for (i = 0; i < 8; i++) {
        r = read_row(text_key_rows[i]);
        for (j = 0; j < 5; j++) {
            if ((r & (1 << j)) && text_key_chars[i][j]) {
                return (signed char)text_key_chars[i][j];
            }
        }
    }
    return -1;
}

/* DELETE = CAPS + 0 (Sinclair convention). */
static unsigned char key_delete(void)
{
    return caps() && (read_row(0xEF) & 0x01);
}

/* Modal filename prompt for tape save. Pre-fills save_name from the
   loaded song's directory entry on first call (so first save defaults
   to the loaded name) and remembers user edits across saves in the
   same session. Letter / digit / space keys overwrite the cell at the
   cursor and advance; CAPS+0 (DELETE) backspaces. ENTER commits, Q
   cancels. Returns 1 on commit, 0 on cancel. */
static unsigned char prompt_save_filename(unsigned char idx)
{
    unsigned char pos = 0;
    unsigned char i;

    /* Lazy init: copy directory[idx].name into save_name, space-padded. */
    if (save_name[0] == 0) {
        const char *src = directory[idx].name;
        unsigned char past_null = 0;
        for (i = 0; i < 8; i++) {
            if (past_null || src[i] == 0) { past_null = 1; save_name[i] = ' '; }
            else                            { save_name[i] = src[i]; }
        }
        save_name[8] = 0;
    }

    /* Cursor starts at the first trailing-space, capped at 7 (last cell). */
    pos = 8;
    while (pos > 0 && save_name[pos - 1] == ' ') pos--;
    if (pos > 7) pos = 7;

    cls();
    draw_banner();
    draw_status(1, "-- Save to tape --");

    at(4, 0); puts_str("Filename (max 8 chars).");
    at(5, 0); puts_str("Letters / digits / space.");

    /* Filename cells at row 8 col 4..11; version suffix at col 13..14. */
    at(8, 4);
    for (i = 0; i < 8; i++) {
        if (i == pos) set_inverse(1);
        putch((unsigned char)save_name[i]);
        if (i == pos) set_inverse(0);
    }
    putch(' ');
    {
        unsigned char hi = save_version >> 4;
        unsigned char lo = save_version & 0x0F;
        putch(hi < 10 ? '0' + hi : 'A' + hi - 10);
        putch(lo < 10 ? '0' + lo : 'A' + lo - 10);
    }

    at(11, 0); puts_str("Bytes: ");
    put_dec5_right(song_size);

    at(13, 0); puts_str("Make sure tape is ready");
    at(14, 0); puts_str("to record before ENTER.");

    at(20, 0); puts_str("DEL=erase  ENTER=save");
    at(21, 0); puts_str("Q (or CAPS+SPACE)=cancel");

    while (key_any()) intrinsic_halt();

    for (;;) {
        signed char c;
        intrinsic_halt();

        if (key_break() || key_Q()) {
            while (key_break() || key_Q()) intrinsic_halt();
            return 0;
        }
        if (key_enter()) {
            while (key_enter()) intrinsic_halt();
            return 1;
        }
        if (key_delete()) {
            while (key_delete()) intrinsic_halt();
            /* Backspace: clear current cell if non-space, else step back. */
            if (save_name[pos] != ' ') {
                save_name[pos] = ' ';
            } else if (pos > 0) {
                pos--;
                save_name[pos] = ' ';
            }
            at(8, 4 + pos);
            set_inverse(1); putch(' '); set_inverse(0);
            if (pos < 7) {
                at(8, 4 + pos + 1);
                putch((unsigned char)save_name[pos + 1]);
            }
            continue;
        }
        c = read_text_key();
        if (c >= 0) {
            while (read_text_key() >= 0) intrinsic_halt();
            save_name[pos] = c;
            at(8, 4 + pos);
            putch((unsigned char)c);
            if (pos < 7) {
                pos++;
                at(8, 4 + pos);
                set_inverse(1); putch((unsigned char)save_name[pos]); set_inverse(0);
            }
        }
    }
}

static void put_hex_digit(unsigned char *dst, unsigned char nyb)
{
    nyb &= 0x0F;
    *dst = (unsigned char)(nyb < 10 ? '0' + nyb : 'A' + nyb - 10);
}

/* Build a 17-byte tape header for the current song slot. Caller supplies
   `name` (the loaded directory entry's null-terminated name, max 8 useful
   chars). The version suffix is appended to fill the 10-byte filename. */
static void build_save_header(unsigned char *hdr, const char *name)
{
    unsigned char i;
    unsigned char past_null = 0;

    hdr[0] = 3;                         /* type 3 = CODE */
    for (i = 0; i < 8; i++) {
        if (past_null || name[i] == 0) {
            past_null = 1;
            hdr[1 + i] = ' ';
        } else {
            hdr[1 + i] = (unsigned char)name[i];
        }
    }
    put_hex_digit(&hdr[9],  save_version >> 4);
    put_hex_digit(&hdr[10], save_version & 0x0F);

    hdr[11] = (unsigned char)(song_size & 0xFF);
    hdr[12] = (unsigned char)(song_size >> 8);
    hdr[13] = (unsigned char)(TAPE_SONG_BASE & 0xFF);
    hdr[14] = (unsigned char)(TAPE_SONG_BASE >> 8);
    hdr[15] = 0x00;                     /* param 2: unused for CODE */
    hdr[16] = 0x80;
}

/* Reuses the global tape_header buffer as the 17-byte header staging area.
   Builds the header from the current `save_name` (set by the prompt) and
   writes header + data to tape. Returns 1 on full success, 0 on tape
   error or break. Bumps save_version on success so the next save lands
   a fresh block. */
static unsigned char save_song_to_tape(void)
{
    build_save_header(tape_header, save_name);

    tape_arg_flag = 0x00;
    tape_arg_dest = (unsigned int)tape_header;
    tape_arg_len  = 17;
    if (!tape_write_block()) return 0;

    tape_arg_flag = 0xFF;
    tape_arg_dest = TAPE_SONG_BASE;
    tape_arg_len  = song_size;
    if (!tape_write_block()) return 0;

    save_version++;
    return 1;
}

static void show_tape_save_result(unsigned char ok)
{
    cls();
    draw_banner();
    if (ok) {
        unsigned char i;
        draw_status(1, "-- Tape save OK --");
        at(4, 0); puts_str("Wrote ");
        put_dec5_right(song_size);
        puts_str(" bytes as");
        at(5, 4);
        for (i = 0; i < 8; i++) putch((unsigned char)save_name[i]);
        putch(' ');
        {
            /* save_version was already bumped; subtract 1 to display the
               version we just wrote. */
            unsigned char prev = save_version - 1;
            unsigned char hi = prev >> 4;
            unsigned char lo = prev & 0x0F;
            putch(hi < 10 ? '0' + hi : 'A' + hi - 10);
            putch(lo < 10 ? '0' + lo : 'A' + lo - 10);
        }
        at(7, 0); puts_str("Future saves use the next");
        at(8, 0); puts_str("version suffix automatically.");
    } else {
        draw_status(1, "-- Tape save failed --");
        at(4, 0); puts_str("SA-BYTES returned an error.");
        at(6, 0); puts_str("Possible causes:");
        at(7, 0); puts_str(" - tape not in record mode");
        at(8, 0); puts_str(" - BREAK pressed mid-write");
        at(9, 0); puts_str(" - emulator tape full");
    }
    at(20, 0); puts_str("Press any key to return.");
}

/* Shown when rebuild_song fails: the regenerated PT3 stream no longer fits
   the tape song slot. The only practical cause now that empty-row-0 is
   handled is sheer size. */
static void show_rebuild_error(void)
{
    cls();
    draw_banner();
    draw_status(1, "-- Song too big --");
    at(4, 0); puts_str("The song no longer fits the");
    at(5, 0); puts_str("tape slot (max ");
    put_dec5_right(SONG_BUDGET);
    puts_str(" bytes).");
    at(7, 0); puts_str("Remove some notes or");
    at(8, 0); puts_str("patterns and try again.");
    at(20, 0); puts_str("Press any key to return.");
}

/* After any modal screen (test result, save result), the editor's full-
   screen content is gone. Repaint everything via the same sequence used
   on initial entry to show_pattern. */
static void repaint_pattern_view(unsigned char idx,    unsigned char pat,
                                 unsigned char num_pat, unsigned char top,
                                 unsigned char cursor,  unsigned char cursor_ch,
                                 unsigned char octave)
{
    draw_pattern_frame(idx, num_pat);
    draw_pat_indicator(pat);
    draw_pattern_grid(top, cursor, cursor_ch);
    draw_row_indicator(cursor);
    draw_ch_indicator(cursor_ch);
    draw_oct_indicator(octave);
    draw_free_mem();
}

/* Modal "jump to pattern" hex prompt. Replaces the "Pat XX" cells on row 4
   with an inverse "??" that fills in as the user types two hex digits.
   Returns the entered value (0..255), or 0xFFFF on cancel. ENTER after a
   single digit accepts that as the low nibble (so "5" + ENTER = pattern 5).
   While the prompt is open, normal piano-key bindings are inactive -- the
   keys A..F instead enter their hex-digit value. */
static unsigned int prompt_jump_pattern(void)
{
    unsigned char nibble = 0;
    unsigned char count = 0;

    at(2, 4);
    set_inverse(1);
    putch('?'); putch('?');
    set_inverse(0);

    while (read_hex_key() >= 0 || key_F() || key_Q() || key_enter())
        intrinsic_halt();

    for (;;) {
        signed char h;
        intrinsic_halt();

        if (key_Q() || key_break()) {
            while (key_Q() || key_break()) intrinsic_halt();
            return 0xFFFFu;
        }
        if (count > 0 && key_enter()) {
            while (key_enter()) intrinsic_halt();
            return (unsigned int)nibble;
        }

        h = read_hex_key();
        if (h < 0) continue;

        if (count == 0) {
            nibble = (unsigned char)h;
            at(2, 4);
            set_inverse(1);
            putch(h < 10 ? '0' + h : 'A' + h - 10);
            putch('?');
            set_inverse(0);
            count = 1;
            while (read_hex_key() >= 0) intrinsic_halt();
        } else {
            unsigned char target = (nibble << 4) | (unsigned char)h;
            while (read_hex_key() >= 0) intrinsic_halt();
            return (unsigned int)target;
        }
    }
}

/* Restore the bottom rows (Free line + hint) after a confirm modal stomps
   them. The hint string is space-padded to 32 chars so it fully overwrites
   whatever was there before -- no separate clear pass needed. */
static void draw_pattern_hints(void)
{
    draw_free_mem();                                       /* row 20 */
    at(21, 0); puts_str("H=help full keys  S=save A=play");
}

/* Modal Y/N input loop for destructive ops. Caller has already painted a
   prompt on rows 20-21. Returns 1 on Y, 0 on N / Q / BREAK; restores the
   pattern-view key-hint footer before returning so the caller's redraw
   only needs to repaint whatever ELSE the prompt stomped (typically just
   the cursor row, which the caller redraws anyway). */
static unsigned char confirm_yn(void)
{
    unsigned char result;

    while (key_Y() || key_N() || key_Q() || key_break())
        intrinsic_halt();

    for (;;) {
        intrinsic_halt();
        if (key_Y()) {
            while (key_Y()) intrinsic_halt();
            result = 1;
            break;
        }
        if (key_N() || key_Q() || key_break()) {
            while (key_N() || key_Q() || key_break()) intrinsic_halt();
            result = 0;
            break;
        }
    }

    draw_pattern_hints();
    return result;
}

/* Full-screen reference card for every key binding the pattern view honours.
   Reached via H. Replaces the pattern view; we cls() and have the caller
   repaint afterwards, the same way the help modal does in the directory. */
static void show_help_page(void)
{
    cls();
    draw_banner();
    draw_status(1, "-- Help --");

    at(3,  0);  puts_str("Move:");
    at(4,  2);  puts_str("Arrows / 5 6 7 8");
    at(5,  2);  puts_str("R=top  O/P=prev/next pat");
    at(6,  2);  puts_str("F = jump to pattern XX");

    at(8,  0);  puts_str("Edit (note mode):");
    at(9,  2);  puts_str("Z..M = piano note");
    at(10, 2);  puts_str("1..8 = octave / retune");
    at(11, 2);  puts_str("ENTER=rest  SPACE=clear");
    at(12, 2);  puts_str("I=insert row  CAPS+0=del");
    at(13, 2);  puts_str("9 = clear channel column");

    at(15, 0);  puts_str("Edit (volume mode):");
    at(16, 2);  puts_str("U toggles vol mode");
    at(17, 2);  puts_str("0..F = set cell volume");

    at(18, 0);  puts_str("Save / play:");
    at(19, 2);  puts_str("S=save tape (auto-rebuild)");
    at(20, 2);  puts_str("A=play song  L=loop pat");

    at(21, 0); puts_str("  Edits auto-save. Any key=back.");

    while (key_any()) intrinsic_halt();
    while (!key_any()) intrinsic_halt();
    while (key_any()) intrinsic_halt();
}

static void show_pattern(unsigned char idx)
{
    unsigned char num_pat = num_pat_total;
    unsigned char pat = 0;
    unsigned char cursor = 0;
    unsigned char cursor_ch = 0;
    unsigned char octave = 4;            /* 1..8; PT3 note = (oct-1)*12+semi */
    unsigned char vol_mode = 0;          /* 0 = oct mode, 1 = volume edit mode */
    unsigned char top;
    unsigned char d;
    signed char   semi;

    /* PT2 has no decoder, so the model holds nothing meaningful -- don't
       pretend to edit it. show_song_info already flagged PT2 as view-only. */
    if (directory[idx].fmt != 0) {
        draw_status(1, "-- PT2: not editable --");
        while (!key_Q() && !key_break()) intrinsic_halt();
        while (key_Q() || key_break()) intrinsic_halt();
        return;
    }

    /* The whole song is already decoded in the model (decode_all_patterns at
       load); editing reads/writes model[pat] via this alias. No per-pattern
       decode, and switching patterns never loses edits. */
    pattern_view = MODEL(pat);
    song_bytes_used = song_size;         /* set accurately by load-time rebuild */
    top = top_for_cursor(cursor);
    draw_pattern_frame(idx, num_pat);
    draw_pat_indicator(pat);
    draw_pattern_grid(top, cursor, cursor_ch);
    draw_row_indicator(cursor);
    draw_ch_indicator(cursor_ch);
    draw_oct_indicator(octave);
    draw_free_mem();

    while (nav_up() || nav_down() || nav_left() || nav_right()
        || key_O() || key_P() || key_Q() || key_enter() || key_R()
        || key_H() || key_U() || key_I() || key_delete())
        intrinsic_halt();

    for (;;) {
        intrinsic_halt();
        if (key_Q() || key_break()) return;

        if (nav_down() && cursor + 1 < PV_ROWS_MAX) {
            unsigned char new_cursor = cursor + 1;
            unsigned char new_top    = top_for_cursor(new_cursor);
            if (new_top == top) {
                move_cursor_in_window(top, cursor, new_cursor, cursor_ch);
            } else {
                top = new_top;
                draw_pattern_grid(top, new_cursor, cursor_ch);
                draw_row_indicator(new_cursor);
            }
            cursor = new_cursor;
            if (vol_mode) draw_vol_value(
                pattern_view[(unsigned int)cursor * 3 + cursor_ch].volume);
            while (nav_down()) intrinsic_halt();
        }
        else if (nav_up() && cursor > 0) {
            unsigned char new_cursor = cursor - 1;
            unsigned char new_top    = top_for_cursor(new_cursor);
            if (new_top == top) {
                move_cursor_in_window(top, cursor, new_cursor, cursor_ch);
            } else {
                top = new_top;
                draw_pattern_grid(top, new_cursor, cursor_ch);
                draw_row_indicator(new_cursor);
            }
            cursor = new_cursor;
            if (vol_mode) draw_vol_value(
                pattern_view[(unsigned int)cursor * 3 + cursor_ch].volume);
            while (nav_up()) intrinsic_halt();
        }
        else if (nav_right() && cursor_ch + 1 < 3) {
            cursor_ch++;
            redraw_cursor_row(top, cursor, cursor_ch);
            draw_ch_indicator(cursor_ch);
            if (vol_mode) draw_vol_value(
                pattern_view[(unsigned int)cursor * 3 + cursor_ch].volume);
            while (nav_right()) intrinsic_halt();
        }
        else if (nav_left() && cursor_ch > 0) {
            cursor_ch--;
            redraw_cursor_row(top, cursor, cursor_ch);
            draw_ch_indicator(cursor_ch);
            if (vol_mode) draw_vol_value(
                pattern_view[(unsigned int)cursor * 3 + cursor_ch].volume);
            while (nav_left()) intrinsic_halt();
        }
        else if (key_U()) {
            /* U = toggle between octave (default) and volume edit modes.
               In vol mode, hex digits 0..F set the cursor cell's volume.
               The mode indicator label at col 22 swaps "Oct:"/"Vol:" and
               the value at col 26 reflects the active mode's value. */
            cell_t *c;
            while (key_U()) intrinsic_halt();
            vol_mode = !vol_mode;
            draw_mode_label(vol_mode);
            c = &pattern_view[(unsigned int)cursor * 3 + cursor_ch];
            if (vol_mode) draw_vol_value(c->volume);
            else          draw_oct_indicator(octave);
        }
        else if (key_I()) {
            /* I = insert empty row at cursor (rows below shift down; the
               last row of the pattern is lost). All 3 channels move
               together. */
            while (key_I()) intrinsic_halt();
            insert_row(cursor);
            draw_pattern_grid(top, cursor, cursor_ch);
            draw_row_indicator(cursor);
            if (vol_mode) draw_vol_value(
                pattern_view[(unsigned int)cursor * 3 + cursor_ch].volume);
        }
        else if (key_delete()) {
            /* CAPS+0 (DELETE) = remove the row at cursor; rows below
               shift up; the last row becomes empty. */
            while (key_delete()) intrinsic_halt();
            delete_row(cursor);
            draw_pattern_grid(top, cursor, cursor_ch);
            draw_row_indicator(cursor);
            if (vol_mode) draw_vol_value(
                pattern_view[(unsigned int)cursor * 3 + cursor_ch].volume);
        }
        else if (vol_mode) {
            /* Volume edit mode: every hex digit 0..F (including the letter
               keys A..F that overlap piano notes) goes to the cursor cell's
               volume, then this branch swallows the iteration so the
               command-letter handlers below don't fire. Press U again to
               leave vol mode and get those letters back. */
            signed char h = read_hex_key();
            if (h >= 0) {
                cell_t *c = &pattern_view[(unsigned int)cursor * 3 + cursor_ch];
                c->volume = (unsigned char)h;
                draw_vol_value(c->volume);
                while (read_hex_key() >= 0) intrinsic_halt();
            }
        }
        else if (key_F()) {
            unsigned int target;
            while (key_F()) intrinsic_halt();
            target = prompt_jump_pattern();
            if (target != 0xFFFFu && (unsigned char)target < num_pat) {
                pat = (unsigned char)target;
                cursor = 0;
                pattern_view = MODEL(pat);   /* instant, lossless switch */
                top = top_for_cursor(cursor);
                draw_pat_indicator(pat);
                draw_pattern_grid(top, cursor, cursor_ch);
                draw_row_indicator(cursor);
                draw_free_mem();
            } else {
                /* Cancel or out-of-range: redraw the current pat number so
                   the inverse "??" placeholder doesn't linger on row 4. */
                draw_pat_indicator(pat);
            }
        }
        else if (key_A()) {
            /* A = play whole song. Regenerate the PT3 stream from the model
               first so playback reflects every edit (no manual commit). */
            while (key_A()) intrinsic_halt();
            if (rebuild_song()) {
                play_song_full(pat);
            } else {
                show_rebuild_error();
                while (key_dismiss())  intrinsic_halt();
                while (!key_dismiss()) intrinsic_halt();
                while (key_dismiss())  intrinsic_halt();
                repaint_pattern_view(idx, pat, num_pat, top, cursor, cursor_ch, octave);
            }
        }
        else if (key_L()) {
            while (key_L()) intrinsic_halt();
            if (rebuild_song()) {
                play_current_pattern(pat);
            } else {
                show_rebuild_error();
                while (key_dismiss())  intrinsic_halt();
                while (!key_dismiss()) intrinsic_halt();
                while (key_dismiss())  intrinsic_halt();
                repaint_pattern_view(idx, pat, num_pat, top, cursor, cursor_ch, octave);
            }
        }
        else if (key_S()) {
            /* S = regenerate the PT3 stream from the model, then write it to
               tape as a fresh CODE block (SA-BYTES). Prompts for a filename;
               Q cancels. */
            while (key_S()) intrinsic_halt();
            if (!rebuild_song()) {
                show_rebuild_error();
                while (key_dismiss())  intrinsic_halt();
                while (!key_dismiss()) intrinsic_halt();
                while (key_dismiss())  intrinsic_halt();
            } else if (prompt_save_filename(idx)) {
                unsigned char ok;
                set_border(2);                  /* red: writing to tape */
                ok = save_song_to_tape();
                set_border(5);                  /* cyan: done, awaiting key */
                show_tape_save_result(ok);
                while (key_dismiss())  intrinsic_halt();
                while (!key_dismiss()) intrinsic_halt();
                while (key_dismiss())  intrinsic_halt();
                set_border(7);
            }
            repaint_pattern_view(idx, pat, num_pat, top, cursor, cursor_ch, octave);
        }
        else if (key_P() && pat + 1 < num_pat) {
            pat++; cursor = 0;
            pattern_view = MODEL(pat);   /* instant, lossless switch */
            top = top_for_cursor(cursor);
            draw_pat_indicator(pat);
            draw_pattern_grid(top, cursor, cursor_ch);
            draw_row_indicator(cursor);
            draw_free_mem();
            while (key_P()) intrinsic_halt();
        }
        else if (key_O() && pat > 0) {
            pat--; cursor = 0;
            pattern_view = MODEL(pat);
            top = top_for_cursor(cursor);
            draw_pat_indicator(pat);
            draw_pattern_grid(top, cursor, cursor_ch);
            draw_row_indicator(cursor);
            draw_free_mem();
            while (key_O()) intrinsic_halt();
        }
        else if (key_R()) {
            /* R = jump cursor back to row 0. Reuses the windowed-redraw
               path: if row 0 is already visible, just move the highlight;
               otherwise scroll the window and repaint. */
            while (key_R()) intrinsic_halt();
            if (cursor != 0) {
                unsigned char new_top = top_for_cursor(0);
                if (new_top == top) {
                    move_cursor_in_window(top, cursor, 0, cursor_ch);
                } else {
                    top = new_top;
                    draw_pattern_grid(top, 0, cursor_ch);
                    draw_row_indicator(0);
                }
                cursor = 0;
            }
        }
        else if (key_H()) {
            while (key_H()) intrinsic_halt();
            show_help_page();
            repaint_pattern_view(idx, pat, num_pat, top, cursor, cursor_ch, octave);
        }
        else if (key_enter()) {
            /* ENTER = rest event at cursor (note=-2, renders -=-, encodes
               to PT3 RELEASE 0xC0). Treats an existing -1 cell as a fresh
               insert (+2 bytes); converting a real note into a rest is
               byte-cost-neutral so we don't bump song_bytes_used there. */
            cell_t *cell = &pattern_view[(unsigned int)cursor * 3 + cursor_ch];
            while (key_enter()) intrinsic_halt();
            if (cell->note != -2) {
                if (cell->note == -1) song_bytes_used += 2;
                cell->note = -2;
                redraw_cursor_row(top, cursor, cursor_ch);
                draw_free_mem();
            }
        }
        else if (key_digit() == 9) {
            /* 9 = clear the entire cursor_ch column (every row). Modal
               confirm because it can wipe a lot of work. A fully cleared
               channel encodes to a single FIN on the next rebuild. */
            while (key_digit() == 9) intrinsic_halt();
            at(20, 0);
            set_inverse(1);
            puts_str(" Clear channel ");
            putch('A' + cursor_ch);
            puts_str(" -- all rows?  ");
            set_inverse(0);
            at(21, 0);
            puts_str("  Y = yes,  N or Q = no         ");
            if (confirm_yn()) {
                unsigned char r;
                for (r = 0; r < PV_ROWS_MAX; r++) {
                    cell_t *cell = &pattern_view[(unsigned int)r * 3 + cursor_ch];
                    cell->note   = -1;
                    cell->sample = 0;
                    cell->volume = 0;
                }
                /* song_bytes_used drifts pessimistically: we don't know
                   how many notes we just removed without re-walking, so
                   leave the estimate alone. The next commit (W) snaps it
                   back to the true song_size. */
                draw_pattern_grid(top, cursor, cursor_ch);
                draw_row_indicator(cursor);
            }
        }
        else if (key_space()) {
            /* Clear the note at (cursor, cursor_ch). Writes straight to the
               model, so it persists across pattern switches. */
            cell_t *cell = &pattern_view[(unsigned int)cursor * 3 + cursor_ch];
            if (cell->note != -1) {
                cell->note = -1;
                if (song_bytes_used >= 2) song_bytes_used -= 2;
                redraw_cursor_row(top, cursor, cursor_ch);
                draw_free_mem();
            }
            while (key_space()) intrinsic_halt();
        }
        else if ((d = key_digit()) >= 1 && d <= 8) {
            cell_t *cell = &pattern_view[(unsigned int)cursor * 3 + cursor_ch];
            octave = d;
            /* If a note already sits at the cursor, retune it to the new
               octave (semitone unchanged). Same byte cost, no edit-delta.
               Preview the retuned pitch so the user gets ear-confirmation. */
            if (cell->note >= 0) {
                unsigned char semitone = (unsigned char)cell->note % 12;
                cell->note = (signed char)((octave - 1) * 12 + semitone);
                redraw_cursor_row(top, cursor, cursor_ch);
                preview_note(cell->note);
            }
            draw_oct_indicator(octave);
            while (key_digit()) intrinsic_halt();
        }
        else if ((semi = read_piano()) >= 0) {
            cell_t *cell = &pattern_view[(unsigned int)cursor * 3 + cursor_ch];
            if (cell->note < 0) song_bytes_used += 2;     /* fresh insert */
            cell->note = (signed char)((octave - 1) * 12 + semi);
            redraw_cursor_row(top, cursor, cursor_ch);
            draw_free_mem();
            preview_note(cell->note);                     /* ear feedback */
            while (read_piano() >= 0) intrinsic_halt();
        }
    }
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
                show_pattern(idx);
                break;
            }
        }
    }
}

/* ---- main ------------------------------------------------------------------ */

void main(void)
{
    unsigned char d;
    /* scan_tape leaves the screen already in directory format; on those
       transitions we want to enter the keyboard loop without another cls. */
    unsigned char dir_already_drawn = 0;

    intrinsic_ei();
    AY_Init();
    PTx_mute();
    set_border(7);

    show_splash();

    for (;;) {
        if (dir_count == 0) {
            show_scan_prompt();
            while (key_space() || key_S() || key_enter() || key_Q() || key_N())
                intrinsic_halt();
            for (;;) {
                intrinsic_halt();
                if (key_enter() || key_Q()) goto quit;
                if (key_space() || key_S()) {
                    while (key_space() || key_S()) intrinsic_halt();
                    scan_tape();
                    dir_already_drawn = 1;
                    break;
                }
                if (key_N()) {
                    while (key_N()) intrinsic_halt();
                    start_new_song();
                    edit_song(0);
                    /* After the user exits edit mode, drop back to the
                       scan prompt -- our synthetic "NEW SONG" entry can't
                       be re-loaded from tape, and presenting it in the
                       directory would confuse the load path. */
                    dir_count = 0;
                    break;
                }
            }
        } else {
            if (!dir_already_drawn) show_directory();
            dir_already_drawn = 0;
            while (key_digit() || key_enter() || key_R() || key_Q())
                intrinsic_halt();
            for (;;) {
                intrinsic_halt();
                if (key_enter() || key_Q()) goto quit;
                if (key_R()) {
                    while (key_R()) intrinsic_halt();
                    scan_tape();
                    dir_already_drawn = 1;
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
