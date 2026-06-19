/* =============================================================================
   ts_io.c -- shared screen + keyboard primitives (see ts_io.h).
============================================================================= */
#include "ts_io.h"

/* ---- ROM character output (RST $10 = PRINT-A, identical on ZX48/TS2068) ---- */

void putch(unsigned char c) __naked __z88dk_fastcall
{
    (void)c;
__asm
    ld   a,l
    rst  #0x10
    ret
__endasm;
}

void puts_str(const char *s)
{
    while (*s) putch((unsigned char)*s++);
}

void puts_str_n(const char *s, unsigned char n)
{
    while (*s && n--) putch((unsigned char)*s++);
}

void at(unsigned char row, unsigned char col)
{
    putch(0x16);
    putch(row);
    putch(col);
}

void set_attr(unsigned char ink, unsigned char paper, unsigned char bright)
{
    putch(0x10); putch(ink);
    putch(0x11); putch(paper);
    putch(0x13); putch(bright);
}

void set_inverse(unsigned char on)
{
    putch(0x14); putch(on);
}

/* Set the TS2068 border colour (bits 0-2 of port $FE). */
void set_border(unsigned char c) __naked __z88dk_fastcall
{
    (void)c;
__asm
    ld   a,l
    and  #0x07
    out  (#0xFE),a
    ret
__endasm;
}

/* ---- keyboard polling ------------------------------------------------------- */

unsigned char read_row(unsigned char rowsel) __naked __z88dk_fastcall
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

unsigned char key_space(void) { return read_row(0x7F) & 0x01; }
unsigned char key_enter(void) { return read_row(0xBF) & 0x01; }

/* TS2068 BREAK = CAPS-SHIFT (row $FE bit 0) + SPACE (row $7F bit 0). */
unsigned char key_break(void)
{
    return (read_row(0xFE) & 0x01) && (read_row(0x7F) & 0x01);
}

/* Sinclair digit rows: $F7 = 1 2 3 4 5, $EF = 0 9 8 7 6. */
unsigned char key_digit(void)
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

unsigned char key_any(void)
{
    return read_row(0xFE) || read_row(0xFD) || read_row(0xFB) || read_row(0xF7)
        || read_row(0xEF) || read_row(0xDF) || read_row(0xBF) || read_row(0x7F);
}

