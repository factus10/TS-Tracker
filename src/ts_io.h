/* =============================================================================
   ts_io.h -- shared screen + keyboard primitives for both apps.

   The player (pt3_player.c) and the tracker (tracker.c) carried byte-identical
   copies of these low-level helpers. They now live here so the two stay in
   sync. App-specific code (cls, draw_banner/status, the per-app command keys)
   stays in each app -- those genuinely differ.
============================================================================= */
#ifndef TS_IO_H
#define TS_IO_H

/* Screen output (ROM RST $10 control codes). */
void putch(unsigned char c) __z88dk_fastcall;     /* print one char */
void puts_str(const char *s);                     /* print a NUL-terminated string */
void puts_str_n(const char *s, unsigned char n);  /* ...at most n chars */
void at(unsigned char row, unsigned char col);     /* AT control code */
void set_attr(unsigned char ink, unsigned char paper, unsigned char bright);
void set_inverse(unsigned char on);
void set_border(unsigned char c) __z88dk_fastcall;

/* Keyboard. read_row returns the pressed bits (active-high) of a Sinclair
   half-row selected by `rowsel` (e.g. 0x7F = SPACE/SYM/M/N/B). */
unsigned char read_row(unsigned char rowsel) __z88dk_fastcall;
unsigned char key_space(void);
unsigned char key_enter(void);
unsigned char key_break(void);   /* CAPS-SHIFT + SPACE */
unsigned char key_digit(void);   /* 1..9 pressed, else 0 */
unsigned char key_any(void);     /* any key down? */

#endif /* TS_IO_H */
