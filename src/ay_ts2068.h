/* =============================================================================
   ay_ts2068.h -- AY-3-8912 buffer library for the Timex/Sinclair 2068

   API-compatible with mvac7's SDCC_AY38910BF_Lib (the AY backend that the
   SDCC_PT3player_Lib expects). The PT3 player consumes only `_AYREGS`,
   `_AY_Init`, and `_PlayAY`; the rest of the API is provided so other
   AY-using code keeps working unchanged.

   Original MSX library:  https://github.com/mvac7/SDCC_AY38910BF_Lib
   TS2068 port:           uses I/O ports $F5 (register select) and
                          $F6 (data read/write) per ts2068_memory_map.md.
============================================================================= */
#ifndef AY_TS2068_H
#define AY_TS2068_H

#ifndef _SWITCHER
#define _SWITCHER
typedef enum { OFF = 0, ON = 1 } SWITCHER;
#endif

/* AY register indices (named the same as the upstream library). */
#ifndef AY_REGISTERS
#define AY_REGISTERS
#define AY_ToneA      0   /* channel A tone period (12 bits) */
#define AY_ToneB      2   /* channel B tone period (12 bits) */
#define AY_ToneC      4   /* channel C tone period (12 bits) */
#define AY_Noise      6   /* noise period (5 bits) */
#define AY_Mixer      7   /* mixer + I/O direction */
#define AY_AmpA       8
#define AY_AmpB       9
#define AY_AmpC      10
#define AY_EnvPeriod 11   /* 16 bits (regs 11/12) */
#define AY_EnvShape  13
#endif

#define AY_Channel_A 0
#define AY_Channel_B 1
#define AY_Channel_C 2

/* The TS2068 has a single internal AY-3-8912. AY_TYPE is kept for API
   compatibility with code that expects the MSX library. It is ignored. */
extern char AY_TYPE;
extern char AYREGS[14];

void AY_Init(void);
void SOUND(char reg, char value);
char GetSound(char reg);
void SetTonePeriod(char channel, unsigned int period);
void SetNoisePeriod(char period);
void SetEnvelopePeriod(unsigned int period);
void SetVolume(char channel, char volume);
void SetChannel(char channel, SWITCHER isTone, SWITCHER isNoise);
void SetEnvelope(char shape);
void PlayAY(void);

#endif
