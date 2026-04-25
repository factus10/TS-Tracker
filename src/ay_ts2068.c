/* =============================================================================
   ay_ts2068.c -- AY-3-8912 buffer library for the Timex/Sinclair 2068

   Port of mvac7's SDCC_AY38910BF_Lib. The PT3 player drops in unchanged
   on top of this file. Only the I/O port constants change versus the
   MSX original; the joystick-direction-preserving handshake on register 7
   works the same on the TS2068 (STICK reads through AY register 14).

   TS2068 ports (per ts2068_memory_map.md):
       $F5  W   AY register select
       $F6  W   AY data write
       $F6  R   AY data read (also joystick via reg 14)
============================================================================= */
#include "ay_ts2068.h"

#define AY_PORT_INDEX 0xF5
#define AY_PORT_WRITE 0xF6
#define AY_PORT_READ  0xF6

char AY_TYPE;          /* always 0 on TS2068 */
char AYREGS[14];


void AY_Init(void) __naked
{
__asm
    xor  a
    ld   (#_AY_TYPE),a

    ld   hl,#_AYREGS
    ld   de,#_AYREGS+1
    ld   bc,#13
    ld   (hl),a
    ldir

    dec  a            ; a = 0xFF -> envelope shape "no retrigger"
    ld   (hl),a
    ret
__endasm;
}


void SOUND(char reg, char value)
{
    AYREGS[reg] = value;
}


char GetSound(char reg)
{
    return AYREGS[reg];
}


void SetTonePeriod(char channel, unsigned int period)
{
    char reg;
    if (channel > 2) return;
    reg = channel * 2;
    AYREGS[reg++] = period & 0xFF;
    AYREGS[reg]   = (period >> 8) & 0x0F;
}


void SetNoisePeriod(char period)
{
    AYREGS[6] = period & 0x1F;
}


void SetEnvelopePeriod(unsigned int period)
{
    AYREGS[11] = period & 0xFF;
    AYREGS[12] = (period >> 8) & 0xFF;
}


void SetVolume(char channel, char volume)
{
    if (channel > 2) return;
    AYREGS[8 + channel] = volume;
}


void SetChannel(char channel, SWITCHER isTone, SWITCHER isNoise)
{
    char m;
    if (channel > 2) return;
    m = AYREGS[7];
    if (channel == 0) {
        if (isTone  == ON) m &= ~0x01; else m |= 0x01;
        if (isNoise == ON) m &= ~0x08; else m |= 0x08;
    } else if (channel == 1) {
        if (isTone  == ON) m &= ~0x02; else m |= 0x02;
        if (isNoise == ON) m &= ~0x10; else m |= 0x10;
    } else {
        if (isTone  == ON) m &= ~0x04; else m |= 0x04;
        if (isNoise == ON) m &= ~0x20; else m |= 0x20;
    }
    AYREGS[7] = m;
}


void SetEnvelope(char shape)
{
    AYREGS[13] = shape;
}


/* PlayAY pushes the 14-byte buffer to the chip. Register 7 (mixer) reads
   back the chip's current bits 6/7 to preserve the joystick I/O direction
   set up by the OS, then OR's in the player's bits 0..5. Register 13
   (envelope shape) is only emitted when the buffer holds a value with
   bit 7 clear; after emitting, the buffer is set to $FF so subsequent
   PlayAY() calls do not retrigger the envelope on every frame. */
void PlayAY(void) __naked
{
__asm
    push ix

    ld   hl,#_AYREGS

    ; preserve current joystick direction bits in mixer
    ld   a,(#_AYREGS + 7)
    and  #0b00111111
    ld   b,a

    ld   a,#7
    out  (#0xF5),a
    in   a,(#0xF6)
    and  #0b11000000
    or   b
    ld   (#_AYREGS + 7),a

    ; blast registers 0..12 to the chip
    xor  a
    ld   b,#13
    ld   c,#0xF6      ; data port for OUTI
ay_loop:
    out  (#0xF5),a    ; select register A
    inc  a
    outi              ; out (C),(HL); inc HL; dec B  (data port = C = $F6)
    jr   nz,ay_loop

    ; envelope shape (register 13) -- only emit if bit 7 of buffer byte is clear
    ld   a,#13
    out  (#0xF5),a
    ld   a,(hl)       ; AYREGS[13]
    and  a
    jp   m,ay_done    ; bit 7 set -> skip
    out  (c),a        ; C is still $F6
    ld   (hl),#0xFF   ; mark as emitted so it does not retrigger next frame
ay_done:
    pop  ix
    ret
__endasm;
}
