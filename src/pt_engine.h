/* =============================================================================
   pt_engine.h -- shared PTxPlay (Bulba) engine wrapper for both apps.

   Both pt3-player and the tracker need to call into the same asm driver
   (PTxPlay, packed as a separate CODE block on the tape and loaded at
   PTX_ORIGIN_HEX from the Makefile). Before this module each app shipped
   its own byte-identical copies of the four asm thunks, the AY-mute
   helper, and the 60Hz->50Hz tempo divider. Now everything lives here
   and the apps just include this header.

   PTxPlay format byte at SETUP_ADDR (formerly hardcoded $C00A, which broke
   silently when PTX_ORIGIN moved):
     bit 0 = no-loop (set to play once)
     bit 1 = format: 0 = PT3, 1 = PT2
     bits 2-3 = channel allocation (0 = ABC stereo, 1 = ACB)
     bit 7 = (read-only) set when loop point passed
============================================================================= */
#ifndef PT_ENGINE_H
#define PT_ENGINE_H

#include "ptxplay_addrs.h"  /* SETUP_ADDR for the macro below */

/* Thin asm wrappers around PTxPlay's INIT / PLAY / MUTE entry points. SDCC
   uses IX as its frame pointer; PTxPlay clobbers it. The wrappers save and
   restore IX around each call. PTxPlay does not touch IY, which the
   Spectrum reserves for the system-variable pointer. */
extern void PTx_init(unsigned int song_addr) __z88dk_fastcall;
extern void PTx_play(void);
extern void PTx_mute(void);

/* Force AY amplitude register 8/9/10 to zero for a given channel (0..2),
   silencing it without touching PTxPlay's AYREGS shadow. Used for live
   per-channel mute in the player. Called every frame after PTx_play
   for muted channels. */
extern void silence_channel(unsigned char ch) __z88dk_fastcall;

/* TS2068 vsync is 60Hz NTSC, but PT2/PT3 tunes are authored for 50Hz.
   Skip 1 frame in 6 so PTx_play fires 50 times per real second
   (60 * 5/6 = 50). Caller maintains `*divider` (start at 0) and calls
   this exactly once per intrinsic_halt(). Returns nonzero on the frame
   PTx_play actually fired -- handy when the caller wants to skip its
   own per-frame work (mute pokes, viz redraw) on the dropped frame. */
extern unsigned char pt_play_60to50(unsigned char *divider);

/* PTxPlay's setup byte. Read its bit 7 to detect "song looped" without
   peeking other internals. */
#define PTx_setup (*(volatile unsigned char *)SETUP_ADDR)

#endif /* PT_ENGINE_H */
