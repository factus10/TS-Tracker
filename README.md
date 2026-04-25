# TS Tracker

A PT3 music player for the **Timex/Sinclair 2068**, with a tracker UI as the
eventual goal. Built with [z88dk](https://github.com/z88dk/z88dk) (SDCC backend).

Plays Vortex Tracker II `.pt3` modules through the AY-3-8912 on the TS2068's
sound ports (`$F5` register select, `$F6` data) at the TS2068's native 60 Hz
frame rate, with a 6:5 software divider so the tempo matches the original
50 Hz Spectrum 128 reference clock.

## Status

- [x] Phase 1 — PT3 playback (one bundled song)
- [x] Phase 2 — song picker UI (auto-bundles every `.pt3` in `songs/`)
- [ ] Phase 3 — PT2 support
- [ ] Phase 4 — tracker UI (pattern grid, sample/ornament editors, save back to PT3)

## Build

Requires z88dk on the path. The `Makefile` exports `Z88DK_HOME` and `ZCCCFG`
so it works without a shell rc.

```sh
make pt3-player           # build/pt3-player.tap (multi-song picker)
make smoketest            # build/smoketest.tap  (AY sanity check)
make pt3-mvp              # build/pt3-mvp.tap    (single-song MVP)
```

Drop more `.pt3` files into `songs/` and re-run `make pt3-player`; up to 9
entries are selectable by digit keys 1-9. To swap which song the
single-song target plays:

```sh
make pt3-mvp SONG="songs/3BIT - Kenotron - KENO50 (Paradox version).pt3"
```

## Run

The output is a Spectrum-flavoured `.tap` (we target `+zx` because the
upstream PT3 player needs SDCC and the `+ts2068` clib is sccz80-only).
The TS2068 loads it cleanly. In zesarux:

```sh
zesarux --machine ts2068 --tape build/pt3-player.tap
```

Controls in the picker: `1`-`9` to play a song, `SPACE` to stop and return
to the menu, `ENTER` to quit to BASIC.

## Layout

```
src/                    handwritten code
  ay_ts2068.[ch]        AY-3-8912 backend (TS2068 ports $F5/$F6)
  pt3_player.c          picker UI + play loop
  pt3_mvp.c             single-song MVP variant
  smoketest.c           "does the AY make noise" sanity check
  PT3player.[ch]        upstream PT3 player core (sanitised for SDCC CPP)
  PT3player_NoteTable1.h Vortex tone table 1
tools/                  build helpers (.pt3 -> .c, TZX/TAP extractors)
vendor/                 unmodified copies of the upstream libraries
songs/                  bundled .pt3/.pt2/.ay files
build/                  generated artifacts (gitignored)
```

## Credits

The PT3 player core is the **Vortex Tracker II PT3 player** by **S.V. Bulba**,
adapted across many hands:

- **S.V. Bulba** — original ZX Spectrum player
- **Dioniso** — MSX adaptation (Jan 2005)
- **msxKun / Paxanga soft** — MSX ROM arrangements
- **SapphiRe** — asMSX version with PT3 commands and split PLAY/PSG-write
- **mvac7 / 303bcn** — SDCC adaptation

The matching SDCC AY backend (`AY38910BF`) is also by **mvac7**. This
project's `ay_ts2068.c` is a small port of that file, swapping the MSX
ports `$A0`/`$A1`/`$A2` for the TS2068's `$F5`/`$F6`.

Upstream sources (preserved in `vendor/`):

- <https://github.com/mvac7/SDCC_PT3player_Lib>
- <https://github.com/mvac7/SDCC_AY38910BF_Lib>

The TS2068-specific reference notes used while writing this came from a
companion repo of disassemblies and memory maps; nothing from it is shipped
here.
