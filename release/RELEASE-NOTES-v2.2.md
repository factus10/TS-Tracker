# TS Tracker 2.2

A small update to the editor: the arrangement editor no longer clears and repaints the whole screen on every cursor move. Everything else is as in 2.1; the player is unchanged.

**Download `ts-tracker.zip`** below. It contains:

| File | What it is |
| --- | --- |
| `tracker2.tap` | TS Tracker 2, the PT3 song editor |
| `pt3-player.tap` | The playback-only picker (plays PT2 and PT3) |
| `songs.tap` | Six PT2/PT3 chiptunes, one CODE block each |
| `TS-Tracker-2-Manual.pdf` / `.md` | The user manual |
| `README.txt` | Quick start |

Load with `LOAD ""` on a Timex/Sinclair 2068, in an emulator (ZEsarUX, FUSE) or on real hardware via a TS-PICO. At the start screen press **N** for a new song, **S** to scan a song tape, or **P** to browse a TS-PICO's SD card.

## What's changed

**Arrangement editor.** Moving with CAPS+5/6/7/8 used to redraw the entire screen, title and all, every step. Now a move repaints the cell the cursor left, the cell it landed on and the numbers on the info line; only crossing a page boundary repaints the page, and that without clearing the screen first. Typing a pattern number repaints its cell, `L` the two cells whose loop marker changed, and insert, delete and new pattern repaint the page without the clear.

## Verification

The eight automated suites pass on the exact binary in this bundle (see the 2.1 notes for what they cover); the arrangement suite now also reads the screen after cursor moves, the loop key and a page crossing. The program has still not been run on a physical TS2068, and the TS-PICO support in particular awaits that pass.

## Known limitations

As in 2.1: the SD-card browser shows the card's current folder only and its raw-file mode is unverified on hardware; undo covers pattern edits, one level; a PT2 bigger than about 5 K may not leave room for its conversion.

## Credits

The replay driver is Sergey Bulba's PTxPlay. The screen layout follows SQ-Tracker. TS-PICO support is built on Gus Pane's TPI protocol and ROM. TS Tracker is a 64K Software production for the Timex Sinclair 2068.
